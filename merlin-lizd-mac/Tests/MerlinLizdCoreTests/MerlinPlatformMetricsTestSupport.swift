import Foundation
@testable import MerlinLizdCore

enum PlatformMetricsTestError: Error {
    case malformedCommand
}

enum PanelBehavior: Sendable {
    case output(String)
    case timedOut
}

func platformMetricsRequestBody(
    _ command: CommandSpec
) throws -> [String: Any] {
    guard
        let index = command.arguments.firstIndex(of: "--json"),
        command.arguments.indices.contains(command.arguments.index(after: index)),
        let data = command.arguments[command.arguments.index(after: index)]
            .data(using: .utf8),
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw PlatformMetricsTestError.malformedCommand
    }
    return body
}

actor PlatformMetricsScriptedRunner: InventoryProcessRunning {
    private static let listURL = "https://grafana.byted.org/d/list-dashboard-uid/metrics?var-podName=sensitive-pod-name&from=now-30m&to=now"

    private let panelBehaviors: [Int: PanelBehavior]
    private let gpuCount: Int
    private var recordedCommands: [CommandSpec] = []
    private var activePanelCommands = 0
    private var maximumPanelCommands = 0

    init(panelBehaviors: [Int: PanelBehavior], gpuCount: Int = 1) {
        self.panelBehaviors = panelBehaviors
        self.gpuCount = gpuCount
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recordedCommands.append(command)
        if command.arguments.starts(with: ["cpu-devbox", "workers", "list"]) {
            return .init(
                stdout: Self.workerListResponse(gpuCount: gpuCount),
                stderr: "",
                exitCode: 0
            )
        }
        if command.arguments.starts(with: ["grafana", "describe"]) {
            return .init(
                stdout: Self.describeResponse,
                stderr: "",
                exitCode: 0
            )
        }
        if command.arguments.starts(with: ["grafana", "panel-data"]) {
            activePanelCommands += 1
            maximumPanelCommands = max(maximumPanelCommands, activePanelCommands)
            defer { activePanelCommands -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            let panelID = try Self.panelID(command)
            switch panelBehaviors[panelID] {
            case let .output(output):
                return .init(stdout: output, stderr: "", exitCode: 0)
            case .timedOut:
                throw InventoryProcessTimeoutError.timedOut
            case nil:
                return .init(stdout: #"{"total":[]}"#, stderr: "", exitCode: 0)
            }
        }
        return .init(stdout: "", stderr: "unexpected command", exitCode: 64)
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }

    func maximumConcurrentPanelCommands() -> Int {
        maximumPanelCommands
    }

    private static func panelID(_ command: CommandSpec) throws -> Int {
        let object = try platformMetricsRequestBody(command)
        guard let panelID = object["panel_id"] as? Int else {
            throw PlatformMetricsTestError.malformedCommand
        }
        return panelID
    }

    private static func workerListResponse(gpuCount: Int) -> String {
        """
        {
          "ResponseBase":{"code":0,"message":"success"},
          "data":[{
            "sid":"wkr_3966762",
            "cpu_cores":20,
            "memory_bytes":10000,
            "gpu_count":\(gpuCount),
            "grafana_url":"\(listURL)",
            "get_grafana_url":"https://grafana.byted.org/d/get-dashboard-must-not-win/"
          }],
          "pagination":{"page_size":100}
        }
        """
    }

    private static let describeResponse = """
        {"dashboards":[{
          "dashboard_uid":"list-dashboard-uid",
          "dashboard_panels":[{"panels":[
            {"id":7,"title":"GPU DutyCycle (GPU 利用率)"},
            {"id":112,"title":"GPU Mem (GPU 显存)"},
            {"id":90,"title":"CPU"},
            {"id":119,"title":"Memory"},
            {"id":122,"title":"GPU Temperature"}
          ]}]
        }]}
        """
}
