import Foundation

public struct MerlinTaskMetricsRefresh: Equatable, Sendable {
    public let metricsByRunID: [String: MerlinTaskMetrics]
    public let attemptedRoutesByRunID: [String: MerlinTaskMetricRoute]
    public let refreshedAt: Date

    public var attemptedRunIDs: Set<String> {
        Set(attemptedRoutesByRunID.keys)
    }

    public init(
        metricsByRunID: [String: MerlinTaskMetrics],
        attemptedRoutesByRunID: [String: MerlinTaskMetricRoute],
        refreshedAt: Date
    ) {
        self.metricsByRunID = metricsByRunID
        self.attemptedRoutesByRunID = attemptedRoutesByRunID
        self.refreshedAt = refreshedAt
    }

    public func metrics(for run: MerlinTaskRun) -> MerlinTaskMetrics? {
        guard attemptedRoutesByRunID[run.id] == run.metricRoute else {
            return nil
        }
        return metricsByRunID[run.id]
    }
}

public struct MerlinTaskMetricsBatch: Equatable, Sendable {
    public let runs: [MerlinTaskRun]
    public let refreshedAt: Date

    public var runIDs: Set<String> { Set(runs.map(\.id)) }
    public var routesByRunID: [String: MerlinTaskMetricRoute] {
        Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0.metricRoute) })
    }

    init(runs: [MerlinTaskRun], refreshedAt: Date) {
        self.runs = runs
        self.refreshedAt = refreshedAt
    }
}

/// Incrementally loads task telemetry through Merlin's authenticated Grafana
/// OpenAPI. Compatible runs share one GPU and one memory screenshot, keeping
/// task status polling independent from slow dashboard rendering.
public actor MerlinTaskMetricsProvider {
    private let loader: MerlinTaskMetricsLoader
    private let batchSize: Int
    private let minimumRefreshInterval: TimeInterval
    private let failedRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var attemptedAtByRoute: [MerlinTaskMetricRoute: Date] = [:]

    public init(
        batchSize: Int = 12,
        minimumRefreshInterval: TimeInterval = 90,
        failedRefreshInterval: TimeInterval = 30
    ) throws {
        let merlinCLIPath = try MerlinCLIResolver.resolve()
        let runner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 4,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(60),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        let panelDataLoader = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: merlinCLIPath,
            processRunner: runner
        )
        try self.init(
            merlinCLIPath: merlinCLIPath,
            processRunner: runner,
            panelDataLoader: panelDataLoader,
            batchSize: batchSize,
            minimumRefreshInterval: minimumRefreshInterval,
            failedRefreshInterval: failedRefreshInterval,
            now: Date.init
        )
    }

    init(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        panelDataLoader: any MerlinTaskPanelDataLoading,
        batchSize: Int = 12,
        minimumRefreshInterval: TimeInterval,
        failedRefreshInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date
    ) throws {
        guard merlinCLIPath.hasPrefix("/"), batchSize > 0 else {
            throw MerlinInventoryError.invalidRequest
        }
        loader = MerlinTaskMetricsLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            panelDataLoader: panelDataLoader,
            dashboardURLCache: MerlinTaskDashboardURLCache()
        )
        self.batchSize = batchSize
        self.minimumRefreshInterval = max(0, minimumRefreshInterval)
        self.failedRefreshInterval = min(
            self.minimumRefreshInterval,
            max(0, failedRefreshInterval)
        )
        self.now = now
    }

    public func refresh(runs: [MerlinTaskRun]) async -> MerlinTaskMetricsRefresh {
        let batch = makeRefreshBatch(runs: runs)
        return await refresh(batch: batch)
    }

    public func makeRefreshBatch(
        runs: [MerlinTaskRun]
    ) -> MerlinTaskMetricsBatch {
        let refreshDate = now()
        let activeRuns = runs.filter { $0.lifecycle == .active }
        let activeRoutes = Set(activeRuns.map(\.metricRoute))
        attemptedAtByRoute = attemptedAtByRoute.filter {
            activeRoutes.contains($0.key)
        }
        let selected = activeRuns
            .filter { run in
                guard let attemptedAt = attemptedAtByRoute[run.metricRoute] else {
                    return true
                }
                return refreshDate.timeIntervalSince(attemptedAt)
                    >= minimumRefreshInterval
            }
            .sorted { lhs, rhs in
                switch (
                    attemptedAtByRoute[lhs.metricRoute],
                    attemptedAtByRoute[rhs.metricRoute]
                ) {
                case (nil, nil):
                    lhs.createdAtMilliseconds > rhs.createdAtMilliseconds
                case (nil, _):
                    true
                case (_, nil):
                    false
                case let (lhsDate?, rhsDate?):
                    lhsDate == rhsDate
                        ? lhs.createdAtMilliseconds > rhs.createdAtMilliseconds
                        : lhsDate < rhsDate
                }
            }
            .prefix(batchSize)
        let selectedRuns = Array(selected)
        for run in selectedRuns {
            attemptedAtByRoute[run.metricRoute] = refreshDate
        }

        return MerlinTaskMetricsBatch(
            runs: selectedRuns,
            refreshedAt: refreshDate
        )
    }

    public func refresh(
        batch: MerlinTaskMetricsBatch
    ) async -> MerlinTaskMetricsRefresh {
        let loader = self.loader
        let metrics = await loader.load(
            runs: batch.runs,
            endingAt: batch.refreshedAt
        )
        if Task.isCancelled {
            releaseReservation(for: batch)
            return MerlinTaskMetricsRefresh(
                metricsByRunID: [:],
                attemptedRoutesByRunID: batch.routesByRunID,
                refreshedAt: batch.refreshedAt
            )
        }
        let failedRetryOffset = minimumRefreshInterval - failedRefreshInterval
        for run in batch.runs where !Self.isComplete(metrics[run.id], for: run) {
            attemptedAtByRoute[run.metricRoute] = batch.refreshedAt
                .addingTimeInterval(-failedRetryOffset)
        }
        return MerlinTaskMetricsRefresh(
            metricsByRunID: metrics,
            attemptedRoutesByRunID: batch.routesByRunID,
            refreshedAt: batch.refreshedAt
        )
    }

    public func abandon(batch: MerlinTaskMetricsBatch) {
        releaseReservation(for: batch)
    }

    private static func isComplete(
        _ metrics: MerlinTaskMetrics?,
        for run: MerlinTaskRun
    ) -> Bool {
        guard let metrics, metrics.memory != nil else { return false }
        return run.allocatedGPUCount == 0 || metrics.gpu != nil
    }

    private func releaseReservation(for batch: MerlinTaskMetricsBatch) {
        for run in batch.runs
            where attemptedAtByRoute[run.metricRoute] == batch.refreshedAt
        {
            attemptedAtByRoute.removeValue(forKey: run.metricRoute)
        }
    }
}

private struct MerlinTaskMetricsLoader: Sendable {
    private static let supportedDataCenters: Set<String> = [
        "gl", "hj", "hl", "lf", "lq", "wlby", "yg", "yx", "zc",
    ]

    private struct GroupKey: Hashable, Sendable {
        let cluster: String
        let dataCenter: String
        let role: String
    }

    private struct GroupedRuns: Sendable {
        let key: GroupKey
        let runs: [MerlinTaskRun]
    }

    let merlinCLIPath: String
    let processRunner: any InventoryProcessRunning
    let panelDataLoader: any MerlinTaskPanelDataLoading
    let dashboardURLCache: MerlinTaskDashboardURLCache

    func load(
        runs: [MerlinTaskRun],
        endingAt: Date
    ) async -> [String: MerlinTaskMetrics] {
        let grouped = Dictionary(grouping: runs.compactMap { run in
            groupKey(for: run).map { ($0, run) }
        }, by: \.0).map { key, values in
            GroupedRuns(key: key, runs: values.map(\.1))
        }
        let groupedRunIDs = Set(grouped.flatMap { $0.runs.map(\.id) })
        let legacyRuns = runs.filter { !groupedRunIDs.contains($0.id) }
        let groupedMetrics = await withTaskGroup(
            of: [String: MerlinTaskMetrics].self,
            returning: [String: MerlinTaskMetrics].self
        ) { group in
            for groupedRuns in grouped {
                group.addTask {
                    await load(group: groupedRuns, endingAt: endingAt)
                }
            }
            var loaded: [String: MerlinTaskMetrics] = [:]
            for await values in group {
                loaded.merge(values) { _, new in new }
            }
            return loaded
        }
        return await withTaskGroup(
            of: (String, MerlinTaskMetrics?).self,
            returning: [String: MerlinTaskMetrics].self
        ) { group in
            for run in legacyRuns {
                group.addTask {
                    (run.id, await loadLegacy(run: run))
                }
            }
            var loaded = groupedMetrics
            for await (runID, sample) in group {
                if let sample {
                    loaded[runID] = sample
                }
            }
            return loaded
        }
    }

    private func load(
        group: GroupedRuns,
        endingAt: Date
    ) async -> [String: MerlinTaskMetrics] {
        let trialIDs = group.runs.compactMap(\.trialID).sorted()
        let earliestStart = group.runs.compactMap(\.startedAtMilliseconds).min()
        var requests: [MerlinTaskPanelDataRequest] = []
        if
            group.runs.contains(where: { $0.allocatedGPUCount != 0 }),
            let gpuURL = MerlinTaskGrafanaURLBuilder.rolePanelURL(
                cluster: group.key.cluster,
                dataCenter: group.key.dataCenter,
                trialIDs: trialIDs,
                role: group.key.role,
                panel: .gpu,
                startingAtMilliseconds: earliestStart,
                endingAt: endingAt
            )
        {
            requests.append(.init(
                panel: .gpu,
                url: gpuURL,
                seriesCountHint: group.runs.count
            ))
        }
        if let memoryURL = MerlinTaskGrafanaURLBuilder.rolePanelURL(
            cluster: group.key.cluster,
            dataCenter: group.key.dataCenter,
            trialIDs: trialIDs,
            role: group.key.role,
            panel: .memory,
            endingAt: endingAt
        ) {
            requests.append(.init(
                panel: .memory,
                url: memoryURL,
                seriesCountHint: group.runs.count
            ))
        }
        let outputs = await panelDataLoader.load(requests)
        return group.runs.reduce(into: [:]) { metrics, run in
            guard
                let trialID = run.trialID,
                let sample = MerlinTaskMetricsParser.parse(
                    gpuOutput: outputs[.gpu],
                    memoryOutput: outputs[.memory],
                    memoryTotalOverride: run.allocatedMemoryBytes,
                    trialID: trialID
                )
            else { return }
            metrics[run.id] = sample
        }
    }

    private func loadLegacy(run: MerlinTaskRun) async -> MerlinTaskMetrics? {
        guard let dashboardURL = await dashboardURLCache.value(
            for: run.metricRoute,
            load: { await dashboardURL(runID: run.id) }
        ) else {
            return nil
        }
        let role = run.metricRoleName ?? "worker"
        var requests: [MerlinTaskPanelDataRequest] = []
        if run.allocatedGPUCount != 0, let gpuURL =
            MerlinTaskGrafanaURLBuilder.rolePanelURL(
                from: dashboardURL,
                role: role,
                panel: .gpu,
                startingAtMilliseconds: run.startedAtMilliseconds
            )
        {
            requests.append(.init(panel: .gpu, url: gpuURL))
        }
        if let memoryURL = MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: dashboardURL,
            role: role,
            panel: .memory
        ) {
            requests.append(.init(panel: .memory, url: memoryURL))
        }
        let outputs = await panelDataLoader.load(requests)
        return MerlinTaskMetricsParser.parse(
            gpuOutput: outputs[.gpu],
            memoryOutput: outputs[.memory],
            memoryTotalOverride: run.allocatedMemoryBytes
        )
    }

    private func groupKey(for run: MerlinTaskRun) -> GroupKey? {
        guard
            let cluster = run.clusterName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !cluster.isEmpty,
            let dataCenter = run.clusterShortCode,
            Self.supportedDataCenters.contains(dataCenter),
            let trialID = run.trialID,
            let numericTrialID = UInt64(trialID),
            numericTrialID > 0
        else { return nil }
        let role = run.metricRoleName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? "worker"
        guard !role.isEmpty else { return nil }
        return GroupKey(
            cluster: cluster,
            dataCenter: dataCenter,
            role: role
        )
    }

    private func dashboardURL(runID: String) async -> String? {
        let request = JobGrafanaRequest(jobRunID: runID)
        guard
            let command = try? command(
                arguments: ["job", "get-grafana"],
                payload: request
            ),
            let output = await output(for: command),
            let data = output.data(using: .utf8),
            let response = try? JSONDecoder().decode(
                JobGrafanaResponse.self,
                from: data
            )
        else { return nil }
        return response.grafanaURL
    }

    private func output(for command: CommandSpec) async -> String? {
        do {
            let output = try await processRunner.run(command)
            return output.exitCode == 0 ? output.stdout : nil
        } catch {
            return nil
        }
    }

    private func command<Payload: Encodable>(
        arguments: [String],
        payload: Payload
    ) throws -> CommandSpec {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let body = String(data: data, encoding: .utf8) else {
            throw MerlinInventoryError.invalidRequest
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: arguments + [
                "--control-plane", "cn",
                "--json", body,
            ]
        )
    }
}

private actor MerlinTaskDashboardURLCache {
    private var values: [MerlinTaskMetricRoute: String] = [:]

    func value(
        for route: MerlinTaskMetricRoute,
        load: @Sendable () async -> String?
    ) async -> String? {
        if let value = values[route] {
            return value
        }
        guard let value = await load() else { return nil }
        values[route] = value
        return value
    }
}

private struct JobGrafanaRequest: Encodable {
    let jobRunID: String

    enum CodingKeys: String, CodingKey {
        case jobRunID = "job_run_id"
    }
}

private struct JobGrafanaResponse: Decodable {
    let grafanaURL: String

    enum CodingKeys: String, CodingKey {
        case grafanaURL = "grafana_url"
    }
}
