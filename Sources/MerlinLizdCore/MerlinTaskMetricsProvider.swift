import Foundation

public struct MerlinTaskMetricsRefresh: Equatable, Sendable {
    public let metricsByRunID: [String: MerlinTaskMetrics]
    public let attemptedRunIDs: Set<String>
    public let refreshedAt: Date

    public init(
        metricsByRunID: [String: MerlinTaskMetrics],
        attemptedRunIDs: Set<String>,
        refreshedAt: Date
    ) {
        self.metricsByRunID = metricsByRunID
        self.attemptedRunIDs = attemptedRunIDs
        self.refreshedAt = refreshedAt
    }
}

/// Incrementally loads task telemetry through Merlin's official Grafana
/// commands. Each refresh touches only a small batch so task status polling is
/// never held behind slow dashboard rendering.
public actor MerlinTaskMetricsProvider {
    private let loader: MerlinTaskMetricsLoader
    private let batchSize: Int
    private let minimumRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var attemptedAtByRunID: [String: Date] = [:]

    public init(
        batchSize: Int = 2,
        minimumRefreshInterval: TimeInterval = 90
    ) throws {
        let merlinCLIPath = try MerlinCLIResolver.resolve()
        let runner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 4,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(60),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        try self.init(
            merlinCLIPath: merlinCLIPath,
            processRunner: runner,
            batchSize: batchSize,
            minimumRefreshInterval: minimumRefreshInterval,
            now: Date.init
        )
    }

    init(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        batchSize: Int,
        minimumRefreshInterval: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) throws {
        guard merlinCLIPath.hasPrefix("/"), batchSize > 0 else {
            throw MerlinInventoryError.invalidRequest
        }
        let panelCatalog = MerlinTaskPanelCatalog(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            now: now
        )
        loader = MerlinTaskMetricsLoader(
            merlinCLIPath: merlinCLIPath,
            processRunner: processRunner,
            panelCatalog: panelCatalog
        )
        self.batchSize = batchSize
        self.minimumRefreshInterval = max(0, minimumRefreshInterval)
        self.now = now
    }

    public func refresh(runs: [MerlinTaskRun]) async -> MerlinTaskMetricsRefresh {
        let refreshDate = now()
        let activeRuns = runs.filter { $0.lifecycle == .active }
        let activeIDs = Set(activeRuns.map(\.id))
        attemptedAtByRunID = attemptedAtByRunID.filter {
            activeIDs.contains($0.key)
        }
        let selected = activeRuns
            .filter { run in
                guard let attemptedAt = attemptedAtByRunID[run.id] else {
                    return true
                }
                return refreshDate.timeIntervalSince(attemptedAt)
                    >= minimumRefreshInterval
            }
            .sorted { lhs, rhs in
                switch (
                    attemptedAtByRunID[lhs.id],
                    attemptedAtByRunID[rhs.id]
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
        let attemptedIDs = Set(selected.map(\.id))
        for id in attemptedIDs {
            attemptedAtByRunID[id] = refreshDate
        }

        let loader = self.loader
        let metrics = await withTaskGroup(
            of: (String, MerlinTaskMetrics?).self,
            returning: [String: MerlinTaskMetrics].self
        ) { group in
            for run in selected {
                group.addTask {
                    (run.id, await loader.load(runID: run.id))
                }
            }
            var loaded: [String: MerlinTaskMetrics] = [:]
            for await (runID, sample) in group {
                if let sample {
                    loaded[runID] = sample
                }
            }
            return loaded
        }
        return MerlinTaskMetricsRefresh(
            metricsByRunID: metrics,
            attemptedRunIDs: attemptedIDs,
            refreshedAt: refreshDate
        )
    }
}

private struct MerlinTaskMetricsLoader: Sendable {
    let merlinCLIPath: String
    let processRunner: any InventoryProcessRunning
    let panelCatalog: MerlinTaskPanelCatalog

    func load(runID: String) async -> MerlinTaskMetrics? {
        guard let dashboardURL = await dashboardURL(runID: runID) else {
            return nil
        }
        guard let panelIDs = await panelCatalog.panels(for: dashboardURL) else {
            return nil
        }
        async let gpuOutput = panelOutput(
            dashboardURL: dashboardURL,
            panelID: panelIDs.gpu
        )
        async let memoryOutput = panelOutput(
            dashboardURL: dashboardURL,
            panelID: panelIDs.memory
        )
        return await MerlinTaskMetricsParser.parse(
            gpuOutput: gpuOutput,
            memoryOutput: memoryOutput
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
        return fiveMinuteURL(response.grafanaURL)
    }

    private func panelOutput(
        dashboardURL: String,
        panelID: Int?
    ) async -> String? {
        guard let panelID else { return nil }
        guard let command = try? command(
            arguments: ["grafana", "panel-data"],
            payload: GrafanaPanelRequest(
                panelID: panelID,
                url: dashboardURL
            )
        ) else { return nil }
        return await output(for: command)
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

    private func fiveMinuteURL(_ rawURL: String) -> String? {
        guard
            var components = URLComponents(string: rawURL),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "grafana.byted.org"
        else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll {
            $0.name.caseInsensitiveCompare("from") == .orderedSame
                || $0.name.caseInsensitiveCompare("to") == .orderedSame
        }
        queryItems.append(URLQueryItem(name: "from", value: "now-5m"))
        queryItems.append(URLQueryItem(name: "to", value: "now"))
        components.queryItems = queryItems
        return components.url?.absoluteString
    }
}

private struct MerlinTaskPanelIDs: Sendable {
    let gpu: Int?
    let memory: Int?

    var hasAnyPanel: Bool { gpu != nil || memory != nil }
}

/// Dashboard panel identifiers are an implementation detail of Grafana. Keep
/// one semantic catalog per dashboard UID and coalesce concurrent discovery
/// when several task rows share the same dashboard definition.
private actor MerlinTaskPanelCatalog {
    private struct Discovery {
        let generation: UUID
        let task: Task<Void, Never>
        var waiters: [
            UUID: CheckedContinuation<MerlinTaskPanelIDs?, Never>
        ]
    }

    private static let cacheLifetime: TimeInterval = 5 * 60

    private let merlinCLIPath: String
    private let processRunner: any InventoryProcessRunning
    private let now: @Sendable () -> Date
    private var cached: [String: CachedMerlinTaskPanelIDs] = [:]
    private var inFlight: [String: Discovery] = [:]

    init(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        now: @escaping @Sendable () -> Date
    ) {
        self.merlinCLIPath = merlinCLIPath
        self.processRunner = processRunner
        self.now = now
    }

    func panels(for dashboardURL: String) async -> MerlinTaskPanelIDs? {
        guard let key = Self.dashboardKey(dashboardURL) else { return nil }
        if let entry = cached[key], entry.expiresAt > now() {
            return entry.panelIDs.hasAnyPanel ? entry.panelIDs : nil
        }
        cached[key] = nil
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    addWaiter(
                        waiterID,
                        continuation: continuation,
                        dashboardKey: key,
                        dashboardURL: dashboardURL
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    dashboardKey: key
                )
            }
        }
    }

    private func addWaiter(
        _ waiterID: UUID,
        continuation: CheckedContinuation<MerlinTaskPanelIDs?, Never>,
        dashboardKey: String,
        dashboardURL: String
    ) {
        if var discovery = inFlight[dashboardKey] {
            discovery.waiters[waiterID] = continuation
            inFlight[dashboardKey] = discovery
            return
        }

        let merlinCLIPath = self.merlinCLIPath
        let processRunner = self.processRunner
        let generation = UUID()
        let task = Task {
            let result = await Self.load(
                dashboardURL: dashboardURL,
                merlinCLIPath: merlinCLIPath,
                processRunner: processRunner
            )
            self.completeDiscovery(
                result,
                dashboardKey: dashboardKey,
                generation: generation
            )
        }
        inFlight[dashboardKey] = Discovery(
            generation: generation,
            task: task,
            waiters: [waiterID: continuation]
        )
    }

    private func completeDiscovery(
        _ result: MerlinTaskPanelIDs?,
        dashboardKey: String,
        generation: UUID
    ) {
        guard inFlight[dashboardKey]?.generation == generation else {
            return
        }
        guard let discovery = inFlight.removeValue(forKey: dashboardKey) else {
            return
        }
        if let result {
            cached[dashboardKey] = CachedMerlinTaskPanelIDs(
                panelIDs: result,
                expiresAt: now().addingTimeInterval(Self.cacheLifetime)
            )
        }
        let visibleResult = result?.hasAnyPanel == true ? result : nil
        for continuation in discovery.waiters.values {
            continuation.resume(returning: visibleResult)
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        dashboardKey: String
    ) {
        guard
            var discovery = inFlight[dashboardKey],
            let continuation = discovery.waiters.removeValue(
                forKey: waiterID
            )
        else { return }
        continuation.resume(returning: nil)
        if discovery.waiters.isEmpty {
            discovery.task.cancel()
            inFlight[dashboardKey] = nil
        } else {
            inFlight[dashboardKey] = discovery
        }
    }

    private static func load(
        dashboardURL: String,
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning
    ) async -> MerlinTaskPanelIDs? {
        let commandSpec: CommandSpec
        do {
            commandSpec = try command(
                merlinCLIPath: merlinCLIPath,
                dashboardURL: dashboardURL
            )
        } catch {
            return nil
        }
        guard
            let output = try? await processRunner.run(commandSpec),
            output.exitCode == 0,
            let catalog = try? GrafanaDescribeParser.parse(output.stdout)
        else { return nil }
        return MerlinTaskPanelIDs(
            gpu: catalog.panel(for: .gpuUtilization)?.id,
            memory: catalog.panel(for: .memory)?.id
        )
    }

    private static func command(
        merlinCLIPath: String,
        dashboardURL: String
    ) throws -> CommandSpec {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            GrafanaDescribeRequest(url: dashboardURL)
        )
        guard let body = String(data: data, encoding: .utf8) else {
            throw MerlinInventoryError.invalidRequest
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: [
                "grafana", "describe",
                "--control-plane", "cn",
                "--json", body,
            ]
        )
    }

    private static func dashboardKey(_ rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard
            let marker = path.firstIndex(of: "d"),
            path.indices.contains(marker + 1)
        else { return nil }
        let key = path[marker + 1]
        guard key.count <= 128, !key.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-"))
        return key.unicodeScalars.allSatisfy(allowed.contains) ? key : nil
    }
}

private struct CachedMerlinTaskPanelIDs: Sendable {
    let panelIDs: MerlinTaskPanelIDs
    let expiresAt: Date
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

private struct GrafanaPanelRequest: Encodable {
    let panelID: Int
    let url: String

    enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case url
    }
}

private struct GrafanaDescribeRequest: Encodable {
    let url: String
}
