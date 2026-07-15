import Darwin
import Foundation

public enum AppServerProcessEvent: Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case terminated(exitCode: Int32)
}

public struct AppServerProcessTermination: Equatable, Sendable {
    public let exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

public protocol AppServerProcessRunning: Sendable {
    func start() async throws
    func write(_ data: Data) async throws
    func nextEvent() async -> AppServerProcessEvent?
    func terminate() async
    func waitForTermination() async -> AppServerProcessTermination
}

public enum AppServerProcessError: Error, Equatable, Sendable {
    case alreadyStarted
    case launchFailed
    case notRunning
    case writeFailed
}

/// Owns one app-server process and exposes its pipes as a pull-driven event
/// source. The internal queue is bounded; pipe readers pause when the consumer
/// falls behind instead of accumulating an unbounded output history.
public actor AppServerProcess: AppServerProcessRunning {
    private static let ioChunkBytes = 16 * 1_024
    private static let eventBufferLimit = 32

    private let process: LockedFoundationProcess
    private let standardInput: LockedFileHandle
    private let standardOutput: LockedFileHandle
    private let standardError: LockedFileHandle
    private let outputWriteHandle: FileHandle
    private let errorWriteHandle: FileHandle
    private let events = BoundedProcessEventChannel(
        capacity: AppServerProcess.eventBufferLimit
    )

    private var started = false
    private var terminationRequested = false
    private var lifecycleTask: Task<AppServerProcessTermination, Never>?

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let foundationProcess = Process()
        foundationProcess.executableURL = executable
        foundationProcess.arguments = arguments
        foundationProcess.environment = environment
        foundationProcess.currentDirectoryURL = currentDirectory
        foundationProcess.standardInput = inputPipe
        foundationProcess.standardOutput = outputPipe
        foundationProcess.standardError = errorPipe

        process = LockedFoundationProcess(foundationProcess)
        standardInput = LockedFileHandle(inputPipe.fileHandleForWriting)
        standardOutput = LockedFileHandle(outputPipe.fileHandleForReading)
        standardError = LockedFileHandle(errorPipe.fileHandleForReading)
        outputWriteHandle = outputPipe.fileHandleForWriting
        errorWriteHandle = errorPipe.fileHandleForWriting
    }

    public func start() async throws {
        guard !started else { throw AppServerProcessError.alreadyStarted }
        started = true
        do {
            try process.run()
        } catch {
            await events.finish()
            throw AppServerProcessError.launchFailed
        }

        try? outputWriteHandle.close()
        try? errorWriteHandle.close()

        let output = standardOutput
        let error = standardError
        let process = process
        let events = events
        let outputReader = Task.detached {
            await Self.drain(
                output,
                event: AppServerProcessEvent.standardOutput,
                into: events
            )
        }
        let errorReader = Task.detached {
            await Self.drain(
                error,
                event: AppServerProcessEvent.standardError,
                into: events
            )
        }
        lifecycleTask = Task.detached {
            let exitCode = process.waitUntilExit()
            await outputReader.value
            await errorReader.value
            await events.send(.terminated(exitCode: exitCode))
            await events.finish()
            return AppServerProcessTermination(exitCode: exitCode)
        }
    }

    public func write(_ data: Data) async throws {
        guard started, lifecycleTask != nil, !terminationRequested else {
            throw AppServerProcessError.notRunning
        }
        do {
            try standardInput.write(data)
        } catch {
            throw AppServerProcessError.writeFailed
        }
    }

    public func nextEvent() async -> AppServerProcessEvent? {
        await events.next()
    }

    public func terminate() async {
        guard started, !terminationRequested else { return }
        terminationRequested = true
        standardInput.close()
        process.terminate()
        process.forceTerminate()
    }

    public func waitForTermination() async -> AppServerProcessTermination {
        guard let lifecycleTask else {
            return AppServerProcessTermination(exitCode: -1)
        }
        return await lifecycleTask.value
    }

    private nonisolated static func drain(
        _ handle: LockedFileHandle,
        event: @Sendable (Data) -> AppServerProcessEvent,
        into channel: BoundedProcessEventChannel
    ) async {
        while true {
            let data: Data
            do {
                data = try handle.read(upToCount: ioChunkBytes) ?? Data()
            } catch {
                break
            }
            guard !data.isEmpty else { break }
            await channel.send(event(data))
        }
        handle.close()
    }
}

private final class LockedFoundationProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func run() throws {
        try lock.withLock { try process.run() }
    }

    func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return lock.withLock { process.terminationStatus }
    }

    func terminate() {
        lock.withLock {
            guard process.isRunning else { return }
            process.terminate()
        }
    }

    func forceTerminate() {
        lock.withLock {
            guard process.isRunning else { return }
            let processID = process.processIdentifier
            guard processID > 1 else { return }
            _ = Darwin.kill(processID, SIGKILL)
        }
    }
}

private final class LockedFileHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var closed = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func read(upToCount count: Int) throws -> Data? {
        try lock.withLock {
            guard !closed else { return nil }
            return try handle.read(upToCount: count)
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !closed else { throw AppServerProcessError.notRunning }
            try handle.write(contentsOf: data)
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
    }
}

private actor BoundedProcessEventChannel {
    private struct Sender {
        let event: AppServerProcessEvent
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct Receiver {
        let id: UUID
        let continuation: CheckedContinuation<AppServerProcessEvent?, Never>
    }

    private let capacity: Int
    private var buffer: [AppServerProcessEvent] = []
    private var receivers: [Receiver] = []
    private var senders: [Sender] = []
    private var finished = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func send(_ event: AppServerProcessEvent) async {
        guard !finished else { return }
        if !receivers.isEmpty {
            receivers.removeFirst().continuation.resume(returning: event)
            return
        }
        if buffer.count < capacity {
            buffer.append(event)
            return
        }
        await withCheckedContinuation { continuation in
            senders.append(Sender(event: event, continuation: continuation))
        }
    }

    func next() async -> AppServerProcessEvent? {
        if !buffer.isEmpty {
            let event = buffer.removeFirst()
            admitSenderIfPossible()
            return event
        }
        if !senders.isEmpty {
            let sender = senders.removeFirst()
            sender.continuation.resume()
            return sender.event
        }
        if finished { return nil }
        let receiverID = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                receivers.append(Receiver(
                    id: receiverID,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelReceiver(receiverID) }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if buffer.isEmpty && senders.isEmpty {
            let pendingReceivers = receivers
            receivers.removeAll()
            for receiver in pendingReceivers {
                receiver.continuation.resume(returning: nil)
            }
        }
        let pendingSenders = senders
        senders.removeAll()
        for sender in pendingSenders { sender.continuation.resume() }
    }

    private func admitSenderIfPossible() {
        guard !finished, !senders.isEmpty, buffer.count < capacity else {
            if finished, buffer.isEmpty {
                let pendingReceivers = receivers
                receivers.removeAll()
                for receiver in pendingReceivers {
                    receiver.continuation.resume(returning: nil)
                }
            }
            return
        }
        let sender = senders.removeFirst()
        buffer.append(sender.event)
        sender.continuation.resume()
    }

    private func cancelReceiver(_ id: UUID) {
        guard let index = receivers.firstIndex(where: { $0.id == id }) else {
            return
        }
        receivers.remove(at: index).continuation.resume(returning: nil)
    }
}
