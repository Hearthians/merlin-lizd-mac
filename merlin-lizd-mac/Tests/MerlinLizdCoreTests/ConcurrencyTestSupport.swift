import Darwin
import Foundation
@testable import MerlinLizdCore

func temporarySSHDirectory() -> URL {
    URL(
        fileURLWithPath: "/tmp/mlz-\(UUID().uuidString.prefix(12))",
        isDirectory: true
    )
}

func createEmptyFile(atPath path: String) throws {
    try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
}

func createDirectory(at directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
}

func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func posixMode(of directory: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    return attributes[.posixPermissions] as? Int ?? -1
}

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

actor AsyncCompletionProbe {
    private var completionCount = 0

    func complete() {
        completionCount += 1
    }

    func count() -> Int {
        completionCount
    }
}

enum SSHMasterTestError: Error, Equatable, Sendable {
    case transport
}

actor SSHMasterScriptedRunner: InventoryProcessRunning {
    indirect enum Action: Sendable {
        case succeed
        case exit(Int32)
        case fail(SSHMasterTestError)
        case wait(AsyncStartGate, then: Action)
    }

    private var actions: [Action]
    private var recordedCommands: [CommandSpec] = []

    init(actions: [Action] = []) {
        self.actions = actions
    }

    init(prepareExitCodes: [Int32]) {
        actions = prepareExitCodes.flatMap { [.exit(255), .exit($0)] }
    }

    func enqueue(_ action: Action) {
        actions.append(action)
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recordedCommands.append(command)
        let action = actions.isEmpty ? .succeed : actions.removeFirst()
        return try await perform(action)
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }

    func count(argumentsContaining substring: String) -> Int {
        recordedCommands.filter { command in
            command.arguments.contains { $0.contains(substring) }
        }.count
    }

    func masterStartAliases() -> [String] {
        recordedCommands.compactMap { command in
            guard
                command.executable == "/usr/bin/ssh",
                command.arguments.first == "-MNf",
                let alias = command.arguments.last
            else { return nil }
            return alias
        }
    }

    func childCommandCount(alias: String) -> Int {
        recordedCommands.filter { command in
            guard
                command.executable == "/usr/bin/ssh",
                command.arguments.first != "-MNf",
                command.arguments.first != "-O",
                let destinationIndex = sshDestinationIndex(in: command.arguments)
            else { return false }
            return command.arguments[destinationIndex] == alias
        }.count
    }

    private func perform(_ action: Action) async throws -> InventoryProcessOutput {
        switch action {
        case .succeed:
            return output(exitCode: 0)
        case let .exit(exitCode):
            return output(exitCode: exitCode)
        case let .fail(error):
            throw error
        case let .wait(gate, then: next):
            await gate.wait()
            return try await perform(next)
        }
    }

    private func output(exitCode: Int32) -> InventoryProcessOutput {
        InventoryProcessOutput(stdout: "", stderr: "", exitCode: exitCode)
    }

    private func sshDestinationIndex(in arguments: [String]) -> Int? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                let destination = arguments.index(after: index)
                return destination < arguments.endIndex ? destination : nil
            }
            if argument == "-" || !argument.hasPrefix("-") {
                return index
            }
            index = arguments.index(after: index)
            if optionConsumesFollowingArgument(argument) {
                guard index < arguments.endIndex else { return nil }
                index = arguments.index(after: index)
            }
        }
        return nil
    }

    private func optionConsumesFollowingArgument(_ argument: String) -> Bool {
        let valueOptions = Set("BbcDEeFIiJLlmOoPpQRSWw")
        let options = argument.dropFirst()
        return options.enumerated().contains { offset, option in
            valueOptions.contains(option) && offset == options.count - 1
        }
    }
}

actor SSHMasterCancellationRunner: InventoryProcessRunning {
    private var callCount = 0
    private var childCount = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        callCount += 1
        if command.arguments.first != "-O", command.arguments.first != "-MNf" {
            childCount += 1
        }
        if callCount == 3 {
            throw CancellationError()
        }
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: callCount == 1 ? 255 : 0)
    }

    func childCommandCount() -> Int {
        childCount
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
