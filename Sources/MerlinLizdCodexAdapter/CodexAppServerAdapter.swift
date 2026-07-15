import Foundation
import MerlinLizdCore

public enum CodexAppServerAdapterError: Error, Equatable, Sendable {
    case unmappedThread
    case invalidResponse
    case unsupportedServerRequest
    case stopped
}

/// Process-local proof that a resumable thread was originally created through
/// this capability-contained adapter. The store can be shared across a process
/// restart boundary by composition code only after its durable Core mapping has
/// been validated.
public actor CodexAppServerThreadMappingStore {
    private var threadIDs: Set<AgentThreadID>

    public init(threadIDs: Set<AgentThreadID> = []) {
        self.threadIDs = threadIDs
    }

    public func contains(_ threadID: AgentThreadID) -> Bool {
        threadIDs.contains(threadID)
    }

    func insert(_ threadID: AgentThreadID) {
        threadIDs.insert(threadID)
    }

    func remove(_ threadID: AgentThreadID) {
        threadIDs.remove(threadID)
    }
}

public actor CodexAppServerAdapter: CodexAgentClient {
    private enum StartupOutcome: Sendable {
        case ready
        case failed
    }

    private let transport: JSONLAppServerTransport
    private let launchConfiguration: CodexLaunchConfiguration
    private let toolExecutor: any CodexDynamicToolExecuting
    private let mappingStore: CodexAppServerThreadMappingStore

    private var startupTask: Task<StartupOutcome, Never>?
    private var consumerTask: Task<Void, Never>?
    private var stopped = false
    private var knownThreads: Set<AgentThreadID> = []
    private var eventReplay: [AgentThreadID: [AgentEvent]] = [:]
    private var eventContinuations: [
        AgentThreadID: [UUID: AsyncStream<AgentEvent>.Continuation]
    ] = [:]
    private var availabilityValue: AgentAvailability = .starting
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentAvailability>.Continuation
    ] = [:]
    private var resumingThreads: Set<AgentThreadID> = []
    private var bufferedLiveEvents: [AgentThreadID: [AgentEvent]] = [:]

    public init(
        transport: JSONLAppServerTransport,
        launchConfiguration: CodexLaunchConfiguration,
        toolExecutor: any CodexDynamicToolExecuting,
        mappingStore: CodexAppServerThreadMappingStore = .init()
    ) {
        self.transport = transport
        self.launchConfiguration = launchConfiguration
        self.toolExecutor = toolExecutor
        self.mappingStore = mappingStore
    }

    public init(
        launchConfiguration: CodexLaunchConfiguration,
        toolExecutor: any CodexDynamicToolExecuting,
        mappingStore: CodexAppServerThreadMappingStore = .init()
    ) {
        transport = JSONLAppServerTransport(
            process: launchConfiguration.makeProcess(),
            knownServerRequestMethods: ["item/tool/call"]
        )
        self.launchConfiguration = launchConfiguration
        self.toolExecutor = toolExecutor
        self.mappingStore = mappingStore
    }

    public func startThread() async throws -> AgentThreadID {
        try await ensureReady()
        let result = try await request(
            method: "thread/start",
            params: launchConfiguration.threadStartParams
        )
        guard let threadID = threadID(in: result) else {
            throw CodexAppServerAdapterError.invalidResponse
        }
        knownThreads.insert(threadID)
        await mappingStore.insert(threadID)
        return threadID
    }

    public func resumeThread(_ threadID: AgentThreadID) async throws {
        guard await mappingStore.contains(threadID) else {
            throw CodexAppServerAdapterError.unmappedThread
        }
        try await ensureReady()
        resumingThreads.insert(threadID)
        bufferedLiveEvents[threadID] = []
        do {
            let result = try await request(
                method: "thread/resume",
                params: .object(["threadId": .string(threadID.rawValue)])
            )
            guard self.threadID(in: result) == threadID else {
                throw CodexAppServerAdapterError.invalidResponse
            }
            knownThreads.insert(threadID)
            publish(.history(try history(in: result)), for: threadID)
            resumingThreads.remove(threadID)
            let buffered = bufferedLiveEvents.removeValue(forKey: threadID) ?? []
            for event in buffered { publish(event, for: threadID) }
        } catch {
            resumingThreads.remove(threadID)
            bufferedLiveEvents.removeValue(forKey: threadID)
            throw normalized(error)
        }
    }

    public func startTurn(
        threadID: AgentThreadID,
        prompt: String
    ) async throws -> AgentTurnID {
        guard await mappingStore.contains(threadID) else {
            throw CodexAppServerAdapterError.unmappedThread
        }
        try await ensureReady()
        let result = try await request(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "input": textInput(prompt),
            ])
        )
        guard let turnID = turnID(in: result) else {
            throw CodexAppServerAdapterError.invalidResponse
        }
        publish(.userMessage(prompt), for: threadID)
        publish(.turnStarted(turnID), for: threadID)
        return turnID
    }

    public func steerTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        prompt: String
    ) async throws {
        guard await mappingStore.contains(threadID) else {
            throw CodexAppServerAdapterError.unmappedThread
        }
        try await ensureReady()
        let result = try await request(
            method: "turn/steer",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "input": textInput(prompt),
            ])
        )
        guard case let .object(fields) = result,
            fields["turnId"]?.nonemptyString == turnID.rawValue
        else { throw CodexAppServerAdapterError.invalidResponse }
        publish(.userMessage(prompt), for: threadID)
    }

    public func interruptTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async {
        guard await mappingStore.contains(threadID), !stopped else { return }
        do {
            try await ensureReady()
            _ = try await request(
                method: "turn/interrupt",
                params: threadTurnParams(threadID: threadID, turnID: turnID)
            )
        } catch {
            // Interrupt is best effort at the replaceable client boundary.
        }
    }

    public func events(
        for threadID: AgentThreadID
    ) -> AsyncStream<AgentEvent> {
        let id = UUID()
        let pair = AsyncStream<AgentEvent>.makeStream()
        for event in eventReplay[threadID] ?? [] {
            pair.continuation.yield(event)
        }
        if stopped {
            pair.continuation.finish()
            return pair.stream
        }
        eventContinuations[threadID, default: [:]][id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id, for: threadID) }
        }
        return pair.stream
    }

    public func availability() -> AsyncStream<AgentAvailability> {
        let id = UUID()
        let pair = AsyncStream<AgentAvailability>.makeStream()
        pair.continuation.yield(availabilityValue)
        if stopped {
            pair.continuation.finish()
            return pair.stream
        }
        availabilityContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAvailabilityContinuation(id) }
        }
        return pair.stream
    }

    public func archiveThread(_ threadID: AgentThreadID) async throws {
        try await threadMutation("thread/archive", threadID: threadID)
    }

    public func unarchiveThread(_ threadID: AgentThreadID) async throws {
        try await threadMutation("thread/unarchive", threadID: threadID)
    }

    public func deleteThread(_ threadID: AgentThreadID) async throws {
        try await threadMutation("thread/delete", threadID: threadID)
        knownThreads.remove(threadID)
        await mappingStore.remove(threadID)
        finishEvents(for: threadID)
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        consumerTask?.cancel()
        await transport.shutdown()
        if let consumerTask { await consumerTask.value }
        self.consumerTask = nil
        startupTask?.cancel()
        startupTask = nil
        setAvailability(.stopped)
        for threadID in Array(eventContinuations.keys) {
            finishEvents(for: threadID)
        }
        for continuation in availabilityContinuations.values {
            continuation.finish()
        }
        availabilityContinuations.removeAll()
    }

    func handleServerRequestForTesting(
        method: String,
        params: JSONValue?
    ) async throws -> JSONValue {
        try await handleServerRequest(method: method, params: params)
    }

    func handleNotificationForTesting(
        method: String,
        params: JSONValue?
    ) {
        handleNotification(method: method, params: params)
    }

    func replayedEventsForTesting(
        _ threadID: AgentThreadID
    ) -> [AgentEvent] {
        eventReplay[threadID] ?? []
    }

    var availabilityForTesting: AgentAvailability { availabilityValue }

    func consumerFailedForTesting() { consumerFailed() }

    private func ensureReady() async throws {
        guard !stopped else { throw CodexAppServerAdapterError.stopped }
        if let startupTask {
            guard await startupTask.value == .ready else {
                throw CodexAppServerAdapterError.invalidResponse
            }
            return
        }
        let transport = transport
        let configuration = launchConfiguration
        let task = Task<StartupOutcome, Never> {
            do {
                try await transport.start()
                let result = try await transport.request(
                    method: "initialize",
                    params: configuration.initializeParams
                )
                try configuration.validateInitializeResult(result)
                try await transport.sendNotification(method: "initialized")
                return .ready
            } catch {
                return .failed
            }
        }
        startupTask = task
        guard await task.value == .ready, !stopped else {
            setAvailability(.crashed)
            throw CodexAppServerAdapterError.invalidResponse
        }
        installConsumerIfNeeded()
        setAvailability(.ready)
    }

    private func installConsumerIfNeeded() {
        guard consumerTask == nil else { return }
        let transport = transport
        consumerTask = Task { [weak self] in
            do {
                for try await message in transport.messages() {
                    guard !Task.isCancelled else { return }
                    await self?.handleServerMessage(message)
                }
                await self?.consumerFailed()
            } catch is CancellationError {
                return
            } catch {
                await self?.consumerFailed()
            }
        }
    }

    private func request(
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        do {
            return try await transport.request(method: method, params: params)
        } catch {
            throw normalized(error)
        }
    }

    private func normalized(_ error: any Error) -> any Error {
        if let error = error as? CodexAppServerAdapterError { return error }
        if error is CancellationError { return CancellationError() }
        return CodexAppServerAdapterError.invalidResponse
    }

    private func threadMutation(
        _ method: String,
        threadID: AgentThreadID
    ) async throws {
        guard await mappingStore.contains(threadID) else {
            throw CodexAppServerAdapterError.unmappedThread
        }
        try await ensureReady()
        _ = try await request(
            method: method,
            params: .object(["threadId": .string(threadID.rawValue)])
        )
    }

    private func handleServerMessage(_ message: CodexServerMessage) async {
        switch message {
        case let .notification(method, params):
            handleNotification(method: method, params: params)
        case let .request(id, method, params):
            do {
                let result = try await handleServerRequest(
                    method: method,
                    params: params
                )
                try await transport.respond(to: id, result: result)
            } catch {
                try? await transport.respondError(
                    to: id,
                    code: -32601,
                    message: "Method not found"
                )
            }
        }
    }

    private func handleServerRequest(
        method: String,
        params: JSONValue?
    ) async throws -> JSONValue {
        guard method == "item/tool/call" else {
            throw CodexAppServerAdapterError.unsupportedServerRequest
        }
        guard case let .object(fields)? = params,
            Set(fields.keys).isSubset(of: [
                "arguments", "callId", "threadId", "tool", "turnId",
                "namespace",
            ]),
            fields["callId"]?.nonemptyString != nil,
            let threadText = fields["threadId"]?.nonemptyString,
            let tool = fields["tool"]?.nonemptyString,
            let turnText = fields["turnId"]?.nonemptyString,
            let arguments = fields["arguments"]
        else {
            return CodexDynamicToolCatalog.failureResponse(
                for: CodexDynamicToolError.invalidArguments
            )
        }
        let threadID = AgentThreadID(rawValue: threadText)
        guard await mappingStore.contains(threadID) else {
            return CodexDynamicToolCatalog.failureResponse(
                for: CodexAppServerAdapterError.unmappedThread
            )
        }
        let namespace = fields["namespace"]?.nonemptyString
            ?? CodexDynamicToolCatalog.namespace
        let call: TerminalToolCall
        do {
            call = try CodexDynamicToolCatalog.decode(
                namespace: namespace,
                tool: tool,
                arguments: arguments
            )
        } catch {
            return CodexDynamicToolCatalog.failureResponse(for: error)
        }
        do {
            let result = try await toolExecutor.execute(
                threadID: threadID,
                turnID: AgentTurnID(rawValue: turnText),
                call: call
            )
            return try CodexDynamicToolCatalog.response(for: result)
        } catch {
            return CodexDynamicToolCatalog.failureResponse(for: error)
        }
    }

    private func handleNotification(method: String, params: JSONValue?) {
        switch method {
        case "item/agentMessage/delta":
            guard let (threadID, _, fields) = notificationIdentity(params),
                let delta = fields["delta"]?.nonemptyString
            else {
                publishProtocolFailure(from: params)
                return
            }
            publishLive(.assistantMessageDelta(delta), for: threadID)
        case "item/completed":
            guard let (threadID, _, fields) = notificationIdentity(params),
                case let .object(item)? = fields["item"],
                let itemType = item["type"]?.nonemptyString
            else {
                publishProtocolFailure(from: params)
                return
            }
            switch itemType {
            case "agentMessage":
                guard let text = item["text"]?.nonemptyString else {
                    publishProtocolFailure(from: params)
                    return
                }
                publishLive(.assistantMessageCompleted(text), for: threadID)
            case "dynamicToolCall":
                // The request path already executed and answered this call.
                // Completion is protocol bookkeeping, not a second action.
                return
            default:
                // ThreadItem is additive. Items not represented by Core are
                // safely ignored without surfacing their content.
                return
            }
        case "turn/completed":
            guard case let .object(fields)? = params,
                let threadText = fields["threadId"]?.nonemptyString,
                case let .object(turn)? = fields["turn"],
                let turnText = turn["id"]?.nonemptyString
            else {
                publishProtocolFailure(from: params)
                return
            }
            let threadID = AgentThreadID(rawValue: threadText)
            let turnID = AgentTurnID(rawValue: turnText)
            switch turn["status"]?.nonemptyString {
            case "completed", nil:
                publishLive(.turnCompleted(turnID), for: threadID)
            case "interrupted":
                publishLive(.turnFailed(turnID, .interrupted), for: threadID)
            default:
                publishLive(.turnFailed(turnID, .protocolFailure), for: threadID)
            }
        case "error":
            guard case let .object(fields)? = params,
                let threadText = fields["threadId"]?.nonemptyString,
                let turnText = fields["turnId"]?.nonemptyString,
                fields["willRetry"]?.boolValue != nil,
                case let .object(error)? = fields["error"],
                error["message"]?.nonemptyString != nil
            else {
                publishProtocolFailure(from: params)
                return
            }
            let threadID = AgentThreadID(rawValue: threadText)
            let turnID = AgentTurnID(rawValue: turnText)
            switch error["codexErrorInfo"]?.nonemptyString {
            case "serverOverloaded", "usageLimitExceeded":
                setAvailability(.overloaded)
                publishLive(.turnFailed(turnID, .overloaded), for: threadID)
            case "unauthorized":
                setAvailability(.authenticationRequired)
                publishLive(
                    .turnFailed(turnID, .authenticationRequired),
                    for: threadID
                )
            default:
                publishLive(.turnFailed(turnID, .protocolFailure), for: threadID)
            }
        default:
            // Additive/unknown notifications are deliberately ignored.
            return
        }
    }

    private func notificationIdentity(
        _ params: JSONValue?
    ) -> (AgentThreadID, AgentTurnID, [String: JSONValue])? {
        guard case let .object(fields)? = params,
            let thread = fields["threadId"]?.nonemptyString,
            let turn = fields["turnId"]?.nonemptyString
        else { return nil }
        return (
            AgentThreadID(rawValue: thread),
            AgentTurnID(rawValue: turn),
            fields
        )
    }

    private func publishProtocolFailure(from params: JSONValue?) {
        guard case let .object(fields)? = params,
            let thread = fields["threadId"]?.nonemptyString
        else { return }
        publishLive(
            .turnFailed(nil, .protocolFailure),
            for: AgentThreadID(rawValue: thread)
        )
    }

    private func consumerFailed() {
        guard !stopped else { return }
        setAvailability(.crashed)
        failKnownThreads(.crashed)
    }

    private func failKnownThreads(_ failure: AgentFailure) {
        for threadID in knownThreads {
            publishLive(.turnFailed(nil, failure), for: threadID)
        }
    }

    private func publishLive(_ event: AgentEvent, for threadID: AgentThreadID) {
        if resumingThreads.contains(threadID) {
            bufferedLiveEvents[threadID, default: []].append(event)
        } else {
            publish(event, for: threadID)
        }
    }

    private func publish(_ event: AgentEvent, for threadID: AgentThreadID) {
        var replay = eventReplay[threadID, default: []]
        replay.append(event)
        if replay.count > 512 { replay.removeFirst(replay.count - 512) }
        eventReplay[threadID] = replay
        for continuation in eventContinuations[threadID]?.values ?? [:].values {
            continuation.yield(event)
        }
    }

    private func setAvailability(_ value: AgentAvailability) {
        guard availabilityValue != value else { return }
        availabilityValue = value
        for continuation in availabilityContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeEventContinuation(
        _ id: UUID,
        for threadID: AgentThreadID
    ) {
        eventContinuations[threadID]?.removeValue(forKey: id)
        if eventContinuations[threadID]?.isEmpty == true {
            eventContinuations.removeValue(forKey: threadID)
        }
    }

    private func removeAvailabilityContinuation(_ id: UUID) {
        availabilityContinuations.removeValue(forKey: id)
    }

    private func finishEvents(for threadID: AgentThreadID) {
        for continuation in eventContinuations.removeValue(
            forKey: threadID
        )?.values ?? [:].values {
            continuation.finish()
        }
        eventReplay.removeValue(forKey: threadID)
        bufferedLiveEvents.removeValue(forKey: threadID)
        resumingThreads.remove(threadID)
    }

    private func threadID(in result: JSONValue) -> AgentThreadID? {
        guard case let .object(resultFields) = result,
            case let .object(thread)? = resultFields["thread"],
            let rawValue = thread["id"]?.nonemptyString
        else { return nil }
        return AgentThreadID(rawValue: rawValue)
    }

    private func turnID(in result: JSONValue) -> AgentTurnID? {
        guard case let .object(resultFields) = result,
            case let .object(turn)? = resultFields["turn"],
            let rawValue = turn["id"]?.nonemptyString
        else { return nil }
        return AgentTurnID(rawValue: rawValue)
    }

    private func history(in result: JSONValue) throws -> [AgentMessage] {
        guard case let .object(resultFields) = result,
            case let .object(thread)? = resultFields["thread"]
        else { throw CodexAppServerAdapterError.invalidResponse }
        guard let turnsValue = thread["turns"] else { return [] }
        guard case let .array(turnValues) = turnsValue else {
            throw CodexAppServerAdapterError.invalidResponse
        }
        var messages: [AgentMessage] = []
        for turnValue in turnValues {
            guard case let .object(turn) = turnValue,
                case let .array(items)? = turn["items"]
            else { throw CodexAppServerAdapterError.invalidResponse }
            for itemValue in items {
                guard case let .object(item) = itemValue,
                    let type = item["type"]?.nonemptyString
                else { throw CodexAppServerAdapterError.invalidResponse }
                switch type {
                case "userMessage":
                    guard case let .array(content)? = item["content"] else {
                        throw CodexAppServerAdapterError.invalidResponse
                    }
                    for contentValue in content {
                        guard case let .object(fields) = contentValue else {
                            throw CodexAppServerAdapterError.invalidResponse
                        }
                        if let contentType = fields["type"]?.nonemptyString,
                            ["text", "inputText"].contains(contentType),
                            let text = fields["text"]?.nonemptyString
                        {
                            messages.append(.init(role: .user, text: text))
                        }
                    }
                case "agentMessage":
                    guard let text = item["text"]?.nonemptyString else {
                        throw CodexAppServerAdapterError.invalidResponse
                    }
                    messages.append(.init(role: .assistant, text: text))
                default:
                    continue
                }
            }
        }
        return messages
    }

    private func textInput(_ prompt: String) -> JSONValue {
        .array([.object([
            "type": .string("text"),
            "text": .string(prompt),
        ])])
    }

    private func threadTurnParams(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) -> JSONValue {
        .object([
            "threadId": .string(threadID.rawValue),
            "turnId": .string(turnID.rawValue),
        ])
    }
}
