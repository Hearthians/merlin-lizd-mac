import Darwin
import Foundation

struct InventoryProcessOutput: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol InventoryProcessRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput
}

enum InventoryProcessTimeoutError: Error, Equatable, Sendable {
    case timedOut
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

            let output = await InventoryProcessOutput(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitCode: exitCode
            )
            await processBox.reap()
            try Task.checkCancellation()
            return output
        } onCancel: {
            processBox.cancel()
            stdout.requestClose()
            stderr.requestClose()
        }
    }
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

    func cancel() {
        var groupToTerminate: pid_t?

        lock.lock()
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

        guard let groupToTerminate else { return }
        signalProcessGroup(groupToTerminate, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.forceKillGracePeriod
        ) { [self] in
            forceKillIfNeeded(processGroupID: groupToTerminate)
        }
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
        let descriptor = handle.fileDescriptor
        guard descriptor >= 0 else { return Data() }
        defer { try? handle.close() }

        var output = Data()
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
                output.append(contentsOf: buffer.prefix(Int(byteCount)))
            } else if byteCount == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }

        return output
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
