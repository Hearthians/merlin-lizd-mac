import Foundation

public enum WorkerMetricsStreamingError: Error, Equatable, Sendable {
    case connectionEnded
    case incompleteEnvelope
    case envelopeTooLarge(maxBytes: Int)
    case stdoutBufferOverflow(maxBufferedBytes: Int)
    case shutDown
}

/// Maintains one long-lived SSH -> Devbox -> Worker process and turns every
/// complete metrics marker envelope into an individual chart sample.
public final class WorkerMetricsStreamer: @unchecked Sendable {
    typealias Parser = @Sendable (String, Date) throws -> WorkerMetricsSample

    private let processStreamer: any InventoryProcessOutputStreaming
    private let sshMasterPool: SSHMasterPool?
    private let now: @Sendable () -> Date
    private let parser: Parser
    private let lease = WorkerMetricsStreamLease()

    public init(sshMasterPool: SSHMasterPool) {
        processStreamer = POSIXInventoryProcessStreamer()
        self.sshMasterPool = sshMasterPool
        now = Date.init
        parser = { output, timestamp in
            try WorkerMetricsParser.parse(output, timestamp: timestamp)
        }
    }

    /// Cancels every active Worker metrics streaming process and returns only
    /// after all local process groups have completed TERM/KILL cleanup and
    /// their leaders have been reaped. Shutdown is permanent: later `stream`
    /// requests finish with `WorkerMetricsStreamingError.shutDown`.
    public static func shutdownAll() async {
        await WorkerMetricsProducerRegistry.shared.shutdownAll()
        await shutdownAllInventoryStreamingProcesses()
    }

    static func resetShutdownStateForTesting() {
        WorkerMetricsProducerRegistry.shared.reopenForTesting()
    }

    init(
        sshMasterPool: SSHMasterPool? = nil,
        processStreamer: any InventoryProcessOutputStreaming,
        now: @escaping @Sendable () -> Date = Date.init,
        parser: @escaping Parser = { output, timestamp in
            try WorkerMetricsParser.parse(output, timestamp: timestamp)
        }
    ) {
        self.sshMasterPool = sshMasterPool
        self.processStreamer = processStreamer
        self.now = now
        self.parser = parser
    }

    public func stream(
        target: TerminalTarget,
        intervalSeconds: Int = 3
    ) -> AsyncThrowingStream<WorkerMetricsSample, Error> {
        return AsyncThrowingStream { continuation in
            guard let producer = WorkerMetricsProducerRegistry.shared.start({
                [processStreamer, sshMasterPool, now, parser, lease] in
                do {
                    let leaseID = try await lease.acquire()
                    do {
                        try Task.checkCancellation()
                        var command = try MerlinCommands.streamWorkerMetrics(
                            target: target,
                            intervalSeconds: intervalSeconds
                        )
                        if
                            let alias = MerlinCommands.sshConnectionTarget(for: target),
                            let sshMasterPool
                        {
                            guard await sshMasterPool.prepare(
                                alias: alias,
                                priority: .foreground
                            ) == .ready else {
                                throw WorkerMetricsStreamingError.connectionEnded
                            }
                            command = try sshMasterPool.managedCommand(
                                command,
                                alias: alias
                            )
                        }
                        var framer = WorkerMetricsEnvelopeFramer()
                        let output = processStreamer.streamStandardOutput(command)

                        do {
                            for try await chunk in output.chunks {
                                try Task.checkCancellation()
                                for envelope in try framer.append(chunk) {
                                    let sample = try parser(envelope, now())
                                    if case .terminated = continuation.yield(sample) {
                                        throw CancellationError()
                                    }
                                }
                            }
                            await output.waitForTermination()
                        } catch {
                            await output.cancelAndWait()
                            throw Self.mapProcessError(error)
                        }

                        for envelope in try framer.finish() {
                            let sample = try parser(envelope, now())
                            if case .terminated = continuation.yield(sample) {
                                throw CancellationError()
                            }
                        }
                        guard !framer.hasIncompleteEnvelope else {
                            throw WorkerMetricsStreamingError.incompleteEnvelope
                        }
                        // The remote command is an intentional infinite loop.
                        // A clean EOF still means the connection ended.
                        throw WorkerMetricsStreamingError.connectionEnded
                    } catch {
                        await lease.release(id: leaseID)
                        throw error
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }) else {
                continuation.finish(
                    throwing: WorkerMetricsStreamingError.shutDown
                )
                return
            }

            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    producer.cancel()
                }
            }
        }
    }

    private static func mapProcessError(_ error: Error) -> Error {
        guard let streamError = error as? InventoryProcessStreamError else {
            return error
        }

        switch streamError {
        case let .commandFailed(exitCode, stderrTail):
            let diagnostic = stderrTail.lowercased()
            if diagnostic.contains("worker has not been ready")
                || diagnostic.contains("worker is not ready")
            {
                return WorkerMetricsSamplingError.workerNotReady
            }
            return WorkerMetricsSamplingError.commandFailed(exitCode: exitCode)
        case let .stdoutBufferOverflow(maxBufferedBytes):
            return WorkerMetricsStreamingError.stdoutBufferOverflow(
                maxBufferedBytes: maxBufferedBytes
            )
        }
    }
}

/// Registers an outer streaming task before it is allowed to run. Closing the
/// registry is permanent in production: this makes shutdown a one-way gate and
/// prevents a lease waiter from launching a late POSIX process.
private final class WorkerMetricsProducerRegistry: @unchecked Sendable {
    static let shared = WorkerMetricsProducerRegistry()

    private let lock = NSLock()
    private var producers: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    func start(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return nil
        }

        let id = UUID()
        let gate = WorkerMetricsProducerStartGate()
        let producer = Task { [self] in
            await gate.wait()
            defer { unregister(id: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        producers[id] = producer
        gate.open()
        lock.unlock()
        return producer
    }

    func shutdownAll() async {
        let activeProducers: [Task<Void, Never>] = lock.withLock {
            isClosed = true
            return Array(producers.values)
        }
        for producer in activeProducers {
            producer.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for producer in activeProducers {
                group.addTask {
                    await producer.value
                }
            }
        }
    }

    func reopenForTesting() {
        lock.withLock {
            precondition(producers.isEmpty)
            isClosed = false
        }
    }

    private func unregister(id: UUID) {
        lock.withLock {
            producers[id] = nil
        }
    }
}

private final class WorkerMetricsProducerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isOpen {
                    return true
                }
                waiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let continuationToResume = lock.withLock {
            isOpen = true
            let currentWaiter = self.waiter
            self.waiter = nil
            return currentWaiter
        }
        continuationToResume?.resume()
    }
}

/// Frames arbitrary byte chunks rather than assuming pipe reads align to
/// UTF-8 characters, lines, or metrics envelopes.
struct WorkerMetricsEnvelopeFramer: Sendable {
    private let maximumLineBytes: Int
    private let maximumEnvelopeBytes: Int
    private var pendingBytes: [UInt8] = []
    private var discardingOversizedNoiseLine = false
    private var envelopeLines: [String]?
    private var envelopeByteCount = 0

    init(
        maximumLineBytes: Int = 256 * 1_024,
        maximumEnvelopeBytes: Int = 2 * 1_024 * 1_024
    ) {
        precondition(maximumLineBytes > 0)
        precondition(maximumEnvelopeBytes >= maximumLineBytes)
        self.maximumLineBytes = maximumLineBytes
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
    }

    var hasIncompleteEnvelope: Bool {
        envelopeLines != nil
    }

    mutating func append(_ data: Data) throws -> [String] {
        try append(Array(data))
    }

    mutating func append(_ bytes: [UInt8]) throws -> [String] {
        var incoming = bytes
        if discardingOversizedNoiseLine {
            guard let newline = incoming.firstIndex(of: 0x0A) else {
                return []
            }
            discardingOversizedNoiseLine = false
            incoming.removeFirst(newline + 1)
        }

        pendingBytes.append(contentsOf: incoming)
        var completed: [String] = []
        while let newline = pendingBytes.firstIndex(of: 0x0A) {
            let lineBytes = Array(pendingBytes[..<newline])
            pendingBytes.removeFirst(newline + 1)
            if lineBytes.count > maximumLineBytes {
                if envelopeLines != nil {
                    throw WorkerMetricsStreamingError.envelopeTooLarge(
                        maxBytes: maximumEnvelopeBytes
                    )
                }
                continue
            }
            if let envelope = try processLine(lineBytes) {
                completed.append(envelope)
            }
        }

        if pendingBytes.count > maximumLineBytes {
            if envelopeLines != nil {
                throw WorkerMetricsStreamingError.envelopeTooLarge(
                    maxBytes: maximumEnvelopeBytes
                )
            }
            pendingBytes.removeAll(keepingCapacity: true)
            discardingOversizedNoiseLine = true
        }
        return completed
    }

    mutating func finish() throws -> [String] {
        guard !discardingOversizedNoiseLine, !pendingBytes.isEmpty else {
            pendingBytes.removeAll()
            return []
        }
        let line = pendingBytes
        pendingBytes.removeAll()
        if let envelope = try processLine(line) {
            return [envelope]
        }
        return []
    }

    private mutating func processLine(_ bytes: [UInt8]) throws -> String? {
        let line = String(decoding: bytes, as: UTF8.self)
        let markerCandidate = line.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if markerCandidate == WorkerMetricsWireFormat.beginMarker {
            envelopeLines = [line]
            envelopeByteCount = bytes.count + 1
            return nil
        }

        guard var lines = envelopeLines else { return nil }
        let nextByteCount = envelopeByteCount + bytes.count + 1
        guard nextByteCount <= maximumEnvelopeBytes else {
            throw WorkerMetricsStreamingError.envelopeTooLarge(
                maxBytes: maximumEnvelopeBytes
            )
        }
        lines.append(line)
        envelopeLines = lines
        envelopeByteCount = nextByteCount

        guard markerCandidate == WorkerMetricsWireFormat.endMarker else {
            return nil
        }
        let envelope = lines.joined(separator: "\n")
        envelopeLines = nil
        envelopeByteCount = 0
        return envelope
    }
}

private actor WorkerMetricsStreamLease {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var activeID: UUID?
    private var waiters: [Waiter] = []

    func acquire() async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if activeID == nil {
                    activeID = id
                    continuation.resume(returning: id)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release(id: UUID) {
        guard activeID == id else { return }
        guard !waiters.isEmpty else {
            activeID = nil
            return
        }
        let waiter = waiters.removeFirst()
        activeID = waiter.id
        waiter.continuation.resume(returning: waiter.id)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
