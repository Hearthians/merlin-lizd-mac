import AppKit
import Foundation
import MerlinLizdCore
import SwiftUI

enum SidebarSelection: Hashable {
    case overview
    case allWorkers
    case tasks
    case local
    case devbox(String)
    case worker(devboxSID: String, workerID: String)
}

@MainActor
final class AppModel: ObservableObject {
    private static let inventoryCacheKey = "safe-inventory-snapshot-v1"
    private static let taskCacheKey = "safe-task-snapshot-v2"

    @Published var selection: SidebarSelection = .overview {
        didSet { prioritizeSelection() }
    }
    @Published private(set) var snapshot: InventorySnapshot?
    @Published private(set) var taskSnapshot: MerlinTaskSnapshot?
    @Published private(set) var taskMetricsByRunID: [String: MerlinTaskMetrics] = [:]
    @Published private(set) var taskMetricAttemptedRunIDs: Set<String> = []
    @Published private(set) var taskMetricLoadingRunIDs: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingTasks = false
    @Published private(set) var isRefreshingTaskMetrics = false
    @Published private(set) var taskRefreshFailed = false
    @Published private(set) var isRefreshingWorkers = false
    @Published private(set) var isStartingDevbox = false
    @Published var pendingStartDevbox: DevboxInventory?
    @Published var message: AppMessage?

    private let inventory: MerlinInventory?
    private let taskInventory: MerlinTaskInventory?
    private let taskMetricsProvider: MerlinTaskMetricsProvider?
    private let devboxLifecycle: MerlinDevboxLifecycle?
    private let runtime: MerlinRemoteRuntime
    private let sshAliases: [String]
    private var workerInventoryTask: Task<Void, Never>?
    private var workerInventoryGeneration: UUID?
    private var workerInventoryRescanPending = false
    private var pendingWorkerInventoryForce = false
    private var workerInventoryCache: [String: CachedWorkerInventory] = [:]
    private var taskMetricsRefreshTask: Task<Void, Never>?
    private var taskMetricsRefreshGeneration: UUID?
    private var taskMetricRouteByRunID: [String: MerlinTaskMetricRoute] = [:]
    private var taskMetricAttemptedRouteByRunID: [
        String: MerlinTaskMetricRoute
    ] = [:]
    private var taskMetricLoadingRouteByRunID: [
        String: MerlinTaskMetricRoute
    ] = [:]
    private let workerInventoryCacheLifetime: TimeInterval = 60
    private let failedWorkerRetryDelay: TimeInterval = 15
    private lazy var warmupUpdateRelay = WarmupUpdateRelay(model: self)
    private var hasStarted = false
    init(runtime: MerlinRemoteRuntime) {
        self.runtime = runtime
        sshAliases = SSHConfigCandidates.load()
        do {
            let inventory = try MerlinInventory(
                sshMasterPool: runtime.sshMasterPool,
                maxConcurrentProcesses: 4
            )
            let devboxLifecycle = try MerlinDevboxLifecycle()
            self.inventory = inventory
            self.devboxLifecycle = devboxLifecycle
        } catch {
            inventory = nil
            devboxLifecycle = nil
            message = AppMessage(
                text: Self.inventoryErrorText(error),
                kind: .error
            )
        }
        do {
            taskInventory = try MerlinTaskInventory()
        } catch {
            taskInventory = nil
            taskRefreshFailed = true
        }
        do {
            taskMetricsProvider = try MerlinTaskMetricsProvider()
        } catch {
            taskMetricsProvider = nil
        }
        if let cached = Self.loadCachedInventory() {
            snapshot = cached.snapshot
            seedCaches(from: cached)
        }
        taskSnapshot = Self.loadCachedTaskSnapshot()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if let snapshot {
            scheduleWarmup(for: snapshot, reason: .appLaunch)
        }
    }

    var devboxes: [DevboxInventory] {
        (snapshot?.devboxes ?? []).sorted { lhs, rhs in
            if lhs.devbox.status.isRunning != rhs.devbox.status.isRunning {
                return lhs.devbox.status.isRunning
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(
                rhs.displayName
            ) == .orderedAscending
        }
    }

    var taskPageState: TaskPageState {
        TaskPageState(
            snapshot: taskSnapshot,
            metricsByRunID: taskMetricsByRunID,
            attemptedMetricRunIDs: taskMetricAttemptedRunIDs,
            loadingMetricRunIDs: taskMetricLoadingRunIDs,
            isRefreshingMetrics: isRefreshingTaskMetrics,
            refreshFailed: taskRefreshFailed
        )
    }

    func devbox(sid: String) -> DevboxInventory? {
        snapshot?.devboxes.first { $0.devbox.sid == sid }
    }

    func worker(devboxSID: String, workerID: String) -> (DevboxInventory, WorkerInventoryRecord)? {
        guard
            let devbox = devbox(sid: devboxSID),
            let worker = devbox.workers.first(where: { $0.id == workerID })
        else {
            return nil
        }
        return (devbox, worker)
    }

    func runRefreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            if NSApp.isActive {
                await refresh()
            }
        }
    }

    func refresh(forceReadinessProbe: Bool = false) async {
        async let machineRefresh: Void = refreshMachines(
            forceReadinessProbe: forceReadinessProbe
        )
        async let taskRefresh: Void = refreshTasks()
        _ = await (machineRefresh, taskRefresh)
    }

    private func refreshMachines(forceReadinessProbe: Bool) async {
        guard !isRefreshing, let inventory else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await inventory.refresh(sshAliases: sshAliases)
            let withWorkers = applyingCachedWorkerInventory(to: loaded)
            snapshot = withWorkers
            persistSnapshot()
            scheduleWarmup(
                for: withWorkers,
                reason: forceReadinessProbe ? .manualRefresh : .inventoryChange
            )
            _ = scheduleWorkerInventoryRefreshes(
                for: withWorkers,
                force: forceReadinessProbe
            )
            if message?.kind == .error {
                message = nil
            }
        } catch {
            message = AppMessage(
                text: Self.inventoryErrorText(error),
                kind: .error
            )
        }
    }

    private func refreshTasks() async {
        guard !isRefreshingTasks, let taskInventory else { return }
        isRefreshingTasks = true
        defer { isRefreshingTasks = false }

        do {
            let loaded = try await taskInventory.refresh()
            taskSnapshot = loaded
            taskRefreshFailed = false
            reconcileTaskMetrics(with: loaded)
            persistTaskSnapshot()
            scheduleTaskMetricsRefresh(for: loaded)
        } catch {
            taskRefreshFailed = true
        }
    }

    private func scheduleTaskMetricsRefresh(for snapshot: MerlinTaskSnapshot) {
        guard
            selection == .tasks,
            taskMetricsRefreshTask == nil,
            let taskMetricsProvider
        else { return }
        let generation = UUID()
        taskMetricsRefreshGeneration = generation
        isRefreshingTaskMetrics = true
        taskMetricsRefreshTask = Task { [weak self] in
            let batch = await taskMetricsProvider.makeRefreshBatch(
                runs: snapshot.runs
            )
            guard !Task.isCancelled else {
                await taskMetricsProvider.abandon(batch: batch)
                return
            }
            guard !batch.runs.isEmpty else {
                self?.finishEmptyTaskMetricsBatch(generation: generation)
                return
            }
            self?.beginTaskMetricsBatch(batch, generation: generation)
            let refresh = await taskMetricsProvider.refresh(batch: batch)
            guard !Task.isCancelled else { return }
            self?.applyTaskMetricsRefresh(refresh, generation: generation)
        }
    }

    private func beginTaskMetricsBatch(
        _ batch: MerlinTaskMetricsBatch,
        generation: UUID
    ) {
        guard taskMetricsRefreshGeneration == generation else { return }
        taskMetricLoadingRunIDs = batch.runIDs
        taskMetricLoadingRouteByRunID = batch.routesByRunID
    }

    private func finishEmptyTaskMetricsBatch(generation: UUID) {
        guard taskMetricsRefreshGeneration == generation else { return }
        taskMetricsRefreshTask = nil
        taskMetricsRefreshGeneration = nil
        isRefreshingTaskMetrics = false
        taskMetricLoadingRunIDs = []
        taskMetricLoadingRouteByRunID = [:]
    }

    private func applyTaskMetricsRefresh(
        _ refresh: MerlinTaskMetricsRefresh,
        generation: UUID
    ) {
        guard taskMetricsRefreshGeneration == generation else { return }
        taskMetricsRefreshTask = nil
        taskMetricsRefreshGeneration = nil
        isRefreshingTaskMetrics = false
        taskMetricLoadingRunIDs = []
        taskMetricLoadingRouteByRunID = [:]
        guard let taskSnapshot else { return }
        let visibleRunsByID = Dictionary(
            uniqueKeysWithValues: taskSnapshot.runs.map { ($0.id, $0) }
        )
        let activeRuns = taskSnapshot.runs(in: .active)
        let activeIDs = Set(activeRuns.map(\.id))
        let matchingAttemptedRuns = visibleRunsByID.values.filter {
            refresh.attemptedRoutesByRunID[$0.id] == $0.metricRoute
        }
        let attemptedIDs = Set(matchingAttemptedRuns.map(\.id))
        let acceptedMetricIDs = Set(matchingAttemptedRuns.compactMap { run in
            refresh.metrics(for: run) == nil ? nil : run.id
        })
        let missingIDs = attemptedIDs.intersection(activeIDs).subtracting(
            acceptedMetricIDs
        )
        for runID in missingIDs {
            // A failed refresh must not leave an older reading looking current.
            taskMetricsByRunID.removeValue(forKey: runID)
            taskMetricRouteByRunID.removeValue(forKey: runID)
        }
        for run in matchingAttemptedRuns {
            taskMetricAttemptedRouteByRunID[run.id] = run.metricRoute
            if let metrics = refresh.metrics(for: run) {
                taskMetricsByRunID[run.id] = metrics
                taskMetricRouteByRunID[run.id] = run.metricRoute
            }
        }
        taskMetricAttemptedRunIDs = Set(taskMetricAttemptedRouteByRunID.keys)
        let pendingActiveIDs = activeIDs.subtracting(
            taskMetricAttemptedRunIDs
        )
        if !pendingActiveIDs.isEmpty {
            scheduleTaskMetricsRefresh(for: taskSnapshot)
        }
    }

    private func reconcileTaskMetrics(with snapshot: MerlinTaskSnapshot) {
        let routesByRunID = Dictionary(
            uniqueKeysWithValues: snapshot.runs.map { ($0.id, $0.metricRoute) }
        )
        let visibleIDs = Set(routesByRunID.keys)
        if taskMetricLoadingRouteByRunID.contains(where: {
            routesByRunID[$0.key] != $0.value
        }) {
            cancelTaskMetricsRefresh()
        }
        // Keep the last real sample when a running task reaches a terminal
        // lifecycle. Historical tasks are never backfilled or re-polled.
        taskMetricsByRunID = taskMetricsByRunID.filter {
            taskMetricRouteByRunID[$0.key] == routesByRunID[$0.key]
        }
        taskMetricRouteByRunID = taskMetricRouteByRunID.filter {
            taskMetricsByRunID[$0.key] != nil
        }
        taskMetricAttemptedRouteByRunID = taskMetricAttemptedRouteByRunID.filter {
            $0.value == routesByRunID[$0.key]
        }
        taskMetricAttemptedRunIDs = Set(taskMetricAttemptedRouteByRunID.keys)
        taskMetricLoadingRunIDs.formIntersection(visibleIDs)
    }

    private func cancelTaskMetricsRefresh() {
        taskMetricsRefreshTask?.cancel()
        taskMetricsRefreshTask = nil
        taskMetricsRefreshGeneration = nil
        isRefreshingTaskMetrics = false
        taskMetricLoadingRunIDs = []
        taskMetricLoadingRouteByRunID = [:]
    }

    private func applyingCachedWorkerInventory(
        to incoming: InventorySnapshot
    ) -> InventorySnapshot {
        let currentSIDs = Set(incoming.devboxes.map(\.devbox.sid))
        workerInventoryCache = workerInventoryCache.filter {
            currentSIDs.contains($0.key)
        }

        let devboxes = incoming.devboxes.map { machine in
            let sid = machine.devbox.sid
            guard let cached = workerInventoryCache[sid] else {
                return machine
            }
            // A Devbox route change invalidates Worker-list freshness, but it
            // must not clear safe last-known rows. Direct Worker readiness can
            // survive; relay readiness is reset by route-aware reconciliation.
            let effectiveCache = if machine.sshConnectionTarget == cached.sshAlias {
                cached
            } else {
                cached.invalidated()
            }
            let reconciled = machine.carryingWorkerInventory(
                from: effectiveCache.machine
            )
            workerInventoryCache[sid] = effectiveCache.replacing(
                machine: reconciled
            )
            return reconciled
        }
        return InventorySnapshot(
            devboxes: devboxes,
            refreshedAt: incoming.refreshedAt
        )
    }

    private func scheduleWorkerInventoryRefreshes(
        for snapshot: InventorySnapshot,
        force: Bool
    ) -> Bool {
        // Do not restart an in-flight Merlin Worker query when a timer tick or
        // repeated click arrives; its result will be merged when it completes.
        if workerInventoryTask != nil {
            workerInventoryRescanPending = true
            pendingWorkerInventoryForce = pendingWorkerInventoryForce || force
            return true
        }
        guard let inventory else { return false }

        let now = Date()
        let targets = snapshot.devboxes.compactMap { machine -> WorkerInventoryTarget? in
            if !force,
               let cached = workerInventoryCache[machine.devbox.sid],
               cached.sshAlias == machine.sshConnectionTarget
            {
                switch cached.status {
                case .loaded
                    where now.timeIntervalSince(cached.fetchedAt)
                        < workerInventoryCacheLifetime:
                    return nil
                case .failed
                    where now.timeIntervalSince(cached.attemptedAt)
                        < failedWorkerRetryDelay:
                    return nil
                default:
                    break
                }
            }
            return WorkerInventoryTarget(
                machine: machine,
                sshAlias: machine.sshConnectionTarget
            )
        }
        guard !targets.isEmpty else { return false }

        let generation = UUID()
        workerInventoryGeneration = generation
        isRefreshingWorkers = true
        workerInventoryTask = Task { [weak self, inventory] in
            await withTaskGroup(
                of: (WorkerInventoryTarget, DevboxInventory).self
            ) { group in
                for target in targets {
                    group.addTask {
                        let result = await inventory.loadWorkers(
                            for: target.machine.devbox,
                            sshAlias: target.sshAlias
                        )
                        return (target, result)
                    }
                }
                for await (target, result) in group {
                    guard !Task.isCancelled else { return }
                    self?.applyWorkerInventory(
                        result,
                        target: target,
                        generation: generation
                    )
                }
            }
            self?.finishWorkerInventoryRefreshes(generation: generation)
        }
        return true
    }

    private func applyWorkerInventory(
        _ result: DevboxInventory,
        target: WorkerInventoryTarget,
        generation: UUID
    ) {
        guard workerInventoryGeneration == generation, let current = snapshot else {
            return
        }
        let sid = target.machine.devbox.sid
        guard
            let currentMachine = current.devboxes.first(where: {
                $0.devbox.sid == sid
            }),
            currentMachine.sshConnectionTarget == target.sshAlias
        else {
            return
        }

        let previous = workerInventoryCache[sid]
        let effectiveWorkers: [WorkerInventoryRecord]
        let fetchedAt: Date
        let attemptedAt = Date()
        switch result.workerStatus {
        case .loaded:
            let previousMachine = previous?.machine ?? currentMachine
            let knownWorkers = previousMachine.workers
            var knownGPUTypes: [String: String] = [:]
            for worker in knownWorkers {
                if let gpuType = worker.gpuType {
                    knownGPUTypes[worker.id] = gpuType
                }
            }
            // The Merlin Worker API intentionally supplies status/resources
            // but not every GPU marketing name. Preserve a previously learned
            // name without making the slow SSH list the primary inventory.
            let refreshedWorkers = result.workers.map { worker in
                guard worker.gpuType == nil else { return worker }
                return worker.withGPUType(knownGPUTypes[worker.id])
            }
            let refreshedMachine = DevboxInventory(
                devbox: currentMachine.devbox,
                sshAlias: currentMachine.sshAlias,
                workers: refreshedWorkers,
                workerStatus: result.workerStatus
            )
            effectiveWorkers = refreshedMachine.workersPreservingReadiness(
                from: previousMachine
            )
            fetchedAt = attemptedAt
        case .failed:
            // A transient SSH/mlx failure must never erase the last useful
            // Worker inventory. Keep it stale and retry on the next poll.
            let previousMachine = previous?.machine ?? currentMachine
            let failedMachine = DevboxInventory(
                devbox: currentMachine.devbox,
                sshAlias: currentMachine.sshAlias,
                workers: previousMachine.workers,
                workerStatus: result.workerStatus
            )
            effectiveWorkers = failedMachine.workersPreservingReadiness(
                from: previousMachine
            )
            fetchedAt = previous?.fetchedAt ?? .distantPast
        case .notQueried:
            return
        }
        let effectiveMachine = DevboxInventory(
            devbox: currentMachine.devbox,
            sshAlias: currentMachine.sshAlias,
            workers: effectiveWorkers,
            workerStatus: result.workerStatus
        )
        workerInventoryCache[sid] = CachedWorkerInventory(
            machine: effectiveMachine,
            fetchedAt: fetchedAt,
            attemptedAt: attemptedAt
        )

        let devboxes = current.devboxes.map { machine in
            guard machine.devbox.sid == sid else { return machine }
            return DevboxInventory(
                devbox: machine.devbox,
                sshAlias: machine.sshAlias,
                workers: effectiveWorkers,
                workerStatus: result.workerStatus
            )
        }
        snapshot = InventorySnapshot(
            devboxes: devboxes,
            refreshedAt: current.refreshedAt
        )
        persistSnapshot()
        if result.workerStatus == .loaded, let snapshot {
            scheduleWarmup(for: snapshot, reason: .inventoryChange)
        }
    }

    private func finishWorkerInventoryRefreshes(generation: UUID) {
        guard workerInventoryGeneration == generation else { return }
        workerInventoryGeneration = nil
        workerInventoryTask = nil
        isRefreshingWorkers = false

        let shouldRescan = workerInventoryRescanPending
        let nextForce = pendingWorkerInventoryForce
        workerInventoryRescanPending = false
        pendingWorkerInventoryForce = false

        guard let current = snapshot else { return }
        if shouldRescan {
            let started = scheduleWorkerInventoryRefreshes(
                for: current,
                force: nextForce
            )
            if started { return }
        }
        scheduleWarmup(
            for: current,
            reason: nextForce ? .manualRefresh : .inventoryChange
        )
    }

    private func scheduleWarmup(
        for snapshot: InventorySnapshot,
        reason: WarmupReason
    ) {
        let inventory = TargetWarmupInventory(snapshot: snapshot)
        let relay = warmupUpdateRelay
        runtime.reconcile(inventory, reason: reason) { update in
            relay.submit(update)
        }
    }

    fileprivate func applyWarmupUpdate(_ update: TargetWarmupUpdate) {
        guard
            case let .worker(devboxSID, _, _, _) = update.target,
            let current = snapshot,
            let updated = current.applyingWarmupUpdate(update),
            let currentMachine = current.devboxes.first(where: {
                $0.devbox.sid == devboxSID
            }),
            let updatedMachine = updated.devboxes.first(where: {
                $0.devbox.sid == devboxSID
            })
        else {
            return
        }

        if
            let cached = workerInventoryCache[devboxSID],
            cached.sshAlias == currentMachine.sshConnectionTarget
        {
            let candidate = DevboxInventory(
                devbox: updatedMachine.devbox,
                sshAlias: updatedMachine.sshAlias,
                workers: cached.workers,
                workerStatus: cached.status
            )
            let reconciled = DevboxInventory(
                devbox: candidate.devbox,
                sshAlias: candidate.sshAlias,
                workers: candidate.workersPreservingReadiness(
                    from: updatedMachine
                ),
                workerStatus: candidate.workerStatus
            )
            workerInventoryCache[devboxSID] = CachedWorkerInventory(
                machine: reconciled,
                fetchedAt: cached.fetchedAt,
                attemptedAt: cached.attemptedAt
            )
        }

        snapshot = updated
        persistSnapshot()
    }

    private func prioritizeSelection() {
        if selection == .tasks {
            if let taskSnapshot {
                scheduleTaskMetricsRefresh(for: taskSnapshot)
            }
        } else {
            cancelTaskMetricsRefresh()
        }
        let target: TerminalTarget?
        switch selection {
        case .overview, .allWorkers, .tasks:
            target = nil
        case .local:
            target = .local
        case let .devbox(sid):
            guard
                let machine = devbox(sid: sid),
                let alias = machine.sshConnectionTarget
            else {
                return
            }
            target = .devbox(
                sid: sid,
                name: machine.devbox.name,
                alias: alias
            )
        case let .worker(devboxSID, workerID):
            guard let (machine, worker) = worker(
                devboxSID: devboxSID,
                workerID: workerID
            ), let workerTarget = machine.workerTerminalTarget(
                for: worker
            ) else {
                return
            }
            target = workerTarget
        }
        guard let target else { return }
        runtime.prioritize(target)
    }

    private func seedCaches(from cached: PersistedInventoryCache) {
        for machine in cached.snapshot.devboxes {
            if machine.workerStatus != .notQueried {
                let seededMachine = DevboxInventory(
                    devbox: machine.devbox,
                    sshAlias: machine.sshAlias,
                    workers: machine.workers.map {
                        $0.withReadiness(.listed)
                    },
                    workerStatus: machine.workerStatus
                )
                workerInventoryCache[machine.devbox.sid] = CachedWorkerInventory(
                    machine: seededMachine,
                    fetchedAt: cached.workerFetchedAtBySID[
                        machine.devbox.sid
                    ] ?? .distantPast,
                    attemptedAt: .distantPast
                )
            }
        }
    }

    private static func loadCachedInventory() -> PersistedInventoryCache? {
        guard let data = UserDefaults.standard.data(forKey: inventoryCacheKey) else {
            return nil
        }
        if let cache = try? JSONDecoder().decode(
            PersistedInventoryCache.self,
            from: data
        ) {
            return cache
        }
        // Compatibility with the original snapshot-only format. Its Worker
        // timestamps are unknown, so refresh them instead of making them fresh.
        guard let snapshot = try? JSONDecoder().decode(
            InventorySnapshot.self,
            from: data
        ) else {
            return nil
        }
        return PersistedInventoryCache(
            snapshot: snapshot,
            workerFetchedAtBySID: [:],
            readinessProbedAtByKey: [:]
        )
    }

    private static func loadCachedTaskSnapshot() -> MerlinTaskSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: taskCacheKey) else {
            return nil
        }
        return try? JSONDecoder().decode(MerlinTaskSnapshot.self, from: data)
    }

    private func persistSnapshot() {
        guard let snapshot else { return }
        let persisted = PersistedInventoryCache(
            snapshot: snapshot,
            workerFetchedAtBySID: workerInventoryCache.mapValues(\.fetchedAt),
            readinessProbedAtByKey: [:]
        )
        guard let data = try? JSONEncoder().encode(persisted) else {
            return
        }
        // InventorySnapshot contains only the explicit safe projection: never
        // Pod IPs, webshell URLs, ProxyCommand text, credentials, or raw output.
        UserDefaults.standard.set(data, forKey: Self.inventoryCacheKey)
    }

    private func persistTaskSnapshot() {
        guard
            let taskSnapshot,
            let data = try? JSONEncoder().encode(taskSnapshot)
        else {
            return
        }
        // MerlinTaskSnapshot contains only the safe task projection: identity,
        // display/status timestamps, and runtime. Raw CLI metadata,
        // Grafana routes, queries, and credentials are never cached.
        UserDefaults.standard.set(data, forKey: Self.taskCacheKey)
    }

    func requestStart(_ machine: DevboxInventory) {
        guard machine.devbox.status.isStopped else { return }
        pendingStartDevbox = machine
    }

    func startPendingDevbox() async {
        guard let machine = pendingStartDevbox else { return }
        pendingStartDevbox = nil
        isStartingDevbox = true
        defer { isStartingDevbox = false }

        do {
            guard let devboxLifecycle else {
                throw MerlinInventoryError.merlinCLINotFound
            }
            let exitCode = try await devboxLifecycle.start(sid: machine.devbox.sid)
            guard exitCode == 0 else {
                message = AppMessage(
                    text: "启动请求失败（退出码 \(exitCode)）。",
                    kind: .error
                )
                return
            }
            message = AppMessage(
                text: "已提交 \(machine.displayName) 的启动请求。",
                kind: .info
            )
            await refresh()
        } catch {
            message = AppMessage(text: "无法提交启动请求。", kind: .error)
        }
    }

    private static func inventoryErrorText(_ error: Error) -> String {
        switch error {
        case MerlinInventoryError.merlinCLINotFound:
            "未找到 ~/.merlin-cli/bin/merlin-cli，请先安装并登录 Merlin CLI。"
        case MerlinInventoryError.commandFailed(let exitCode):
            "Merlin 状态刷新失败（退出码 \(exitCode)）。"
        default:
            "暂时无法刷新 Merlin 状态，请检查登录与网络连接。"
        }
    }
}

private struct WorkerProbeKey: Codable, Hashable, Sendable {
    let devboxSID: String
    let workerID: String
}

private struct WorkerInventoryTarget: Sendable {
    let machine: DevboxInventory
    let sshAlias: String?
}

private struct CachedWorkerInventory: Sendable {
    let machine: DevboxInventory
    let fetchedAt: Date
    let attemptedAt: Date

    var sshAlias: String? { machine.sshConnectionTarget }
    var workers: [WorkerInventoryRecord] { machine.workers }
    var status: WorkerInventoryStatus { machine.workerStatus }

    func invalidated() -> CachedWorkerInventory {
        CachedWorkerInventory(
            machine: machine,
            fetchedAt: .distantPast,
            attemptedAt: .distantPast
        )
    }

    func replacing(machine: DevboxInventory) -> CachedWorkerInventory {
        CachedWorkerInventory(
            machine: machine,
            fetchedAt: fetchedAt,
            attemptedAt: attemptedAt
        )
    }
}

private struct PersistedInventoryCache: Codable {
    let snapshot: InventorySnapshot
    let workerFetchedAtBySID: [String: Date]
    let readinessProbedAtByKey: [WorkerProbeKey: Date]
}

struct AppMessage: Equatable {
    enum Kind: Equatable {
        case info
        case warning
        case error
    }

    let text: String
    let kind: Kind
}

@MainActor
private final class WarmupUpdateRelay: @unchecked Sendable {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    nonisolated func submit(_ update: TargetWarmupUpdate) {
        Task { @MainActor [weak self] in
            self?.model?.applyWarmupUpdate(update)
        }
    }
}

private enum SSHConfigCandidates {
    private static let knownAliases = [
        "hl_gpu_2", "lq_gpu", "hl_gpu", "hl_lq_nas",
    ]

    static func load() -> [String] {
        var aliases = Set(knownAliases)
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        if let contents = try? String(contentsOf: configURL, encoding: .utf8) {
            for rawLine in contents.split(whereSeparator: \Character.isNewline) {
                let line = rawLine.split(separator: "#", maxSplits: 1).first ?? rawLine
                let fields = line.split(whereSeparator: \Character.isWhitespace)
                guard fields.first?.lowercased() == "host" else { continue }
                for candidate in fields.dropFirst() {
                    let value = String(candidate)
                    guard
                        !value.contains(where: { "*?!".contains($0) }),
                        MerlinIdentifierValidator.isSSHAlias(value)
                    else {
                        continue
                    }
                    aliases.insert(value)
                }
            }
        }
        return aliases.sorted()
    }
}
