import Darwin
import Foundation

public enum AppServerProcessEvent: Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case outputOverflow(maximumBufferedEvents: Int)
    case outputDrainLimitExceeded(maximumBytes: Int)
    case eventConsumerUnavailable
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
    func nextEvent(receiverID: UUID) async -> AppServerProcessEvent?
    func terminate() async
    func waitForTermination() async -> AppServerProcessTermination
    nonisolated func emergencyTerminate()
}

public extension AppServerProcessRunning {
    nonisolated func emergencyTerminate() {}
}

public enum AppServerProcessError: Error, Equatable, Sendable {
    case alreadyStarted
    case launchFailed
    case notRunning
    case writeFailed
    case writeTooLarge(maximumBytes: Int)
    case writeQueueOverflow(maximumRequests: Int, maximumBytes: Int)
}

/// Owns one app-server process and exposes its pipes as a pull-driven event
/// source. The internal queue is bounded and fails explicitly if the consumer
/// falls behind, so process reaping never depends on downstream consumption.
public actor AppServerProcess: AppServerProcessRunning {
    public static let maximumWriteBytes = 4 * 1_024 * 1_024
    public static let maximumRetainedWriteRequests = 32
    public static let maximumRetainedWriteBytes = 8 * 1_024 * 1_024
    private static let ioChunkBytes = 16 * 1_024
    private static let eventBufferLimit = 32

    private let process: LockedFoundationProcess
    private let standardInput: NonblockingFIFOFileWriter
    private let standardOutput: NonblockingPipeReader
    private let standardError: NonblockingPipeReader
    private let inputReadHandle: FileHandle
    private let outputWriteHandle: FileHandle
    private let errorWriteHandle: FileHandle
    private let events: BoundedProcessEventChannel
    private let cleanupOwner: AppServerProcessCleanupOwner

    private var started = false
    private var terminationRequested = false
    private var lifecycleTask: Task<AppServerProcessTermination, Never>?

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        maximumPostLeaderDrainBytes: Int = 4 * 1_024 * 1_024,
        maximumPostLeaderDrainDuration: Duration = .milliseconds(100),
        maximumRetainedWriteRequests: Int = AppServerProcess
            .maximumRetainedWriteRequests,
        maximumRetainedWriteBytes: Int = AppServerProcess
            .maximumRetainedWriteBytes
    ) {
        precondition(maximumPostLeaderDrainBytes > 0)
        precondition(maximumPostLeaderDrainDuration > .zero)
        precondition(maximumRetainedWriteRequests > 0)
        precondition(maximumRetainedWriteBytes > 0)
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

        let lockedProcess = LockedFoundationProcess(foundationProcess)
        let input = NonblockingFIFOFileWriter(
            fileDescriptor: Darwin.dup(
                inputPipe.fileHandleForWriting.fileDescriptor
            ),
            maximumRetainedRequests: maximumRetainedWriteRequests,
            maximumRetainedBytes: maximumRetainedWriteBytes
        )
        let output = NonblockingPipeReader(
            fileDescriptor: Darwin.dup(
                outputPipe.fileHandleForReading.fileDescriptor
            ),
            maximumPostLeaderDrainBytes: maximumPostLeaderDrainBytes,
            maximumPostLeaderDrainDuration: maximumPostLeaderDrainDuration
        )
        let error = NonblockingPipeReader(
            fileDescriptor: Darwin.dup(
                errorPipe.fileHandleForReading.fileDescriptor
            ),
            maximumPostLeaderDrainBytes: maximumPostLeaderDrainBytes,
            maximumPostLeaderDrainDuration: maximumPostLeaderDrainDuration
        )
        let inputReadHandle = inputPipe.fileHandleForReading
        let outputWriteHandle = outputPipe.fileHandleForWriting
        let errorWriteHandle = errorPipe.fileHandleForWriting
        let events = BoundedProcessEventChannel(
            capacity: AppServerProcess.eventBufferLimit
        )
        process = lockedProcess
        standardInput = input
        standardOutput = output
        standardError = error
        self.inputReadHandle = inputReadHandle
        self.outputWriteHandle = outputWriteHandle
        self.errorWriteHandle = errorWriteHandle
        self.events = events
        cleanupOwner = AppServerProcessCleanupOwner(
            process: lockedProcess,
            input: input,
            output: output,
            error: error,
            inputReadHandle: inputReadHandle,
            outputWriteHandle: outputWriteHandle,
            errorWriteHandle: errorWriteHandle,
            events: events
        )
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }

    public func start() async throws {
        guard !started else { throw AppServerProcessError.alreadyStarted }
        guard cleanupOwner.beginLaunch() else {
            throw AppServerProcessError.notRunning
        }
        started = true
        do {
            try process.run()
        } catch {
            cleanupOwner.resolveLaunch(lifecycleTask: nil)
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
        let lifecycle = Task.detached {
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
        lifecycleTask = lifecycle
        cleanupOwner.resolveLaunch(lifecycleTask: lifecycle)
    }

    public func write(_ data: Data) async throws {
        guard started, lifecycleTask != nil, !terminationRequested,
            !cleanupOwner.hasBegunCleanup
        else {
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

    public func nextEvent(receiverID: UUID) async -> AppServerProcessEvent? {
        await events.next(receiverID: receiverID)
    }

    public func terminate() async {
        guard started, !terminationRequested else { return }
        terminationRequested = true
        _ = cleanupOwner.beginCleanup()
        await standardInput.close()
    }

    public func waitForTermination() async -> AppServerProcessTermination {
        guard let lifecycleTask else {
            return AppServerProcessTermination(exitCode: -1)
        }
        return await lifecycleTask.value
    }

    public nonisolated func emergencyTerminate() {
        _ = cleanupOwner.beginCleanup()
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

private final class AppServerProcessCleanupOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let process: LockedFoundationProcess
    private let input: NonblockingFIFOFileWriter
    private let output: NonblockingPipeReader
    private let error: NonblockingPipeReader
    private let inputReadHandle: FileHandle
    private let outputWriteHandle: FileHandle
    private let errorWriteHandle: FileHandle
    private let events: BoundedProcessEventChannel
    private let lifecycle = AppServerProcessLifecycleRegistration()
    private var cleanupTask: Task<AppServerProcessTermination, Never>?
    private var cleanupStarted = false

    init(
        process: LockedFoundationProcess,
        input: NonblockingFIFOFileWriter,
        output: NonblockingPipeReader,
        error: NonblockingPipeReader,
        inputReadHandle: FileHandle,
        outputWriteHandle: FileHandle,
        errorWriteHandle: FileHandle,
        events: BoundedProcessEventChannel
    ) {
        self.process = process
        self.input = input
        self.output = output
        self.error = error
        self.inputReadHandle = inputReadHandle
        self.outputWriteHandle = outputWriteHandle
        self.errorWriteHandle = errorWriteHandle
        self.events = events
    }

    var hasBegunCleanup: Bool { lock.withLock { cleanupStarted } }

    func beginLaunch() -> Bool {
        lock.withLock {
            guard !cleanupStarted else { return false }
            lifecycle.markLaunching()
            return true
        }
    }

    func resolveLaunch(
        lifecycleTask: Task<AppServerProcessTermination, Never>?
    ) {
        lifecycle.resolve(lifecycleTask)
    }

    func beginCleanup() -> Task<AppServerProcessTermination, Never> {
        lock.withLock {
            if let cleanupTask { return cleanupTask }
            cleanupStarted = true
            input.emergencyClose()
            output.requestStop()
            error.requestStop()
            try? inputReadHandle.close()
            try? outputWriteHandle.close()
            try? errorWriteHandle.close()
            process.terminate()
            process.forceTerminate()
            let input = input
            let lifecycle = lifecycle
            let events = events
            let task = Task.detached {
                await input.close()
                let lifecycleTask = await lifecycle.value()
                if let lifecycleTask { return await lifecycleTask.value }
                await events.finish()
                return AppServerProcessTermination(exitCode: -1)
            }
            cleanupTask = task
            return task
        }
    }

    deinit { _ = beginCleanup() }
}

private final class AppServerProcessLifecycleRegistration:
    @unchecked Sendable
{
    private enum State {
        case idle
        case launching
        case resolved(Task<AppServerProcessTermination, Never>?)
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var waiters: [
        CheckedContinuation<
            Task<AppServerProcessTermination, Never>?,
            Never
        >
    ] = []

    func markLaunching() {
        lock.withLock {
            guard case .idle = state else { return }
            state = .launching
        }
    }

    func resolve(_ lifecycleTask: Task<AppServerProcessTermination, Never>?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<
            Task<AppServerProcessTermination, Never>?,
            Never
        >] in
            guard case .launching = state else { return [] }
            state = .resolved(lifecycleTask)
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: lifecycleTask) }
    }

    func value() async -> Task<AppServerProcessTermination, Never>? {
        let immediate = lock.withLock { () -> (
            Bool,
            Task<AppServerProcessTermination, Never>?
        ) in
            switch state {
            case .idle: return (true, nil)
            case .launching: return (false, nil)
            case let .resolved(task): return (true, task)
            }
        }
        if immediate.0 { return immediate.1 }
        return await withCheckedContinuation { continuation in
            let resolved = lock.withLock { () -> (
                Bool,
                Task<AppServerProcessTermination, Never>?
            ) in
                if case let .resolved(task) = state { return (true, task) }
                waiters.append(continuation)
                return (false, nil)
            }
            if resolved.0 { continuation.resume(returning: resolved.1) }
        }
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

actor NonblockingFIFOFileWriter {
    private struct WriteRequest {
        let id: UInt64
        let data: Data
        var continuation: CheckedContinuation<Void, Error>?
    }

    private let descriptor: NonblockingWritableDescriptor
    private let maximumRetainedRequests: Int
    private let maximumRetainedBytes: Int
    private var queue: [WriteRequest] = []
    private var active: WriteRequest?
    private var nextRequestID: UInt64 = 1
    private var retainedBytes = 0
    private var physicalStarts = 0
    private var closed = false

    init(
        fileDescriptor: Int32,
        maximumRetainedRequests: Int,
        maximumRetainedBytes: Int
    ) {
        precondition(maximumRetainedRequests > 0)
        precondition(maximumRetainedBytes > 0)
        descriptor = NonblockingWritableDescriptor(
            fileDescriptor: fileDescriptor
        )
        self.maximumRetainedRequests = maximumRetainedRequests
        self.maximumRetainedBytes = maximumRetainedBytes
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw AppServerProcessError.notRunning }
        try Task.checkCancellation()
        guard nextRequestID < UInt64.max else {
            throw AppServerProcessError.writeFailed
        }
        let requestID = nextRequestID
        nextRequestID += 1
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !closed else {
                    continuation.resume(
                        throwing: AppServerProcessError.notRunning
                    )
                    return
                }
                guard retainedRequestCountForTesting < maximumRetainedRequests,
                    data.count <= maximumRetainedBytes - retainedBytes
                else {
                    continuation.resume(
                        throwing: AppServerProcessError.writeQueueOverflow(
                            maximumRequests: maximumRetainedRequests,
                            maximumBytes: maximumRetainedBytes
                        )
                    )
                    return
                }
                retainedBytes += data.count
                queue.append(WriteRequest(
                    id: requestID,
                    data: data,
                    continuation: continuation
                ))
                beginNextIfNeeded()
            }
        } onCancel: {
            Task { await self.cancel(requestID) }
        }
    }

    var retainedRequestCountForTesting: Int {
        queue.count + (active == nil ? 0 : 1)
    }

    var retainedByteCountForTesting: Int { retainedBytes }
    var physicalStartCountForTesting: Int { physicalStarts }

    nonisolated func emergencyClose() { descriptor.close() }

    private func cancel(_ id: UInt64) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let request = queue.remove(at: index)
            retainedBytes -= request.data.count
            request.continuation?.resume(throwing: CancellationError())
            return
        }
        guard var request = active, request.id == id,
            let continuation = request.continuation
        else { return }
        request.continuation = nil
        active = request
        continuation.resume(throwing: CancellationError())
    }

    func close() {
        close(throwing: AppServerProcessError.writeFailed)
    }

    func processExited() {
        close(throwing: AppServerProcessError.writeFailed)
    }

    private func close(throwing error: AppServerProcessError) {
        guard !closed else { return }
        closed = true
        descriptor.close()
        let activeContinuation = active?.continuation
        active = nil
        let waiting = queue
        queue.removeAll(keepingCapacity: false)
        retainedBytes = 0
        activeContinuation?.resume(throwing: error)
        for request in waiting {
            request.continuation?.resume(throwing: error)
        }
    }

    private func beginNextIfNeeded() {
        guard !closed, active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        active = request
        physicalStarts += 1
        let descriptor = descriptor
        let operation = Task.detached {
            descriptor.writeAll(request.data)
        }
        Task { [weak self] in
            let succeeded = await operation.value
            await self?.finishWrite(id: request.id, succeeded: succeeded)
        }
    }

    private func finishWrite(id: UInt64, succeeded: Bool) {
        guard let request = active, request.id == id else { return }
        active = nil
        retainedBytes -= request.data.count
        if succeeded {
            request.continuation?.resume()
        } else {
            request.continuation?.resume(
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
        let pollDescriptor = lock.withLock {
            guard fileDescriptor >= 0 else { return Int32(-1) }
            return Darwin.dup(fileDescriptor)
        }
        guard pollDescriptor >= 0 else { return }
        defer { _ = Darwin.close(pollDescriptor) }
        var descriptorState = pollfd(
            fd: pollDescriptor,
            events: Int16(POLLOUT | POLLHUP | POLLERR),
            revents: 0
        )
        _ = Darwin.poll(&descriptorState, 1, milliseconds)
    }
}

actor BoundedProcessEventChannel {
    private struct Receiver {
        let id: UUID
        let continuation: CheckedContinuation<AppServerProcessEvent?, Never>
    }

    private let capacity: Int
    private var buffer: [AppServerProcessEvent] = []
    private var leasedReceiverID: UUID?
    private var receiver: Receiver?
    private var accepting = true
    private var finished = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func offer(_ event: AppServerProcessEvent) -> Bool {
        guard accepting, !finished else { return false }
        if let receiver {
            self.receiver = nil
            receiver.continuation.resume(returning: event)
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

    func next(receiverID: UUID) async -> AppServerProcessEvent? {
        if let leasedReceiverID, leasedReceiverID != receiverID {
            return .eventConsumerUnavailable
        }
        if receiver != nil { return .eventConsumerUnavailable }
        leasedReceiverID = receiverID
        if !buffer.isEmpty {
            let event = buffer.removeFirst()
            return event
        }
        if finished { return nil }
        let receiverID = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                receiver = Receiver(
                    id: receiverID,
                    continuation: continuation
                )
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
            let pendingReceiver = receiver
            receiver = nil
            pendingReceiver?.continuation.resume(returning: nil)
        }
    }

    var pendingReceiverCountForTesting: Int { receiver == nil ? 0 : 1 }

    private func cancelReceiver(_ id: UUID) {
        guard receiver?.id == id else { return }
        let continuation = receiver?.continuation
        receiver = nil
        continuation?.resume(returning: nil)
    }
}
