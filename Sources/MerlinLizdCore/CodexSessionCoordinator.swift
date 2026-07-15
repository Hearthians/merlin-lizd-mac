import Foundation

public enum CodexConversationDeletionConfirmation: Sendable {
    case confirmed
}

public enum CodexSessionCoordinatorError: Error, Equatable, Sendable {
    case conversationNotFound
    case archiveReconciliationPending
    case archiveChangeConflict
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

    private struct DeletionOperation: Sendable {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private struct ArchiveOperation: Sendable {
        let id: UUID
        let desiredArchived: Bool
        let task: Task<Void, any Error>
    }

    private struct EventConsumer: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct SubscriptionConsumer: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct SubscriptionInstallation: Sendable {
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
    private var preparedTurns: [TerminalConversationKey: AgentTurnHandle] = [:]
    private var pendingStarts: [TerminalConversationKey: PendingStart] = [:]
    private var resumedThreads: Set<AgentThreadID> = []
    private var eventConsumers: [AgentThreadID: EventConsumer] = [:]
    private var threadOwners: [AgentThreadID: TerminalConversationKey] = [:]
    private var pendingTerminalEvents: [AgentThreadID: AgentEvent] = [:]
    private var partialAssistantMessages: [TerminalConversationKey: String] = [:]
    private var volatileOrphans: [AgentThreadID: CodexOrphanedThread] = [:]
    private var stoppingKeys: Set<TerminalConversationKey> = []
    private var deletingKeys: Set<TerminalConversationKey> = []
    private var terminatingKeys: Set<TerminalConversationKey> = []
    private var terminationWaiters: [
        TerminalConversationKey: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var deletionOperations: [
        TerminalConversationKey: DeletionOperation
    ] = [:]
    private var archiveOperations: [
        TerminalConversationKey: ArchiveOperation
    ] = [:]
    private var registryConsumer: SubscriptionConsumer?
    private var registryInstallation: SubscriptionInstallation?
    private var routerActivityConsumer: SubscriptionConsumer?
    private var routerActivityInstallation: SubscriptionInstallation?
    private var routerActivities: [UUID: TerminalToolActivity] = [:]
    private var routerApprovals: [UUID: TerminalToolApprovalActivity] = [:]
    private var registryPins: [TerminalEndpointPinID: TerminalEndpointPin] = [:]
    private var registryPinRevision: UInt64 = 0
    private var didRestorePersistedState = false
    private var isShuttingDown = false
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
    private var activityRevision: UInt64 = 0
    private var registryEventHook: (
        @Sendable (TerminalEndpointRegistryEvent) async -> Void
    )?
    private var routerActivityEventHook: (
        @Sendable (TerminalToolActivityEvent) async -> Void
    )?

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
        guard !Task.isCancelled, !isShuttingDown else { return }
        await ensureRegistryConsumer()
        await ensureRouterActivityConsumer()
        guard !Task.isCancelled, !isShuttingDown,
            !stoppingKeys.contains(key),
            !deletingKeys.contains(key),
            sessionStates[key]?.deletionRetry == nil
        else { return }
        if terminatingKeys.contains(key) {
            await waitForTermination(of: key)
            guard !Task.isCancelled else { return }
            await submit(prompt, for: key)
            return
        }
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
                await releaseAfterSteerFailure(
                    key: key,
                    threadID: threadID,
                    active: active
                )
            }
            return
        }
        if let pending = pendingStarts[key] {
            await pending.task.value
            guard !Task.isCancelled, !stoppingKeys.contains(key),
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
                await releaseAfterSteerFailure(
                    key: key,
                    threadID: threadID,
                    active: active
                )
            }
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart(prompt: prompt, key: key)
        }
        pendingStarts[key] = PendingStart(id: id, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if pendingStarts[key]?.id == id {
            pendingStarts.removeValue(forKey: key)
        }
    }

    private func releaseAfterSteerFailure(
        key: TerminalConversationKey,
        threadID: AgentThreadID,
        active: ActiveTurn
    ) async {
        guard activeTurns[key]?.handle == active.handle,
            activeTurns[key]?.turnID == active.turnID
        else { return }
        activeTurns.removeValue(forKey: key)
        terminatingKeys.insert(key)
        try? await router.interruptTurn(
            handle: active.handle,
            turnID: active.turnID
        )
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: .failed(.protocolFailure),
            pendingApprovals: []
        )
        await agent.interruptTurn(
            threadID: threadID,
            turnID: active.turnID
        )
        finishTermination(of: key)
    }

    private func waitForTermination(
        of key: TerminalConversationKey
    ) async {
        guard terminatingKeys.contains(key) else { return }
        await withCheckedContinuation {
            terminationWaiters[key, default: []].append($0)
        }
    }

    private func finishTermination(of key: TerminalConversationKey) {
        terminatingKeys.remove(key)
        let waiters = terminationWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
    }

    public func approve(_ requestID: UUID) async {
        _ = await router.approveOnce(requestID)
    }

    public func deny(_ requestID: UUID) async {
        _ = await router.denyApproval(requestID)
    }

    public func stopAndTakeOver(_ key: TerminalConversationKey) async {
        if let deletion = deletionOperations[key] {
            _ = try? await deletion.task.value
            return
        }
        await performStopAndTakeOver(key)
    }

    private func performStopAndTakeOver(
        _ key: TerminalConversationKey
    ) async {
        stoppingKeys.insert(key)
        if let threadID = sessionStates[key]?.threadID {
            pendingTerminalEvents.removeValue(forKey: threadID)
            await cancelEventConsumer(threadID)
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
            try? await router.interruptTurn(
                handle: active.handle,
                turnID: active.turnID
            )
            activeTurns.removeValue(forKey: key)
            updateState(
                for: key,
                activeTurnID: .some(nil),
                phase: .interrupted,
                pendingApprovals: []
            )
            await agent.interruptTurn(
                threadID: threadID,
                turnID: active.turnID
            )
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
        guard !deletingKeys.contains(key),
            sessionStates[key]?.deletionRetry == nil
        else { throw CodexSessionCoordinatorError.deletionPending }
        if let existing = archiveOperations[key] {
            guard existing.desiredArchived == archived else {
                throw CodexSessionCoordinatorError.archiveChangeConflict
            }
            return try await existing.task.value
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performArchiveChange(archived, for: key)
        }
        archiveOperations[key] = ArchiveOperation(
            id: id,
            desiredArchived: archived,
            task: task
        )
        do {
            try await task.value
            finishArchiveOperation(key: key, id: id)
        } catch {
            finishArchiveOperation(key: key, id: id)
            throw error
        }
    }

    private func finishArchiveOperation(
        key: TerminalConversationKey,
        id: UUID
    ) {
        guard archiveOperations[key]?.id == id else { return }
        archiveOperations.removeValue(forKey: key)
    }

    private func performArchiveChange(
        _ archived: Bool,
        for key: TerminalConversationKey
    ) async throws {
        let now = Date()
        let initial = try await store.snapshot()
        guard initial.records[key] != nil else {
            throw CodexSessionCoordinatorError.conversationNotFound
        }
        guard initial.deletions[key] == nil else {
            throw CodexSessionCoordinatorError.deletionPending
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
        guard reconciliation.desiredArchived == archived else {
            throw CodexSessionCoordinatorError.archiveChangeConflict
        }
        do {
            if reconciliation.stage < .remoteApplied {
                if reconciliation.desiredArchived {
                    try await agent.archiveThread(reconciliation.threadID)
                } else {
                    try await agent.unarchiveThread(reconciliation.threadID)
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
        if let existing = deletionOperations[key] {
            return try await existing.task.value
        }
        let id = UUID()
        let admittedArchive = archiveOperations[key]
        deletingKeys.insert(key)
        let task = Task { [weak self] in
            guard let self else { return }
            if let admittedArchive {
                _ = try? await admittedArchive.task.value
            }
            try await self.performDeletion(key)
        }
        deletionOperations[key] = DeletionOperation(id: id, task: task)
        do {
            try await task.value
            finishDeletionOperation(key: key, id: id)
        } catch {
            finishDeletionOperation(key: key, id: id)
            throw error
        }
    }

    private func finishDeletionOperation(
        key: TerminalConversationKey,
        id: UUID
    ) {
        guard deletionOperations[key]?.id == id else { return }
        deletionOperations.removeValue(forKey: key)
        deletingKeys.remove(key)
    }

    private func performDeletion(
        _ key: TerminalConversationKey
    ) async throws {
        await performStopAndTakeOver(key)
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
                try await agent.ensureThreadDeleted(record.threadID)
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
            await cancelEventConsumer(record.threadID)
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
        pair.continuation.yield(.reconciliationRequired(activitySnapshot()))
        return pair.stream
    }

    public func snapshot() -> [TerminalConversationKey: CodexSessionState] {
        sessionStates
    }

    func setRegistryEventHookForTesting(
        _ hook: (
            @Sendable (TerminalEndpointRegistryEvent) async -> Void
        )?
    ) {
        registryEventHook = hook
    }

    func setRouterActivityEventHookForTesting(
        _ hook: (@Sendable (TerminalToolActivityEvent) async -> Void)?
    ) {
        routerActivityEventHook = hook
    }

    public func shutdown() async {
        isShuttingDown = true
        stoppingKeys.formUnion(sessionStates.keys)
        let starts = Array(pendingStarts.values)
        for start in starts { start.task.cancel() }
        for start in starts { await start.task.value }
        pendingStarts.removeAll()

        let active = activeTurns
        activeTurns.removeAll()
        for (key, turn) in active {
            terminatingKeys.insert(key)
            try? await router.interruptTurn(
                handle: turn.handle,
                turnID: turn.turnID
            )
            updateState(
                for: key,
                activeTurnID: .some(nil),
                phase: .interrupted,
                pendingApprovals: []
            )
        }
        for (key, turn) in active {
            if let threadID = sessionStates[key]?.threadID {
                await agent.interruptTurn(
                    threadID: threadID,
                    turnID: turn.turnID
                )
            }
            finishTermination(of: key)
        }

        let registryInstallation = self.registryInstallation
        self.registryInstallation = nil
        registryInstallation?.task.cancel()
        let registryConsumer = self.registryConsumer
        self.registryConsumer = nil
        registryConsumer?.task.cancel()
        let routerInstallation = routerActivityInstallation
        routerActivityInstallation = nil
        routerInstallation?.task.cancel()
        let routerConsumer = routerActivityConsumer
        self.routerActivityConsumer = nil
        routerConsumer?.task.cancel()
        restorationTask?.cancel()
        restorationTask = nil
        let consumers = Array(eventConsumers.values)
        eventConsumers.removeAll()
        for consumer in consumers { consumer.task.cancel() }
        for consumer in consumers { await consumer.task.value }
        if let registryInstallation { await registryInstallation.task.value }
        if let registryConsumer { await registryConsumer.task.value }
        if let routerInstallation { await routerInstallation.task.value }
        if let routerConsumer { await routerConsumer.task.value }
        for key in terminationWaiters.keys { finishTermination(of: key) }
        stateSubscribers.values.forEach { $0.finish() }
        activitySubscribers.values.forEach { $0.finish() }
        stateSubscribers.removeAll()
        activitySubscribers.removeAll()
        await agent.shutdown()
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
            preparedTurns[key] = prepared
            await reconcileRegistrySnapshot(await registry.pinSnapshot())
            try Task.checkCancellation()
            let turnID = try await agent.startTurn(
                threadID: threadID,
                prompt: prompt
            )
            startedTurn = (threadID, turnID)
            try Task.checkCancellation()
            try await router.confirmTurnID(handle: prepared, turnID: turnID)
            guard !stoppingKeys.contains(key) else {
                preparedTurns.removeValue(forKey: key)
                try? await router.interruptTurn(
                    handle: prepared,
                    turnID: turnID
                )
                await agent.interruptTurn(threadID: threadID, turnID: turnID)
                updateState(for: key, phase: .interrupted)
                return
            }
            activeTurns[key] = ActiveTurn(handle: prepared, turnID: turnID)
            preparedTurns.removeValue(forKey: key)
            updateState(
                for: key,
                activeTurnID: .some(turnID),
                phase: .thinking
            )
            reconcileRouterActivity(await router.activitySnapshot())
            await reconcileRegistrySnapshot(await registry.pinSnapshot())
            if let pending = pendingTerminalEvents.removeValue(
                forKey: threadID
            ), let consumerID = eventConsumers[threadID]?.id {
                await consume(
                    pending,
                    threadID: threadID,
                    key: key,
                    consumerID: consumerID
                )
            }
        } catch is CancellationError {
            preparedTurns.removeValue(forKey: key)
            if let handle { try? await router.abortTurn(handle: handle) }
            if let startedTurn {
                await agent.interruptTurn(
                    threadID: startedTurn.threadID,
                    turnID: startedTurn.turnID
                )
            }
            if let threadID = sessionStates[key]?.threadID {
                pendingTerminalEvents.removeValue(forKey: threadID)
            }
            updateState(
                for: key,
                activeTurnID: .some(nil),
                phase: .interrupted
            )
        } catch {
            preparedTurns.removeValue(forKey: key)
            if let handle { try? await router.abortTurn(handle: handle) }
            if let startedTurn {
                await agent.interruptTurn(
                    threadID: startedTurn.threadID,
                    turnID: startedTurn.turnID
                )
            }
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
        var snapshot: CodexConversationStoreSnapshot
        do {
            snapshot = try await task.value
        } catch {
            restorationTask = nil
            throw error
        }
        for orphan in snapshot.orphans.values.sorted(by: {
            $0.threadID.rawValue < $1.threadID.rawValue
        }) {
            do {
                try await agent.ensureThreadDeleted(orphan.threadID)
                snapshot = try await store.apply(
                    .removeOrphan(threadID: orphan.threadID)
                )
                volatileOrphans.removeValue(forKey: orphan.threadID)
            } catch {
                // Preserve the existing durable orphan unchanged. A later
                // launch can retry the idempotent ensure-delete operation.
            }
        }
        for (key, record) in snapshot.records where sessionStates[key] == nil {
            sessionStates[key] = state(
                for: key,
                record: record,
                snapshot: snapshot,
                existing: nil
            )
        }
        for key in Set(snapshot.orphans.values.map(\.attemptedKey))
        where sessionStates[key] == nil {
            sessionStates[key] = CodexSessionState(
                key: key,
                phase: .failed(.persistenceUnavailable),
                orphanedThreads: orphanState(
                    for: key,
                    durable: Array(snapshot.orphans.values),
                    existing: []
                )
            )
        }
        didRestorePersistedState = true
        restorationTask = nil
        publishStates()
    }

    private func resolveThread(
        for key: TerminalConversationKey
    ) async throws -> AgentThreadID {
        var snapshot = try await store.snapshot()
        let record: CodexConversationRecord
        if let persisted = snapshot.records[key] {
            guard snapshot.deletions[key] == nil else {
                throw CodexSessionCoordinatorError.deletionPending
            }
            record = persisted
        } else {
            let threadID = try await agent.startThread()
            let created = CodexConversationRecord(key: key, threadID: threadID)
            do {
                snapshot = try await store.apply(.insertIfAbsent(created))
            } catch {
                do {
                    snapshot = try await store.apply(.insertIfAbsent(created))
                } catch {
                    await compensateOrphan(
                        threadID: threadID,
                        attemptedKey: key
                    )
                    throw error
                }
            }
            guard let winner = snapshot.records[key] else {
                await compensateOrphan(
                    threadID: threadID,
                    attemptedKey: key
                )
                throw CodexConversationStoreError.recordNotFound
            }
            if winner.threadID != threadID {
                await compensateOrphan(
                    threadID: threadID,
                    attemptedKey: key
                )
            }
            record = winner
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

    private func compensateOrphan(
        threadID: AgentThreadID,
        attemptedKey: TerminalConversationKey
    ) async {
        do {
            try await agent.ensureThreadDeleted(threadID)
            volatileOrphans.removeValue(forKey: threadID)
        } catch {
            var orphan = CodexOrphanedThread(
                threadID: threadID,
                attemptedKey: attemptedKey,
                failure: .remoteUnavailable,
                updatedAt: Date()
            )
            volatileOrphans[threadID] = orphan
            do {
                _ = try await store.apply(.recordOrphan(orphan))
            } catch {
                orphan.failure = .persistenceUnavailable
                orphan.updatedAt = Date()
                volatileOrphans[threadID] = orphan
            }
            updateState(for: attemptedKey, phase: .failed(.persistenceUnavailable))
        }
    }

    private func ensureEventConsumer(
        threadID: AgentThreadID,
        key: TerminalConversationKey
    ) async throws {
        if eventConsumers[threadID] != nil { return }
        let stream = await agent.events(for: threadID)
        let id = UUID()
        let task = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consume(
                    event,
                    threadID: threadID,
                    key: key,
                    consumerID: id
                )
            }
            await self?.eventConsumerEnded(threadID: threadID, id: id)
        }
        eventConsumers[threadID] = EventConsumer(id: id, task: task)
    }

    private func cancelEventConsumer(_ threadID: AgentThreadID) async {
        guard let consumer = eventConsumers.removeValue(
            forKey: threadID
        ) else { return }
        consumer.task.cancel()
        await consumer.task.value
    }

    private func eventConsumerEnded(
        threadID: AgentThreadID,
        id: UUID
    ) async {
        guard eventConsumers[threadID]?.id == id else { return }
        eventConsumers.removeValue(forKey: threadID)
        guard !isShuttingDown,
            let key = threadOwners.removeValue(forKey: threadID),
            !stoppingKeys.contains(key),
            !deletingKeys.contains(key)
        else { return }
        pendingStarts[key]?.task.cancel()
        if let active = activeTurns.removeValue(forKey: key) {
            terminatingKeys.insert(key)
            try? await router.crashTurn(
                handle: active.handle,
                turnID: active.turnID
            )
            updateState(
                for: key,
                activeTurnID: .some(nil),
                phase: .failed(.protocolFailure),
                pendingApprovals: []
            )
            finishTermination(of: key)
        } else {
            updateState(for: key, phase: .failed(.protocolFailure))
        }
    }

    private func consume(
        _ event: AgentEvent,
        threadID: AgentThreadID,
        key: TerminalConversationKey,
        consumerID: UUID
    ) async {
        guard eventConsumers[threadID]?.id == consumerID,
            threadOwners[threadID] == key,
            !stoppingKeys.contains(key),
            !deletingKeys.contains(key)
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
        activeTurns.removeValue(forKey: key)
        terminatingKeys.insert(key)
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
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: phase,
            pendingApprovals: []
        )
        finishTermination(of: key)
    }

    private func ensureRegistryConsumer() async {
        guard registryConsumer == nil else { return }
        if let installation = registryInstallation {
            await installation.task.value
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.installRegistryConsumer(id: id)
        }
        registryInstallation = SubscriptionInstallation(id: id, task: task)
        await task.value
        if registryInstallation?.id == id {
            registryInstallation = nil
        }
    }

    private func installRegistryConsumer(id: UUID) async {
        let subscription = await registry.subscribe()
        guard !Task.isCancelled, registryInstallation?.id == id,
            registryConsumer == nil
        else { return }
        await reconcileRegistrySnapshot(subscription.snapshot)
        let consumerID = UUID()
        let stream = subscription.events
        let task = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consumeRegistryEvent(event)
            }
            await self?.registryConsumerEnded(id: consumerID)
        }
        registryConsumer = SubscriptionConsumer(id: consumerID, task: task)
    }

    private func registryConsumerEnded(id: UUID) {
        guard registryConsumer?.id == id else { return }
        registryConsumer = nil
    }

    private func ensureRouterActivityConsumer() async {
        guard routerActivityConsumer == nil else { return }
        if let installation = routerActivityInstallation {
            await installation.task.value
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.installRouterActivityConsumer(id: id)
        }
        routerActivityInstallation = SubscriptionInstallation(id: id, task: task)
        await task.value
        if routerActivityInstallation?.id == id {
            routerActivityInstallation = nil
        }
    }

    private func installRouterActivityConsumer(id: UUID) async {
        let subscription = await router.subscribeActivity()
        guard !Task.isCancelled, routerActivityInstallation?.id == id,
            routerActivityConsumer == nil
        else { return }
        reconcileRouterActivity(subscription.snapshot)
        let consumerID = UUID()
        let stream = subscription.events
        let task = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.consumeRouterActivity(event)
            }
            await self?.routerActivityConsumerEnded(id: consumerID)
        }
        routerActivityConsumer = SubscriptionConsumer(
            id: consumerID,
            task: task
        )
    }

    private func routerActivityConsumerEnded(id: UUID) {
        guard routerActivityConsumer?.id == id else { return }
        routerActivityConsumer = nil
    }

    private func consumeRouterActivity(
        _ event: TerminalToolActivityEvent
    ) async {
        await routerActivityEventHook?(event)
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
            let isNew = routerApprovals[activity.request.id] == nil
            routerApprovals[activity.request.id] = activity
            reconcileActivity(for: activity.conversationKey)
            if isNew {
                publishActivity { revision in
                    .approvalRequested(
                        key: activity.conversationKey,
                        request: activity.request,
                        revision: revision
                    )
                }
            }
        case let .approvalRemoved(requestID, _):
            guard let activity = routerApprovals.removeValue(
                forKey: requestID
            ) else { return }
            reconcileActivity(for: activity.conversationKey)
            publishActivity { revision in
                .approvalResolved(
                    key: activity.conversationKey,
                    requestID: requestID,
                    revision: revision
                )
            }
        case .reconciliationRequired:
            reconcileRouterActivity(await router.activitySnapshot())
        }
    }

    private func reconcileRouterActivity(
        _ snapshot: TerminalToolActivitySnapshot
    ) {
        let previousApprovals = routerApprovals
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
        for (requestID, activity) in previousApprovals
        where routerApprovals[requestID] == nil {
            publishActivity { revision in
                .approvalResolved(
                    key: activity.conversationKey,
                    requestID: requestID,
                    revision: revision
                )
            }
        }
        for (requestID, activity) in routerApprovals
        where previousApprovals[requestID] == nil {
            publishActivity { revision in
                .approvalRequested(
                    key: activity.conversationKey,
                    request: activity.request,
                    revision: revision
                )
            }
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
        await registryEventHook?(event)
        guard event.revision > registryPinRevision else { return }
        registryPinRevision = event.revision
        switch event {
        case let .upsert(pin, _):
            registryPins[pin.id] = pin
        case let .removed(pinID, _):
            registryPins.removeValue(forKey: pinID)
            await reconcileKnownRegistryPins()
        case let .pinLost(loss, _):
            registryPins.removeValue(forKey: loss.pin.id)
            await handlePinLoss(loss)
        case .reconciliationRequired:
            await reconcileRegistrySnapshot(await registry.pinSnapshot())
        }
    }

    private func reconcileRegistrySnapshot(
        _ snapshot: TerminalEndpointRegistrySnapshot
    ) async {
        guard snapshot.revision >= registryPinRevision else { return }
        registryPinRevision = snapshot.revision
        registryPins = snapshot.pins
        await reconcileKnownRegistryPins()
    }

    private func reconcileKnownRegistryPins() async {
        for (key, prepared) in preparedTurns {
            let stillPinned = registryPins.values.contains {
                $0.handle == prepared && $0.conversationKey == key
            }
            if !stillPinned {
                pendingStarts[key]?.task.cancel()
            }
        }
        for (key, active) in activeTurns {
            let stillPinned = registryPins.values.contains {
                $0.handle == active.handle
                    && $0.turnID == active.turnID
                    && $0.conversationKey == key
            }
            if !stillPinned {
                await interruptForPinLoss(key: key, active: active)
            }
        }
    }

    private func handlePinLoss(_ loss: TerminalEndpointPinLoss) async {
        if preparedTurns[loss.conversationKey] == loss.handle {
            pendingStarts[loss.conversationKey]?.task.cancel()
        }
        guard let active = activeTurns[loss.conversationKey],
            active.handle == loss.handle,
            loss.turnID == nil || loss.turnID == active.turnID
        else { return }
        await interruptForPinLoss(key: loss.conversationKey, active: active)
    }

    private func interruptForPinLoss(
        key: TerminalConversationKey,
        active: ActiveTurn
    ) async {
        guard activeTurns[key]?.handle == active.handle,
            activeTurns[key]?.turnID == active.turnID,
            let threadID = sessionStates[key]?.threadID
        else { return }
        activeTurns.removeValue(forKey: key)
        terminatingKeys.insert(key)
        try? await router.interruptTurn(
            handle: active.handle,
            turnID: active.turnID
        )
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: .interrupted,
            pendingApprovals: []
        )
        await agent.interruptTurn(threadID: threadID, turnID: active.turnID)
        finishTermination(of: key)
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
            },
            orphanedThreads: orphanState(
                for: key,
                durable: Array(snapshot.orphans.values),
                existing: existing?.orphanedThreads ?? []
            )
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
            deletionRetry: current.deletionRetry,
            orphanedThreads: orphanState(
                for: key,
                durable: [],
                existing: current.orphanedThreads
            )
        )
        publishStates()
    }

    private func orphanState(
        for key: TerminalConversationKey,
        durable: [CodexOrphanedThread],
        existing: [CodexOrphanedThread]
    ) -> [CodexOrphanedThread] {
        var byThread = Dictionary(
            uniqueKeysWithValues: existing
                .filter { $0.attemptedKey == key }
                .map { ($0.threadID, $0) }
        )
        for orphan in durable where orphan.attemptedKey == key {
            byThread[orphan.threadID] = orphan
        }
        for orphan in volatileOrphans.values
        where orphan.attemptedKey == key && byThread[orphan.threadID] == nil {
            byThread[orphan.threadID] = orphan
        }
        return byThread.values
            .sorted { $0.threadID.rawValue < $1.threadID.rawValue }
            .prefix(64)
            .map { $0 }
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

    private func publishActivity(
        _ makeEvent: (UInt64) -> CodexSessionActivityEvent
    ) {
        activityRevision &+= 1
        let event = makeEvent(activityRevision)
        var ended: [UUID] = []
        for (id, subscriber) in activitySubscribers {
            switch subscriber.yield(event) {
            case .enqueued:
                break
            case .dropped:
                _ = subscriber.yield(
                    .reconciliationRequired(activitySnapshot())
                )
            case .terminated:
                ended.append(id)
            @unknown default:
                ended.append(id)
            }
        }
        ended.forEach { activitySubscribers.removeValue(forKey: $0) }
    }

    private func activitySnapshot() -> CodexSessionActivitySnapshot {
        CodexSessionActivitySnapshot(
            revision: activityRevision,
            states: sessionStates
        )
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
