import Foundation

/// A validated route to one Merlin Worker. Only stable platform identifiers
/// cross this boundary; aliases, Pod addresses, signed links, and Grafana URLs
/// remain private implementation details of the provider.
public struct MerlinPlatformMetricsTarget: Equatable, Hashable, Sendable {
    public let devboxSID: String
    public let workerID: String

    public init?(devboxSID: String, workerID: String) {
        guard
            MerlinIdentifierValidator.isDevboxSID(devboxSID),
            MerlinIdentifierValidator.isWorkerID(workerID)
        else { return nil }
        self.devboxSID = devboxSID
        self.workerID = workerID
    }
}

/// Persistence-safe platform telemetry. The raw CLI/Grafana response and its
/// routing variables cannot enter this type.
public struct MerlinPlatformMetricsBatch: Equatable, Sendable {
    public let samples: [WorkerMetricsSample]
    /// Requested Merlin panels that did not contain a usable semantic series
    /// in this response. Grafana occasionally returns lookup-only data on the
    /// first request, so callers should display partial samples and retry.
    public let missingMetrics: Set<GrafanaMetricKind>

    public init(
        samples: [WorkerMetricsSample],
        missingMetrics: Set<GrafanaMetricKind> = []
    ) {
        self.samples = samples.sorted { $0.timestamp < $1.timestamp }
        self.missingMetrics = missingMetrics
    }
}

public enum MerlinPlatformMetricsError: Error, Equatable, Sendable {
    case invalidConcurrencyLimit
    case invalidExecutablePath
    case workerNotFound
    case commandFailed(exitCode: Int32)
    case timedOut
    case transport
    case malformedResponse
    case noData
}

/// Loads official Merlin/Grafana telemetry without entering the Worker over
/// SSH. Panel discovery is semantic and cached by the dashboard UID from the
/// Worker-list URL, so dashboard panel IDs are not a durable dependency.
public actor MerlinPlatformMetricsProvider {
    private let merlinCLIPath: String
    private let discoveryProcessRunner: any InventoryProcessRunning
    private let panelProcessRunner: any InventoryProcessRunning
    private let alignmentTolerance: TimeInterval
    private var catalogCache: [String: CachedCatalog] = [:]
    private var workerCache: [MerlinPlatformMetricsTarget: CachedWorkerDescriptor] = [:]

    public init(maxConcurrentPanelProcesses: Int = 3) throws {
        guard maxConcurrentPanelProcesses > 0 else {
            throw MerlinPlatformMetricsError.invalidConcurrencyLimit
        }
        let merlinCLIPath = try MerlinCLIResolver.resolve()
        let discoveryProcessRunner = TimedInventoryProcessRunner(
            // Grafana dashboard discovery is materially slower than Worker
            // listing in production and has been observed above 40 seconds.
            timeout: .seconds(60),
            underlying: FoundationInventoryProcessRunner()
        )
        let panelProcessRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: maxConcurrentPanelProcesses,
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(60),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        self.merlinCLIPath = merlinCLIPath
        self.discoveryProcessRunner = discoveryProcessRunner
        self.panelProcessRunner = panelProcessRunner
        alignmentTolerance = 10
    }

    init(
        merlinCLIPath: String,
        discoveryProcessRunner: any InventoryProcessRunning,
        panelProcessRunner: any InventoryProcessRunning,
        alignmentTolerance: TimeInterval = 10
    ) throws {
        guard
            merlinCLIPath.hasPrefix("/"),
            !merlinCLIPath.contains(where: { $0.isNewline || $0 == "\0" })
        else {
            throw MerlinPlatformMetricsError.invalidExecutablePath
        }
        self.merlinCLIPath = merlinCLIPath
        self.discoveryProcessRunner = discoveryProcessRunner
        self.panelProcessRunner = panelProcessRunner
        self.alignmentTolerance = max(0, alignmentTolerance)
    }

    public func fetch(
        _ target: MerlinPlatformMetricsTarget,
        metrics requestedSubset: Set<GrafanaMetricKind>? = nil
    ) async throws -> MerlinPlatformMetricsBatch {
        let worker = try await discoverWorker(target)
        let dashboardURL = try Self.fiveMinuteURL(worker.grafanaURL)
        let cacheKey = try Self.dashboardCacheKey(dashboardURL)
        let catalog = try await catalog(
            for: dashboardURL,
            cacheKey: cacheKey
        )
        let supportedMetrics: [GrafanaMetricKind] = worker.gpuCount > 0
            ? [.cpu, .memory, .gpuUtilization, .gpuMemory, .temperature]
            : [.cpu, .memory]
        let requestedMetrics = requestedSubset.map { subset in
            supportedMetrics.filter(subset.contains)
        } ?? supportedMetrics
        let panels = requestedMetrics.compactMap { metric in
            catalog.panel(for: metric).map { (metric, $0) }
        }
        guard !panels.isEmpty else {
            throw MerlinPlatformMetricsError.noData
        }

        let merlinCLIPath = self.merlinCLIPath
        let panelProcessRunner = self.panelProcessRunner
        let outcomes = try await withThrowingTaskGroup(
            of: PanelOutcome.self,
            returning: [PanelOutcome].self
        ) { group in
            for (metric, panel) in panels {
                group.addTask {
                    do {
                        let command = try Self.panelDataCommand(
                            merlinCLIPath: merlinCLIPath,
                            dashboardURL: dashboardURL,
                            panelID: panel.id
                        )
                        let output = try await Self.run(
                            command,
                            using: panelProcessRunner
                        )
                        let series: [GrafanaMetricSeries]
                        do {
                            series = try GrafanaPanelDataParser.parse(output)
                        } catch {
                            throw MerlinPlatformMetricsError.malformedResponse
                        }
                        return .success(metric: metric, series: series)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MerlinPlatformMetricsError {
                        return .failure(error)
                    } catch {
                        return .failure(.transport)
                    }
                }
            }

            var results: [PanelOutcome] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        let successes = outcomes.compactMap(\.success)
        let samples = Self.merge(
            successes,
            worker: worker,
            alignmentTolerance: alignmentTolerance
        )
        let receivedMetrics = Set(successes.compactMap { metric, series in
            Self.hasCompleteMetric(
                metric,
                series: series,
                worker: worker
            ) ? metric : nil
        })
        let missingMetrics = Set(requestedMetrics).subtracting(receivedMetrics)
        if !samples.isEmpty {
            return MerlinPlatformMetricsBatch(
                samples: samples,
                missingMetrics: missingMetrics
            )
        }

        // Empty panels are not authoritative. In production Grafana can return
        // lookup-only data on the first request and real time series on the
        // next one; surface noData so the caller can retry on a short cadence.
        if !successes.isEmpty {
            throw MerlinPlatformMetricsError.noData
        }
        let failures = outcomes.compactMap(\.failure)
        if failures.contains(where: { error in
            switch error {
            case .commandFailed, .malformedResponse:
                true
            default:
                false
            }
        }) {
            invalidateCatalog(catalog)
        }
        if failures.contains(.timedOut) {
            throw MerlinPlatformMetricsError.timedOut
        }
        throw failures.first ?? MerlinPlatformMetricsError.noData
    }

    private func discoverWorker(
        _ target: MerlinPlatformMetricsTarget
    ) async throws -> WorkerDescriptor {
        if
            let cached = workerCache[target],
            cached.expiresAt > Date()
        {
            return cached.worker
        }
        workerCache.removeValue(forKey: target)
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        let expectedSID = "wkr_\(target.workerID)"

        repeat {
            let command: CommandSpec
            do {
                command = try MerlinCommands.listWorkers(
                    merlinCLIPath: merlinCLIPath,
                    instanceSID: target.devboxSID,
                    pageSize: 100,
                    pageToken: pageToken
                )
            } catch {
                throw MerlinPlatformMetricsError.malformedResponse
            }
            let output = try await Self.run(
                command,
                using: discoveryProcessRunner
            )
            let page: WorkerDiscoveryPage
            do {
                page = try WorkerDiscoveryPage.parse(output)
            } catch {
                throw MerlinPlatformMetricsError.malformedResponse
            }
            if let worker = page.workers.first(where: { $0.sid == expectedSID }) {
                guard
                    worker.cpuCores > 0,
                    worker.memoryBytes > 0,
                    worker.gpuCount >= 0,
                    !worker.grafanaURL.isEmpty
                else {
                    throw MerlinPlatformMetricsError.malformedResponse
                }
                workerCache[target] = CachedWorkerDescriptor(
                    worker: worker,
                    expiresAt: Date().addingTimeInterval(2 * 60)
                )
                return worker
            }
            pageToken = page.nextPageToken
            if let pageToken, !seenPageTokens.insert(pageToken).inserted {
                throw MerlinPlatformMetricsError.malformedResponse
            }
        } while pageToken != nil

        throw MerlinPlatformMetricsError.workerNotFound
    }

    private func catalog(
        for dashboardURL: String,
        cacheKey: String
    ) async throws -> GrafanaPanelCatalog {
        if
            let cached = catalogCache[cacheKey],
            cached.expiresAt > Date()
        {
            return cached.catalog
        }
        catalogCache.removeValue(forKey: cacheKey)
        let command = try Self.describeCommand(
            merlinCLIPath: merlinCLIPath,
            dashboardURL: dashboardURL
        )
        let output = try await Self.run(
            command,
            using: discoveryProcessRunner
        )
        let catalog: GrafanaPanelCatalog
        do {
            catalog = try GrafanaDescribeParser.parse(output)
        } catch {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        guard !catalog.availableMetrics.isEmpty else {
            return catalog
        }
        let cached = CachedCatalog(
            catalog: catalog,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        catalogCache[cacheKey] = cached
        for metric in catalog.availableMetrics {
            if
                let uid = catalog.panel(for: metric)?.dashboardUID,
                Self.isSafeDashboardKey(uid)
            {
                catalogCache[uid] = cached
            }
        }
        return catalog
    }

    private func invalidateCatalog(_ catalog: GrafanaPanelCatalog) {
        catalogCache = catalogCache.filter { $0.value.catalog != catalog }
    }

    private static func run(
        _ command: CommandSpec,
        using processRunner: any InventoryProcessRunning
    ) async throws -> String {
        let output: InventoryProcessOutput
        do {
            output = try await processRunner.run(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch InventoryProcessTimeoutError.timedOut {
            throw MerlinPlatformMetricsError.timedOut
        } catch let error as MerlinPlatformMetricsError {
            throw error
        } catch {
            throw MerlinPlatformMetricsError.transport
        }
        guard output.exitCode == 0 else {
            throw MerlinPlatformMetricsError.commandFailed(
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }

    private static func describeCommand(
        merlinCLIPath: String,
        dashboardURL: String
    ) throws -> CommandSpec {
        try grafanaCommand(
            merlinCLIPath: merlinCLIPath,
            arguments: ["grafana", "describe"],
            payload: GrafanaDescribeRequest(url: dashboardURL)
        )
    }

    private static func panelDataCommand(
        merlinCLIPath: String,
        dashboardURL: String,
        panelID: Int
    ) throws -> CommandSpec {
        try grafanaCommand(
            merlinCLIPath: merlinCLIPath,
            arguments: ["grafana", "panel-data"],
            payload: GrafanaPanelDataRequest(
                panelID: panelID,
                url: dashboardURL
            )
        )
    }

    private static func grafanaCommand<Payload: Encodable>(
        merlinCLIPath: String,
        arguments: [String],
        payload: Payload
    ) throws -> CommandSpec {
        guard merlinCLIPath.hasPrefix("/") else {
            throw MerlinPlatformMetricsError.invalidExecutablePath
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let body = String(
                data: try encoder.encode(payload),
                encoding: .utf8
            )
        else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: arguments + [
                "--control-plane", "cn",
                "--json", body,
            ]
        )
    }

    private static func fiveMinuteURL(_ rawURL: String) throws -> String {
        guard
            var components = URLComponents(string: rawURL),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "grafana.byted.org"
        else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll {
            $0.name.caseInsensitiveCompare("from") == .orderedSame
                || $0.name.caseInsensitiveCompare("to") == .orderedSame
        }
        queryItems.append(URLQueryItem(name: "from", value: "now-5m"))
        queryItems.append(URLQueryItem(name: "to", value: "now"))
        components.queryItems = queryItems
        guard let result = components.url?.absoluteString else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        return result
    }

    private static func dashboardCacheKey(_ url: String) throws -> String {
        guard let components = URLComponents(string: url) else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard
            let dashboardMarker = path.firstIndex(of: "d"),
            path.indices.contains(dashboardMarker + 1)
        else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        let key = path[dashboardMarker + 1]
        guard isSafeDashboardKey(key) else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        return key
    }

    private static func isSafeDashboardKey(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9_-]{1,128}$"#,
            options: .regularExpression
        ).map { $0 == value.startIndex..<value.endIndex } ?? false
    }
}

private extension PanelOutcome {
    var success: (GrafanaMetricKind, [GrafanaMetricSeries])? {
        guard case let .success(metric, series) = self else { return nil }
        return (metric, series)
    }

    var failure: MerlinPlatformMetricsError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

private enum PanelOutcome: Sendable {
    case success(metric: GrafanaMetricKind, series: [GrafanaMetricSeries])
    case failure(MerlinPlatformMetricsError)
}

private struct CachedCatalog: Sendable {
    let catalog: GrafanaPanelCatalog
    let expiresAt: Date
}

private struct WorkerDescriptor: Sendable {
    let sid: String
    let cpuCores: Int
    let memoryBytes: UInt64
    let gpuCount: Int
    let grafanaURL: String
}

private struct CachedWorkerDescriptor: Sendable {
    let worker: WorkerDescriptor
    let expiresAt: Date
}

private struct WorkerDiscoveryPage {
    let workers: [WorkerDescriptor]
    let nextPageToken: String?

    static func parse(_ output: String) throws -> WorkerDiscoveryPage {
        guard let data = output.data(using: .utf8) else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        guard payload.responseBase.code == 0 else {
            throw MerlinPlatformMetricsError.malformedResponse
        }
        let workers = payload.data.map {
            WorkerDescriptor(
                sid: $0.sid,
                cpuCores: $0.cpuCores,
                memoryBytes: $0.memoryBytes,
                gpuCount: $0.gpuCount,
                grafanaURL: $0.grafanaURL ?? ""
            )
        }
        let token = payload.pagination?.nextPageToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkerDiscoveryPage(
            workers: workers,
            nextPageToken: token?.isEmpty == false ? token : nil
        )
    }

    private struct Response: Decodable {
        let responseBase: ResponseBase
        let data: [Worker]
        let pagination: Pagination?

        enum CodingKeys: String, CodingKey {
            case responseBase = "ResponseBase"
            case data
            case pagination
        }
    }

    private struct ResponseBase: Decodable {
        let code: Int
    }

    private struct Worker: Decodable {
        let sid: String
        let cpuCores: Int
        let memoryBytes: UInt64
        let gpuCount: Int
        let grafanaURL: String?

        enum CodingKeys: String, CodingKey {
            case sid
            case cpuCores = "cpu_cores"
            case memoryBytes = "memory_bytes"
            case gpuCount = "gpu_count"
            case grafanaURL = "grafana_url"
        }
    }

    private struct Pagination: Decodable {
        let nextPageToken: String?

        enum CodingKeys: String, CodingKey {
            case nextPageToken = "next_page_token"
        }
    }
}

private struct GrafanaDescribeRequest: Encodable {
    let url: String
}

private struct GrafanaPanelDataRequest: Encodable {
    let panelID: Int
    let url: String

    enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case url
    }
}

private extension MerlinPlatformMetricsProvider {
    enum SemanticMetric: Hashable {
        case cpuUsage
        case memoryUsed
        case gpuUtilization(Int)
        case gpuMemoryUsed(Int)
        case gpuMemoryTotal(Int)
        case gpuTemperature(Int)
    }

    struct ReadingIdentity: Hashable {
        let semantic: SemanticMetric
        let metricKind: GrafanaMetricKind
        let seriesIndex: Int
    }

    struct Reading {
        let identity: ReadingIdentity
        let timestamp: Date
        let value: Double
    }

    struct ReadingBucket {
        let anchor: Date
        var timestamp: Date
        var readings: [ReadingIdentity: Reading]

        init(_ reading: Reading) {
            anchor = reading.timestamp
            timestamp = reading.timestamp
            readings = [reading.identity: reading]
        }

        mutating func add(_ reading: Reading) {
            timestamp = max(timestamp, reading.timestamp)
            if
                let existing = readings[reading.identity],
                existing.timestamp > reading.timestamp
            {
                return
            }
            readings[reading.identity] = reading
        }
    }

    struct PartialGPU {
        var utilization: [Double] = []
        var memoryUsed: [Double] = []
        var memoryTotal: [Double] = []
        var temperature: [Double] = []
    }

    static func merge(
        _ panels: [(GrafanaMetricKind, [GrafanaMetricSeries])],
        worker: WorkerDescriptor,
        alignmentTolerance: TimeInterval
    ) -> [WorkerMetricsSample] {
        let gpuIDMap = physicalToLogicalGPUMap(
            panels,
            expectedCount: worker.gpuCount
        )
        var readings: [Reading] = []
        for (metricKind, seriesList) in panels {
            for (seriesIndex, series) in seriesList.enumerated() {
                guard
                    let physicalSemantic = semanticMetric(
                        for: series,
                        panel: metricKind
                    ),
                    let semantic = logicalSemantic(
                        physicalSemantic,
                        gpuIDMap: gpuIDMap
                    )
                else { continue }
                let identity = ReadingIdentity(
                    semantic: semantic,
                    metricKind: metricKind,
                    seriesIndex: seriesIndex
                )
                for point in series.points where point.value.isFinite {
                    readings.append(Reading(
                        identity: identity,
                        timestamp: point.timestamp,
                        value: point.value
                    ))
                }
            }
        }
        readings.sort {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return String(describing: $0.identity.semantic)
                < String(describing: $1.identity.semantic)
        }

        var buckets: [ReadingBucket] = []
        for reading in readings {
            if
                !buckets.isEmpty,
                reading.timestamp.timeIntervalSince(buckets[buckets.count - 1].anchor)
                    <= alignmentTolerance
            {
                buckets[buckets.count - 1].add(reading)
            } else {
                buckets.append(ReadingBucket(reading))
            }
        }

        return buckets.compactMap { bucket in
            sample(from: bucket, worker: worker)
        }
    }

    static func physicalToLogicalGPUMap(
        _ panels: [(GrafanaMetricKind, [GrafanaMetricSeries])],
        expectedCount: Int
    ) -> [Int: Int]? {
        guard expectedCount > 0 else { return [:] }
        let physicalIDs = Set(panels.flatMap { metric, seriesList in
            seriesList.compactMap { series -> Int? in
                guard let semantic = semanticMetric(for: series, panel: metric) else {
                    return nil
                }
                switch semantic {
                case let .gpuUtilization(id),
                     let .gpuMemoryUsed(id),
                     let .gpuMemoryTotal(id),
                     let .gpuTemperature(id):
                    return id
                case .cpuUsage, .memoryUsed:
                    return nil
                }
            }
        })
        guard physicalIDs.count == expectedCount else { return nil }
        return Dictionary(uniqueKeysWithValues: physicalIDs.sorted()
            .enumerated()
            .map { logicalID, physicalID in (physicalID, logicalID) })
    }

    static func logicalSemantic(
        _ semantic: SemanticMetric,
        gpuIDMap: [Int: Int]?
    ) -> SemanticMetric? {
        switch semantic {
        case .cpuUsage, .memoryUsed:
            return semantic
        case let .gpuUtilization(physicalID):
            return gpuIDMap?[physicalID].map(SemanticMetric.gpuUtilization)
        case let .gpuMemoryUsed(physicalID):
            return gpuIDMap?[physicalID].map(SemanticMetric.gpuMemoryUsed)
        case let .gpuMemoryTotal(physicalID):
            return gpuIDMap?[physicalID].map(SemanticMetric.gpuMemoryTotal)
        case let .gpuTemperature(physicalID):
            return gpuIDMap?[physicalID].map(SemanticMetric.gpuTemperature)
        }
    }

    static func semanticMetric(
        for series: GrafanaMetricSeries,
        panel: GrafanaMetricKind
    ) -> SemanticMetric? {
        switch panel {
        case .cpu:
            return series.targetField == "usage" ? .cpuUsage : nil
        case .memory:
            return series.targetField == "used" ? .memoryUsed : nil
        case .gpuUtilization:
            guard
                metric(series.metric, hasAnySuffix: [
                    "gpu_duty_cycle", "gpu_utilization", "gpu_usage",
                ]),
                let gpuID = gpuID(series)
            else { return nil }
            return .gpuUtilization(gpuID)
        case .gpuMemory:
            guard let gpuID = gpuID(series) else { return nil }
            if metric(series.metric, hasAnySuffix: [
                "gpu_mem_used", "gpu_memory_used",
            ]) {
                return .gpuMemoryUsed(gpuID)
            }
            if metric(series.metric, hasAnySuffix: [
                "gpu_mem_total", "gpu_memory_total",
            ]) {
                return .gpuMemoryTotal(gpuID)
            }
            return nil
        case .temperature:
            guard
                metric(series.metric, hasAnySuffix: [
                    "gpu_temperature", "gpu_temp", "gpu_temperature_celsius",
                ]),
                let gpuID = gpuID(series)
            else { return nil }
            return .gpuTemperature(gpuID)
        }
    }

    static func hasCompleteMetric(
        _ metric: GrafanaMetricKind,
        series: [GrafanaMetricSeries],
        worker: WorkerDescriptor
    ) -> Bool {
        let semantics = series.compactMap { item -> SemanticMetric? in
            guard !item.points.isEmpty else { return nil }
            return semanticMetric(for: item, panel: metric)
        }
        switch metric {
        case .cpu:
            return semantics.contains(.cpuUsage)
        case .memory:
            return semantics.contains(.memoryUsed)
        case .gpuUtilization:
            let devices = Set(semantics.compactMap { semantic -> Int? in
                guard case let .gpuUtilization(id) = semantic else { return nil }
                return id
            })
            return worker.gpuCount > 0 && devices.count >= worker.gpuCount
        case .gpuMemory:
            let used = Set(semantics.compactMap { semantic -> Int? in
                guard case let .gpuMemoryUsed(id) = semantic else { return nil }
                return id
            })
            let totals = Set(semantics.compactMap { semantic -> Int? in
                guard case let .gpuMemoryTotal(id) = semantic else { return nil }
                return id
            })
            return worker.gpuCount > 0
                && used.intersection(totals).count >= worker.gpuCount
        case .temperature:
            let devices = Set(semantics.compactMap { semantic -> Int? in
                guard case let .gpuTemperature(id) = semantic else { return nil }
                return id
            })
            return worker.gpuCount > 0 && devices.count >= worker.gpuCount
        }
    }

    static func metric(_ metric: String, hasAnySuffix suffixes: [String]) -> Bool {
        let normalized = metric.lowercased().replacingOccurrences(of: "-", with: "_")
        return suffixes.contains { normalized.hasSuffix($0) }
    }

    static func gpuID(_ series: GrafanaMetricSeries) -> Int? {
        let acceptedKeys: Set<String> = [
            "gpuid", "dockergpuid", "gpu", "device", "deviceid", "index",
        ]
        for (key, value) in series.tags {
            let normalizedKey = key.lowercased().filter {
                $0.isLetter || $0.isNumber
            }
            if
                acceptedKeys.contains(normalizedKey),
                let result = Int(value),
                result >= 0
            {
                return result
            }
        }
        return nil
    }

    static func sample(
        from bucket: ReadingBucket,
        worker: WorkerDescriptor
    ) -> WorkerMetricsSample? {
        var cpuValues: [Double] = []
        var memoryValues: [Double] = []
        var gpuValues: [Int: PartialGPU] = [:]

        for reading in bucket.readings.values {
            switch reading.identity.semantic {
            case .cpuUsage:
                cpuValues.append(reading.value)
            case .memoryUsed:
                memoryValues.append(reading.value)
            case let .gpuUtilization(gpuID):
                gpuValues[gpuID, default: PartialGPU()].utilization.append(
                    reading.value
                )
            case let .gpuMemoryUsed(gpuID):
                gpuValues[gpuID, default: PartialGPU()].memoryUsed.append(
                    reading.value
                )
            case let .gpuMemoryTotal(gpuID):
                gpuValues[gpuID, default: PartialGPU()].memoryTotal.append(
                    reading.value
                )
            case let .gpuTemperature(gpuID):
                gpuValues[gpuID, default: PartialGPU()].temperature.append(
                    reading.value
                )
            }
        }
        guard
            !cpuValues.isEmpty || !memoryValues.isEmpty || !gpuValues.isEmpty
        else { return nil }

        let cpuUtilization = cpuValues.isEmpty
            ? nil
            : percentage(
                used: cpuValues.reduce(0, +),
                total: Double(worker.cpuCores)
            )
        let memoryUsed = memoryValues.isEmpty
            ? nil
            : unsignedInteger(memoryValues.reduce(0, +))
        // IDs were normalized once for the entire fetch before bucketization.
        // Emit the allocation's complete logical namespace at every instant so
        // sparse points cannot create a transient extra GPU or a low total.
        let gpus = (0..<max(0, worker.gpuCount)).map { gpuID in
            let partial = gpuValues[gpuID] ?? PartialGPU()
            return WorkerGPUMetrics(
                index: gpuID,
                utilization: average(partial.utilization).map {
                    min(100, max(0, $0))
                },
                memoryUsedBytes: unsignedInteger(partial.memoryUsed.max()),
                memoryTotalBytes: unsignedInteger(partial.memoryTotal.max()),
                temperatureCelsius: partial.temperature.max(),
                powerWatts: nil,
                powerLimitWatts: nil
            )
        }
        return WorkerMetricsSample(
            timestamp: bucket.timestamp,
            cpuUtilization: cpuUtilization,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: worker.memoryBytes,
            gpus: gpus
        )
    }

    static func percentage(used: Double, total: Double) -> Double? {
        guard used.isFinite, total.isFinite, used >= 0, total > 0 else {
            return nil
        }
        return min(100, max(0, used / total * 100))
    }

    static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let result = values.reduce(0, +) / Double(values.count)
        return result.isFinite ? result : nil
    }

    static func unsignedInteger(_ value: Double?) -> UInt64? {
        guard
            let value,
            value.isFinite,
            value >= 0,
            value <= Double(UInt64.max)
        else { return nil }
        return UInt64(value.rounded())
    }
}
