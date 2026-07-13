import Foundation

public enum WarmupReason: Sendable {
    case appLaunch
    case inventoryChange
    case manualRefresh
    case cacheExpiry
    case foregroundSelection
}

public struct TargetWarmupInventory: Equatable, Sendable {
    public let runningDevboxAliases: [String]
    public let workerTargets: [TerminalTarget]

    public init(
        runningDevboxAliases: [String],
        workerTargets: [TerminalTarget]
    ) {
        self.runningDevboxAliases = runningDevboxAliases
        self.workerTargets = workerTargets
    }
}

public struct TargetWarmupUpdate: Equatable, Sendable {
    public let target: TerminalTarget
    public let snapshot: TmuxSessionSnapshot

    public init(target: TerminalTarget, snapshot: TmuxSessionSnapshot) {
        self.target = target
        self.snapshot = snapshot
    }
}

public actor TargetWarmupCoordinator {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct QueuedWarmup: Sendable {
        let target: TerminalTarget
        let generation: UInt64
    }

    private struct InFlightWarmup: Sendable {
        let token: UInt64
        var generation: UInt64
        let task: Task<Void, Never>
    }

    private let sshMasterPool: SSHMasterPool
    private let discovery: TmuxSessionDiscovery
    private let maxConcurrentWorkerWarmups: Int
    private let sleeper: Sleeper
    private var generation: UInt64 = 0
    private var latestInventory: TargetWarmupInventory?
    private var latestUpdate: (@Sendable (TargetWarmupUpdate) -> Void)?
    private var queue: [QueuedWarmup] = []
    private var inFlightTargets: [TerminalTarget: InFlightWarmup] = [:]
    private var nextWarmupToken: UInt64 = 0
    private var mruTargets: [TerminalTarget] = []
    private var preparationTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextPreparationToken: UInt64 = 0
    private var periodicTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false

    public init(
        sshMasterPool: SSHMasterPool,
        discovery: TmuxSessionDiscovery,
        maxConcurrentWorkerWarmups: Int = 2
    ) {
        precondition(maxConcurrentWorkerWarmups > 0)
        self.sshMasterPool = sshMasterPool
        self.discovery = discovery
        self.maxConcurrentWorkerWarmups = maxConcurrentWorkerWarmups
        sleeper = { duration in try await Task.sleep(for: duration) }
    }

    init(
        sshMasterPool: SSHMasterPool,
        discovery: TmuxSessionDiscovery,
        maxConcurrentWorkerWarmups: Int = 2,
        sleeper: @escaping Sleeper
    ) {
        precondition(maxConcurrentWorkerWarmups > 0)
        self.sshMasterPool = sshMasterPool
        self.discovery = discovery
        self.maxConcurrentWorkerWarmups = maxConcurrentWorkerWarmups
        self.sleeper = sleeper
    }

    public func reconcile(
        _ inventory: TargetWarmupInventory,
        reason: WarmupReason,
        onUpdate: @escaping @Sendable (TargetWarmupUpdate) -> Void
    ) async {
        guard !isShuttingDown else { return }
        generation &+= 1
        latestInventory = inventory
        latestUpdate = onUpdate
        startPeriodicRefreshIfNeeded()

        for alias in inventory.runningDevboxAliases {
            let pool = sshMasterPool
            nextPreparationToken &+= 1
            let token = nextPreparationToken
            preparationTasks[token] = Task { [weak self] in
                _ = await pool.prepare(alias: alias, priority: .background)
                await self?.completePreparation(token: token)
            }
        }

        let currentTargets = Set(inventory.workerTargets)
        queue.removeAll { !currentTargets.contains($0.target) }
        let obsoleteTargets = inFlightTargets.keys.filter {
            !currentTargets.contains($0)
        }
        for target in obsoleteTargets {
            guard let obsolete = inFlightTargets.removeValue(forKey: target)
            else { continue }
            obsolete.task.cancel()
            await discovery.cancelRefresh(target: target)
        }
        if case .cacheExpiry = reason {
            // Keep active work distinct so it gets one follow-up, while
            // queued work is adopted by this expiry generation.
            queue = queue.map {
                currentTargets.contains($0.target)
                    ? .init(target: $0.target, generation: generation)
                    : $0
            }
        } else {
            // A newer explicit inventory/manual generation supersedes any
            // queued expiry duplicate and adopts compatible active work.
            queue.removeAll {
                currentTargets.contains($0.target)
                    && inFlightTargets[$0.target] != nil
            }
            for target in currentTargets {
                guard var active = inFlightTargets[target] else { continue }
                active.generation = generation
                inFlightTargets[target] = active
            }
            queue = queue.map {
                currentTargets.contains($0.target)
                    ? .init(target: $0.target, generation: generation)
                    : $0
            }
        }
        var alreadyQueued = Set(queue.map(\.target))
        let indexed = inventory.workerTargets.enumerated().map { ($0, $1) }
        let queuesInFlightTargets: Bool
        if case .cacheExpiry = reason {
            queuesInFlightTargets = true
        } else {
            queuesInFlightTargets = false
        }
        let sortedTargets = indexed.sorted { lhs, rhs in
            let leftRank = mruTargets.firstIndex(of: lhs.1) ?? Int.max
            let rightRank = mruTargets.firstIndex(of: rhs.1) ?? Int.max
            return leftRank == rightRank ? lhs.0 < rhs.0 : leftRank < rightRank
        }.map(\.1)
        for target in sortedTargets
        where !alreadyQueued.contains(target)
            && (inFlightTargets[target] == nil || queuesInFlightTargets)
        {
            queue.append(.init(target: target, generation: generation))
            alreadyQueued.insert(target)
        }
        reorderQueue()
        pumpQueue()
    }

    public func prioritize(_ target: TerminalTarget) {
        mruTargets.removeAll { $0 == target }
        mruTargets.insert(target, at: 0)
        if mruTargets.count > 32 {
            mruTargets.removeLast(mruTargets.count - 32)
        }
        reorderQueue()
        pumpQueue()
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        queue.removeAll()
        periodicTask?.cancel()
        let periodic = periodicTask
        periodicTask = nil

        let preparations = Array(preparationTasks.values)
        preparationTasks.removeAll()
        for task in preparations { task.cancel() }

        let active = inFlightTargets
        inFlightTargets.removeAll()
        for warmup in active.values { warmup.task.cancel() }
        let discovery = discovery
        let cleanup = Task {
            for target in active.keys {
                await discovery.cancelRefresh(target: target)
            }
            if let periodic { await periodic.value }
            for task in preparations { await task.value }
            for warmup in active.values { await warmup.task.value }
        }
        shutdownTask = cleanup
        await cleanup.value
    }

    func preparationTaskCountForTesting() -> Int {
        preparationTasks.count
    }

    private func reorderQueue() {
        queue = queue.enumerated().sorted { lhs, rhs in
            let leftRank = mruTargets.firstIndex(of: lhs.element.target) ?? Int.max
            let rightRank = mruTargets.firstIndex(of: rhs.element.target) ?? Int.max
            return leftRank == rightRank
                ? lhs.offset < rhs.offset
                : leftRank < rightRank
        }.map(\.element)
    }

    private func completePreparation(token: UInt64) {
        preparationTasks[token] = nil
    }

    private func pumpQueue() {
        guard !isShuttingDown else { return }
        while inFlightTargets.count < maxConcurrentWorkerWarmups,
            !queue.isEmpty
        {
            guard let index = queue.firstIndex(where: {
                inFlightTargets[$0.target] == nil
            }) else { return }
            let entry = queue.remove(at: index)
            let discovery = discovery
            nextWarmupToken &+= 1
            let token = nextWarmupToken
            let task = Task { [weak self] in
                let snapshot = await discovery.refresh(
                    target: entry.target,
                    lane: .background
                )
                await self?.completeWarmup(
                    target: entry.target,
                    token: token,
                    snapshot: snapshot
                )
            }
            inFlightTargets[entry.target] = .init(
                token: token,
                generation: entry.generation,
                task: task
            )
        }
    }

    private func completeWarmup(
        target: TerminalTarget,
        token: UInt64,
        snapshot: TmuxSessionSnapshot
    ) {
        guard let active = inFlightTargets[target], active.token == token else {
            return
        }
        inFlightTargets[target] = nil
        guard !isShuttingDown else { return }
        if active.generation == generation,
            latestInventory?.workerTargets.contains(target) == true
        {
            latestUpdate?(.init(target: target, snapshot: snapshot))
        }
        pumpQueue()
    }

    private func startPeriodicRefreshIfNeeded() {
        guard periodicTask == nil else { return }
        let sleeper = sleeper
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper(.seconds(300))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.periodicRefresh()
            }
        }
    }

    private func periodicRefresh() async {
        guard let latestInventory, let latestUpdate else { return }
        await reconcile(
            latestInventory,
            reason: .cacheExpiry,
            onUpdate: latestUpdate
        )
    }
}
