import Foundation
import MerlinLizdCore

public enum CodexAppServerAdapterError: Error, Equatable, Sendable {
    case unmappedThread
    case invalidResponse
    case unsupportedServerRequest
    case turnAlreadyStarting
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

struct CodexAppServerAdapterStateCounts: Equatable, Sendable {
    let knownThreads: Int
    let activeTurns: Int
    let pendingTurnStarts: Int
    let replayThreads: Int
    let replayEvents: Int
    let bufferedNotifications: Int
}

public actor CodexAppServerAdapter: CodexAgentClient {
    private static let maximumBufferedTurnNotifications = 128
    private static let productionMaximumInFlightToolRequests = 32

    private enum StartupOutcome: Sendable {
        case ready
        case failed
    }

    private struct BufferedTurnNotification: Sendable {
        let method: String
        let params: JSONValue?
        let threadID: AgentThreadID
        let turnID: AgentTurnID
    }

    private struct PendingTurnStart: Sendable {
        let token: UUID
        let requestTask: Task<JSONValue, Error>
        var notifications: [BufferedTurnNotification]
        var overflowed: Bool
    }

    private struct InFlightToolRequest: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let transport: JSONLAppServerTransport
    private let launchConfiguration: CodexLaunchConfiguration
    private let toolExecutor: any CodexDynamicToolExecuting
    private let mappingStore: CodexAppServerThreadMappingStore
    private let maximumInFlightToolRequests: Int

    private var startupTask: Task<StartupOutcome, Never>?
    private var consumerTask: Task<Void, Never>?
    private var stopped = false
    private var knownThreads: Set<AgentThreadID> = []
    private var activeTurns: [AgentThreadID: AgentTurnID] = [:]
    private var pendingTurnStarts: [AgentThreadID: PendingTurnStart] = [:]
    private var inFlightToolRequests: [JSONRPCID: InFlightToolRequest] = [:]
    private var eventReplay: [AgentThreadID: [AgentEvent]] = [:]
    private var eventContinuations: [
        AgentThreadID: [UUID: AsyncStream<AgentEvent>.Continuation]
    ] = [:]
    private var availabilityValue: AgentAvailability = .starting
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentAvailability>.Continuation
    ] = [:]
    private var resumingThreads: Set<AgentThreadID> = []
    private var bufferedResumeNotifications: [
        AgentThreadID: [BufferedTurnNotification]
    ] = [:]
    private var overflowedResumeNotifications: Set<AgentThreadID> = []

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
        maximumInFlightToolRequests = Self
            .productionMaximumInFlightToolRequests
    }

    init(
        transport: JSONLAppServerTransport,
        launchConfiguration: CodexLaunchConfiguration,
        toolExecutor: any CodexDynamicToolExecuting,
        mappingStore: CodexAppServerThreadMappingStore = .init(),
        maximumInFlightToolRequests: Int
    ) {
        precondition(maximumInFlightToolRequests > 0)
        self.transport = transport
        self.launchConfiguration = launchConfiguration
        self.toolExecutor = toolExecutor
        self.mappingStore = mappingStore
        self.maximumInFlightToolRequests = maximumInFlightToolRequests
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
        maximumInFlightToolRequests = Self
            .productionMaximumInFlightToolRequests
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
        await mappingStore.insert(threadID)
        knownThreads.insert(threadID)
        return threadID
    }

    public func resumeThread(_ threadID: AgentThreadID) async throws {
        guard await mappingStore.contains(threadID) else {
            throw CodexAppServerAdapterError.unmappedThread
        }
        try await ensureReady()
        resumingThreads.insert(threadID)
        bufferedResumeNotifications[threadID] = []
        overflowedResumeNotifications.remove(threadID)
        do {
            let result = try await request(
                method: "thread/resume",
                params: .object(["threadId": .string(threadID.rawValue)])
            )
            guard self.threadID(in: result) == threadID else {
                throw CodexAppServerAdapterError.invalidResponse
            }
            guard !overflowedResumeNotifications.contains(threadID) else {
                throw CodexAppServerAdapterError.invalidResponse
            }
            let resumedTurnID = try activeTurnID(in: result)
            let resumedHistory = try history(in: result)
            knownThreads.insert(threadID)
            activeTurns.removeValue(forKey: threadID)
            if let resumedTurnID {
                activeTurns[threadID] = resumedTurnID
            }
            publish(.history(resumedHistory), for: threadID)
            resumingThreads.remove(threadID)
            let buffered = bufferedResumeNotifications.removeValue(
                forKey: threadID
            ) ?? []
            overflowedResumeNotifications.remove(threadID)
            for notification in buffered {
                processOwnedNotification(notification)
            }
        } catch {
            resumingThreads.remove(threadID)
            bufferedResumeNotifications.removeValue(forKey: threadID)
            overflowedResumeNotifications.remove(threadID)
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
        guard pendingTurnStarts[threadID] == nil else {
            throw CodexAppServerAdapterError.turnAlreadyStarting
        }
        let token = UUID()
        let transport = transport
        let params = JSONValue.object([
            "threadId": .string(threadID.rawValue),
            "input": textInput(prompt),
        ])
        let requestTask = Task<JSONValue, Error> {
            try await transport.request(method: "turn/start", params: params)
        }
        pendingTurnStarts[threadID] = PendingTurnStart(
            token: token,
            requestTask: requestTask,
            notifications: [],
            overflowed: false
        )
        let result: JSONValue
        do {
            result = try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: {
                requestTask.cancel()
            }
        } catch {
            removePendingTurnStart(threadID: threadID, token: token)
            throw normalized(error)
        }
        guard let pending = pendingTurnStarts[threadID],
            pending.token == token,
            !pending.overflowed,
            let turnID = turnID(in: result)
        else {
            removePendingTurnStart(threadID: threadID, token: token)
            throw CodexAppServerAdapterError.invalidResponse
        }
        pendingTurnStarts.removeValue(forKey: threadID)
        activeTurns[threadID] = turnID
        publish(.userMessage(prompt), for: threadID)
        publish(.turnStarted(turnID), for: threadID)
        for notification in pending.notifications
        where notification.turnID == turnID {
            processOwnedNotification(notification)
        }
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
        cancelPendingTurnStart(for: threadID)
        activeTurns.removeValue(forKey: threadID)
        knownThreads.remove(threadID)
        await mappingStore.remove(threadID)
        finishEvents(for: threadID)
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        consumerTask?.cancel()
        cancelAllPendingTurnStarts()
        await cancelAndDrainToolRequests()
        await transport.shutdown()
        if let consumerTask { await consumerTask.value }
        self.consumerTask = nil
        startupTask?.cancel()
        startupTask = nil
        activeTurns.removeAll()
        knownThreads.removeAll()
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

    var stateCountsForTesting: CodexAppServerAdapterStateCounts {
        .init(
            knownThreads: knownThreads.count,
            activeTurns: activeTurns.count,
            pendingTurnStarts: pendingTurnStarts.count,
            replayThreads: eventReplay.count,
            replayEvents: eventReplay.values.reduce(0) { $0 + $1.count },
            bufferedNotifications: pendingTurnStarts.values.reduce(0) {
                $0 + $1.notifications.count
            } + bufferedResumeNotifications.values.reduce(0) {
                $0 + $1.count
            }
        )
    }

    var availabilityForTesting: AgentAvailability { availabilityValue }

    var inFlightToolRequestCountForTesting: Int {
        inFlightToolRequests.count
    }

    var maximumInFlightToolRequestCountForTesting: Int {
        maximumInFlightToolRequests
    }

    func consumerFailedForTesting() async { await consumerFailed() }

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
            await beginServerRequest(id: id, method: method, params: params)
        }
    }

    private func beginServerRequest(
        id: JSONRPCID,
        method: String,
        params: JSONValue?
    ) async {
        guard !stopped else { return }
        if let duplicate = inFlightToolRequests.removeValue(forKey: id) {
            duplicate.task.cancel()
            try? await transport.respondError(
                to: id,
                code: -32600,
                message: "Duplicate request"
            )
            return
        }
        guard inFlightToolRequests.count < maximumInFlightToolRequests else {
            try? await transport.respondError(
                to: id,
                code: -32000,
                message: "Server busy"
            )
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.handleServerRequest(
                    method: method,
                    params: params
                )
                await self.finishServerRequest(
                    id: id,
                    token: token,
                    result: result
                )
            } catch {
                await self.finishServerRequestWithError(id: id, token: token)
            }
        }
        inFlightToolRequests[id] = InFlightToolRequest(
            token: token,
            task: task
        )
    }

    private func finishServerRequest(
        id: JSONRPCID,
        token: UUID,
        result: JSONValue
    ) async {
        guard inFlightToolRequests[id]?.token == token else { return }
        guard !stopped else {
            inFlightToolRequests.removeValue(forKey: id)
            return
        }
        try? await transport.respond(to: id, result: result)
        guard inFlightToolRequests[id]?.token == token else { return }
        inFlightToolRequests.removeValue(forKey: id)
    }

    private func finishServerRequestWithError(
        id: JSONRPCID,
        token: UUID
    ) async {
        guard inFlightToolRequests[id]?.token == token else { return }
        guard !stopped else {
            inFlightToolRequests.removeValue(forKey: id)
            return
        }
        try? await transport.respondError(
            to: id,
            code: -32601,
            message: "Method not found"
        )
        guard inFlightToolRequests[id]?.token == token else { return }
        inFlightToolRequests.removeValue(forKey: id)
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
        guard let notification = turnScopedNotification(
            method: method,
            params: params
        ) else { return }
        let threadID = notification.threadID
        guard knownThreads.contains(threadID)
            || resumingThreads.contains(threadID)
        else { return }
        if activeTurns[threadID] == notification.turnID {
            processOwnedNotification(notification)
            return
        }
        if pendingTurnStarts[threadID] != nil {
            bufferPendingStartNotification(notification)
            return
        }
        if resumingThreads.contains(threadID) {
            bufferResumeNotification(notification)
        }
    }

    private func turnScopedNotification(
        method: String,
        params: JSONValue?
    ) -> BufferedTurnNotification? {
        guard [
            "item/agentMessage/delta", "item/completed", "turn/completed",
            "error",
        ].contains(method),
            case let .object(fields)? = params,
            let thread = fields["threadId"]?.nonemptyString
        else { return nil }
        let turn: String?
        if method == "turn/completed" {
            guard case let .object(turnFields)? = fields["turn"] else {
                return nil
            }
            turn = turnFields["id"]?.nonemptyString
        } else {
            turn = fields["turnId"]?.nonemptyString
        }
        guard let turn else { return nil }
        return BufferedTurnNotification(
            method: method,
            params: params,
            threadID: AgentThreadID(rawValue: thread),
            turnID: AgentTurnID(rawValue: turn)
        )
    }

    private func processOwnedNotification(
        _ notification: BufferedTurnNotification
    ) {
        let threadID = notification.threadID
        let turnID = notification.turnID
        guard knownThreads.contains(threadID),
            activeTurns[threadID] == turnID,
            case let .object(fields)? = notification.params
        else { return }
        switch notification.method {
        case "item/agentMessage/delta":
            guard let delta = fields["delta"]?.nonemptyString else {
                failActiveTurn(threadID: threadID, turnID: turnID)
                return
            }
            publishLive(.assistantMessageDelta(delta), for: threadID)
        case "item/completed":
            guard case let .object(item)? = fields["item"],
                let itemType = item["type"]?.nonemptyString
            else {
                failActiveTurn(threadID: threadID, turnID: turnID)
                return
            }
            switch itemType {
            case "agentMessage":
                guard let text = item["text"]?.nonemptyString else {
                    failActiveTurn(threadID: threadID, turnID: turnID)
                    return
                }
                publishLive(.assistantMessageCompleted(text), for: threadID)
            case "dynamicToolCall":
                return
            default:
                return
            }
        case "turn/completed":
            guard case let .object(turn)? = fields["turn"],
                turn["id"]?.nonemptyString == turnID.rawValue,
                let status = turn["status"]?.nonemptyString
            else {
                failActiveTurn(threadID: threadID, turnID: turnID)
                return
            }
            activeTurns.removeValue(forKey: threadID)
            switch status {
            case "completed":
                publishLive(.turnCompleted(turnID), for: threadID)
            case "interrupted":
                publishLive(.turnFailed(turnID, .interrupted), for: threadID)
            case "failed":
                publishLive(.turnFailed(turnID, .protocolFailure), for: threadID)
            default:
                publishLive(.turnFailed(turnID, .protocolFailure), for: threadID)
            }
        case "error":
            guard fields["willRetry"]?.boolValue != nil,
                case let .object(error)? = fields["error"],
                error["message"]?.nonemptyString != nil
            else {
                failActiveTurn(threadID: threadID, turnID: turnID)
                return
            }
            if fields["willRetry"]?.boolValue == true { return }
            activeTurns.removeValue(forKey: threadID)
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
            return
        }
    }

    private func failActiveTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) {
        guard takeActiveTurn(threadID: threadID, turnID: turnID) else { return }
        publishLive(.turnFailed(turnID, .protocolFailure), for: threadID)
    }

    private func bufferPendingStartNotification(
        _ notification: BufferedTurnNotification
    ) {
        guard var pending = pendingTurnStarts[notification.threadID] else {
            return
        }
        guard pending.notifications.count
            < Self.maximumBufferedTurnNotifications
        else {
            pending.overflowed = true
            pendingTurnStarts[notification.threadID] = pending
            return
        }
        pending.notifications.append(notification)
        pendingTurnStarts[notification.threadID] = pending
    }

    private func bufferResumeNotification(
        _ notification: BufferedTurnNotification
    ) {
        let threadID = notification.threadID
        var notifications = bufferedResumeNotifications[threadID] ?? []
        guard notifications.count < Self.maximumBufferedTurnNotifications else {
            overflowedResumeNotifications.insert(threadID)
            return
        }
        notifications.append(notification)
        bufferedResumeNotifications[threadID] = notifications
    }

    private func removePendingTurnStart(
        threadID: AgentThreadID,
        token: UUID
    ) {
        guard pendingTurnStarts[threadID]?.token == token else { return }
        pendingTurnStarts.removeValue(forKey: threadID)
    }

    private func cancelPendingTurnStart(for threadID: AgentThreadID) {
        pendingTurnStarts.removeValue(forKey: threadID)?.requestTask.cancel()
    }

    private func cancelAllPendingTurnStarts() {
        let pending = pendingTurnStarts.values
        pendingTurnStarts.removeAll()
        for start in pending { start.requestTask.cancel() }
    }

    private func consumerFailed() async {
        guard !stopped else { return }
        cancelAllPendingTurnStarts()
        await cancelAndDrainToolRequests()
        resumingThreads.removeAll()
        bufferedResumeNotifications.removeAll()
        overflowedResumeNotifications.removeAll()
        let failedTurns = activeTurns
        activeTurns.removeAll()
        setAvailability(.crashed)
        for (threadID, turnID) in failedTurns {
            publishLive(.turnFailed(turnID, .crashed), for: threadID)
        }
    }

    private func cancelAndDrainToolRequests() async {
        let tasks = inFlightToolRequests.values.map(\.task)
        inFlightToolRequests.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func takeActiveTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) -> Bool {
        guard activeTurns[threadID] == turnID else { return false }
        activeTurns.removeValue(forKey: threadID)
        return true
    }

    private func publishLive(_ event: AgentEvent, for threadID: AgentThreadID) {
        publish(event, for: threadID)
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
        bufferedResumeNotifications.removeValue(forKey: threadID)
        overflowedResumeNotifications.remove(threadID)
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

    private func activeTurnID(in result: JSONValue) throws -> AgentTurnID? {
        guard case let .object(resultFields) = result,
            case let .object(thread)? = resultFields["thread"]
        else { throw CodexAppServerAdapterError.invalidResponse }
        guard let turnsValue = thread["turns"] else { return nil }
        guard case let .array(turnValues) = turnsValue else {
            throw CodexAppServerAdapterError.invalidResponse
        }
        let active = turnValues.compactMap { value -> AgentTurnID? in
            guard case let .object(turn) = value,
                turn["status"]?.nonemptyString == "inProgress",
                let rawValue = turn["id"]?.nonemptyString
            else { return nil }
            return AgentTurnID(rawValue: rawValue)
        }
        guard active.count <= 1 else {
            throw CodexAppServerAdapterError.invalidResponse
        }
        return active.first
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
