import Darwin
import Foundation
@testable import MerlinLizdCore

struct TemporaryMarkerFile: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("merlin-lizd-cancel-\(UUID().uuidString)")

    var path: String { url.path }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct TemporaryProcessIDFile: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("merlin-lizd-pid-\(UUID().uuidString)")

    var path: String { url.path }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func waitForProcessID() async throws -> pid_t {
        for _ in 0..<200 {
            if
                let contents = try? String(contentsOf: url, encoding: .utf8),
                let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return processID
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ConcurrencyRegressionTestError.processDidNotStart
    }

    func processIsAbsent(_ processID: pid_t) -> Bool {
        errno = 0
        return kill(processID, 0) == -1 && errno == ESRCH
    }

    func processHasExitedWithoutReaping(_ processID: pid_t) -> Bool {
        var exitInformation = siginfo_t()
        let result = waitid(
            P_PID,
            id_t(processID),
            &exitInformation,
            WEXITED | WNOWAIT | WNOHANG
        )
        return result == 0 && exitInformation.si_pid == processID
    }

    func waitUntilProcessIsAbsent(_ processID: pid_t) async -> Bool {
        for _ in 0..<200 {
            if processIsAbsent(processID) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return processIsAbsent(processID)
    }
}

enum ConcurrencyRegressionTestError: Error {
    case processDidNotStart
    case unexpectedExit
}

actor AsyncStartGate {
    private var isOpen = false
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}

actor RecordingDelayedProcessRunner: InventoryProcessRunning {
    private var recordedLabels: [String] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recordedLabels.append(command.arguments[0])
        resumeSatisfiedWaiters()
        try await Task.sleep(for: .milliseconds(50))
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func waitUntilCommandCount(_ count: Int) async {
        guard recordedLabels.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func labels() -> [String] {
        recordedLabels
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = countWaiters.filter { $0.0 <= recordedLabels.count }
        countWaiters.removeAll { $0.0 <= recordedLabels.count }
        satisfied.forEach { $0.1.resume() }
    }
}

actor OverlapTrackingEmptyInventoryRunner: InventoryProcessRunning {
    private var activeCommands = 0
    private var maximumActiveCommands = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        activeCommands += 1
        maximumActiveCommands = max(maximumActiveCommands, activeCommands)
        try await Task.sleep(for: .milliseconds(2))
        activeCommands -= 1
        return InventoryProcessOutput(
            stdout: """
            {
              "ResponseBase": {"code": 0, "message": "success"},
              "data": [],
              "pagination": {"page_size": 100}
            }
            """,
            stderr: "",
            exitCode: 0
        )
    }

    func maximumConcurrentCommands() -> Int {
        maximumActiveCommands
    }
}
