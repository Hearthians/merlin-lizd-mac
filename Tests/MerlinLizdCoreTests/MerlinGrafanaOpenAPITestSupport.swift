import Foundation
@testable import MerlinLizdCore

func grafanaQueryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.last { $0.name == name }?.value
}

struct RecordedGrafanaOpenAPIRequest: Sendable {
    let endpoint: String
    let method: String?
    let hasExpectedToken: Bool
    let bodyContainsOnlyData: Bool
    let bodyContainsEditPanel: Bool
    let bodyContainsViewPanel: Bool
    let bodyContainsScreenshotSize: Bool
}

actor GrafanaOpenAPIScriptedHTTP: MerlinHTTPDataLoading {
    private var recorded: [RecordedGrafanaOpenAPIRequest] = []

    func data(for request: URLRequest) -> MerlinHTTPResponse {
        let body = request.httpBody.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        let panel = MerlinTaskMetricPanel.allCases.first {
            body.contains("viewPanel=\($0.rawValue)")
        }
        recorded.append(RecordedGrafanaOpenAPIRequest(
            endpoint: request.url?.absoluteString ?? "",
            method: request.httpMethod,
            hasExpectedToken: request.value(
                forHTTPHeaderField: "X-JWT-Token"
            ) == "test-jwt",
            bodyContainsOnlyData: body.contains("\"only_data\":true"),
            bodyContainsEditPanel: body.contains("editPanel="),
            bodyContainsViewPanel: body.contains("viewPanel="),
            bodyContainsScreenshotSize: body.contains("\"width\":1200")
                && (
                    body.contains("\"height\":600")
                        || body.contains("\"height\":900")
                )
        ))
        return MerlinHTTPResponse(
            data: Data([UInt8(panel?.rawValue ?? 0)]),
            statusCode: 200
        )
    }

    func requests() -> [RecordedGrafanaOpenAPIRequest] {
        recorded
    }
}

actor GrafanaScreenshotScriptedReader:
    MerlinTaskMetricScreenshotReading
{
    private let values: [
        MerlinTaskMetricPanel: [String: MerlinTaskMetricLegendValues]
    ]
    private var recordedPanels: [MerlinTaskMetricPanel] = []

    init(values: [MerlinTaskMetricPanel: MerlinTaskMetricLegendValues]) {
        self.values = values.mapValues { ["1": $0] }
    }

    init(values: [
        MerlinTaskMetricPanel: [String: MerlinTaskMetricLegendValues]
    ]) {
        self.values = values
    }

    func readings(
        for panel: MerlinTaskMetricPanel,
        imageData: Data
    ) -> [String: MerlinTaskMetricLegendValues] {
        recordedPanels.append(panel)
        return values[panel] ?? [:]
    }

    func panels() -> [MerlinTaskMetricPanel] {
        recordedPanels
    }
}

actor FlakyGrafanaScreenshotReader:
    MerlinTaskMetricScreenshotReading
{
    private let valueAfterRetry: Double
    private var calls = 0

    init(valueAfterRetry: Double) {
        self.valueAfterRetry = valueAfterRetry
    }

    func readings(
        for panel: MerlinTaskMetricPanel,
        imageData: Data
    ) -> [String: MerlinTaskMetricLegendValues] {
        calls += 1
        return calls == 1 ? [:] : [
            "1": MerlinTaskMetricLegendValues(
                current: valueAfterRetry,
                average: nil
            ),
        ]
    }

    func callCount() -> Int {
        calls
    }
}

actor GrafanaJWTScriptedRunner: InventoryProcessRunning {
    private var recordedCommands: [CommandSpec] = []

    func run(_ command: CommandSpec) -> InventoryProcessOutput {
        recordedCommands.append(command)
        return InventoryProcessOutput(
            stdout: #"{"jwt_token":"test-jwt","success":true}"#,
            stderr: "",
            exitCode: 0
        )
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

actor GatedGrafanaJWTRunner: InventoryProcessRunning {
    private let gate: AsyncStartGate
    private var count = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    init(gate: AsyncStartGate) {
        self.gate = gate
    }

    func run(_ command: CommandSpec) async -> InventoryProcessOutput {
        count += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await gate.wait()
        return InventoryProcessOutput(
            stdout: #"{"jwt_token":"test-jwt","success":true}"#,
            stderr: "",
            exitCode: 0
        )
    }

    func waitUntilStarted() async {
        guard count > 0 else {
            await withCheckedContinuation { continuation in
                startedWaiters.append(continuation)
            }
            return
        }
    }

    func commandCount() -> Int {
        count
    }
}

actor ConcurrencyTrackingGrafanaHTTP: MerlinHTTPDataLoading {
    private let gate: AsyncStartGate
    private var active = 0
    private var maximumActive = 0
    private var startedWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    init(gate: AsyncStartGate) {
        self.gate = gate
    }

    func data(for request: URLRequest) async -> MerlinHTTPResponse {
        active += 1
        maximumActive = max(maximumActive, active)
        let ready = startedWaiters.filter { active >= $0.count }
        startedWaiters.removeAll { active >= $0.count }
        ready.forEach { $0.continuation.resume() }
        await gate.wait()
        active -= 1
        return MerlinHTTPResponse(data: Data([1]), statusCode: 200)
    }

    func waitUntilStarted(count: Int) async {
        guard active < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func maximumActiveCount() -> Int {
        maximumActive
    }
}
