import Foundation

public enum JSONLAppServerTransportError: Error, Equatable, Sendable {
    case notStarted
    case alreadyStarted
    case launchFailed
    case stopped
    case invalidMessage
    case lineTooLarge(maximumBytes: Int)
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
        case running
        case failed(JSONLAppServerTransportError)
        case stopped
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
    private var stderrTail = Data()
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var serverMessages: [CodexServerMessage] = []
    private var messageWaiters: [
        UUID: CheckedContinuation<CodexServerMessage, Error>
    ] = [:]
    private var deliveredMessageCount = 0
    private var consumerTask: Task<Void, Never>?
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
        guard state == .idle else {
            if state == .running {
                throw JSONLAppServerTransportError.alreadyStarted
            }
            throw currentTerminalError
        }
        do {
            try await process.start()
        } catch {
            state = .failed(.launchFailed)
            throw JSONLAppServerTransportError.launchFailed
        }
        state = .running
        let process = process
        consumerTask = Task { [weak self] in
            while let event = await process.nextEvent() {
                await self?.consume(event)
            }
            await self?.consumeUnexpectedEOF()
        }
    }

    public func request(
        method: String,
        params: JSONValue? = nil
    ) async throws -> JSONValue {
        guard state == .running else { throw currentTerminalError }
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
        let requestID = nextRequestID
        nextRequestID += 1
        let data: Data
        do {
            data = try encodedLine(JSONRPCRequestEnvelope(
                id: .integer(requestID),
                method: method,
                params: params
            ))
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
        guard state == .running else { throw currentTerminalError }
        try await writeLine(JSONRPCResultResponse(id: id, result: result))
    }

    public func respondError(
        to id: JSONRPCID,
        code: Int,
        message: String
    ) async throws {
        guard state == .running else { throw currentTerminalError }
        try await writeLine(JSONRPCErrorResponseEnvelope(
            id: id,
            error: .init(code: code, message: message)
        ))
    }

    public func nextServerMessage() async throws -> CodexServerMessage {
        if !serverMessages.isEmpty {
            return serverMessages.removeFirst()
        }
        guard state == .running else { throw currentTerminalError }
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
        AsyncThrowingStream(unfolding: { [weak self] in
            guard let self else { return nil }
            return try await self.nextServerMessage()
        })
    }

    public func shutdown() async {
        if state != .stopped {
            let error = JSONLAppServerTransportError.stopped
            state = .stopped
            standardOutputBuffer.removeAll(keepingCapacity: false)
            resumeAllPending(throwing: error)
            resumeAllMessageWaiters(throwing: error)
        }
        let reap = beginReapIfNeeded()
        await reap.value
        consumerTask?.cancel()
        consumerTask = nil
    }

    var pendingRequestCountForTesting: Int { pending.count }
    var deliveredMessageCountForTesting: Int { deliveredMessageCount }
    var messageWaiterCountForTesting: Int { messageWaiters.count }
    var bufferedStandardOutputBytesForTesting: Int {
        standardOutputBuffer.count
    }
    var stderrTailForTesting: Data { stderrTail }
    var isRunningForTesting: Bool { state == .running }
    var failureForTesting: JSONLAppServerTransportError? {
        guard case let .failed(error) = state else { return nil }
        return error
    }

    private var currentTerminalError: JSONLAppServerTransportError {
        switch state {
        case .idle: .notStarted
        case .running: .invalidMessage
        case let .failed(error): error
        case .stopped: .stopped
        }
    }

    private func writeRegisteredRequest(_ data: Data, id: Int64) async {
        guard state == .running, pending[id] != nil else { return }
        do {
            try await process.write(data)
        } catch {
            fail(.writeFailed)
        }
    }

    private func cancelPendingRequest(_ id: Int64) {
        pending.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func cancelMessageWaiter(_ id: UUID) {
        messageWaiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func consume(_ event: AppServerProcessEvent) async {
        switch event {
        case let .standardOutput(data):
            guard state == .running else { return }
            standardOutputBuffer.append(data)
            await processCompleteLines()
        case let .standardError(data):
            appendStderr(data)
        case let .terminated(exitCode):
            guard state == .running else { return }
            if !standardOutputBuffer.isEmpty {
                if standardOutputBuffer.count > lineByteLimit {
                    fail(.lineTooLarge(maximumBytes: lineByteLimit))
                    return
                }
                let tail = standardOutputBuffer
                standardOutputBuffer.removeAll(keepingCapacity: false)
                await processLine(tail)
            }
            if state == .running {
                fail(.processTerminated(exitCode: exitCode))
            }
        }
    }

    private func consumeUnexpectedEOF() {
        guard state == .running else { return }
        fail(.processTerminated(exitCode: -1))
    }

    private func processCompleteLines() async {
        while let newline = standardOutputBuffer.firstIndex(of: 0x0A) {
            let length = standardOutputBuffer.distance(
                from: standardOutputBuffer.startIndex,
                to: newline
            )
            guard length <= lineByteLimit else {
                fail(.lineTooLarge(maximumBytes: lineByteLimit))
                return
            }
            var line = Data(standardOutputBuffer[..<newline])
            standardOutputBuffer.removeSubrange(
                standardOutputBuffer.startIndex...newline
            )
            if line.last == 0x0D { line.removeLast() }
            await processLine(line)
            guard state == .running else { return }
        }
        if standardOutputBuffer.count > lineByteLimit {
            fail(.lineTooLarge(maximumBytes: lineByteLimit))
        }
    }

    private func processLine(_ line: Data) async {
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
        guard let requestID = outboundRequestID(from: id) else {
            return
        }
        guard let continuation = pending.removeValue(forKey: requestID) else {
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
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func outboundRequestID(from id: JSONRPCID) -> Int64? {
        switch id {
        case let .integer(value): return value
        case let .string(value):
            guard let integer = Int64(value), String(integer) == value else {
                return nil
            }
            return integer
        }
    }

    private func fail(_ error: JSONLAppServerTransportError) {
        guard state == .running || state == .idle else { return }
        state = .failed(error)
        standardOutputBuffer.removeAll(keepingCapacity: false)
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
