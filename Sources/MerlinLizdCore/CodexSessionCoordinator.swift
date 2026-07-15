import Foundation

private final class CodexActivitySubscriptionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func keepAlive() {}

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit { cancel() }
}

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
        let lifecycleRevision: UInt64
        let task: Task<Void, Never>
    }

    private struct DeletionOperation: Sendable {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private struct StopOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct TerminationOperation: Sendable {
        let id: UUID
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

    private struct ActivitySubscriber {
        var cursor: UInt64
        var needsInitialReconciliation: Bool
        var deliveredCounterExhaustion: Bool
        var waiters: [UUID: CheckedContinuation<Void, Never>]
    }

    private static let stateStreamCapacity = 1
    private static let activityTransitionLimit = 64
    private static let orphanLimit = 64

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
    private var terminalEventConsumerIDs: Set<UUID> = []
    private var threadOwners: [AgentThreadID: TerminalConversationKey] = [:]
    private var pendingTerminalEvents: [AgentThreadID: AgentEvent] = [:]
    private var lastAgentEventSequences: [AgentThreadID: UInt64] = [:]
    private var partialAssistantMessages: [TerminalConversationKey: String] = [:]
    private var volatileOrphans: [AgentThreadID: CodexOrphanedThread] = [:]
    private var orphanReservations: Set<UUID> = []
    private var stoppingKeys: Set<TerminalConversationKey> = []
    private var deletingKeys: Set<TerminalConversationKey> = []
    private var lifecycleRevisions: [TerminalConversationKey: UInt64] = [:]
    private var terminationOperations: [
        TerminalConversationKey: TerminationOperation
    ] = [:]
    private var terminationWaiters: [
        UUID: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]
    private var pendingStartWaiters: [
        UUID: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]
    private var deletionOperations: [
        TerminalConversationKey: DeletionOperation
    ] = [:]
    private var stopOperations: [
        TerminalConversationKey: StopOperation
    ] = [:]
    private var archiveOperations: [
        TerminalConversationKey: ArchiveOperation
    ] = [:]
    private var registryConsumer: SubscriptionConsumer?
    private var registryInstallation: SubscriptionInstallation?
    private var registrySubscriberID: UUID?
    private var routerActivityConsumer: SubscriptionConsumer?
    private var routerActivityInstallation: SubscriptionInstallation?
    private var routerActivitySubscriberID: UUID?
    private var routerActivities: [UUID: TerminalToolActivity] = [:]
    private var routerApprovals: [UUID: TerminalToolApprovalActivity] = [:]
    private var routerActivityRevision: UInt64 = 0
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
    private var activitySubscribers: [UUID: ActivitySubscriber] = [:]
    private var activityRevision: UInt64 = 0
    private var activityTransitions: [CodexSessionActivityEvent] = []
    private var activityCounterExhausted = false
    private var registryEventHook: (
        @Sendable (TerminalEndpointRegistryEvent) async -> Void
    )?
    private var routerActivityEventHook: (
        @Sendable (TerminalToolActivityEvent) async -> Void
    )?
    private var eventConsumerCancellationHook: (
        @Sendable () async -> Void
    )?
    private var pendingStartWaitHook: (@Sendable () async -> Void)?
    private var terminationWaitHook: (@Sendable () async -> Void)?

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
        guard !isShuttingDown else { throw CancellationError() }
        try await restorePersistedState()
        await ensureRegistryConsumer()
        await ensureRouterActivityConsumer()
        try await registry.register(endpoint)
    }

    public func unregisterEndpoint(_ endpointID: TerminalEndpointID) async {
        guard !isShuttingDown else { return }
        await ensureRegistryConsumer()
        await registry.unregister(endpointID)
    }

    public func focusEndpoint(_ endpointID: TerminalEndpointID) async throws {
        guard !isShuttingDown else { throw CancellationError() }
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
        if terminationOperations[key] != nil {
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
            await pendingStartWaitHook?()
            await waitForPendingStart(pending, key: key)
            guard !Task.isCancelled, !stoppingKeys.contains(key),
                !deletingKeys.contains(key),
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
        let lifecycleRevision = lifecycleRevisions[key, default: 0]
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart(
                prompt: prompt,
                key: key,
                startID: id,
                lifecycleRevision: lifecycleRevision
            )
        }
        pendingStarts[key] = PendingStart(
            id: id,
            lifecycleRevision: lifecycleRevision,
            task: task
        )
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishPendingStart(key: key, id: id)
    }

    private func waitForPendingStart(
        _ pending: PendingStart,
        key: TerminalConversationKey
    ) async {
        guard pendingStarts[key]?.id == pending.id else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                    pendingStarts[key]?.id == pending.id
                else {
                    continuation.resume()
                    return
                }
                pendingStartWaiters[pending.id, default: [:]][waiterID]
                    = continuation
            }
        } onCancel: {
            Task {
                await self.cancelPendingStartWaiter(
                    startID: pending.id,
                    waiterID: waiterID
                )
            }
        }
    }

    private func cancelPendingStartWaiter(
        startID: UUID,
        waiterID: UUID
    ) {
        pendingStartWaiters[startID]?.removeValue(forKey: waiterID)?.resume()
        if pendingStartWaiters[startID]?.isEmpty == true {
            pendingStartWaiters.removeValue(forKey: startID)
        }
    }

    private func finishPendingStart(
        key: TerminalConversationKey,
        id: UUID
    ) {
        if pendingStarts[key]?.id == id {
            pendingStarts.removeValue(forKey: key)
        }
        let waiters = pendingStartWaiters.removeValue(forKey: id) ?? [:]
        waiters.values.forEach { $0.resume() }
    }

    private func releaseAfterSteerFailure(
        key: TerminalConversationKey,
        threadID: AgentThreadID,
        active: ActiveTurn
    ) async {
        let lifecycleRevision = lifecycleRevisions[key, default: 0]
        guard activeTurns[key]?.handle == active.handle,
            activeTurns[key]?.turnID == active.turnID
        else { return }
        activeTurns.removeValue(forKey: key)
        let termination = beginTermination(of: key)
        defer { finishTermination(of: key, operation: termination) }
        try? await router.interruptTurn(
            handle: active.handle,
            turnID: active.turnID
        )
        await agent.interruptTurn(
            threadID: threadID,
            turnID: active.turnID
        )
        guard lifecycleRevisions[key, default: 0] == lifecycleRevision else {
            return
        }
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: .failed(.protocolFailure),
            pendingApprovals: []
        )
    }

    private func waitForTermination(
        of key: TerminalConversationKey
    ) async {
        guard let operation = terminationOperations[key] else { return }
        await terminationWaitHook?()
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                    terminationOperations[key]?.id == operation.id
                else {
                    continuation.resume()
                    return
                }
                terminationWaiters[operation.id, default: [:]][waiterID]
                    = continuation
            }
        } onCancel: {
            Task {
                await self.cancelTerminationWaiter(
                    operationID: operation.id,
                    waiterID: waiterID
                )
            }
        }
    }

    private func drainTermination(
        of key: TerminalConversationKey
    ) async {
        guard let operation = terminationOperations[key] else { return }
        await terminationWaitHook?()
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            guard terminationOperations[key]?.id == operation.id else {
                continuation.resume()
                return
            }
            terminationWaiters[operation.id, default: [:]][waiterID]
                = continuation
        }
    }

    private func cancelTerminationWaiter(
        operationID: UUID,
        waiterID: UUID
    ) {
        terminationWaiters[operationID]?.removeValue(forKey: waiterID)?.resume()
        if terminationWaiters[operationID]?.isEmpty == true {
            terminationWaiters.removeValue(forKey: operationID)
        }
    }

    private func beginTermination(
        of key: TerminalConversationKey
    ) -> TerminationOperation {
        precondition(terminationOperations[key] == nil)
        let operation = TerminationOperation(id: UUID())
        terminationOperations[key] = operation
        return operation
    }

    private func finishTermination(
        of key: TerminalConversationKey,
        operation: TerminationOperation
    ) {
        guard terminationOperations[key]?.id == operation.id else { return }
        terminationOperations.removeValue(forKey: key)
        let waiters = terminationWaiters.removeValue(forKey: operation.id) ?? [:]
        waiters.values.forEach { $0.resume() }
    }

    public func approve(_ requestID: UUID) async {
        guard !isShuttingDown else { return }
        if let approval = await router.activitySnapshot().approvals[requestID],
            stoppingKeys.contains(approval.conversationKey)
                || deletingKeys.contains(approval.conversationKey)
        {
            _ = await router.denyApproval(requestID)
            return
        }
        _ = await router.approveOnce(requestID)
    }

    public func deny(_ requestID: UUID) async {
        guard !isShuttingDown else { return }
        _ = await router.denyApproval(requestID)
    }

    public func stopAndTakeOver(_ key: TerminalConversationKey) async {
        guard !isShuttingDown else { return }
        if let deletion = deletionOperations[key] {
            _ = try? await deletion.task.value
            return
        }
        let operation = admitStopOperation(for: key)
        await operation.task.value
        finishStopOperation(key: key, id: operation.id)
    }

    private func admitStopOperation(
        for key: TerminalConversationKey
    ) -> StopOperation {
        if let existing = stopOperations[key] { return existing }
        stoppingKeys.insert(key)
        lifecycleRevisions[key, default: 0] &+= 1
        pendingStarts[key]?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStopAndTakeOver(key)
        }
        let operation = StopOperation(id: id, task: task)
        stopOperations[key] = operation
        return operation
    }

    private func finishStopOperation(
        key: TerminalConversationKey,
        id: UUID
    ) {
        guard stopOperations[key]?.id == id else { return }
        stopOperations.removeValue(forKey: key)
        stoppingKeys.remove(key)
    }

    private func performStopAndTakeOver(
        _ key: TerminalConversationKey
    ) async {
        await drainTermination(of: key)
        let active = activeTurns.removeValue(forKey: key)
        let termination = active.map { _ in beginTermination(of: key) }
        defer {
            if let termination {
                finishTermination(of: key, operation: termination)
            }
        }
        let prepared = preparedTurns.removeValue(forKey: key)
        if let active {
            try? await router.interruptTurn(
                handle: active.handle,
                turnID: active.turnID
            )
        } else if let prepared {
            try? await router.abortTurn(handle: prepared)
        }
        updateState(
            for: key,
            activeTurnID: .some(nil),
            phase: .interrupted,
            pendingApprovals: []
        )
        if let pending = pendingStarts[key] {
            pending.task.cancel()
            await pending.task.value
            finishPendingStart(key: key, id: pending.id)
        }
        if let threadID = sessionStates[key]?.threadID {
            pendingTerminalEvents.removeValue(forKey: threadID)
            await cancelEventConsumer(threadID)
        }
        if let active,
            let threadID = sessionStates[key]?.threadID
        {
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
    }

    public func setArchived(
        _ archived: Bool,
        for key: TerminalConversationKey
    ) async throws {
        guard !isShuttingDown else { throw CancellationError() }
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
        guard !isShuttingDown else { throw CancellationError() }
        if let existing = deletionOperations[key] {
            return try await existing.task.value
        }
        let id = UUID()
        let admittedArchive = archiveOperations[key]
        deletingKeys.insert(key)
        lifecycleRevisions[key, default: 0] &+= 1
        pendingStarts[key]?.task.cancel()
        let admittedStop = admitStopOperation(for: key)
        let task = Task { [weak self] in
            guard let self else { return }
            if let admittedArchive {
                _ = try? await admittedArchive.task.value
            }
            await admittedStop.task.value
            await self.finishStopOperation(
                key: key,
                id: admittedStop.id
            )
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
            lastAgentEventSequences.removeValue(forKey: record.threadID)
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
        guard !isShuttingDown else {
            return AsyncStream { $0.finish() }
        }
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

    public func activityEvents(
        after revision: UInt64? = nil
    ) -> AsyncStream<CodexSessionActivityEvent> {
        guard !isShuttingDown else {
            return AsyncStream(unfolding: { nil })
        }
        let id = UUID()
        activitySubscribers[id] = ActivitySubscriber(
            cursor: revision ?? activityRevision,
            needsInitialReconciliation: revision == nil,
            deliveredCounterExhaustion: false,
            waiters: [:]
        )
        let lifetime = CodexActivitySubscriptionLifetime { [weak self] in
            Task { await self?.cancelActivitySubscriber(id) }
        }
        return AsyncStream(unfolding: { [weak self, lifetime] in
            lifetime.keepAlive()
            return await self?.nextActivityEvent(
                subscriberID: id,
                waiterID: UUID()
            )
        })
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

    func setEventConsumerCancellationHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        eventConsumerCancellationHook = hook
    }

    func setPendingStartWaitHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        pendingStartWaitHook = hook
    }

    func setTerminationWaitHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        terminationWaitHook = hook
    }

    func activityHistoryForTesting() -> (
        revision: UInt64,
        count: Int,
        limit: Int,
        subscriberCount: Int,
        waiterCount: Int
    ) {
        (
            activityRevision,
            activityTransitions.count,
            Self.activityTransitionLimit,
            activitySubscribers.count,
            activitySubscribers.values.reduce(0) { $0 + $1.waiters.count }
        )
    }

    func terminationStateForTesting() -> (
        operationCount: Int,
        waiterCount: Int
    ) {
        (
            terminationOperations.count,
            terminationWaiters.values.reduce(0) { $0 + $1.count }
        )
    }

    func setActivityRevisionForTesting(_ revision: UInt64) {
        activityRevision = revision
        activityCounterExhausted = false
    }

    func routerActivityStateForTesting() -> (
        revision: UInt64,
        operationCount: Int,
        approvalCount: Int
    ) {
        (routerActivityRevision, routerActivities.count, routerApprovals.count)
    }

    public func shutdown() async {
        isShuttingDown = true
        stoppingKeys.formUnion(sessionStates.keys)
        for key in sessionStates.keys {
            lifecycleRevisions[key, default: 0] &+= 1
        }
        let stops = stopOperations
        let archives = archiveOperations
        let deletions = deletionOperations
        for operation in archives.values { operation.task.cancel() }
        for operation in deletions.values { operation.task.cancel() }
        let starts = pendingStarts
        for start in starts.values { start.task.cancel() }
        for (key, start) in starts {
            await start.task.value
            finishPendingStart(key: key, id: start.id)
        }

        while let key = terminationOperations.keys.first {
            await drainTermination(of: key)
        }
        let active = activeTurns
        activeTurns.removeAll()
        var activeTerminations: [
            TerminalConversationKey: TerminationOperation
        ] = [:]
        for (key, turn) in active {
            activeTerminations[key] = beginTermination(of: key)
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
            if let termination = activeTerminations[key] {
                finishTermination(of: key, operation: termination)
            }
        }

        let registryInstallation = self.registryInstallation
        self.registryInstallation = nil
        registryInstallation?.task.cancel()
        let registryConsumer = self.registryConsumer
        self.registryConsumer = nil
        registryConsumer?.task.cancel()
        let registrySubscriberID = self.registrySubscriberID
        self.registrySubscriberID = nil
        let routerInstallation = routerActivityInstallation
        routerActivityInstallation = nil
        routerInstallation?.task.cancel()
        let routerConsumer = routerActivityConsumer
        self.routerActivityConsumer = nil
        routerConsumer?.task.cancel()
        let routerSubscriberID = routerActivitySubscriberID
        routerActivitySubscriberID = nil
        let restoration = restorationTask
        restoration?.cancel()
        restorationTask = nil
        let consumers = Array(eventConsumers.values)
        eventConsumers.removeAll()
        terminalEventConsumerIDs.removeAll()
        for consumer in consumers { consumer.task.cancel() }
        if let registrySubscriberID {
            await registry.cancelSubscription(registrySubscriberID)
        }
        if let routerSubscriberID {
            await router.cancelActivitySubscription(routerSubscriberID)
        }
        for consumer in consumers { await consumer.task.value }
        if let registryInstallation { await registryInstallation.task.value }
        if let registryConsumer { await registryConsumer.task.value }
        if let routerInstallation { await routerInstallation.task.value }
        if let routerConsumer { await routerConsumer.task.value }
        for (key, operation) in stops {
            await operation.task.value
            if stopOperations[key]?.id == operation.id {
                stopOperations.removeValue(forKey: key)
                stoppingKeys.remove(key)
            }
        }
        for (key, operation) in archives {
            _ = try? await operation.task.value
            finishArchiveOperation(key: key, id: operation.id)
        }
        for (key, operation) in deletions {
            _ = try? await operation.task.value
            finishDeletionOperation(key: key, id: operation.id)
        }
        if let restoration { _ = try? await restoration.value }
        while let key = terminationOperations.keys.first {
            await drainTermination(of: key)
        }
        stateSubscribers.values.forEach {
            $0.onTermination = nil
            $0.finish()
        }
        let activityWaiters = activitySubscribers.values.flatMap {
            $0.waiters.values
        }
        stateSubscribers.removeAll()
        activitySubscribers.removeAll()
        activityWaiters.forEach { $0.resume() }
        await agent.shutdown()
    }

    private func performStart(
        prompt: String,
        key: TerminalConversationKey,
        startID: UUID,
        lifecycleRevision: UInt64
    ) async {
        var handle: AgentTurnHandle?
        var startedTurn: (threadID: AgentThreadID, turnID: AgentTurnID)?
        do {
            let threadID = try await resolveThread(for: key)
            guard ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) else {
                return
            }
            updateState(for: key, phase: .thinking)
            let prepared = try await router.beginTurn(
                threadID: threadID,
                conversationKey: key
            )
            handle = prepared
            guard ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) else {
                try? await router.abortTurn(handle: prepared)
                handle = nil
                return
            }
            preparedTurns[key] = prepared
            await reconcileRegistrySnapshot(await registry.pinSnapshot())
            try Task.checkCancellation()
            guard ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) else {
                preparedTurns.removeValue(forKey: key)
                try? await router.abortTurn(handle: prepared)
                handle = nil
                return
            }
            let turnID = try await agent.startTurn(
                threadID: threadID,
                prompt: prompt
            )
            startedTurn = (threadID, turnID)
            try Task.checkCancellation()
            guard ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) else {
                preparedTurns.removeValue(forKey: key)
                try? await router.abortTurn(handle: prepared)
                handle = nil
                await agent.interruptTurn(threadID: threadID, turnID: turnID)
                startedTurn = nil
                return
            }
            try await router.confirmTurnID(handle: prepared, turnID: turnID)
            guard ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) else {
                preparedTurns.removeValue(forKey: key)
                try? await router.interruptTurn(
                    handle: prepared,
                    turnID: turnID
                )
                handle = nil
                await agent.interruptTurn(threadID: threadID, turnID: turnID)
                startedTurn = nil
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
                await consumeEvent(
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
            if ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) {
                updateState(
                    for: key,
                    activeTurnID: .some(nil),
                    phase: .interrupted
                )
            }
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
            if ownsPendingStart(
                key: key,
                id: startID,
                lifecycleRevision: lifecycleRevision
            ) {
                updateState(
                    for: key,
                    activeTurnID: .some(nil),
                    phase: phase
                )
            }
        }
    }

    private func ownsPendingStart(
        key: TerminalConversationKey,
        id: UUID,
        lifecycleRevision: UInt64
    ) -> Bool {
        pendingStarts[key]?.id == id
            && pendingStarts[key]?.lifecycleRevision == lifecycleRevision
            && lifecycleRevisions[key, default: 0] == lifecycleRevision
            && !stoppingKeys.contains(key)
            && !deletingKeys.contains(key)
            && !isShuttingDown
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
        var snapshot = try await store.recoverDurableSnapshot()
        snapshot = await reconcileVolatileOrphans(after: snapshot)
        let record: CodexConversationRecord
        if let persisted = snapshot.records[key] {
            guard snapshot.deletions[key] == nil else {
                throw CodexSessionCoordinatorError.deletionPending
            }
            record = persisted
        } else {
            let reservation = try reserveOrphanCapacity(snapshot: snapshot)
            defer { orphanReservations.remove(reservation) }
            let threadID = try await agent.startThread()
            let created = CodexConversationRecord(key: key, threadID: threadID)
            do {
                snapshot = try await store.apply(.insertIfAbsent(created))
            } catch let firstError {
                do {
                    snapshot = try await store.recoverDurableSnapshot()
                } catch {
                    retainIndeterminateCandidate(
                        threadID: threadID,
                        attemptedKey: key
                    )
                    throw firstError
                }
                if snapshot.records[key] == nil {
                    do {
                        snapshot = try await store.apply(.insertIfAbsent(created))
                    } catch let retryError {
                        do {
                            snapshot = try await store.recoverDurableSnapshot()
                        } catch {
                            retainIndeterminateCandidate(
                                threadID: threadID,
                                attemptedKey: key
                            )
                            throw retryError
                        }
                        guard snapshot.records[key] != nil else {
                            await compensateOrphan(
                                threadID: threadID,
                                attemptedKey: key
                            )
                            throw retryError
                        }
                    }
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

    private func retainIndeterminateCandidate(
        threadID: AgentThreadID,
        attemptedKey: TerminalConversationKey
    ) {
        volatileOrphans[threadID] = CodexOrphanedThread(
            threadID: threadID,
            attemptedKey: attemptedKey,
            failure: .persistenceUnavailable,
            updatedAt: Date()
        )
        updateState(
            for: attemptedKey,
            phase: .failed(.persistenceUnavailable)
        )
    }

    private func reconcileVolatileOrphans(
        after durableSnapshot: CodexConversationStoreSnapshot
    ) async -> CodexConversationStoreSnapshot {
        var snapshot = durableSnapshot
        let candidates = volatileOrphans.values.sorted {
            $0.threadID.rawValue < $1.threadID.rawValue
        }
        for candidate in candidates {
            let isWinner = snapshot.records.values.contains {
                $0.threadID == candidate.threadID
            }
            if isWinner {
                clearVolatileOrphan(candidate)
                continue
            }
            do {
                try await agent.ensureThreadDeleted(candidate.threadID)
                if snapshot.orphans[candidate.threadID] != nil {
                    do {
                        snapshot = try await store.apply(
                            .removeOrphan(threadID: candidate.threadID)
                        )
                    } catch {
                        retainIndeterminateCandidate(
                            threadID: candidate.threadID,
                            attemptedKey: candidate.attemptedKey
                        )
                        continue
                    }
                }
                clearVolatileOrphan(candidate)
            } catch {
                if let persisted = await recordOrphanCompensationFailure(
                    threadID: candidate.threadID,
                    attemptedKey: candidate.attemptedKey
                ) {
                    snapshot = persisted
                }
            }
        }
        return snapshot
    }

    private func clearVolatileOrphan(_ orphan: CodexOrphanedThread) {
        volatileOrphans.removeValue(forKey: orphan.threadID)
        guard let state = sessionStates[orphan.attemptedKey] else { return }
        updateState(
            for: orphan.attemptedKey,
            orphanedThreads: state.orphanedThreads.filter {
                $0.threadID != orphan.threadID
            }
        )
    }

    private func reserveOrphanCapacity(
        snapshot: CodexConversationStoreSnapshot
    ) throws -> UUID {
        let retainedThreadIDs = Set(snapshot.orphans.keys)
            .union(volatileOrphans.keys)
        guard retainedThreadIDs.count + orphanReservations.count
            < Self.orphanLimit
        else { throw CodexConversationStoreError.orphanLimitReached }
        let reservation = UUID()
        orphanReservations.insert(reservation)
        return reservation
    }

    private func compensateOrphan(
        threadID: AgentThreadID,
        attemptedKey: TerminalConversationKey
    ) async {
        do {
            try await agent.ensureThreadDeleted(threadID)
            if let orphan = volatileOrphans[threadID] {
                clearVolatileOrphan(orphan)
            }
        } catch {
            _ = await recordOrphanCompensationFailure(
                threadID: threadID,
                attemptedKey: attemptedKey
            )
        }
    }

    private func recordOrphanCompensationFailure(
        threadID: AgentThreadID,
        attemptedKey: TerminalConversationKey
    ) async -> CodexConversationStoreSnapshot? {
        var orphan = CodexOrphanedThread(
            threadID: threadID,
            attemptedKey: attemptedKey,
            failure: .remoteUnavailable,
            updatedAt: Date()
        )
        volatileOrphans[threadID] = orphan
        let snapshot: CodexConversationStoreSnapshot?
        do {
            snapshot = try await store.apply(.recordOrphan(orphan))
        } catch {
            orphan.failure = .persistenceUnavailable
            orphan.updatedAt = Date()
            volatileOrphans[threadID] = orphan
            snapshot = nil
        }
        updateState(for: attemptedKey, phase: .failed(.persistenceUnavailable))
        return snapshot
    }

    private func ensureEventConsumer(
        threadID: AgentThreadID,
        key: TerminalConversationKey
    ) async throws {
        if eventConsumers[threadID] != nil { return }
        let stream = await agent.events(
            for: threadID,
            after: lastAgentEventSequences[threadID]
        )
        let id = UUID()
        let task = Task { [weak self] in
            for await delivery in stream {
                guard !Task.isCancelled else { return }
                switch delivery {
                case let .event(record):
                    guard await self?.consume(
                        record,
                        threadID: threadID,
                        key: key,
                        consumerID: id
                    ) == true else {
                        await self?.eventConsumerEnded(
                            threadID: threadID,
                            id: id,
                            reason: .replayGap
                        )
                        return
                    }
                case let .events(records):
                    for record in records {
                        guard await self?.consume(
                            record,
                            threadID: threadID,
                            key: key,
                            consumerID: id
                        ) == true else {
                            await self?.eventConsumerEnded(
                                threadID: threadID,
                                id: id,
                                reason: .replayGap
                            )
                            return
                        }
                    }
                case .replayGap:
                    await self?.eventConsumerEnded(
                        threadID: threadID,
                        id: id,
                        reason: .replayGap
                    )
                    return
                }
            }
            await self?.eventConsumerEnded(
                threadID: threadID,
                id: id,
                reason: .endOfStream
            )
        }
        eventConsumers[threadID] = EventConsumer(id: id, task: task)
    }

    private func cancelEventConsumer(_ threadID: AgentThreadID) async {
        guard let consumer = eventConsumers.removeValue(
            forKey: threadID
        ) else { return }
        terminalEventConsumerIDs.remove(consumer.id)
        await eventConsumerCancellationHook?()
        consumer.task.cancel()
        await consumer.task.value
    }

    private enum EventConsumerEndReason: Sendable {
        case endOfStream
        case replayGap
    }

    private func eventConsumerEnded(
        threadID: AgentThreadID,
        id: UUID,
        reason: EventConsumerEndReason
    ) async {
        _ = reason
        guard eventConsumers[threadID]?.id == id else { return }
        eventConsumers.removeValue(forKey: threadID)
        let reducedTerminal = terminalEventConsumerIDs.remove(id) != nil
        guard !isShuttingDown,
            let key = threadOwners.removeValue(forKey: threadID),
            !stoppingKeys.contains(key),
            !deletingKeys.contains(key)
        else { return }
        if reducedTerminal {
            resumedThreads.remove(threadID)
            return
        }
        pendingStarts[key]?.task.cancel()
        if let active = activeTurns.removeValue(forKey: key) {
            let termination = beginTermination(of: key)
            defer { finishTermination(of: key, operation: termination) }
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
            resumedThreads.remove(threadID)
            await agent.interruptTurn(
                threadID: threadID,
                turnID: active.turnID
            )
        } else {
            resumedThreads.remove(threadID)
            updateState(for: key, phase: .failed(.protocolFailure))
        }
    }

    private func consume(
        _ record: AgentEventRecord,
        threadID: AgentThreadID,
        key: TerminalConversationKey,
        consumerID: UUID
    ) async -> Bool {
        guard eventConsumers[threadID]?.id == consumerID,
            threadOwners[threadID] == key,
            !stoppingKeys.contains(key),
            !deletingKeys.contains(key)
        else { return true }
        if let previous = lastAgentEventSequences[threadID] {
            guard previous < UInt64.max else { return false }
            if record.sequence <= previous { return true }
            guard record.sequence == previous + 1 else { return false }
        }
        lastAgentEventSequences[threadID] = record.sequence
        await consumeEvent(
            record.event,
            threadID: threadID,
            key: key,
            consumerID: consumerID
        )
        return true
    }

    private func consumeEvent(
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
            let ownsCrashTerminal = failure == .crashed
                && (turnID == nil || activeTurns[key]?.turnID == turnID)
            let phase: CodexSessionPhase = failure == .interrupted
                ? .interrupted
                : .failed(mapFailure(failure))
            await finishTurn(
                key: key,
                turnID: turnID,
                phase: phase,
                termination: failure == .crashed ? .crash : .interrupt
            )
            if ownsCrashTerminal {
                terminalEventConsumerIDs.insert(consumerID)
            }
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
        let operation = beginTermination(of: key)
        defer { finishTermination(of: key, operation: operation) }
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
        else {
            if let subscriberID = subscription.subscriberID {
                await registry.cancelSubscription(subscriberID)
            }
            return
        }
        await reconcileRegistrySnapshot(subscription.snapshot)
        registrySubscriberID = subscription.subscriberID
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

    private func registryConsumerEnded(id: UUID) async {
        guard registryConsumer?.id == id else { return }
        registryConsumer = nil
        if let subscriberID = registrySubscriberID {
            registrySubscriberID = nil
            await registry.cancelSubscription(subscriberID)
        }
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
        let subscription = await router.subscribeActivity(
            after: routerActivityRevision
        )
        guard !Task.isCancelled, routerActivityInstallation?.id == id,
            routerActivityConsumer == nil
        else {
            if let subscriberID = subscription.subscriberID {
                await router.cancelActivitySubscription(subscriberID)
            }
            return
        }
        applyRouterActivityReconciliation(subscription.reconciliation)
        routerActivitySubscriberID = subscription.subscriberID
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

    private func routerActivityConsumerEnded(id: UUID) async {
        guard routerActivityConsumer?.id == id else { return }
        routerActivityConsumer = nil
        if let subscriberID = routerActivitySubscriberID {
            routerActivitySubscriberID = nil
            await router.cancelActivitySubscription(subscriberID)
        }
    }

    private func consumeRouterActivity(
        _ event: TerminalToolActivityEvent
    ) async {
        await routerActivityEventHook?(event)
        guard event.revision > routerActivityRevision else { return }
        guard let expectedRevision = checkedSuccessor(
            after: routerActivityRevision
        ), event.revision == expectedRevision else {
            await reconcileRouterActivity(after: routerActivityRevision)
            return
        }
        if case .reconciliationRequired = event {
            await reconcileRouterActivity(after: routerActivityRevision)
            return
        }
        applyRouterActivityTransition(event)
    }

    private func applyRouterActivityTransition(
        _ event: TerminalToolActivityEvent
    ) {
        guard let expectedRevision = checkedSuccessor(
            after: routerActivityRevision
        ), event.revision == expectedRevision else { return }
        routerActivityRevision = event.revision
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
            break
        }
    }

    private func reconcileRouterActivity(after revision: UInt64) async {
        let reconciliation = await router.reconcileActivity(after: revision)
        applyRouterActivityReconciliation(reconciliation)
    }

    private func applyRouterActivityReconciliation(
        _ reconciliation: TerminalToolActivityReconciliation
    ) {
        switch reconciliation {
        case let .replay(snapshot, transitions):
            guard snapshot.revision >= routerActivityRevision else { return }
            for event in transitions {
                if event.revision <= routerActivityRevision { continue }
                guard let expectedRevision = checkedSuccessor(
                    after: routerActivityRevision
                ), event.revision == expectedRevision else {
                    publishActivityHistoryGap()
                    reconcileRouterActivity(snapshot)
                    return
                }
                applyRouterActivityTransition(event)
            }
            if routerActivityRevision < snapshot.revision {
                publishActivityHistoryGap()
                reconcileRouterActivity(snapshot)
            }
        case let .historyGap(snapshot, _):
            guard snapshot.revision >= routerActivityRevision else { return }
            if snapshot.revision > routerActivityRevision {
                publishActivityHistoryGap()
            }
            reconcileRouterActivity(snapshot)
        }
    }

    private func checkedSuccessor(after revision: UInt64) -> UInt64? {
        guard revision < UInt64.max else { return nil }
        return revision + 1
    }

    private func reconcileRouterActivity(
        _ snapshot: TerminalToolActivitySnapshot
    ) {
        guard snapshot.revision >= routerActivityRevision else { return }
        routerActivityRevision = snapshot.revision
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
        let termination = beginTermination(of: key)
        defer { finishTermination(of: key, operation: termination) }
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
        archived: Bool? = nil,
        orphanedThreads: [CodexOrphanedThread]? = nil
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
            orphanedThreads: orphanedThreads ?? orphanState(
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

    private func cancelActivitySubscriber(_ id: UUID) {
        let waiters = activitySubscribers
            .removeValue(forKey: id)?.waiters.values ?? [:].values
        waiters.forEach { $0.resume() }
    }

    private func nextActivityEvent(
        subscriberID: UUID,
        waiterID: UUID
    ) async -> CodexSessionActivityEvent? {
        while true {
            guard !Task.isCancelled else {
                cancelActivityWaiter(
                    subscriberID: subscriberID,
                    waiterID: waiterID
                )
                return nil
            }
            guard var subscriber = activitySubscribers[subscriberID] else {
                return nil
            }
            if subscriber.needsInitialReconciliation {
                let snapshot = activitySnapshot()
                subscriber.cursor = snapshot.revision
                subscriber.needsInitialReconciliation = false
                subscriber.deliveredCounterExhaustion =
                    activityCounterExhausted
                activitySubscribers[subscriberID] = subscriber
                return .reconciliationRequired(snapshot)
            }
            if activityRevision > subscriber.cursor {
                let snapshot = activitySnapshot()
                guard subscriber.cursor < UInt64.max else {
                    cancelActivitySubscriber(subscriberID)
                    return nil
                }
                let successor = subscriber.cursor + 1
                guard let oldest = activityTransitions.first?.revision,
                    oldest <= successor
                else {
                    subscriber.cursor = snapshot.revision
                    subscriber.deliveredCounterExhaustion =
                        activityCounterExhausted
                    activitySubscribers[subscriberID] = subscriber
                    return .transitionHistoryGap(snapshot)
                }
                if let event = activityTransitions.first(where: {
                    $0.revision > subscriber.cursor
                }) {
                    subscriber.cursor = event.revision
                    activitySubscribers[subscriberID] = subscriber
                    return event
                }
                subscriber.cursor = snapshot.revision
                subscriber.deliveredCounterExhaustion =
                    activityCounterExhausted
                activitySubscribers[subscriberID] = subscriber
                return .transitionHistoryGap(snapshot)
            }
            if activityCounterExhausted {
                guard !subscriber.deliveredCounterExhaustion else {
                    cancelActivitySubscriber(subscriberID)
                    return nil
                }
                let snapshot = activitySnapshot()
                subscriber.cursor = snapshot.revision
                subscriber.deliveredCounterExhaustion = true
                activitySubscribers[subscriberID] = subscriber
                return .transitionHistoryGap(snapshot)
            }
            guard subscriber.cursor < UInt64.max else {
                cancelActivitySubscriber(subscriberID)
                return nil
            }
            guard !isShuttingDown else {
                cancelActivitySubscriber(subscriberID)
                return nil
            }
            await waitForActivity(
                subscriberID: subscriberID,
                waiterID: waiterID
            )
        }
    }

    private func waitForActivity(
        subscriberID: UUID,
        waiterID: UUID
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation(isolation: self) { continuation in
                guard !Task.isCancelled,
                    var subscriber = activitySubscribers[subscriberID]
                else {
                    continuation.resume()
                    return
                }
                subscriber.waiters[waiterID] = continuation
                activitySubscribers[subscriberID] = subscriber
            }
        } onCancel: {
            Task {
                await self.cancelActivityWaiter(
                    subscriberID: subscriberID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func wakeActivitySubscribers() {
        var waiters: [CheckedContinuation<Void, Never>] = []
        for id in Array(activitySubscribers.keys) {
            guard var subscriber = activitySubscribers[id] else { continue }
            waiters.append(contentsOf: subscriber.waiters.values)
            subscriber.waiters.removeAll()
            activitySubscribers[id] = subscriber
        }
        waiters.forEach { $0.resume() }
    }

    private func cancelActivityWaiter(
        subscriberID: UUID,
        waiterID: UUID
    ) {
        activitySubscribers[subscriberID]?
            .waiters.removeValue(forKey: waiterID)?.resume()
    }

    private func publishActivity(
        _ makeEvent: (UInt64) -> CodexSessionActivityEvent
    ) {
        guard let revision = nextActivityRevision() else {
            wakeActivitySubscribers()
            return
        }
        let event = makeEvent(revision)
        recordAndPublishActivity(event)
    }

    private func publishActivityHistoryGap() {
        guard nextActivityRevision() != nil else {
            wakeActivitySubscribers()
            return
        }
        recordAndPublishActivity(
            .transitionHistoryGap(activitySnapshot())
        )
    }

    private func nextActivityRevision() -> UInt64? {
        guard !activityCounterExhausted,
            activityRevision < UInt64.max
        else {
            activityCounterExhausted = true
            return nil
        }
        activityRevision += 1
        if activityRevision == UInt64.max {
            activityCounterExhausted = true
        }
        return activityRevision
    }

    private func recordAndPublishActivity(
        _ event: CodexSessionActivityEvent
    ) {
        activityTransitions.append(event)
        if activityTransitions.count > Self.activityTransitionLimit {
            activityTransitions.removeFirst(
                activityTransitions.count - Self.activityTransitionLimit
            )
        }
        wakeActivitySubscribers()
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
