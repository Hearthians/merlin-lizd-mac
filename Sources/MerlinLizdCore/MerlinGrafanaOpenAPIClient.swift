import Foundation

struct MerlinTaskPanelDataRequest: Hashable, Sendable {
    let panel: MerlinTaskMetricPanel
    let url: URL
    let seriesCountHint: Int

    init(
        panel: MerlinTaskMetricPanel,
        url: URL,
        seriesCountHint: Int = 1
    ) {
        self.panel = panel
        self.url = url
        self.seriesCountHint = max(1, seriesCountHint)
    }
}

protocol MerlinTaskPanelDataLoading: Sendable {
    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) async -> [MerlinTaskMetricPanel: String]
}

struct MerlinHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol MerlinHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> MerlinHTTPResponse
}

final class URLSessionMerlinHTTPDataLoader: MerlinHTTPDataLoading,
    @unchecked Sendable
{
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(for request: URLRequest) async throws -> MerlinHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MerlinGrafanaOpenAPIError.invalidResponse
        }
        return MerlinHTTPResponse(
            data: data,
            statusCode: response.statusCode
        )
    }
}

/// Fetches documented Grafana panel screenshots and normalizes their current
/// legend values locally. The JWT remains memory-only and is sent as an HTTP
/// header, never as a subprocess argument or persisted task state.
actor MerlinGrafanaOpenAPIClient: MerlinTaskPanelDataLoading {
    private struct CachedToken: Sendable {
        let value: String
        let validUntil: Date
    }

    private struct TokenResponse: Decodable {
        let jwtToken: String
        let success: Bool?

        enum CodingKeys: String, CodingKey {
            case jwtToken = "jwt_token"
            case success
        }
    }

    private struct TokenClaims: Decodable {
        let expiration: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case expiration = "exp"
        }
    }

    private struct PanelRequestBody: Encodable {
        let url: String
        let width: Int
        let height: Int
        let deviceScaleFactor = 1.0

        init(request: MerlinTaskPanelDataRequest) {
            url = request.url.absoluteString
            width = 1_200
            height = switch request.panel {
            case .gpu:
                min(1_600, 600 + max(0, request.seriesCountHint - 2) * 45)
            case .memory:
                min(2_800, 900 + max(0, request.seriesCountHint - 1) * 110)
            }
        }

        enum CodingKeys: String, CodingKey {
            case url
            case width
            case height
            case deviceScaleFactor = "device_scale_factor"
        }
    }

    private struct NormalizedPanelOutput: Encodable {
        let total: [NormalizedPanelEntry]
    }

    private struct NormalizedPanelEntry: Encodable {
        let data: [NormalizedPanelSeries]
    }

    private struct NormalizedPanelSeries: Encodable {
        let metric: String
        let tags: [String: String]
        let dps: [String: Double]
    }

    private struct FetchResult: Sendable {
        let panel: MerlinTaskMetricPanel
        let output: String?
        let authorizationFailed: Bool
    }

    private static let endpoint = URL(
        string: "https://cloud.bytedance.net/api/v1/grafana_open_api/screenshot"
    )!
    private static let maximumResponseBytes = 128 * 1_024 * 1_024

    private let merlinCLIPath: String
    private let processRunner: any InventoryProcessRunning
    private let httpLoader: any MerlinHTTPDataLoading
    private let screenshotReader: any MerlinTaskMetricScreenshotReading
    private let now: @Sendable () -> Date
    private let requestTimeout: TimeInterval
    private let retryDelay: Duration
    private let screenshotOperationRunner: BoundedAsyncOperationRunner
    private var cachedToken: CachedToken?
    private var tokenTask: Task<CachedToken?, Never>?

    init(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        httpLoader: any MerlinHTTPDataLoading = URLSessionMerlinHTTPDataLoader(),
        screenshotReader: any MerlinTaskMetricScreenshotReading =
            VisionMerlinTaskMetricScreenshotReader(),
        now: @escaping @Sendable () -> Date = Date.init,
        requestTimeout: TimeInterval = 90,
        retryDelay: Duration = .milliseconds(750)
    ) {
        self.merlinCLIPath = merlinCLIPath
        self.processRunner = processRunner
        self.httpLoader = httpLoader
        self.screenshotReader = screenshotReader
        self.now = now
        self.requestTimeout = requestTimeout
        self.retryDelay = retryDelay
        screenshotOperationRunner = BoundedAsyncOperationRunner(
            maxConcurrentOperations: 4,
            timeout: .seconds(max(120, requestTimeout + 30))
        )
    }

    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) async -> [MerlinTaskMetricPanel: String] {
        guard !requests.isEmpty, let tokenValue = await token() else { return [:] }
        let first = await fetch(requests, token: tokenValue)
        var loaded = dictionary(from: first)
        let missing = first.filter { $0.output == nil }
        guard !missing.isEmpty, !Task.isCancelled else { return loaded }

        let retryToken: String
        if missing.contains(where: \.authorizationFailed) {
            cachedToken = nil
            guard let replacement = await token() else { return loaded }
            retryToken = replacement
        } else {
            retryToken = tokenValue
        }
        try? await Task.sleep(for: retryDelay)
        guard !Task.isCancelled else { return loaded }
        let retryPanels = Set(missing.map(\.panel))
        let retryRequests = requests.filter { retryPanels.contains($0.panel) }
        let retried = await fetch(retryRequests, token: retryToken)
        loaded.merge(dictionary(from: retried)) { _, new in new }
        return loaded
    }

    private func fetch(
        _ requests: [MerlinTaskPanelDataRequest],
        token: String
    ) async -> [FetchResult] {
        let httpLoader = self.httpLoader
        let screenshotReader = self.screenshotReader
        let now = self.now
        let requestTimeout = self.requestTimeout
        let operationRunner = screenshotOperationRunner
        return await withTaskGroup(
            of: FetchResult.self,
            returning: [FetchResult].self
        ) { group in
            for panelRequest in requests {
                group.addTask {
                    do {
                        return try await operationRunner.run {
                            await Self.fetchResult(
                                panelRequest,
                                token: token,
                                httpLoader: httpLoader,
                                screenshotReader: screenshotReader,
                                now: now,
                                requestTimeout: requestTimeout
                            )
                        }
                    } catch {
                        return FetchResult(
                            panel: panelRequest.panel,
                            output: nil,
                            authorizationFailed: false
                        )
                    }
                }
            }
            var results: [FetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func token() async -> String? {
        let date = now()
        if let cachedToken, cachedToken.validUntil > date {
            return cachedToken.value
        }
        if let tokenTask {
            return await tokenTask.value?.value
        }
        let merlinCLIPath = self.merlinCLIPath
        let processRunner = self.processRunner
        let task = Task {
            await Self.loadToken(
                merlinCLIPath: merlinCLIPath,
                processRunner: processRunner,
                requestedAt: date
            )
        }
        tokenTask = task
        let loaded = await task.value
        tokenTask = nil
        cachedToken = loaded
        return loaded?.value
    }

    private static func loadToken(
        merlinCLIPath: String,
        processRunner: any InventoryProcessRunning,
        requestedAt date: Date
    ) async -> CachedToken? {
        let command = CommandSpec(
            executable: merlinCLIPath,
            arguments: [
                "login", "get-jwt",
                "--control-plane", "cn",
            ]
        )
        guard
            let output = try? await processRunner.run(command),
            output.exitCode == 0,
            let data = output.stdout.data(using: .utf8),
            let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
            response.success != false
        else { return nil }
        let value = response.jwtToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty, value.utf8.count <= 16 * 1_024 else { return nil }
        let fallback = date.addingTimeInterval(30 * 60)
        let expiration = Self.expiration(of: value) ?? fallback
        let validUntil = min(
            expiration.addingTimeInterval(-120),
            date.addingTimeInterval(60 * 60)
        )
        guard validUntil > date else { return nil }
        return CachedToken(value: value, validUntil: validUntil)
    }

    private static func fetchResult(
        _ panelRequest: MerlinTaskPanelDataRequest,
        token: String,
        httpLoader: any MerlinHTTPDataLoading,
        screenshotReader: any MerlinTaskMetricScreenshotReading,
        now: @Sendable () -> Date,
        requestTimeout: TimeInterval
    ) async -> FetchResult {
        guard let request = request(
            for: panelRequest,
            token: token,
            requestTimeout: requestTimeout
        ) else {
            return FetchResult(
                panel: panelRequest.panel,
                output: nil,
                authorizationFailed: false
            )
        }
        do {
            let response = try await httpLoader.data(for: request)
            let authorizationFailed = [401, 403].contains(response.statusCode)
            guard
                (200..<300).contains(response.statusCode),
                response.data.count <= maximumResponseBytes
            else {
                return FetchResult(
                    panel: panelRequest.panel,
                    output: nil,
                    authorizationFailed: authorizationFailed
                )
            }
            let readings = await screenshotReader.readings(
                for: panelRequest.panel,
                imageData: response.data
            )
            guard !Task.isCancelled else {
                return FetchResult(
                    panel: panelRequest.panel,
                    output: nil,
                    authorizationFailed: false
                )
            }
            guard let output = normalizedOutput(
                panel: panelRequest.panel,
                readings: readings,
                sampledAt: windowEnd(for: panelRequest.url) ?? now()
            ) else {
                return FetchResult(
                    panel: panelRequest.panel,
                    output: nil,
                    authorizationFailed: authorizationFailed
                )
            }
            return FetchResult(
                panel: panelRequest.panel,
                output: output,
                authorizationFailed: false
            )
        } catch {
            return FetchResult(
                panel: panelRequest.panel,
                output: nil,
                authorizationFailed: false
            )
        }
    }

    private static func windowEnd(for url: URL) -> Date? {
        guard
            let value = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.last(where: { $0.name == "to" })?.value,
            let milliseconds = Int64(value),
            milliseconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func request(
        for panelRequest: MerlinTaskPanelDataRequest,
        token: String,
        requestTimeout: TimeInterval
    ) -> URLRequest? {
        let panelURL = panelRequest.url
        guard
            panelURL.scheme?.lowercased() == "https",
            panelURL.host?.lowercased() == "grafana.byted.org",
            let body = try? JSONEncoder().encode(PanelRequestBody(
                request: panelRequest
            ))
        else { return nil }
        var request = URLRequest(
            url: endpoint,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-JWT-Token")
        request.httpBody = body
        return request
    }

    private static func normalizedOutput(
        panel: MerlinTaskMetricPanel,
        readings: [String: MerlinTaskMetricLegendValues],
        sampledAt: Date
    ) -> String? {
        let metric = switch panel {
        case .gpu:
            "lab.arnold.instance_monitor.gpu_duty_cycle"
        case .memory:
            "lab.arnold.instance_monitor.mem_usage"
        }
        let timestamp = String(Int64(sampledAt.timeIntervalSince1970))
        let series = readings.keys.sorted().flatMap { trialID in
            guard
                let reading = readings[trialID],
                reading.current.isFinite,
                reading.current >= 0
            else { return [NormalizedPanelSeries]() }
            var values = [NormalizedPanelSeries(
                metric: metric,
                tags: [
                    "source": "grafana-panel-legend",
                    "stat": "current",
                    "trial_id": trialID,
                ],
                dps: [timestamp: reading.current]
            )]
            if
                panel == .gpu,
                let average = reading.average,
                average.isFinite,
                average >= 0
            {
                values.append(NormalizedPanelSeries(
                    metric: metric,
                    tags: [
                        "source": "grafana-panel-legend",
                        "stat": "average",
                        "trial_id": trialID,
                    ],
                    dps: [timestamp: average]
                ))
            }
            return values
        }
        guard !series.isEmpty else { return nil }
        let output = NormalizedPanelOutput(total: [
            NormalizedPanelEntry(data: series),
        ])
        guard
            let data = try? JSONEncoder().encode(output),
            let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func expiration(of token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let data = Data(base64Encoded: payload),
            let claims = try? JSONDecoder().decode(TokenClaims.self, from: data),
            let expiration = claims.expiration
        else { return nil }
        return Date(timeIntervalSince1970: expiration)
    }

    private func dictionary(
        from results: [FetchResult]
    ) -> [MerlinTaskMetricPanel: String] {
        results.reduce(into: [:]) { output, result in
            if let value = result.output {
                output[result.panel] = value
            }
        }
    }
}

private enum MerlinGrafanaOpenAPIError: Error {
    case invalidResponse
}
