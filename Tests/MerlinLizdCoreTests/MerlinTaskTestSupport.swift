import Foundation
import os
@testable import MerlinLizdCore

final class TaskMetricsTestClock: @unchecked Sendable {
    private let value: OSAllocatedUnfairLock<Date>

    init(now: Date) {
        value = OSAllocatedUnfairLock(initialState: now)
    }

    var now: Date { value.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

func taskTestDate(_ timestamp: TimeInterval) -> Date {
    Date(timeIntervalSince1970: timestamp)
}

func taskSnapshotTimestamp(_ snapshot: MerlinTaskSnapshot) -> TimeInterval {
    snapshot.refreshedAt.timeIntervalSince1970
}

func encodedTaskSnapshot(_ snapshot: MerlinTaskSnapshot) throws -> String {
    String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
}

func taskPageJSON(total: Int, items: [[String: Any]]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
        "total": total,
        "list": items,
    ])
    return String(decoding: data, as: UTF8.self)
}

func taskRequestPage(from command: CommandSpec) throws -> Int {
    try taskRequestBody(from: command)["current"] as? Int ?? -1
}

func taskRequestPageSize(from command: CommandSpec) throws -> Int {
    try taskRequestBody(from: command)["pageSize"] as? Int ?? -1
}

func commandContainsAdjacentArguments(
    _ expected: [String],
    command: CommandSpec
) -> Bool {
    guard !expected.isEmpty else { return true }
    return command.arguments.indices.contains { start in
        let end = start + expected.count
        guard end <= command.arguments.endIndex else { return false }
        return Array(command.arguments[start..<end]) == expected
    }
}

func taskMetricPanelID(from command: CommandSpec) throws -> Int {
    try taskRequestBody(from: command)["panel_id"] as? Int ?? -1
}

func taskMetricPanelIDs(from commands: [CommandSpec]) throws -> [Int] {
    try commands
        .filter { Array($0.arguments.prefix(2)) == ["grafana", "panel-data"] }
        .map(taskMetricPanelID(from:))
        .sorted()
}

func taskMetricJobRunID(from commands: [CommandSpec]) throws -> String? {
    guard let command = commands.first(where: {
        Array($0.arguments.prefix(2)) == ["job", "get-grafana"]
    }) else { return nil }
    return try taskRequestBody(from: command)["job_run_id"] as? String
}

private func taskRequestBody(
    from command: CommandSpec
) throws -> [String: Any] {
    guard
        let index = command.arguments.firstIndex(of: "--json"),
        command.arguments.indices.contains(index + 1)
    else {
        throw TaskTestSupportError.missingRequestBody
    }
    let data = Data(command.arguments[index + 1].utf8)
    guard
        let body = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    else {
        throw TaskTestSupportError.invalidRequestBody
    }
    return body
}

private enum TaskTestSupportError: Error {
    case missingRequestBody
    case invalidRequestBody
}

actor TaskInventoryScriptedRunner: InventoryProcessRunning {
    private var outputs: [String]
    private var recordedCommands: [CommandSpec] = []

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) throws -> InventoryProcessOutput {
        recordedCommands.append(command)
        let output = outputs.isEmpty ? "" : outputs.removeFirst()
        return InventoryProcessOutput(stdout: output, stderr: "", exitCode: 0)
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

actor GatedTaskInventoryRunner: InventoryProcessRunning {
    private let gate: AsyncStartGate
    private let output: String
    private var count = 0

    init(gate: AsyncStartGate, output: String) {
        self.gate = gate
        self.output = output
    }

    func run(_ command: CommandSpec) async -> InventoryProcessOutput {
        count += 1
        await gate.wait()
        return InventoryProcessOutput(stdout: output, stderr: "", exitCode: 0)
    }

    func commandCount() -> Int {
        count
    }
}

actor SequencedTaskInventoryRunner: InventoryProcessRunning {
    struct Result: Sendable {
        let stdout: String
        let exitCode: Int32
    }

    private var results: [Result]
    private var count = 0

    init(results: [Result]) {
        self.results = results
    }

    func run(_ command: CommandSpec) -> InventoryProcessOutput {
        count += 1
        let result = results.removeFirst()
        return InventoryProcessOutput(
            stdout: result.stdout,
            stderr: "",
            exitCode: result.exitCode
        )
    }

    func commandCount() -> Int {
        count
    }
}
