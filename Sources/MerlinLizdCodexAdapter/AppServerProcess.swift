import Darwin
import Foundation

public enum AppServerProcessEvent: Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case outputOverflow(maximumBufferedEvents: Int)
    case outputDrainLimitExceeded(maximumBytes: Int)
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
    case writeTooLarge(maximumBytes: Int)
}

/// Owns one app-server process and exposes its pipes as a pull-driven event
/// source. The internal queue is bounded and fails explicitly if the consumer
/// falls behind, so process reaping never depends on downstream consumption.
public actor AppServerProcess: AppServerProcessRunning {
    public static let maximumWriteBytes = 4 * 1_024 * 1_024
    private static let ioChunkBytes = 16 * 1_024
    private static let eventBufferLimit = 32

    private let process: LockedFoundationProcess
    private let standardInput: NonblockingFIFOFileWriter
    private let standardOutput: NonblockingPipeReader
    private let standardError: NonblockingPipeReader
    private let inputReadHandle: FileHandle
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
        currentDirectory: URL? = nil,
        maximumPostLeaderDrainBytes: Int = 4 * 1_024 * 1_024,
        maximumPostLeaderDrainDuration: Duration = .milliseconds(100)
    ) {
        precondition(maximumPostLeaderDrainBytes > 0)
        precondition(maximumPostLeaderDrainDuration > .zero)
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
        standardInput = NonblockingFIFOFileWriter(
            fileDescriptor: Darwin.dup(
                inputPipe.fileHandleForWriting.fileDescriptor
            )
        )
        standardOutput = NonblockingPipeReader(
            fileDescriptor: Darwin.dup(
                outputPipe.fileHandleForReading.fileDescriptor
            ),
            maximumPostLeaderDrainBytes: maximumPostLeaderDrainBytes,
            maximumPostLeaderDrainDuration: maximumPostLeaderDrainDuration
        )
        standardError = NonblockingPipeReader(
            fileDescriptor: Darwin.dup(
                errorPipe.fileHandleForReading.fileDescriptor
            ),
            maximumPostLeaderDrainBytes: maximumPostLeaderDrainBytes,
            maximumPostLeaderDrainDuration: maximumPostLeaderDrainDuration
        )
        inputReadHandle = inputPipe.fileHandleForReading
        outputWriteHandle = outputPipe.fileHandleForWriting
        errorWriteHandle = errorPipe.fileHandleForWriting
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }

    public func start() async throws {
        guard !started else { throw AppServerProcessError.alreadyStarted }
        started = true
        do {
            try process.run()
        } catch {
            await standardInput.close()
            standardOutput.close()
            standardError.close()
            try? inputReadHandle.close()
            try? outputWriteHandle.close()
            try? errorWriteHandle.close()
            await events.finish()
            throw AppServerProcessError.launchFailed
        }

        try? inputReadHandle.close()
        try? outputWriteHandle.close()
        try? errorWriteHandle.close()

        let output = standardOutput
        let error = standardError
        let input = standardInput
        let process = process
        let events = events
        let outputReader = Task.detached {
            await Self.drain(
                output,
                event: AppServerProcessEvent.standardOutput,
                into: events,
                process: process
            )
        }
        let errorReader = Task.detached {
            await Self.drain(
                error,
                event: AppServerProcessEvent.standardError,
                into: events,
                process: process
            )
        }
        lifecycleTask = Task.detached {
            let exitCode = process.waitUntilExit()
            output.markLeaderExited()
            error.markLeaderExited()
            await input.processExited()
            await outputReader.value
            await errorReader.value
            _ = await events.offer(.terminated(exitCode: exitCode))
            await events.finish()
            return AppServerProcessTermination(exitCode: exitCode)
        }
    }

    public func write(_ data: Data) async throws {
        guard started, lifecycleTask != nil, !terminationRequested else {
            throw AppServerProcessError.notRunning
        }
        guard data.count <= Self.maximumWriteBytes else {
            throw AppServerProcessError.writeTooLarge(
                maximumBytes: Self.maximumWriteBytes
            )
        }
        do {
            try await standardInput.write(data)
        } catch {
            if let error = error as? AppServerProcessError { throw error }
            throw AppServerProcessError.writeFailed
        }
    }

    public func nextEvent() async -> AppServerProcessEvent? {
        await events.next()
    }

    public func terminate() async {
        guard started, !terminationRequested else { return }
        terminationRequested = true
        await standardInput.close()
        standardOutput.requestStop()
        standardError.requestStop()
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
        _ handle: NonblockingPipeReader,
        event: @Sendable (Data) -> AppServerProcessEvent,
        into channel: BoundedProcessEventChannel,
        process: LockedFoundationProcess
    ) async {
        drainLoop: while true {
            if handle.shouldStop { break }
            if handle.reachedPostLeaderLimit(afterReading: 0) {
                _ = await channel.offer(.outputDrainLimitExceeded(
                    maximumBytes: handle.maximumPostLeaderDrainBytes
                ))
                break
            }
            switch handle.read(upToCount: ioChunkBytes) {
            case let .data(data):
                guard await channel.offer(event(data)) else {
                    process.forceTerminate()
                    handle.requestStop()
                    break drainLoop
                }
                if handle.reachedPostLeaderLimit(afterReading: data.count) {
                    _ = await channel.offer(.outputDrainLimitExceeded(
                        maximumBytes: handle.maximumPostLeaderDrainBytes
                    ))
                    break drainLoop
                }
            case .wouldBlock:
                if handle.shouldStop { break drainLoop }
                if handle.reachedPostLeaderLimit(afterReading: 0) {
                    _ = await channel.offer(.outputDrainLimitExceeded(
                        maximumBytes: handle.maximumPostLeaderDrainBytes
                    ))
                    break drainLoop
                }
                handle.waitUntilReadable(milliseconds: 25)
            case .end:
                break drainLoop
            }
        }
        handle.close()
    }
}

private final class LockedFoundationProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let terminationSignal: FoundationProcessTerminationSignal

    init(_ process: Process) {
        self.process = process
        let terminationSignal = FoundationProcessTerminationSignal()
        self.terminationSignal = terminationSignal
        process.terminationHandler = { process in
            terminationSignal.record(exitCode: process.terminationStatus)
        }
    }

    func run() throws {
        try lock.withLock { try process.run() }
    }

    func waitUntilExit() -> Int32 {
        terminationSignal.wait()
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

private final class FoundationProcessTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var exitCode: Int32?

    func record(exitCode: Int32) {
        let shouldSignal = lock.withLock {
            guard self.exitCode == nil else { return false }
            self.exitCode = exitCode
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    func wait() -> Int32 {
        if let exitCode = lock.withLock({ exitCode }) { return exitCode }
        semaphore.wait()
        return lock.withLock { exitCode ?? -1 }
    }
}

private final class NonblockingPipeReader: @unchecked Sendable {
    enum ReadResult {
        case data(Data)
        case wouldBlock
        case end
    }

    private let lock = NSLock()
    let maximumPostLeaderDrainBytes: Int
    private let maximumPostLeaderDrainDuration: Duration
    private var fileDescriptor: Int32
    private var stopRequested = false
    private var leaderExitInstant: ContinuousClock.Instant?
    private var postExitDrainBytes = 0

    init(
        fileDescriptor: Int32,
        maximumPostLeaderDrainBytes: Int,
        maximumPostLeaderDrainDuration: Duration
    ) {
        self.fileDescriptor = fileDescriptor
        self.maximumPostLeaderDrainBytes = maximumPostLeaderDrainBytes
        self.maximumPostLeaderDrainDuration = maximumPostLeaderDrainDuration
        guard fileDescriptor >= 0 else { return }
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    var shouldStop: Bool {
        lock.withLock { stopRequested || fileDescriptor < 0 }
    }

    func read(upToCount count: Int) -> ReadResult {
        lock.withLock {
            guard !stopRequested, fileDescriptor >= 0 else { return .end }
            var data = Data(count: count)
            let byteCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, count)
            }
            if byteCount > 0 {
                data.removeSubrange(byteCount..<data.count)
                return .data(data)
            }
            if byteCount == 0 { return .end }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return .wouldBlock
            }
            return .end
        }
    }

    func waitUntilReadable(milliseconds: Int32) {
        let descriptor = lock.withLock { fileDescriptor }
        guard descriptor >= 0 else { return }
        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        _ = Darwin.poll(&descriptorState, 1, milliseconds)
    }

    func markLeaderExited() {
        lock.withLock {
            if leaderExitInstant == nil {
                leaderExitInstant = ContinuousClock.now
            }
        }
    }

    func reachedPostLeaderLimit(afterReading byteCount: Int) -> Bool {
        lock.withLock {
            guard let leaderExitInstant else { return false }
            postExitDrainBytes += byteCount
            return postExitDrainBytes >= maximumPostLeaderDrainBytes
                || ContinuousClock.now >= leaderExitInstant.advanced(
                    by: maximumPostLeaderDrainDuration
                )
        }
    }

    func requestStop() {
        lock.withLock { stopRequested = true }
    }

    func close() {
        lock.withLock {
            guard fileDescriptor >= 0 else { return }
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
            stopRequested = true
        }
    }

    deinit { close() }
}

private actor NonblockingFIFOFileWriter {
    private struct WriteRequest {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    private let descriptor: NonblockingWritableDescriptor
    private var queue: [WriteRequest] = []
    private var active: WriteRequest?
    private var closed = false

    init(fileDescriptor: Int32) {
        descriptor = NonblockingWritableDescriptor(
            fileDescriptor: fileDescriptor
        )
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw AppServerProcessError.notRunning }
        try await withCheckedThrowingContinuation { continuation in
            queue.append(WriteRequest(
                id: UUID(),
                data: data,
                continuation: continuation
            ))
            beginNextIfNeeded()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        descriptor.close()
        active?.continuation.resume(throwing: AppServerProcessError.writeFailed)
        active = nil
        let waiting = queue
        queue.removeAll()
        for request in waiting {
            request.continuation.resume(
                throwing: AppServerProcessError.writeFailed
            )
        }
    }

    func processExited() {
        guard !closed else { return }
        closed = true
        descriptor.close()
        let waiting = queue
        queue.removeAll()
        for request in waiting {
            request.continuation.resume(
                throwing: AppServerProcessError.writeFailed
            )
        }
    }

    private func beginNextIfNeeded() {
        guard !closed, active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        active = request
        let descriptor = descriptor
        let operation = Task.detached {
            descriptor.writeAll(request.data)
        }
        Task { [weak self] in
            let succeeded = await operation.value
            await self?.finishWrite(id: request.id, succeeded: succeeded)
        }
    }

    private func finishWrite(id: UUID, succeeded: Bool) {
        guard let request = active, request.id == id else { return }
        active = nil
        if succeeded {
            request.continuation.resume()
        } else {
            request.continuation.resume(
                throwing: AppServerProcessError.writeFailed
            )
        }
        beginNextIfNeeded()
    }
}

private final class NonblockingWritableDescriptor: @unchecked Sendable {
    private enum WriteResult {
        case bytes(Int)
        case wouldBlock
        case failed
    }

    private let lock = NSLock()
    private var fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        guard fileDescriptor >= 0 else { return }
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        _ = Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func writeAll(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            switch writeSome(data, offset: offset) {
            case let .bytes(count): offset += count
            case .wouldBlock: waitUntilWritable(milliseconds: 25)
            case .failed: return false
            }
        }
        return true
    }

    func close() {
        lock.withLock {
            guard fileDescriptor >= 0 else { return }
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    deinit { close() }

    private func writeSome(_ data: Data, offset: Int) -> WriteResult {
        lock.withLock {
            guard fileDescriptor >= 0 else { return .failed }
            let result = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if result > 0 { return .bytes(result) }
            if result < 0,
                errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
            {
                return .wouldBlock
            }
            return .failed
        }
    }

    private func waitUntilWritable(milliseconds: Int32) {
        let descriptor = lock.withLock { fileDescriptor }
        guard descriptor >= 0 else { return }
        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT | POLLHUP | POLLERR),
            revents: 0
        )
        _ = Darwin.poll(&descriptorState, 1, milliseconds)
    }
}

private actor BoundedProcessEventChannel {
    private struct Receiver {
        let id: UUID
        let continuation: CheckedContinuation<AppServerProcessEvent?, Never>
    }

    private let capacity: Int
    private var buffer: [AppServerProcessEvent] = []
    private var receivers: [Receiver] = []
    private var accepting = true
    private var finished = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func offer(_ event: AppServerProcessEvent) -> Bool {
        guard accepting, !finished else { return false }
        if !receivers.isEmpty {
            receivers.removeFirst().continuation.resume(returning: event)
            return true
        }
        if buffer.count < capacity {
            buffer.append(event)
            return true
        }
        accepting = false
        buffer.removeAll(keepingCapacity: false)
        buffer.append(.outputOverflow(maximumBufferedEvents: capacity))
        return false
    }

    func next() async -> AppServerProcessEvent? {
        if !buffer.isEmpty {
            let event = buffer.removeFirst()
            return event
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
        accepting = false
        if buffer.isEmpty {
            let pendingReceivers = receivers
            receivers.removeAll()
            for receiver in pendingReceivers {
                receiver.continuation.resume(returning: nil)
            }
        }
    }

    private func cancelReceiver(_ id: UUID) {
        guard let index = receivers.firstIndex(where: { $0.id == id }) else {
            return
        }
        receivers.remove(at: index).continuation.resume(returning: nil)
    }
}
