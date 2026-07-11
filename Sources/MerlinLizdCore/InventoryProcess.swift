import Foundation

struct InventoryProcessOutput: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol InventoryProcessRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput
}

actor BoundedInventoryProcessRunner: InventoryProcessRunning {
    private let maximumConcurrentProcesses: Int
    private let underlying: any InventoryProcessRunning
    private var activeProcesses = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        maxConcurrentProcesses: Int,
        underlying: any InventoryProcessRunning
    ) {
        precondition(maxConcurrentProcesses > 0)
        self.maximumConcurrentProcesses = maxConcurrentProcesses
        self.underlying = underlying
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        await acquireSlot()
        defer { releaseSlot() }
        return try await underlying.run(command)
    }

    private func acquireSlot() async {
        if activeProcesses < maximumConcurrentProcesses {
            activeProcesses += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeProcesses -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class FoundationInventoryProcessRunner: InventoryProcessRunning, @unchecked Sendable {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = RunningProcessBox(process)
        let stdout = FileHandleBox(stdoutPipe.fileHandleForReading)
        let stderr = FileHandleBox(stderrPipe.fileHandleForReading)

        return try await withTaskCancellationHandler {
            try process.run()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            async let stdoutData = Task.detached { stdout.readToEnd() }.value
            async let stderrData = Task.detached { stderr.readToEnd() }.value
            let exitCode = await Task.detached { processBox.waitForExit() }.value

            return await InventoryProcessOutput(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitCode: exitCode
            )
        } onCancel: {
            processBox.terminateIfRunning()
        }
    }
}

private final class RunningProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func waitForExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    func terminateIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() -> Data {
        handle.readDataToEndOfFile()
    }
}
