import Foundation

public enum JSONLAppServerTransportError: Error, Equatable, Sendable {
    case notStarted
    case alreadyStarted
    case launchFailed
    case stopped
    case invalidMessage
    case lineTooLarge(maximumBytes: Int)
    case outboundLineTooLarge(maximumBytes: Int)
    case processOutputOverflow(maximumBufferedEvents: Int)
    case processTerminated(exitCode: Int32)
    case writeFailed
    case remoteError(code: Int)
    case messageBufferOverflow(maximumMessages: Int)
    case tooManyPendingRequests(maximumRequests: Int)
    case messageConsumerAlreadyWaiting
}

public actor JSONLAppServerTransport {
    public static let maximumLineBytes = 4 * 1_024 * 1_024
    public static let maximumStderrTailBytes = 64 * 1_024
    private static let maximumBufferedMessages = 128

    private enum State: Equatable {
        case idle
        case starting(UUID)
        case running(UUID)
        case stopping(UUID?)
        case failed(JSONLAppServerTransportError)
        case stopped
    }

    private enum StartOutcome: Sendable {
        case started
        case failed
    }

    private struct StartWaiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let process: any AppServerProcessRunning
    private let knownServerRequestMethods: Set<String>
    private let lineByteLimit: Int
    private let pendingRequestLimit: Int
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private var state: State = .idle
    private var nextRequestID: Int64 = 1
    private var standardOutputBuffer = Data()
    private var maximumBufferedStandardOutputBytes = 0
    private var stderrTail = Data()
    private var pending: [
        JSONRPCID: CheckedContinuation<JSONValue, Error>
    ] = [:]
    private var serverMessages: [CodexServerMessage] = []
    private var messageWaiters: [
        UUID: CheckedContinuation<CodexServerMessage, Error>
    ] = [:]
    private var deliveredMessageCount = 0
    private var processedLineCount = 0
    private let directMessageConsumerID = UUID()
    private var messageConsumerID: UUID?
    private var startWaiters: [UUID: StartWaiter] = [:]
    private var startOperation: (UUID, Task<StartOutcome, Never>)?
    private var consumerTask: (UUID, Task<Void, Never>)?
    private var reapTask: Task<Void, Never>?

    public init(
        process: any AppServerProcessRunning,
        knownServerRequestMethods: Set<String> = [],
        maximumLineBytes: Int = JSONLAppServerTransport.maximumLineBytes,
        maximumPendingRequests: Int = 1_024
    ) {
        precondition(maximumLineBytes > 0)
        precondition(maximumPendingRequests > 0)
        self.process = process
        self.knownServerRequestMethods = knownServerRequestMethods
        lineByteLimit = maximumLineBytes
        pendingRequestLimit = maximumPendingRequests
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func start() async throws {
        let token: UUID
        switch state {
        case .idle:
            token = UUID()
            state = .starting(token)
            let process = process
            let operation = Task.detached(priority: nil) {
                do {
                    try await process.start()
                    return StartOutcome.started
                } catch {
                    return StartOutcome.failed
                }
            }
            startOperation = (token, operation)
            Task { [weak self] in
                let outcome = await operation.value
                await self?.finishStart(token: token, outcome: outcome)
            }
        case let .starting(activeToken):
            token = activeToken
        case .running:
            throw JSONLAppServerTransportError.alreadyStarted
        case .stopping, .stopped:
            throw JSONLAppServerTransportError.stopped
        case let .failed(error):
            throw error
        }

        try await awaitStart(token: token)
    }

    private func awaitStart(token: UUID) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation(
                isolation: self
            ) { continuation in
                startWaiters[waiterID] = StartWaiter(
                    token: token,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(waiterID) }
        }
        try Task.checkCancellation()
    }

    private func finishStart(token: UUID, outcome: StartOutcome) {
        guard case let .starting(activeToken) = state,
            activeToken == token
        else {
            resumeStartWaiters(
                for: token,
                throwing: JSONLAppServerTransportError.stopped
            )
            if startOperation?.0 == token { startOperation = nil }
            return
        }
        if startOperation?.0 == token { startOperation = nil }
        switch outcome {
        case .failed:
            let error = JSONLAppServerTransportError.launchFailed
            state = .failed(error)
            discardBufferedProtocolState()
            resumeStartWaiters(for: token, throwing: error)
            _ = beginReapIfNeeded()
        case .started:
            state = .running(token)
            installConsumer(token: token)
            resumeStartWaiters(for: token)
        }
    }

    private func installConsumer(token: UUID) {
        let process = process
        let task = Task { [weak self] in
            while let event = await process.nextEvent() {
                await self?.consume(event, token: token)
            }
            await self?.consumeUnexpectedEOF(token: token)
        }
        consumerTask = (token, task)
    }

    public func request(
        method: String,
        params: JSONValue? = nil
    ) async throws -> JSONValue {
        guard case .running = state else { throw currentTerminalError }
        try Task.checkCancellation()
        guard pending.count < pendingRequestLimit else {
            throw JSONLAppServerTransportError.tooManyPendingRequests(
                maximumRequests: pendingRequestLimit
            )
        }
        guard nextRequestID < Int64.max else {
            fail(.invalidMessage)
            throw JSONLAppServerTransportError.invalidMessage
        }
        let requestID = JSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        let data: Data
        do {
            data = try encodedLine(JSONRPCRequestEnvelope(
                id: requestID,
                method: method,
                params: params
            ))
        } catch let error as JSONLAppServerTransportError {
            throw error
        } catch {
            throw JSONLAppServerTransportError.invalidMessage
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation(
                isolation: self
            ) { continuation in
                pending[requestID] = continuation
                Task { await self.writeRegisteredRequest(data, id: requestID) }
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(requestID) }
        }
    }

    public func respond(to id: JSONRPCID, result: JSONValue) async throws {
        guard case .running = state else { throw currentTerminalError }
        try await writeLine(JSONRPCResultResponse(id: id, result: result))
    }

    public func respondError(
        to id: JSONRPCID,
        code: Int,
        message: String
    ) async throws {
        guard case .running = state else { throw currentTerminalError }
        try await writeLine(JSONRPCErrorResponseEnvelope(
            id: id,
            error: .init(code: code, message: message)
        ))
    }

    public func nextServerMessage() async throws -> CodexServerMessage {
        try await nextServerMessage(consumerID: directMessageConsumerID)
    }

    private func nextServerMessage(
        consumerID: UUID
    ) async throws -> CodexServerMessage {
        guard case .running = state else { throw currentTerminalError }
        if let messageConsumerID, messageConsumerID != consumerID {
            throw JSONLAppServerTransportError.messageConsumerAlreadyWaiting
        }
        messageConsumerID = consumerID
        if !serverMessages.isEmpty { return serverMessages.removeFirst() }
        guard messageWaiters.isEmpty else {
            throw JSONLAppServerTransportError.messageConsumerAlreadyWaiting
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation(
                isolation: self
            ) { continuation in
                messageWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelMessageWaiter(waiterID) }
        }
    }

    /// A pull-driven view over decoded messages. The unfolding stream does not
    /// add a second observation buffer; each `next()` consumes exactly one
    /// message from the actor's bounded queue.
    public nonisolated func messages() -> AsyncThrowingStream<
        CodexServerMessage,
        Error
    > {
        let consumerID = UUID()
        return AsyncThrowingStream(unfolding: { [weak self] in
            guard let self else { return nil }
            return try await self.nextServerMessage(consumerID: consumerID)
        })
    }

    public func shutdown() async {
        if state != .stopped, !isStopping {
            let activeToken: UUID?
            switch state {
            case let .starting(token), let .running(token): activeToken = token
            default: activeToken = nil
            }
            let error = JSONLAppServerTransportError.stopped
            state = .stopping(activeToken)
            startOperation?.1.cancel()
            discardBufferedProtocolState()
            resumeAllStartWaiters(throwing: error)
            resumeAllPending(throwing: error)
            resumeAllMessageWaiters(throwing: error)
        }
        let reap = beginReapIfNeeded()
        await reap.value
        state = .stopped
        consumerTask?.1.cancel()
        if let task = consumerTask?.1 { await task.value }
        consumerTask = nil
    }

    var pendingRequestCountForTesting: Int { pending.count }
    var deliveredMessageCountForTesting: Int { deliveredMessageCount }
    var processedLineCountForTesting: Int { processedLineCount }
    var queuedMessageCountForTesting: Int { serverMessages.count }
    var messageWaiterCountForTesting: Int { messageWaiters.count }
    var bufferedStandardOutputBytesForTesting: Int {
        standardOutputBuffer.count
    }
    var maximumBufferedStandardOutputBytesForTesting: Int {
        maximumBufferedStandardOutputBytes
    }
    var stderrTailForTesting: Data { stderrTail }
    var isRunningForTesting: Bool {
        guard case .running = state else { return false }
        return true
    }
    var failureForTesting: JSONLAppServerTransportError? {
        guard case let .failed(error) = state else { return nil }
        return error
    }

    private var currentTerminalError: JSONLAppServerTransportError {
        switch state {
        case .idle: .notStarted
        case .starting: .notStarted
        case .running: .invalidMessage
        case .stopping: .stopped
        case let .failed(error): error
        case .stopped: .stopped
        }
    }

    private var isStopping: Bool {
        guard case .stopping = state else { return false }
        return true
    }

    private func writeRegisteredRequest(_ data: Data, id: JSONRPCID) async {
        guard case .running = state, pending[id] != nil else { return }
        do {
            try await process.write(data)
        } catch {
            fail(.writeFailed)
        }
    }

    private func cancelPendingRequest(_ id: JSONRPCID) {
        pending.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func cancelMessageWaiter(_ id: UUID) {
        messageWaiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func consume(_ event: AppServerProcessEvent, token: UUID) async {
        guard case let .running(activeToken) = state,
            activeToken == token
        else { return }
        switch event {
        case let .standardOutput(data):
            await processStandardOutput(data)
        case let .standardError(data):
            appendStderr(data)
        case let .outputOverflow(maximumBufferedEvents):
            fail(.processOutputOverflow(
                maximumBufferedEvents: maximumBufferedEvents
            ))
        case let .terminated(exitCode):
            if !standardOutputBuffer.isEmpty {
                if standardOutputBuffer.count > lineByteLimit {
                    fail(.lineTooLarge(maximumBytes: lineByteLimit))
                    return
                }
                let tail = standardOutputBuffer
                standardOutputBuffer.removeAll(keepingCapacity: false)
                await processLine(tail)
            }
            if case let .running(activeToken) = state,
                activeToken == token
            {
                fail(.processTerminated(exitCode: exitCode))
            }
        }
    }

    private func consumeUnexpectedEOF(token: UUID) {
        guard case let .running(activeToken) = state,
            activeToken == token
        else { return }
        fail(.processTerminated(exitCode: -1))
    }

    private func processStandardOutput(_ data: Data) async {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if let newline = data[cursor...].firstIndex(of: 0x0A) {
                guard appendLineFragment(data[cursor..<newline]) else { return }
                var line = standardOutputBuffer
                standardOutputBuffer.removeAll(keepingCapacity: true)
                if line.last == 0x0D { line.removeLast() }
                await processLine(line)
                guard case .running = state else { return }
                cursor = data.index(after: newline)
            } else {
                _ = appendLineFragment(data[cursor...])
                return
            }
        }
    }

    private func appendLineFragment(_ fragment: Data.SubSequence) -> Bool {
        guard fragment.count <= lineByteLimit - standardOutputBuffer.count else {
            fail(.lineTooLarge(maximumBytes: lineByteLimit))
            return false
        }
        standardOutputBuffer.append(contentsOf: fragment)
        maximumBufferedStandardOutputBytes = max(
            maximumBufferedStandardOutputBytes,
            standardOutputBuffer.count
        )
        return true
    }

    private func processLine(_ line: Data) async {
        processedLineCount += 1
        guard !line.isEmpty,
            String(data: line, encoding: .utf8) != nil,
            let value = try? decoder.decode(JSONValue.self, from: line),
            let header = try? decoder.decode(JSONRPCHeader.self, from: line),
            case let .object(object) = value,
            object["jsonrpc"] == .string("2.0")
        else {
            fail(.invalidMessage)
            return
        }

        if case let .string(method)? = object["method"] {
            let parameters = object["params"]
            if object["id"] != nil {
                guard let id = header.id else {
                    fail(.invalidMessage)
                    return
                }
                if knownServerRequestMethods.contains(method) {
                    enqueue(.request(id: id, method: method, params: parameters))
                } else {
                    do {
                        try await writeLine(JSONRPCErrorResponseEnvelope(
                            id: id,
                            error: .init(
                                code: -32601,
                                message: "Method not found"
                            )
                        ))
                    } catch {
                        fail(.writeFailed)
                    }
                }
            } else {
                enqueue(.notification(method: method, params: parameters))
            }
            return
        }

        guard object["id"] != nil, let id = header.id else {
            fail(.invalidMessage)
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else {
            return
        }
        if let result = object["result"], object["error"] == nil {
            continuation.resume(returning: result)
        } else if case let .object(error)? = object["error"],
            case let .number(code)? = error["code"],
            let integerCode = Int(exactly: code),
            object["result"] == nil
        {
            continuation.resume(
                throwing: JSONLAppServerTransportError.remoteError(
                    code: integerCode
                )
            )
        } else {
            continuation.resume(
                throwing: JSONLAppServerTransportError.invalidMessage
            )
            fail(.invalidMessage)
        }
    }

    private func enqueue(_ message: CodexServerMessage) {
        deliveredMessageCount += 1
        if let waiter = messageWaiters.first {
            messageWaiters.removeValue(forKey: waiter.key)?.resume(
                returning: message
            )
            return
        }
        guard serverMessages.count < Self.maximumBufferedMessages else {
            fail(.messageBufferOverflow(
                maximumMessages: Self.maximumBufferedMessages
            ))
            return
        }
        serverMessages.append(message)
    }

    private func appendStderr(_ data: Data) {
        if data.count >= Self.maximumStderrTailBytes {
            stderrTail = Data(data.suffix(Self.maximumStderrTailBytes))
            return
        }
        let overflow = stderrTail.count + data.count
            - Self.maximumStderrTailBytes
        if overflow > 0 { stderrTail.removeFirst(overflow) }
        stderrTail.append(data)
    }

    private func writeLine<Value: Encodable>(_ value: Value) async throws {
        let data: Data
        do {
            data = try encodedLine(value)
        } catch let error as JSONLAppServerTransportError {
            throw error
        } catch {
            throw JSONLAppServerTransportError.invalidMessage
        }
        do {
            try await process.write(data)
        } catch {
            fail(.writeFailed)
            throw JSONLAppServerTransportError.writeFailed
        }
    }

    private func encodedLine<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded: Data
        do {
            encoded = try encoder.encode(value)
        } catch {
            throw JSONLAppServerTransportError.invalidMessage
        }
        let maximumBytes = min(
            lineByteLimit,
            AppServerProcess.maximumWriteBytes
        )
        guard encoded.count < maximumBytes else {
            throw JSONLAppServerTransportError.outboundLineTooLarge(
                maximumBytes: maximumBytes
            )
        }
        var data = encoded
        data.append(0x0A)
        return data
    }

    private func fail(_ error: JSONLAppServerTransportError) {
        guard case .running = state else { return }
        state = .failed(error)
        discardBufferedProtocolState()
        resumeAllPending(throwing: error)
        resumeAllMessageWaiters(throwing: error)
        _ = beginReapIfNeeded()
    }

    private func resumeAllPending(
        throwing error: JSONLAppServerTransportError
    ) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func resumeAllMessageWaiters(
        throwing error: JSONLAppServerTransportError
    ) {
        let continuations = messageWaiters.values
        messageWaiters.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func cancelStartWaiter(_ id: UUID) {
        startWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func resumeStartWaiters(
        for token: UUID,
        throwing error: JSONLAppServerTransportError? = nil
    ) {
        let matching = startWaiters.filter { $0.value.token == token }
        for (id, waiter) in matching {
            startWaiters.removeValue(forKey: id)
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume()
            }
        }
    }

    private func resumeAllStartWaiters(
        throwing error: JSONLAppServerTransportError
    ) {
        let continuations = startWaiters.values.map(\.continuation)
        startWaiters.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func discardBufferedProtocolState() {
        standardOutputBuffer.removeAll(keepingCapacity: false)
        serverMessages.removeAll(keepingCapacity: false)
    }

    private func beginReapIfNeeded() -> Task<Void, Never> {
        if let reapTask { return reapTask }
        let process = process
        let task = Task {
            await process.terminate()
            _ = await process.waitForTermination()
        }
        reapTask = task
        return task
    }
}

private struct JSONRPCResultResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let result: JSONValue
}
