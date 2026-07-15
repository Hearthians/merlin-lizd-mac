import Foundation

public enum CodexConversationDeletionConfirmation: Sendable {
    case confirmed
}

public enum CodexSessionCoordinatorError: Error, Equatable, Sendable {
    case conversationNotFound
    case archiveReconciliationPending
    case deletionPending
}

public actor CodexSessionCoordinator {
    private struct ActiveTurn: Sendable {
        let handle: AgentTurnHandle
        let turnID: AgentTurnID
    }

    private struct PendingStart: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let stateStreamCapacity = 1
    private static let activityStreamCapacity = 1

    private let agent: any CodexAgentClient
    private let store: any CodexConversationStoring
    private let registry: TerminalEndpointRegistry
    private let router: TerminalToolRouter
    private let journal: any TerminalOperationJournaling
    private let messageLimit: Int

    private var sessionStates: [TerminalConversationKey: CodexSessionState]
        = [:]
    private var activeTurns: [TerminalConversationKey: ActiveTurn] = [:]
    private var pendingStarts: [TerminalConversationKey: PendingStart] = [:]
    private var resumedThreads: Set<AgentThreadID> = []
    private var eventConsumers: [AgentThreadID: Task<Void, Never>] = [:]
    private var threadOwners: [AgentThreadID: TerminalConversationKey] = [:]
    private var pendingTerminalEvents: [AgentThreadID: AgentEvent] = [:]
    private var partialAssistantMessages: [TerminalConversationKey: String] = [:]
    private var stoppingKeys: Set<TerminalConversationKey> = []
    private var registryConsumer: Task<Void, Never>?
    private var routerActivityConsumer: Task<Void, Never>?
    private var routerActivities: [UUID: TerminalToolActivity] = [:]
    private var routerApprovals: [UUID: TerminalToolApprovalActivity] = [:]
    private var didRestorePersistedState = false
    private var restorationTask: Task<
        CodexConversationStoreSnapshot, any Error
    >?
    private var stateSubscribers: [
        UUID: AsyncStream<[
            TerminalConversationKey: CodexSessionState
        ]>.Continuation
    ] = [:]
    private var activitySubscribers: [
        UUID: AsyncStream<CodexSessionActivityEvent>.Continuation
    ] = [:]

    public init(
        agent: any CodexAgentClient,
        store: any CodexConversationStoring,
        registry: TerminalEndpointRegistry,
        router: TerminalToolRouter,
        journal: any TerminalOperationJournaling,
        messageLimit: Int = 200
    ) {
        precondition(messageLimit > 0)
        self.agent = agent
        self.store = store
        self.registry = registry
        self.router = router
        self.journal = journal
        self.messageLimit = messageLimit
    }

    public func registerEndpoint(_ endpoint: TerminalEndpoint) async throws {
        try await restorePersistedState()
        await ensureRegistryConsumer()
        await ensureRouterActivityConsumer()
        try await registry.register(endpoint)
    }

    public func unregisterEndpoint(_ endpointID: TerminalEndpointID) async {
        await ensureRegistryConsumer()
        await registry.unregister(endpointID)
    }

    public func focusEndpoint(_ endpointID: TerminalEndpointID) async throws {
        await ensureRegistryConsumer()
        try await registry.focus(endpointID)
    }

    public func submit(
        _ prompt: String,
        for key: TerminalConversationKey
    ) async {
        await ensureRegistryConsumer()
        await ensureRouterActivityConsumer()
        guard !stoppingKeys.contains(key) else { return }
        if let active = activeTurns[key],
            let threadID = sessionStates[key]?.threadID
        {
            do {
                try await agent.steerTurn(
                    threadID: threadID,
                    turnID: active.turnID,
                    prompt: prompt
                )
            } catch {
                updateState(for: key, phase: .failed(.protocolFailure))
            }
            return
        }
        if let pending = pendingStarts[key] {
            await pending.task.value
            guard !stoppingKeys.contains(key),
                let active = activeTurns[key],
                let threadID = sessionStates[key]?.threadID
            else { return }
            do {
                try await agent.steerTurn(
                    threadID: threadID,
                    turnID: active.turnID,
                    prompt: prompt
                )
            } catch {
                updateState(for: key, phase: .failed(.protocolFailure))
            }
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart(prompt: prompt, key: key)
        }
        pendingStarts[key] = PendingStart(id: id, task: task)
        await task.value
        if pendingStarts[key]?.id == id {
            pendingStarts.removeValue(forKey: key)
        }
    }

    public func approve(_ requestID: UUID) async {
        _ = await router.approveOnce(requestID)
    }

    public func deny(_ requestID: UUID) async {
        _ = await router.denyApproval(requestID)
    }

    public func stopAndTakeOver(_ key: TerminalConversationKey) async {
        stoppingKeys.insert(key)
        if let threadID = sessionStates[key]?.threadID {
            pendingTerminalEvents.removeValue(forKey: threadID)
        }
        if let pending = pendingStarts[key] {
            pending.task.cancel()
            await pending.task.value
            if pendingStarts[key]?.id == pending.id {
                pendingStarts.removeValue(forKey: key)
            }
        }
        if let active = activeTurns[key],
            let threadID = sessionStates[key]?.threadID
        {
            await agent.interruptTurn(
                threadID: threadID,
                turnID: active.turnID
            )
            try? await router.interruptTurn(
                handle: active.handle,
                turnID: active.turnID
            )
            activeTurns.removeValue(forKey: key)
        }
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: .interrupted,
            pendingApprovals: []
        )
        stoppingKeys.remove(key)
    }

    public func setArchived(
        _ archived: Bool,
        for key: TerminalConversationKey
    ) async throws {
        let now = Date()
        let initial = try await store.snapshot()
        guard let record = initial.records[key] else {
            throw CodexSessionCoordinatorError.conversationNotFound
        }
        var snapshot = initial
        if snapshot.archiveReconciliations[key] == nil {
            snapshot = try await store.apply(
                .beginArchiveChange(
                    key: key,
                    desiredArchived: archived,
                    updatedAt: now
                )
            )
        }
        guard let reconciliation = snapshot.archiveReconciliations[key] else {
            return
        }
        do {
            if reconciliation.stage < .remoteApplied {
                if archived {
                    try await agent.archiveThread(record.threadID)
                } else {
                    try await agent.unarchiveThread(record.threadID)
                }
                _ = try await store.apply(
                    .advanceArchiveChange(
                        key: key,
                        stage: .remoteApplied,
                        updatedAt: Date()
                    )
                )
            }
            let completed = try await store.apply(
                .completeArchiveChange(key: key, updatedAt: Date())
            )
            updateState(for: key, archived: completed.records[key]?.archived)
        } catch {
            _ = try? await store.apply(
                .recordArchiveFailure(
                    key: key,
                    failure: archiveFailure(for: error),
                    updatedAt: Date()
                )
            )
            throw CodexSessionCoordinatorError.archiveReconciliationPending
        }
    }

    public func deleteConversation(
        _ key: TerminalConversationKey,
        confirmation: CodexConversationDeletionConfirmation
    ) async throws {
        _ = confirmation
        await stopAndTakeOver(key)
        var snapshot = try await store.snapshot()
        guard let record = snapshot.records[key] else {
            throw CodexSessionCoordinatorError.conversationNotFound
        }
        if snapshot.deletions[key] == nil {
            snapshot = try await store.apply(
                .beginDeletion(key: key, updatedAt: Date())
            )
            updateState(from: snapshot, for: key)
        }
        guard var tombstone = snapshot.deletions[key] else {
            throw CodexSessionCoordinatorError.deletionPending
        }

        do {
            if tombstone.lastCompletedStage < .remoteThreadDeleted {
                try await agent.deleteThread(record.threadID)
                snapshot = try await store.apply(
                    .advanceDeletion(
                        key: key,
                        stage: .remoteThreadDeleted,
                        updatedAt: Date()
                    )
                )
                tombstone = snapshot.deletions[key]!
                updateState(from: snapshot, for: key)
            }
            if tombstone.lastCompletedStage < .journalDeleted {
                try await journal.deleteJournal(for: key)
                snapshot = try await store.apply(
                    .advanceDeletion(
                        key: key,
                        stage: .journalDeleted,
                        updatedAt: Date()
                    )
                )
                tombstone = snapshot.deletions[key]!
                updateState(from: snapshot, for: key)
            }
            if tombstone.lastCompletedStage < .routerForgotten {
                try await router.forgetThread(record.threadID)
                snapshot = try await store.apply(
                    .advanceDeletion(
                        key: key,
                        stage: .routerForgotten,
                        updatedAt: Date()
                    )
                )
                updateState(from: snapshot, for: key)
            }
            _ = try await store.apply(.completeDeletion(key: key))
            eventConsumers.removeValue(forKey: record.threadID)?.cancel()
            threadOwners.removeValue(forKey: record.threadID)
            resumedThreads.remove(record.threadID)
            activeTurns.removeValue(forKey: key)
            partialAssistantMessages.removeValue(forKey: key)
            sessionStates.removeValue(forKey: key)
            publishStates()
        } catch {
            let failure = deletionFailure(for: error, stage: tombstone.lastCompletedStage)
            if let failed = try? await store.apply(
                .recordDeletionFailure(
                    key: key,
                    failure: failure,
                    updatedAt: Date()
                )
            ) {
                updateState(from: failed, for: key)
            }
            throw CodexSessionCoordinatorError.deletionPending
        }
    }

    public func states() -> AsyncStream<[
        TerminalConversationKey: CodexSessionState
    ]> {
        let id = UUID()
        let pair = AsyncStream<[
            TerminalConversationKey: CodexSessionState
        ]>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.stateStreamCapacity)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        stateSubscribers[id] = pair.continuation
        pair.continuation.yield(sessionStates)
        return pair.stream
    }

    public func activityEvents() -> AsyncStream<CodexSessionActivityEvent> {
        let id = UUID()
        let pair = AsyncStream<CodexSessionActivityEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.activityStreamCapacity)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivitySubscriber(id) }
        }
        activitySubscribers[id] = pair.continuation
        return pair.stream
    }

    public func snapshot() -> [TerminalConversationKey: CodexSessionState] {
        sessionStates
    }

    public func shutdown() async {
        registryConsumer?.cancel()
        registryConsumer = nil
        routerActivityConsumer?.cancel()
        routerActivityConsumer = nil
        restorationTask?.cancel()
        restorationTask = nil
        for task in pendingStarts.values.map(\.task) { task.cancel() }
        for task in eventConsumers.values { task.cancel() }
        pendingStarts.removeAll()
        eventConsumers.removeAll()
        stateSubscribers.values.forEach { $0.finish() }
        activitySubscribers.values.forEach { $0.finish() }
        stateSubscribers.removeAll()
        activitySubscribers.removeAll()
    }

    private func performStart(
        prompt: String,
        key: TerminalConversationKey
    ) async {
        var handle: AgentTurnHandle?
        var startedTurn: (threadID: AgentThreadID, turnID: AgentTurnID)?
        do {
            let threadID = try await resolveThread(for: key)
            guard !stoppingKeys.contains(key) else {
                updateState(for: key, phase: .interrupted)
                return
            }
            updateState(for: key, phase: .thinking)
            let prepared = try await router.beginTurn(
                threadID: threadID,
                conversationKey: key
            )
            handle = prepared
            try Task.checkCancellation()
            let turnID = try await agent.startTurn(
                threadID: threadID,
                prompt: prompt
            )
            startedTurn = (threadID, turnID)
            try Task.checkCancellation()
            try await router.confirmTurnID(handle: prepared, turnID: turnID)
            guard !stoppingKeys.contains(key) else {
                await agent.interruptTurn(threadID: threadID, turnID: turnID)
                try? await router.interruptTurn(
                    handle: prepared,
                    turnID: turnID
                )
                updateState(for: key, phase: .interrupted)
                return
            }
            activeTurns[key] = ActiveTurn(handle: prepared, turnID: turnID)
            updateState(
                for: key,
                activeTurnID: .some(turnID),
                phase: .thinking
            )
            reconcileRouterActivity(await router.activitySnapshot())
            if let pending = pendingTerminalEvents.removeValue(
                forKey: threadID
            ) {
                await consume(pending, threadID: threadID, key: key)
            }
        } catch is CancellationError {
            if let startedTurn {
                await agent.interruptTurn(
                    threadID: startedTurn.threadID,
                    turnID: startedTurn.turnID
                )
            }
            if let handle { try? await router.abortTurn(handle: handle) }
            if let threadID = sessionStates[key]?.threadID {
                pendingTerminalEvents.removeValue(forKey: threadID)
            }
            updateState(
                for: key,
                activeTurnID: .some(nil),
                phase: .interrupted
            )
        } catch {
            if let startedTurn {
                await agent.interruptTurn(
                    threadID: startedTurn.threadID,
                    turnID: startedTurn.turnID
                )
            }
            if let handle { try? await router.abortTurn(handle: handle) }
            if let threadID = sessionStates[key]?.threadID {
                pendingTerminalEvents.removeValue(forKey: threadID)
            }
            let phase: CodexSessionPhase
            if startedTurn != nil, error is TerminalToolRouterError {
                phase = .interrupted
            } else {
                phase = .failed(mapFailure(error))
            }
            updateState(
                for: key,
                activeTurnID: .some(nil),
                phase: phase
            )
        }
    }

    private func restorePersistedState() async throws {
        if didRestorePersistedState { return }
        let task: Task<CodexConversationStoreSnapshot, any Error>
        if let existing = restorationTask {
            task = existing
        } else {
            let store = self.store
            let created = Task {
                try await store.snapshot()
            }
            restorationTask = created
            task = created
        }
        let snapshot: CodexConversationStoreSnapshot
        do {
            snapshot = try await task.value
        } catch {
            restorationTask = nil
            throw error
        }
        for (key, record) in snapshot.records where sessionStates[key] == nil {
            sessionStates[key] = state(
                for: key,
                record: record,
                snapshot: snapshot,
                existing: nil
            )
        }
        didRestorePersistedState = true
        restorationTask = nil
        publishStates()
    }

    private func resolveThread(
        for key: TerminalConversationKey
    ) async throws -> AgentThreadID {
        let snapshot = try await store.snapshot()
        let record: CodexConversationRecord
        if let persisted = snapshot.records[key] {
            record = persisted
        } else {
            let threadID = try await agent.startThread()
            let created = CodexConversationRecord(key: key, threadID: threadID)
            do {
                _ = try await store.apply(.upsert(created))
            } catch {
                try? await agent.deleteThread(threadID)
                throw error
            }
            record = created
        }

        threadOwners[record.threadID] = key
        sessionStates[key] = state(
            for: key,
            record: record,
            snapshot: snapshot,
            existing: sessionStates[key]
        )
        publishStates()
        try await ensureEventConsumer(threadID: record.threadID, key: key)
        if !resumedThreads.contains(record.threadID) {
            if snapshot.records[key] != nil {
                try await agent.resumeThread(record.threadID)
            }
            resumedThreads.insert(record.threadID)
        }
        return record.threadID
    }

    private func ensureEventConsumer(
        threadID: AgentThreadID,
        key: TerminalConversationKey
    ) async throws {
        if eventConsumers[threadID] != nil { return }
        let stream = await agent.events(for: threadID)
        let task = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consume(event, threadID: threadID, key: key)
            }
        }
        eventConsumers[threadID] = task
    }

    private func consume(
        _ event: AgentEvent,
        threadID: AgentThreadID,
        key: TerminalConversationKey
    ) async {
        guard threadOwners[threadID] == key,
            !stoppingKeys.contains(key)
        else { return }
        switch event {
        case let .history(messages):
            partialAssistantMessages.removeValue(forKey: key)
            updateState(for: key, messages: bounded(messages))
        case let .userMessage(text):
            appendMessage(AgentMessage(role: .user, text: text), for: key)
        case let .assistantMessageDelta(delta):
            if let existing = partialAssistantMessages[key] {
                let partial = existing + delta
                partialAssistantMessages[key] = partial
                replacePartialAssistant(partial, for: key)
            } else {
                partialAssistantMessages[key] = delta
                appendMessage(
                    AgentMessage(role: .assistant, text: delta),
                    for: key
                )
            }
        case let .assistantMessageCompleted(text):
            if partialAssistantMessages.removeValue(forKey: key) != nil {
                replacePartialAssistant(text, for: key)
            } else {
                appendMessage(
                    AgentMessage(role: .assistant, text: text),
                    for: key
                )
            }
        case .turnStarted:
            updateState(for: key, phase: .thinking)
        case let .turnCompleted(turnID):
            guard activeTurns[key] != nil else {
                if pendingStarts[key] != nil {
                    pendingTerminalEvents[threadID] = event
                }
                return
            }
            await finishTurn(
                key: key,
                turnID: turnID,
                phase: .waitingForUser,
                termination: .end
            )
        case let .turnFailed(turnID, failure):
            guard activeTurns[key] != nil else {
                if pendingStarts[key] != nil {
                    pendingTerminalEvents[threadID] = event
                }
                return
            }
            let phase: CodexSessionPhase = failure == .interrupted
                ? .interrupted
                : .failed(mapFailure(failure))
            await finishTurn(
                key: key,
                turnID: turnID,
                phase: phase,
                termination: failure == .crashed ? .crash : .interrupt
            )
        }
    }

    private enum Termination { case end, interrupt, crash }

    private func finishTurn(
        key: TerminalConversationKey,
        turnID: AgentTurnID?,
        phase: CodexSessionPhase,
        termination: Termination
    ) async {
        guard let active = activeTurns[key],
            turnID == nil || turnID == active.turnID
        else { return }
        switch termination {
        case .end:
            try? await router.endTurn(
                handle: active.handle,
                turnID: active.turnID
            )
        case .interrupt:
            try? await router.interruptTurn(
                handle: active.handle,
                turnID: active.turnID
            )
        case .crash:
            try? await router.crashTurn(
                handle: active.handle,
                turnID: active.turnID
            )
        }
        activeTurns.removeValue(forKey: key)
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: phase,
            pendingApprovals: []
        )
    }

    private func ensureRegistryConsumer() async {
        guard registryConsumer == nil else { return }
        let subscription = await registry.subscribe()
        let stream = subscription.events
        registryConsumer = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consumeRegistryEvent(event)
            }
        }
    }

    private func ensureRouterActivityConsumer() async {
        guard routerActivityConsumer == nil else { return }
        let subscription = await router.subscribeActivity()
        reconcileRouterActivity(subscription.snapshot)
        let stream = subscription.events
        routerActivityConsumer = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consumeRouterActivity(event)
            }
        }
    }

    private func consumeRouterActivity(
        _ event: TerminalToolActivityEvent
    ) async {
        switch event {
        case let .operationUpserted(activity, _):
            guard owns(activity) else { return }
            routerActivities[activity.id] = activity
            reconcileActivity(for: activity.conversationKey)
        case let .operationRemoved(id, _):
            guard let activity = routerActivities.removeValue(forKey: id) else {
                return
            }
            reconcileActivity(for: activity.conversationKey)
        case let .approvalUpserted(activity, _):
            guard owns(activity) else { return }
            routerApprovals[activity.request.id] = activity
            reconcileActivity(for: activity.conversationKey)
            publishActivity(
                .approvalRequested(
                    key: activity.conversationKey,
                    request: activity.request
                )
            )
        case let .approvalRemoved(requestID, _):
            guard let activity = routerApprovals.removeValue(
                forKey: requestID
            ) else { return }
            reconcileActivity(for: activity.conversationKey)
            publishActivity(
                .approvalResolved(
                    key: activity.conversationKey,
                    requestID: requestID
                )
            )
        case .reconciliationRequired:
            reconcileRouterActivity(await router.activitySnapshot())
        }
    }

    private func reconcileRouterActivity(
        _ snapshot: TerminalToolActivitySnapshot
    ) {
        let previousKeys = Set(
            routerActivities.values.map(\.conversationKey)
                + routerApprovals.values.map(\.conversationKey)
        )
        routerActivities = snapshot.operations.filter { owns($0.value) }
        routerApprovals = snapshot.approvals.filter { owns($0.value) }
        let currentKeys = Set(
            routerActivities.values.map(\.conversationKey)
                + routerApprovals.values.map(\.conversationKey)
        )
        for key in previousKeys.union(currentKeys) {
            reconcileActivity(for: key)
        }
    }

    private func owns(_ activity: TerminalToolActivity) -> Bool {
        guard let active = activeTurns[activity.conversationKey] else {
            return false
        }
        return active.handle == activity.handle
            && active.turnID == activity.turnID
    }

    private func owns(_ activity: TerminalToolApprovalActivity) -> Bool {
        guard let active = activeTurns[activity.conversationKey] else {
            return false
        }
        return active.handle == activity.handle
            && active.turnID == activity.turnID
    }

    private func reconcileActivity(for key: TerminalConversationKey) {
        let approvals = routerApprovals.values
            .filter { $0.conversationKey == key }
            .map(\.request)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        if !approvals.isEmpty {
            updateState(
                for: key,
                phase: .awaitingApproval,
                pendingApprovals: approvals
            )
            return
        }
        let isControlling = routerActivities.values.contains {
            $0.conversationKey == key
        }
        if isControlling {
            updateState(
                for: key,
                phase: .controlling,
                pendingApprovals: []
            )
        } else if activeTurns[key] != nil {
            updateState(
                for: key,
                phase: .thinking,
                pendingApprovals: []
            )
        }
    }

    private func consumeRegistryEvent(
        _ event: TerminalEndpointRegistryEvent
    ) async {
        guard case let .pinLost(loss, _) = event,
            let active = activeTurns[loss.conversationKey],
            active.handle == loss.handle,
            loss.turnID == nil || loss.turnID == active.turnID,
            let threadID = sessionStates[loss.conversationKey]?.threadID
        else { return }
        await agent.interruptTurn(threadID: threadID, turnID: active.turnID)
        try? await router.interruptTurn(
            handle: active.handle,
            turnID: active.turnID
        )
        activeTurns.removeValue(forKey: loss.conversationKey)
        updateState(
            for: loss.conversationKey,
            activeTurnID: .some(nil),
            phase: .interrupted,
            pendingApprovals: []
        )
    }

    private func state(
        for key: TerminalConversationKey,
        record: CodexConversationRecord,
        snapshot: CodexConversationStoreSnapshot,
        existing: CodexSessionState?
    ) -> CodexSessionState {
        let tombstone = snapshot.deletions[key]
        return CodexSessionState(
            key: key,
            threadID: record.threadID,
            activeTurnID: existing?.activeTurnID,
            phase: existing?.phase ?? .idle,
            messages: existing?.messages ?? [],
            pendingApprovals: existing?.pendingApprovals ?? [],
            archived: record.archived,
            deletionRetry: tombstone.map {
                CodexDeletionRetryState(
                    stage: $0.lastCompletedStage,
                    failure: $0.failure,
                    updatedAt: $0.updatedAt
                )
            }
        )
    }

    private func updateState(from snapshot: CodexConversationStoreSnapshot, for key: TerminalConversationKey) {
        guard let record = snapshot.records[key] else { return }
        sessionStates[key] = state(
            for: key,
            record: record,
            snapshot: snapshot,
            existing: sessionStates[key]
        )
        publishStates()
    }

    private func updateState(
        for key: TerminalConversationKey,
        threadID: AgentThreadID?? = nil,
        activeTurnID: AgentTurnID?? = nil,
        phase: CodexSessionPhase? = nil,
        messages: [AgentMessage]? = nil,
        pendingApprovals: [TerminalApprovalRequest]? = nil,
        archived: Bool? = nil
    ) {
        let current = sessionStates[key] ?? CodexSessionState(key: key)
        sessionStates[key] = CodexSessionState(
            key: key,
            threadID: threadID ?? current.threadID,
            activeTurnID: activeTurnID ?? current.activeTurnID,
            phase: phase ?? current.phase,
            messages: messages ?? current.messages,
            pendingApprovals: pendingApprovals ?? current.pendingApprovals,
            archived: archived ?? current.archived,
            deletionRetry: current.deletionRetry
        )
        publishStates()
    }

    private func appendMessage(_ message: AgentMessage, for key: TerminalConversationKey) {
        let messages = bounded((sessionStates[key]?.messages ?? []) + [message])
        updateState(for: key, messages: messages)
    }

    private func replacePartialAssistant(_ text: String, for key: TerminalConversationKey) {
        var messages = sessionStates[key]?.messages ?? []
        if messages.last?.role == .assistant {
            messages.removeLast()
        }
        messages.append(AgentMessage(role: .assistant, text: text))
        updateState(for: key, messages: bounded(messages))
    }

    private func bounded(_ messages: [AgentMessage]) -> [AgentMessage] {
        Array(messages.suffix(messageLimit))
    }

    private func publishStates() {
        var ended: [UUID] = []
        for (id, subscriber) in stateSubscribers {
            if case .terminated = subscriber.yield(sessionStates) {
                ended.append(id)
            }
        }
        ended.forEach { stateSubscribers.removeValue(forKey: $0) }
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers.removeValue(forKey: id)
    }

    private func removeActivitySubscriber(_ id: UUID) {
        activitySubscribers.removeValue(forKey: id)
    }

    private func publishActivity(_ event: CodexSessionActivityEvent) {
        var ended: [UUID] = []
        for (id, subscriber) in activitySubscribers {
            if case .terminated = subscriber.yield(event) {
                ended.append(id)
            }
        }
        ended.forEach { activitySubscribers.removeValue(forKey: $0) }
    }

    private func mapFailure(_ error: any Error) -> CodexFailure {
        if error is CodexConversationStoreError { return .persistenceUnavailable }
        if error is TerminalEndpointRegistryError
            || error is TerminalToolRouterError
        {
            return .endpointUnavailable
        }
        return .protocolFailure
    }

    private func mapFailure(_ failure: AgentFailure) -> CodexFailure {
        switch failure {
        case .authenticationRequired: .authenticationRequired
        case .overloaded: .overloaded
        case .capabilityUnavailable: .capabilityUnavailable
        case .interrupted: .interrupted
        case .crashed: .crashed
        case .protocolFailure: .protocolFailure
        }
    }

    private func archiveFailure(for error: any Error) -> CodexArchiveFailure {
        if error is CodexConversationStoreError { return .persistenceUnavailable }
        return .remoteUnavailable
    }

    private func deletionFailure(
        for error: any Error,
        stage: CodexDeletionStage
    ) -> CodexDeletionFailure {
        if error is CodexConversationStoreError { return .persistenceUnavailable }
        if error is TerminalToolRouterError { return .routerBusy }
        if stage < .remoteThreadDeleted { return .remoteUnavailable }
        if stage < .journalDeleted { return .journalUnavailable }
        return .unknown
    }
}
