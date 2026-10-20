import Foundation
import TmuxHubCore

enum HPC2ConnectionState: Equatable {
    case idle
    case loading
    case ready(Date)
    case stale(Date?, String)
}

enum HPC2ConfigurationError: LocalizedError, Equatable {
    case launchInProgress
    case invalidProfile
    case invalidPreset
    case invalidCostRates
    case activeJobs

    var errorDescription: String? {
        switch self {
        case .launchInProgress:
            "正在启动交互环境，请等待提交完成后再保存配置。"
        case .invalidProfile:
            "平台配置无效，请检查显示名称、SSH 登录目标和集群用户名。"
        case .invalidPreset:
            "资源配置无效，请检查环境名称、分区和资源参数。"
        case .invalidCostRates:
            "费用单价必须是有效的非负数。"
        case .activeJobs:
            "当前仍有活动或待确认的 TmuxHub 任务，暂时不能更改 SSH 主机别名或集群用户名。请先结束任务并刷新状态，或恢复原配置。"
        }
    }
}

enum HPC2ManagedRunPhase: String, Codable, Hashable, Sendable {
    case submitting
    case awaitingScheduler
    case active
    case cancellationRequested
    case leftQueue
    case launchOutcomeUnknown
    case launchFailed
    case notFound
}

struct HPC2ManagedRunRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID { receipt.requestID }

    let receipt: SlurmLaunchReceipt
    let preset: SlurmInteractivePreset
    var snapshot: SlurmJobSnapshot?
    var phase: HPC2ManagedRunPhase
    var updatedAt: Date

    init(
        receipt: SlurmLaunchReceipt,
        preset: SlurmInteractivePreset,
        snapshot: SlurmJobSnapshot? = nil,
        phase: HPC2ManagedRunPhase,
        updatedAt: Date = Date()
    ) {
        self.receipt = receipt
        self.preset = preset
        self.snapshot = snapshot
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

@MainActor
final class HPC2PlatformModel: ObservableObject {
    @Published private(set) var profile: SlurmPlatformProfile
    @Published private(set) var defaultPreset: SlurmInteractivePreset
    @Published private(set) var costConfiguration: SlurmCostConfiguration
    @Published private(set) var jobs: [SlurmJobSnapshot] = []
    @Published var historyRange: SlurmHistoryRange = .month
    @Published private(set) var accountingHistory: [SlurmJobHistoryRecord] = []
    @Published private(set) var historyError: String?
    @Published private(set) var historyUpdatedAt: Date?
    @Published private(set) var isRefreshingHistory = false
    @Published private(set) var queueSnapshots: [SlurmQueueSnapshot] = []
    @Published private(set) var queueMonitoringError: String?
    @Published private(set) var queueMonitoringUpdatedAt: Date?
    @Published private(set) var jobUtilization: [SlurmJobID: SlurmJobUtilizationSnapshot] = [:]
    @Published private(set) var isRefreshingMonitoring = false
    @Published private(set) var managedRuns: [HPC2ManagedRunRecord]
    @Published private(set) var connectionState: HPC2ConnectionState = .idle
    @Published private(set) var connectionDiagnostic: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStarting = false
    @Published private(set) var cancellingRequestIDs: Set<UUID> = []
    @Published var notice: String?

    private let service: SlurmService
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let profileKey = "hpc2-platform-profile-v1"
    private let presetKey = "hpc2-interactive-preset-v1"
    private let costConfigurationKey = "hpc2-cost-configuration-v1"
    private let managedRunsKey = "hpc2-managed-runs-v1"
    private let freshnessInterval: TimeInterval = 30
    private let unresolvedLaunchInterval: TimeInterval = 120
    private var isHistoryVisible = false
    private var loadedHistoryRange: SlurmHistoryRange?
    private var lastHistoryAttempt: Date?
    private var lastHistoryAttemptRange: SlurmHistoryRange?
    private var historyRefreshID: UUID?
    private var requestedHistoryRange: SlurmHistoryRange?
    private var lastSuccessfulRefresh: Date?
    private var lastQueueMonitoringAttempt: Date?
    private var lastUtilizationAttempt: Date?
    private var monitoringRefreshID: UUID?
    private let queueMonitoringInterval: TimeInterval = 60
    private let utilizationInterval: TimeInterval = 30

    init(
        service: SlurmService,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.defaults = defaults
        self.now = now

        let decodedProfile: SlurmPlatformProfile? = Self.decode(
            SlurmPlatformProfile.self,
            from: defaults.data(forKey: profileKey)
        )
        let restoredProfile = decodedProfile.flatMap(Self.validProfile)
            ?? Self.makeDefaultProfile()
        profile = restoredProfile

        let decodedPreset: SlurmInteractivePreset? = Self.decode(
            SlurmInteractivePreset.self,
            from: defaults.data(forKey: presetKey)
        )
        defaultPreset = decodedPreset.flatMap(Self.validPreset)
            ?? Self.makeDefaultPreset()

        let decodedCosts = Self.decode(
            SlurmCostConfiguration.self,
            from: defaults.data(forKey: costConfigurationKey)
        )
        costConfiguration = decodedCosts.flatMap { $0.isValid ? $0 : nil } ?? .hkustHPC2

        let decodedRuns: [HPC2ManagedRunRecord] = Self.decode(
            [HPC2ManagedRunRecord].self,
            from: defaults.data(forKey: managedRunsKey)
        ) ?? []
        let restoredRuns = Self.sanitizedRuns(
            decodedRuns,
            platformID: restoredProfile.id
        )
        managedRuns = restoredRuns
        if restoredRuns != decodedRuns,
            let data = try? JSONEncoder().encode(restoredRuns)
        {
            defaults.set(data, forKey: managedRunsKey)
        }
    }

    func saveCostConfiguration(_ configuration: SlurmCostConfiguration) throws {
        guard configuration.isValid else { throw HPC2ConfigurationError.invalidCostRates }
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: costConfigurationKey)
        costConfiguration = configuration
    }

    func costEstimate(for job: SlurmJobSnapshot) -> SlurmCostEstimate? {
        guard let allocation = jobUtilization[job.jobID]?.allocation else { return nil }
        return SlurmCostEstimator.estimate(
            partition: job.partition,
            allocatedCPU: allocation.allocatedCPU,
            allocatedGPU: allocation.allocatedGPU,
            elapsedSeconds: allocation.elapsedSeconds,
            configuration: costConfiguration,
            allocatedResources: allocation.allocatedResources
        )
    }

    func costEstimate(for record: SlurmJobHistoryRecord) -> SlurmCostEstimate? {
        SlurmCostEstimator.estimate(history: record, configuration: costConfiguration)
    }

    var activeJobs: [SlurmJobSnapshot] {
        jobs.filter { !$0.state.isTerminal }
    }

    var pendingJobCount: Int {
        activeJobs.filter { $0.state == .pending }.count
    }

    var runningJobCount: Int {
        activeJobs.filter { $0.state == .running }.count
    }

    var hasLoadedJobs: Bool {
        lastSuccessfulRefresh != nil
    }

    var isShowingCachedJobs: Bool {
        if case .stale = connectionState {
            return hasLoadedJobs
        }
        return false
    }

    var visibleNotice: String? {
        if case let .stale(_, message) = connectionState, notice == message {
            return nil
        }
        return notice
    }

    var unresolvedRuns: [HPC2ManagedRunRecord] {
        let visibleJobIDs = Set(jobs.map(\.jobID))
        return managedRuns.filter { run in
            guard run.snapshot.map({ !visibleJobIDs.contains($0.jobID) }) ?? true else {
                return false
            }
            switch run.phase {
            case .submitting, .awaitingScheduler, .launchOutcomeUnknown:
                return true
            default:
                return false
            }
        }
    }

    var visibleAccountingHistory: [SlurmJobHistoryRecord] {
        guard loadedHistoryRange == historyRange else { return [] }
        // Accounting already contains only finished allocations. An older
        // squeue snapshot or a requeued job with the same numeric ID must not
        // hide a completion confirmed by the accounting database.
        return accountingHistory
    }

    var localOnlyHistoryRuns: [HPC2ManagedRunRecord] {
        let records = visibleAccountingHistory
        return historyRuns.filter { run in
            guard run.receipt.platformID == profile.id,
                run.receipt.owner == profile.owner,
                run.receipt.loginDestination == profile.loginDestination
            else { return false }
            return !records.contains { record in
                Self.matches(run.receipt, job: record.snapshot)
            }
        }
    }

    func setHistoryVisible(_ visible: Bool) {
        isHistoryVisible = visible
    }

    func refreshHistory(force: Bool = false) async {
        let range = historyRange
        let requestedProfile = profile
        let date = now()
        if isRefreshingHistory, requestedHistoryRange == range { return }
        if !force, lastHistoryAttemptRange == range, let lastHistoryAttempt,
            date.timeIntervalSince(lastHistoryAttempt) < 60
        { return }
        let refreshID = UUID()
        historyRefreshID = refreshID
        requestedHistoryRange = range
        isRefreshingHistory = true
        if loadedHistoryRange != range {
            accountingHistory = []
            historyUpdatedAt = nil
            loadedHistoryRange = nil
            lastHistoryAttempt = nil
            lastHistoryAttemptRange = nil
        }
        historyError = nil
        defer {
            if historyRefreshID == refreshID { isRefreshingHistory = false }
        }
        do {
            let records = try await service.jobHistory(on: requestedProfile, range: range)
            guard !Task.isCancelled, profile == requestedProfile,
                historyRange == range, historyRefreshID == refreshID else { return }
            accountingHistory = records
            loadedHistoryRange = range
            historyUpdatedAt = date
            lastHistoryAttempt = date
            lastHistoryAttemptRange = range
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, profile == requestedProfile,
                historyRange == range, historyRefreshID == refreshID else { return }
            lastHistoryAttempt = date
            lastHistoryAttemptRange = range
            if let parseError = error as? SlurmParserError, parseError == .responseTooLarge {
                historyError = "历史记录过多，请缩短查询范围后重试。"
            } else {
                historyError = "无法读取 Slurm 历史：\(error.localizedDescription)"
            }
        }
    }

    var historyRuns: [HPC2ManagedRunRecord] {
        let visibleJobIDs = Set(jobs.map(\.jobID))
        return managedRuns.filter { run in
            switch run.phase {
            case .leftQueue, .launchFailed, .notFound:
                return true
            case .cancellationRequested:
                return run.snapshot.map { !visibleJobIDs.contains($0.jobID) } ?? false
            default:
                return run.snapshot?.state.isTerminal == true
            }
        }
    }

    func run(for job: SlurmJobSnapshot) -> HPC2ManagedRunRecord? {
        managedRuns.first { Self.matches($0.receipt, job: job) }
    }

    func managedJob(for job: SlurmJobSnapshot) -> SlurmManagedJob? {
        guard let run = run(for: job) else { return nil }
        return SlurmManagedJob(receipt: run.receipt, snapshot: job)
    }

    func isCancelling(_ receipt: SlurmLaunchReceipt) -> Bool {
        cancellingRequestIDs.contains(receipt.requestID)
    }

    func refresh(force: Bool = false) async {
        if isRefreshing { return }
        let refreshDate = now()
        if !force, let lastSuccessfulRefresh,
            refreshDate.timeIntervalSince(lastSuccessfulRefresh) < freshnessInterval
        {
            return
        }

        isRefreshing = true
        if lastSuccessfulRefresh == nil { connectionState = .loading }
        defer { isRefreshing = false }
        let requestedProfile = profile
        var jobsAreFresh = false

        do {
            let refreshedJobs = try await service.listJobs(on: requestedProfile)
            guard !Task.isCancelled, profile == requestedProfile else { return }
            jobs = refreshedJobs.sorted(by: Self.jobOrdering)
            jobsAreFresh = true
            reconcileRuns(with: refreshedJobs, at: refreshDate)
            lastSuccessfulRefresh = refreshDate
            connectionDiagnostic = nil
            connectionState = .ready(refreshDate)
            notice = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, profile == requestedProfile else { return }
            if let failure = error as? SlurmServiceError,
                case let .connectionFailed(message) = failure
            {
                connectionDiagnostic = message
                connectionState = .stale(
                    lastSuccessfulRefresh,
                    failure.connectionFailureSummary ?? error.localizedDescription
                )
            } else {
                connectionDiagnostic = nil
                connectionState = .stale(lastSuccessfulRefresh, error.localizedDescription)
            }
        }
        await refreshMonitoring(force: force, on: requestedProfile, jobsAreFresh: jobsAreFresh)
        if isHistoryVisible { await refreshHistory(force: force) }
    }

    private func refreshMonitoring(
        force: Bool,
        on requestedProfile: SlurmPlatformProfile,
        jobsAreFresh: Bool
    ) async {
        guard !Task.isCancelled, profile == requestedProfile, !isRefreshingMonitoring else { return }
        let date = now()
        let refreshQueues = force || lastQueueMonitoringAttempt.map {
            date.timeIntervalSince($0) >= queueMonitoringInterval
        } ?? true
        let refreshUtilization = force || lastUtilizationAttempt.map {
            date.timeIntervalSince($0) >= utilizationInterval
        } ?? true
        guard refreshQueues || refreshUtilization else { return }

        let refreshID = UUID()
        monitoringRefreshID = refreshID
        isRefreshingMonitoring = true
        defer {
            if monitoringRefreshID == refreshID {
                isRefreshingMonitoring = false
                monitoringRefreshID = nil
            }
        }
        if refreshQueues { lastQueueMonitoringAttempt = date }
        if refreshUtilization { lastUtilizationAttempt = date }
        let requestedJobs = activeJobs
        async let queues: Void = refreshQueueResources(
            enabled: refreshQueues, on: requestedProfile, refreshID: refreshID
        )
        async let utilization: Void = refreshJobUtilization(
            enabled: refreshUtilization, on: requestedProfile, jobs: requestedJobs,
            jobsAreFresh: jobsAreFresh, refreshID: refreshID
        )
        _ = await (queues, utilization)
    }

    private func refreshQueueResources(
        enabled: Bool,
        on requestedProfile: SlurmPlatformProfile,
        refreshID: UUID
    ) async {
        guard enabled else { return }
        do {
            let snapshots = try await service.queueResources(on: requestedProfile)
            guard !Task.isCancelled, profile == requestedProfile,
                monitoringRefreshID == refreshID else { return }
            queueSnapshots = snapshots
            queueMonitoringUpdatedAt = now()
            queueMonitoringError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, profile == requestedProfile,
                monitoringRefreshID == refreshID else { return }
            queueMonitoringError = error.localizedDescription
        }
    }

    private func refreshJobUtilization(
        enabled: Bool,
        on requestedProfile: SlurmPlatformProfile,
        jobs requestedJobs: [SlurmJobSnapshot],
        jobsAreFresh: Bool,
        refreshID: UUID
    ) async {
        guard enabled else { return }
        do {
            guard jobsAreFresh else {
                markUtilizationUnavailable(for: requestedJobs, reason: "任务列表刷新失败，利用率未知。")
                return
            }
            let snapshots = requestedJobs.isEmpty ? [:]
                : try await service.jobUtilization(on: requestedProfile, jobs: requestedJobs)
            guard !Task.isCancelled, profile == requestedProfile,
                monitoringRefreshID == refreshID else { return }
            jobUtilization = snapshots
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, profile == requestedProfile,
                monitoringRefreshID == refreshID else { return }
            markUtilizationUnavailable(for: requestedJobs, reason: error.localizedDescription)
        }
    }

    private func markUtilizationUnavailable(for jobs: [SlurmJobSnapshot], reason: String) {
        let sampledAt = now()
        jobUtilization = Dictionary(uniqueKeysWithValues: jobs.map { job in
            (job.jobID, SlurmJobUtilizationSnapshot(
                jobID: job.jobID, allocation: nil, statistics: nil, gpus: nil,
                sampledAt: sampledAt, unavailableReason: reason
            ))
        })
    }

    func refreshContinuously() async {
        await refresh(force: false)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            await refresh(force: false)
        }
    }

    /// Saves only local preferences. Launching, refreshing, and cancelling jobs
    /// remain separate actions; existing launch receipts are never rewritten.
    func saveConfiguration(
        profile proposedProfile: SlurmPlatformProfile,
        preset proposedPreset: SlurmInteractivePreset
    ) throws {
        guard !isStarting else { throw HPC2ConfigurationError.launchInProgress }
        guard let profile = Self.validProfile(proposedProfile) else {
            throw HPC2ConfigurationError.invalidProfile
        }
        guard let preset = Self.validPreset(proposedPreset) else {
            throw HPC2ConfigurationError.invalidPreset
        }
        guard Self.canChangePlatformIdentity(
            from: self.profile,
            to: profile,
            managedRuns: managedRuns
        ) else {
            throw HPC2ConfigurationError.activeJobs
        }

        // Prepare both payloads before changing either the stored or live state.
        let profileData = try JSONEncoder().encode(profile)
        let presetData = try JSONEncoder().encode(preset)
        defaults.set(profileData, forKey: profileKey)
        defaults.set(presetData, forKey: presetKey)

        let identityChanged = self.profile.loginDestination != profile.loginDestination
            || self.profile.owner != profile.owner
        self.profile = profile
        defaultPreset = preset
        if identityChanged {
            jobs = []
            accountingHistory = []
            historyError = nil
            historyUpdatedAt = nil
            loadedHistoryRange = nil
            lastHistoryAttempt = nil
            lastHistoryAttemptRange = nil
            historyRefreshID = nil
            requestedHistoryRange = nil
            isRefreshingHistory = false
            queueSnapshots = []
            queueMonitoringError = nil
            queueMonitoringUpdatedAt = nil
            jobUtilization = [:]
            lastQueueMonitoringAttempt = nil
            lastUtilizationAttempt = nil
            monitoringRefreshID = nil
            isRefreshingMonitoring = false
            lastSuccessfulRefresh = nil
            connectionDiagnostic = nil
            connectionState = .idle
        }
    }

    /// Returns true once a launch was accepted locally. An uncertain SSH result
    /// is also accepted because its durable receipt must be reconciled, not retried.
    func start(
        profile proposedProfile: SlurmPlatformProfile,
        preset proposedPreset: SlurmInteractivePreset
    ) async -> Bool {
        do {
            try saveConfiguration(profile: proposedProfile, preset: proposedPreset)
        } catch {
            notice = error.localizedDescription
            return false
        }
        let profile = self.profile
        let preset = defaultPreset

        let requestID = UUID()
        let requestedAt = now()
        let expectedReceipt: SlurmLaunchReceipt
        do {
            expectedReceipt = try SlurmCommands.launchReceipt(
                platform: profile,
                requestID: requestID,
                requestedAt: requestedAt
            )
        } catch {
            notice = error.localizedDescription
            return false
        }

        upsertRun(HPC2ManagedRunRecord(
            receipt: expectedReceipt,
            preset: preset,
            phase: .submitting,
            updatedAt: requestedAt
        ))
        isStarting = true
        defer { isStarting = false }

        do {
            let receipt = try await service.startInteractive(
                on: profile,
                preset: preset,
                requestID: requestID,
                requestedAt: requestedAt
            )
            updateRun(receipt.requestID) {
                $0 = HPC2ManagedRunRecord(
                    receipt: receipt,
                    preset: preset,
                    snapshot: $0.snapshot,
                    phase: .awaitingScheduler,
                    updatedAt: now()
                )
            }
            guard !Task.isCancelled else { return true }
            notice = nil
            await refresh(force: true)
            return true
        } catch let SlurmServiceError.submissionOutcomeUnknown(receipt) {
            updateRun(receipt.requestID) {
                $0 = HPC2ManagedRunRecord(
                    receipt: receipt,
                    preset: preset,
                    snapshot: $0.snapshot,
                    phase: .launchOutcomeUnknown,
                    updatedAt: now()
                )
            }
            notice = "启动连接在确认前中断。TmuxHub 会按请求编号查询，不会自动重复提交。"
            return true
        } catch is CancellationError {
            updateRun(requestID) {
                $0.phase = .launchOutcomeUnknown
                $0.updatedAt = now()
            }
            notice = "启动结果尚未确认；下次刷新会继续核对。"
            return true
        } catch {
            updateRun(requestID) {
                $0.phase = .launchFailed
                $0.updatedAt = now()
            }
            notice = error.localizedDescription
            return false
        }
    }

    func cancel(_ managedJob: SlurmManagedJob) async {
        let requestID = managedJob.receipt.requestID
        guard run(for: managedJob.snapshot)?.receipt == managedJob.receipt,
            cancellingRequestIDs.insert(requestID).inserted
        else { return }
        defer { cancellingRequestIDs.remove(requestID) }

        do {
            try await service.cancel(managedJob, on: profile)
            guard !Task.isCancelled else { return }
            updateRun(requestID) {
                $0.snapshot = managedJob.snapshot
                $0.phase = .cancellationRequested
                $0.updatedAt = now()
            }
            notice = "已提交任务 \(managedJob.snapshot.jobID.rawValue) 的取消请求。"
            await refresh(force: true)
        } catch is CancellationError {
            return
        } catch {
            notice = error.localizedDescription
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func reconcileRuns(with jobs: [SlurmJobSnapshot], at date: Date) {
        var runs = managedRuns
        for index in runs.indices {
            let matched = jobs.first { Self.matches(runs[index].receipt, job: $0) }
            if let matched {
                runs[index].snapshot = matched
                if runs[index].phase != .cancellationRequested {
                    runs[index].phase = matched.state.isTerminal ? .leftQueue : .active
                }
                runs[index].updatedAt = date
                continue
            }

            if runs[index].snapshot != nil {
                runs[index].phase = .leftQueue
                runs[index].updatedAt = date
                continue
            }

            let age = date.timeIntervalSince(runs[index].receipt.requestedAt)
            if age >= unresolvedLaunchInterval {
                switch runs[index].phase {
                case .submitting, .awaitingScheduler:
                    runs[index].phase = .notFound
                    runs[index].updatedAt = date
                case .launchOutcomeUnknown:
                    // An uncertain mutation remains explicitly uncertain. A
                    // missing queue row is not proof that no job was submitted.
                    break
                default:
                    break
                }
            }
        }
        managedRuns = Self.sortedRuns(runs)
        persistRuns()
    }

    private func upsertRun(_ run: HPC2ManagedRunRecord) {
        if let index = managedRuns.firstIndex(where: { $0.id == run.id }) {
            managedRuns[index] = run
        } else {
            managedRuns.append(run)
        }
        managedRuns = Self.sortedRuns(managedRuns)
        persistRuns()
    }

    private func updateRun(
        _ requestID: UUID,
        update: (inout HPC2ManagedRunRecord) -> Void
    ) {
        guard let index = managedRuns.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        update(&managedRuns[index])
        managedRuns = Self.sortedRuns(managedRuns)
        persistRuns()
    }

    private func persistRuns() {
        if let data = try? JSONEncoder().encode(managedRuns) {
            defaults.set(data, forKey: managedRunsKey)
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data?
    ) -> Value? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func validProfile(
        _ profile: SlurmPlatformProfile
    ) -> SlurmPlatformProfile? {
        guard profile.id == "hkust-hpc2",
            !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            IdentifierValidator.isSSHDestination(profile.loginDestination),
            isSafeIdentifier(profile.owner)
        else { return nil }
        return profile
    }

    private static func validPreset(
        _ preset: SlurmInteractivePreset
    ) -> SlurmInteractivePreset? {
        guard isSafeIdentifier(preset.id),
            !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            preset.name.utf8.count <= 256,
            isSafeIdentifier(preset.partition),
            preset.tasks == 1,
            (1...4_096).contains(preset.cpusPerTask),
            (1...1_073_741_824).contains(preset.memoryMiB),
            (1...31_536_000).contains(preset.wallTime.seconds),
            preset.gpu.map({ (1...1_024).contains($0.count) }) ?? true,
            preset.workingDirectory.map({
                $0.hasPrefix("/") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) ?? true,
            preset.initializationScript.map({
                !$0.isEmpty && $0.utf8.count <= 64 * 1_024 && !$0.contains("\0")
            }) ?? true
        else { return nil }
        if let type = preset.gpu?.type, !isSafeIdentifier(type) { return nil }
        return preset
    }

    static func canChangePlatformIdentity(
        from current: SlurmPlatformProfile,
        to proposed: SlurmPlatformProfile,
        managedRuns: [HPC2ManagedRunRecord]
    ) -> Bool {
        let identityChanged = current.loginDestination != proposed.loginDestination
            || current.owner != proposed.owner
        guard identityChanged else { return true }
        return !managedRuns.contains(where: blocksPlatformIdentityChange)
    }

    static func blocksPlatformIdentityChange(
        _ run: HPC2ManagedRunRecord
    ) -> Bool {
        switch run.phase {
        case .submitting, .awaitingScheduler, .active,
            .cancellationRequested, .launchOutcomeUnknown:
            true
        case .leftQueue, .launchFailed, .notFound:
            false
        }
    }

    static func sanitizedRuns(
        _ runs: [HPC2ManagedRunRecord],
        platformID: String
    ) -> [HPC2ManagedRunRecord] {
        var seen = Set<UUID>()
        return sortedRuns(runs.compactMap { run in
            guard run.receipt.platformID == platformID,
                seen.insert(run.receipt.requestID).inserted,
                validPreset(run.preset) != nil
            else { return nil }

            var restored = run
            if restored.phase == .submitting {
                // The receipt is written before the remote mutation. If the app
                // stopped at this phase, the command may already have reached
                // the login node, so absence from squeue cannot prove failure.
                restored.phase = .launchOutcomeUnknown
            }
            return restored
        })
    }

    private static func matches(
        _ receipt: SlurmLaunchReceipt,
        job: SlurmJobSnapshot
    ) -> Bool {
        job.owner == receipt.owner
            && job.name == receipt.jobName
            && job.comment == receipt.comment
    }

    private static func sortedRuns(
        _ runs: [HPC2ManagedRunRecord]
    ) -> [HPC2ManagedRunRecord] {
        runs.sorted { $0.receipt.requestedAt > $1.receipt.requestedAt }
    }

    private static func jobOrdering(
        _ lhs: SlurmJobSnapshot,
        _ rhs: SlurmJobSnapshot
    ) -> Bool {
        if stateRank(lhs.state) != stateRank(rhs.state) {
            return stateRank(lhs.state) < stateRank(rhs.state)
        }
        return lhs.jobID.rawValue.localizedStandardCompare(rhs.jobID.rawValue)
            == .orderedDescending
    }

    private static func stateRank(_ state: SlurmJobState) -> Int {
        switch state {
        case .running: 0
        case .pending: 1
        case .completing: 2
        default: 3
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || "._:@+-".unicodeScalars.contains($0)
        }
    }

    private static func makeDefaultProfile() -> SlurmPlatformProfile {
        SlurmPlatformProfile(
            id: "hkust-hpc2",
            name: "HKUST HPC2",
            loginDestination: "hpc2",
            owner: "zli760"
        )
    }

    private static func makeDefaultPreset() -> SlurmInteractivePreset {
        SlurmInteractivePreset(
            id: "hpc2-default",
            name: "交互环境",
            partition: "debug",
            tasks: 1,
            cpusPerTask: 4,
            memoryMiB: 16 * 1_024,
            wallTime: SlurmWallTime(seconds: 30 * 60),
            gpu: SlurmGPURequest(count: 1),
            workingDirectory: nil,
            initializationScript: nil
        )
    }
}
