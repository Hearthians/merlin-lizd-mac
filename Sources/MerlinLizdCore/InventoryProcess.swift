import Darwin
import Foundation

private let inventoryProcessIOChunkBytes = 16 * 1_024

struct InventoryProcessOutput: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol InventoryProcessRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput
}

protocol InventoryProcessOutputStreaming: Sendable {
    /// Starts one process and forwards its standard output as it arrives.
    /// Cancelling iteration cancels the producer task, which in turn
    /// terminates and reaps the process group through `RunningProcessBox`.
    func streamStandardOutput(
        _ command: CommandSpec
    ) -> InventoryProcessOutputStream
}

enum InventoryProcessStreamError: Error, Equatable, Sendable {
    case commandFailed(exitCode: Int32, stderrTail: String)
    case stdoutBufferOverflow(maxBufferedBytes: Int)
}

struct InventoryProcessOutputStream: Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let producer: Task<Void, Never>

    init(
        chunks: AsyncThrowingStream<Data, Error>,
        producer: Task<Void, Never>
    ) {
        self.chunks = chunks
        self.producer = producer
    }

    /// Waits until the process group has completed output draining and reaping.
    func waitForTermination() async {
        await producer.value
    }

    /// Cancellation is intentionally awaitable so a replacement connection
    /// cannot launch during the TERM/KILL cleanup window.
    func cancelAndWait() async {
        producer.cancel()
        await producer.value
    }
}

enum InventoryProcessTimeoutError: Error, Equatable, Sendable {
    case timedOut
}

/// Applies one shared concurrency and timeout budget around a complete async
/// operation. The slot is held until cancellation has propagated through the
/// child operation, so process-backed work is terminated and reaped before a
/// replacement operation can start.
actor BoundedAsyncOperationRunner {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrentOperations: Int
    private let timeout: Duration
    private var activeOperations = 0
    private var waiters: [Waiter] = []

    init(maxConcurrentOperations: Int, timeout: Duration) {
        precondition(maxConcurrentOperations > 0)
        maximumConcurrentOperations = maxConcurrentOperations
        self.timeout = timeout
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw InventoryProcessTimeoutError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    private func acquireSlot() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if activeOperations < maximumConcurrentOperations {
                    activeOperations += 1
                    continuation.resume()
                } else {
                    waiters.append(.init(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeOperations -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }
}

struct TimedInventoryProcessRunner: InventoryProcessRunning {
    let timeout: Duration
    let underlying: any InventoryProcessRunning

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        try await withThrowingTaskGroup(of: InventoryProcessOutput.self) { group in
            group.addTask {
                try await underlying.run(command)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw InventoryProcessTimeoutError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }
}

actor BoundedInventoryProcessRunner: InventoryProcessRunning {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrentProcesses: Int
    private let underlying: any InventoryProcessRunning
    private var activeProcesses = 0
    private var waiters: [Waiter] = []

    init(
        maxConcurrentProcesses: Int,
        underlying: any InventoryProcessRunning
    ) {
        precondition(maxConcurrentProcesses > 0)
        self.maximumConcurrentProcesses = maxConcurrentProcesses
        self.underlying = underlying
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        try await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()
        return try await underlying.run(command)
    }

    private func acquireSlot() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if activeProcesses < maximumConcurrentProcesses {
                    activeProcesses += 1
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeProcesses -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

final class FoundationInventoryProcessRunner: InventoryProcessRunning, @unchecked Sendable {
    private let processExitBoundaryHook: @Sendable () async -> Void
    private let completionBoundaryHook: @Sendable () async -> Void

    init(
        processExitBoundaryHook: @escaping @Sendable () async -> Void = {},
        completionBoundaryHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.processExitBoundaryHook = processExitBoundaryHook
        self.completionBoundaryHook = completionBoundaryHook
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let processBox = RunningProcessBox(
            command: command,
            standardOutput: stdoutPipe.fileHandleForWriting.fileDescriptor,
            standardError: stderrPipe.fileHandleForWriting.fileDescriptor,
            childDescriptorsToClose: [
                stdoutPipe.fileHandleForReading.fileDescriptor,
                stderrPipe.fileHandleForReading.fileDescriptor,
            ]
        )
        let stdout = FileHandleBox(stdoutPipe.fileHandleForReading)
        let stderr = FileHandleBox(stderrPipe.fileHandleForReading)

        return try await withTaskCancellationHandler {
            do {
                try processBox.start()
            } catch {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                throw error
            }
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            async let stdoutData = Task.detached { stdout.readToEnd() }.value
            async let stderrData = Task.detached { stderr.readToEnd() }.value
            let exitCode = await processBox.waitForExit()
            await processExitBoundaryHook()

            let output = await InventoryProcessOutput(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitCode: exitCode
            )
            await processBox.reap()
            let completionFinalized = processBox.finalizeCompletion()
            await completionBoundaryHook()
            guard completionFinalized else {
                throw CancellationError()
            }
            return output
        } onCancel: {
            if processBox.cancel() {
                stdout.requestClose()
                stderr.requestClose()
            }
        }
    }
}

/// A streaming counterpart to `FoundationInventoryProcessRunner` backed by
/// the same `posix_spawn` process-group lifecycle. It intentionally retains
/// only a bounded tail of stderr while continuously draining the pipe.
final class POSIXInventoryProcessStreamer: InventoryProcessOutputStreaming, @unchecked Sendable {
    private static let defaultStdoutBufferBytes = 512 * 1_024

    private let stderrTailByteLimit: Int
    private let stdoutBufferChunkLimit: Int
    private let stdoutBufferByteLimit: Int

    init(
        stderrTailByteLimit: Int = 64 * 1_024,
        maximumBufferedStdoutBytes: Int = defaultStdoutBufferBytes
    ) {
        precondition(maximumBufferedStdoutBytes >= inventoryProcessIOChunkBytes)
        self.stderrTailByteLimit = max(0, stderrTailByteLimit)
        stdoutBufferChunkLimit = maximumBufferedStdoutBytes
            / inventoryProcessIOChunkBytes
        stdoutBufferByteLimit = stdoutBufferChunkLimit
            * inventoryProcessIOChunkBytes
    }

    func streamStandardOutput(
        _ command: CommandSpec
    ) -> InventoryProcessOutputStream {
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(stdoutBufferChunkLimit)
        )
        let lifecycle = ActiveStreamingProcessLifecycle()
        let registry = InventoryStreamingProcessRegistry.shared
        let producer = Task {
            defer {
                lifecycle.markFinished()
                registry.unregister(id: lifecycle.id)
            }
            do {
                try await pump(
                    command,
                    stderrTailByteLimit: stderrTailByteLimit,
                    stdoutBufferByteLimit: stdoutBufferByteLimit
                ) { data in
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        registry.register(lifecycle: lifecycle, producer: producer)
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                producer.cancel()
            }
        }
        return InventoryProcessOutputStream(chunks: chunks, producer: producer)
    }

    private func pump(
        _ command: CommandSpec,
        stderrTailByteLimit: Int,
        stdoutBufferByteLimit: Int,
        consume: @escaping @Sendable (Data) ->
            AsyncThrowingStream<Data, Error>.Continuation.YieldResult
    ) async throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let processBox = RunningProcessBox(
            command: command,
            standardOutput: stdoutPipe.fileHandleForWriting.fileDescriptor,
            standardError: stderrPipe.fileHandleForWriting.fileDescriptor,
            childDescriptorsToClose: [
                stdoutPipe.fileHandleForReading.fileDescriptor,
                stderrPipe.fileHandleForReading.fileDescriptor,
            ]
        )
        let stdout = FileHandleBox(stdoutPipe.fileHandleForReading)
        let stderr = FileHandleBox(stderrPipe.fileHandleForReading)
        let overflow = StreamingOutputOverflowState()

        try await withTaskCancellationHandler {
            do {
                try processBox.start()
            } catch {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                throw error
            }
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            async let stdoutRead: Void = Task.detached {
                stdout.readChunks { data in
                    guard case .dropped = consume(data) else { return }
                    guard overflow.markOverflowed() else { return }
                    processBox.cancel()
                    stdout.requestClose()
                    stderr.requestClose()
                }
            }.value
            async let stderrTail: Data = Task.detached {
                stderr.readToEnd(retainingLast: stderrTailByteLimit)
            }.value

            let exitCode = await processBox.waitForExit()
            await stdoutRead
            let diagnosticTail = await stderrTail
            await processBox.reap()
            if overflow.isOverflowed {
                throw InventoryProcessStreamError.stdoutBufferOverflow(
                    maxBufferedBytes: stdoutBufferByteLimit
                )
            }
            try Task.checkCancellation()

            guard exitCode == 0 else {
                throw InventoryProcessStreamError.commandFailed(
                    exitCode: exitCode,
                    stderrTail: String(decoding: diagnosticTail, as: UTF8.self)
                )
            }
        } onCancel: {
            processBox.cancel()
            stdout.requestClose()
            stderr.requestClose()
        }
    }
}

private final class StreamingOutputOverflowState: @unchecked Sendable {
    private let lock = NSLock()
    private var overflowed = false

    var isOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    /// Returns true only for the first overflow signal.
    func markOverflowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return false }
        overflowed = true
        return true
    }
}

private final class ActiveStreamingProcessLifecycle: @unchecked Sendable {
    let id = UUID()

    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

/// Tracks every active POSIX streaming child, independently of stream iterator
/// lifetime, so application shutdown can cancel and await process-group reap.
private final class InventoryStreamingProcessRegistry: @unchecked Sendable {
    private struct Entry {
        let lifecycle: ActiveStreamingProcessLifecycle
        let producer: Task<Void, Never>
    }

    static let shared = InventoryStreamingProcessRegistry()

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var isShuttingDown = false

    func register(
        lifecycle: ActiveStreamingProcessLifecycle,
        producer: Task<Void, Never>
    ) {
        var shouldCancel = false
        lock.lock()
        if !lifecycle.isFinished {
            entries[lifecycle.id] = Entry(
                lifecycle: lifecycle,
                producer: producer
            )
            shouldCancel = isShuttingDown
        }
        lock.unlock()

        if shouldCancel {
            producer.cancel()
        }
    }

    func unregister(id: UUID) {
        lock.lock()
        entries[id] = nil
        lock.unlock()
    }

    func shutdownAll() async {
        while true {
            let producers: [Task<Void, Never>] = lock.withLock {
                isShuttingDown = true
                let activeProducers = entries.values.map(\.producer)
                if activeProducers.isEmpty {
                    isShuttingDown = false
                }
                return activeProducers
            }
            guard !producers.isEmpty else { return }

            for producer in producers {
                producer.cancel()
            }
            await withTaskGroup(of: Void.self) { group in
                for producer in producers {
                    group.addTask {
                        await producer.value
                    }
                }
            }
        }
    }
}

func shutdownAllInventoryStreamingProcesses() async {
    await InventoryStreamingProcessRegistry.shared.shutdownAll()
}

private final class RunningProcessBox: @unchecked Sendable {
    private static let forceKillGracePeriod = DispatchTimeInterval.seconds(2)

    private let command: CommandSpec
    private let standardOutput: Int32
    private let standardError: Int32
    private let childDescriptorsToClose: [Int32]
    private let lock = NSLock()
    private var cancellationRequested = false
    private var forceKillScheduled = false
    private var escalationComplete = false
    private var reapCommitted = false
    private var started = false
    private var processID: pid_t?
    private var processGroupID: pid_t?
    private var observedExitCode: Int32?
    private var completionFinalized = false
    private var exitWaiter: CheckedContinuation<Int32, Never>?
    private var reapWaiter: CheckedContinuation<pid_t?, Never>?

    init(
        command: CommandSpec,
        standardOutput: Int32,
        standardError: Int32,
        childDescriptorsToClose: [Int32]
    ) {
        self.command = command
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.childDescriptorsToClose = childDescriptorsToClose
    }

    /// Serializes cancellation with `posix_spawn()` so cancellation cannot
    /// observe "not running" and then lose a race to a subsequent launch.
    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !cancellationRequested else {
            throw CancellationError()
        }
        let spawnedProcessID = try spawnProcess()
        processID = spawnedProcessID
        processGroupID = spawnedProcessID
        started = true

        DispatchQueue.global(qos: .utility).async { [self] in
            observeExit(processID: spawnedProcessID)
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let observedExitCode {
                lock.unlock()
                continuation.resume(returning: observedExitCode)
            } else {
                exitWaiter = continuation
                lock.unlock()
            }
        }
    }

    /// Reaps only after all output pipes are finished. On cancellation the
    /// leader remains a zombie until group escalation completes, preventing
    /// its PID/PGID from being reused before the delayed SIGKILL.
    func reap() async {
        let processIDToReap: pid_t? = await withCheckedContinuation {
            (continuation: CheckedContinuation<pid_t?, Never>) in
            lock.lock()
            if reapCommitted {
                lock.unlock()
                continuation.resume(returning: nil)
            } else if cancellationRequested, !escalationComplete {
                reapWaiter = continuation
                lock.unlock()
            } else {
                reapCommitted = true
                processGroupID = nil
                let processID = self.processID
                lock.unlock()
                continuation.resume(returning: processID)
            }
        }

        guard let processIDToReap else { return }
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processIDToReap, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
    }

    func finalizeCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested else { return false }
        completionFinalized = true
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        var groupToTerminate: pid_t?

        lock.lock()
        guard !completionFinalized else {
            lock.unlock()
            return false
        }
        cancellationRequested = true
        if
            started,
            !reapCommitted,
            let processGroupID,
            !forceKillScheduled
        {
            forceKillScheduled = true
            groupToTerminate = processGroupID
        }
        lock.unlock()

        guard let groupToTerminate else { return true }
        signalProcessGroup(groupToTerminate, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.forceKillGracePeriod
        ) { [self] in
            forceKillIfNeeded(processGroupID: groupToTerminate)
        }
        return true
    }

    private func forceKillIfNeeded(processGroupID: pid_t) {
        lock.lock()
        guard
            forceKillScheduled,
            !reapCommitted,
            self.processGroupID == processGroupID
        else {
            lock.unlock()
            return
        }
        lock.unlock()

        signalProcessGroup(processGroupID, signal: SIGKILL)
        completeEscalation()
    }

    private func completeEscalation() {
        var waiter: CheckedContinuation<pid_t?, Never>?
        var processIDToReap: pid_t?

        lock.lock()
        escalationComplete = true
        if !reapCommitted, let reapWaiter {
            reapCommitted = true
            processGroupID = nil
            processIDToReap = processID
            waiter = reapWaiter
            self.reapWaiter = nil
        }
        lock.unlock()

        waiter?.resume(returning: processIDToReap)
    }

    private func signalProcessGroup(_ processGroupID: pid_t, signal: Int32) {
        guard processGroupID > 1, processGroupID != Darwin.getpgrp() else {
            return
        }
        _ = Darwin.kill(-processGroupID, signal)
    }

    private func spawnProcess() throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let standardInputResult = "/dev/null".withCString { path in
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                path,
                O_RDONLY,
                0
            )
        }
        try checkPOSIX(standardInputResult)
        try checkPOSIX(posix_spawn_file_actions_adddup2(
            &fileActions,
            standardOutput,
            STDOUT_FILENO
        ))
        try checkPOSIX(posix_spawn_file_actions_adddup2(
            &fileActions,
            standardError,
            STDERR_FILENO
        ))

        let descriptorsToClose = Set(
            [standardOutput, standardError] + childDescriptorsToClose
        )
        for descriptor in descriptorsToClose where descriptor > STDERR_FILENO {
            try checkPOSIX(posix_spawn_file_actions_addclose(
                &fileActions,
                descriptor
            ))
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        try checkPOSIX(posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals
        ))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try checkPOSIX(posix_spawnattr_setsigmask(&attributes, &signalMask))
        let flags = Int16(POSIX_SPAWN_SETPGROUP) |
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT) |
            Int16(POSIX_SPAWN_SETSIGDEF) |
            Int16(POSIX_SPAWN_SETSIGMASK)
        try checkPOSIX(posix_spawnattr_setflags(&attributes, flags))

        var arguments: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for case let argument? in arguments {
                free(argument)
            }
        }
        for argument in [command.executable] + command.arguments {
            guard let duplicatedArgument = strdup(argument) else {
                throw posixError(ENOMEM)
            }
            arguments.append(duplicatedArgument)
        }
        arguments.append(nil)

        var spawnedProcessID: pid_t = 0
        let spawnResult = command.executable.withCString { executable in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                posix_spawn(
                    &spawnedProcessID,
                    executable,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environ
                )
            }
        }
        try checkPOSIX(spawnResult)
        return spawnedProcessID
    }

    private func observeExit(processID: pid_t) {
        var exitInformation = siginfo_t()
        var waitResult: Int32
        repeat {
            waitResult = Darwin.waitid(
                P_PID,
                id_t(processID),
                &exitInformation,
                WEXITED | WNOWAIT
            )
        } while waitResult == -1 && errno == EINTR

        let status = waitResult == 0 ? Int32(exitInformation.si_status) : -1

        lock.lock()
        guard self.processID == processID else {
            lock.unlock()
            return
        }
        observedExitCode = status
        let waiter = exitWaiter
        exitWaiter = nil
        lock.unlock()
        waiter?.resume(returning: status)
    }

    private func checkPOSIX(_ result: Int32) throws {
        guard result == 0 else { throw posixError(result) }
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private final class FileHandleBox: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closeRequested = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() -> Data {
        readToEnd(retainingLast: nil)
    }

    /// Drains the descriptor to EOF while retaining either all bytes or only
    /// the newest `byteLimit` bytes. The latter keeps noisy SSH diagnostics
    /// from growing memory for the lifetime of a metrics stream.
    func readToEnd(retainingLast byteLimit: Int?) -> Data {
        var output = Data()
        readChunks { data in
            guard byteLimit != 0 else { return }
            output.append(data)
            guard let byteLimit, output.count > byteLimit else { return }
            output.removeFirst(output.count - byteLimit)
        }
        return output
    }

    func readChunks(_ consume: (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        guard descriptor >= 0 else { return }
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while !shouldClose {
            var descriptorState = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptorState, 1, 100)

            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                break
            }
            if descriptorState.revents & Int16(POLLNVAL) != 0 {
                break
            }

            let byteCount = Darwin.read(descriptor, &buffer, buffer.count)
            if byteCount > 0 {
                consume(Data(buffer.prefix(Int(byteCount))))
            } else if byteCount == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }

    }

    func requestClose() {
        lock.lock()
        closeRequested = true
        lock.unlock()
    }

    private var shouldClose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closeRequested
    }
}
