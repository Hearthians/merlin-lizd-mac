import Foundation

private actor TerminalToolOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var busy: Set<TerminalConversationKey> = []
    private var waiters: [TerminalConversationKey: [Waiter]] = [:]

    func acquire(_ key: TerminalConversationKey) async throws {
        try Task.checkCancellation()
        if busy.insert(key).inserted { return }

        let id = UUID()
        var acquired = false
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters[key, default: []].append(
                        Waiter(id: id, continuation: continuation)
                    )
                }
            } onCancel: {
                Task { await self.cancel(id: id, key: key) }
            }
            acquired = true
            try Task.checkCancellation()
        } catch {
            if acquired {
                release(key)
            }
            throw error
        }
    }

    func release(_ key: TerminalConversationKey) {
        guard var queued = waiters[key], !queued.isEmpty else {
            busy.remove(key)
            waiters.removeValue(forKey: key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.continuation.resume()
    }

    private func cancel(id: UUID, key: TerminalConversationKey) {
        guard var queued = waiters[key],
            let index = queued.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(throwing: CancellationError())
    }

}

struct TerminalToolRouterStateSnapshot: Equatable, Sendable {
    let activeOperationCount: Int
    let preparedTurnCount: Int
    let activationTaskCount: Int
    let activeBindingCount: Int
    let turnLifecycleCount: Int
    let terminationTaskCount: Int
    let terminationReasonCount: Int
    let observedTurnIdentityCount: Int
}

public actor TerminalToolRouter {
    private struct ThreadTurnIdentity: Hashable, Sendable {
        let threadID: AgentThreadID
        let turnID: AgentTurnID
    }

    private struct TurnKey: Hashable, Sendable {
        let handle: AgentTurnHandle
        let turnID: AgentTurnID

        var threadID: AgentThreadID {
            handle.threadID
        }
    }

    private struct ActiveOperation {
        let turn: TurnKey
        let task: Task<TerminalToolResult, any Error>
    }

    private enum TurnLifecycle: Sendable {
        case activating
        case active
        case terminating
    }

    private struct PreparedTurn: Sendable {
        let handle: AgentTurnHandle
        let bindingToken: TerminalEndpointBindingToken
        let conversationKey: TerminalConversationKey
        let task: Task<TerminalEndpointBinding, any Error>
    }

    private struct ActivationTask: Sendable {
        let token: UUID
        let conversationKey: TerminalConversationKey
        let task: Task<TerminalEndpointBinding, any Error>
    }

    private struct TerminationTask: Sendable {
        let token: UUID
        let task: Task<Void, any Error>
    }

    private struct LeaseRecord: Sendable {
        let binding: TerminalEndpointBinding
        let provenance: RetainedTemporaryPaneLease
        let lease: TemporaryPaneLease?
        var retentionReason: TemporaryPaneRetentionReason?
        var indeterminateReason: TmuxTemporaryPaneCloseIndeterminateReason?
        var isAutoCloseable: Bool
    }

    private struct LeaseKey: Hashable, Sendable {
        let turn: TurnKey
        let leaseID: UUID
    }

    private enum MutationAuditBlock: Sendable {
        case allMutations
        case indeterminateRecovery(
            leaseID: UUID,
            handle: AgentTurnHandle,
            bindingToken: TerminalEndpointBindingToken
        )
    }

    private struct MutationPreparation: Sendable {
        let operationID: UUID
        let binding: TerminalEndpointBinding
        let screen: TerminalScreenSnapshot
        let batch: TerminalInputBatch
        let evaluation: TerminalPermissionEvaluation
    }

    private enum ShellProbe {
        case supported(command: String, begin: String, end: String)
        case retain(TemporaryPaneRetentionReason)
    }

    private let registry: TerminalEndpointRegistry
    private let approvalBroker: TerminalApprovalBroker
    private let journal: any TerminalOperationJournaling
    private let policy: TerminalPermissionPolicy
    private let gate = TerminalToolOperationGate()
    private let nonce: @Sendable (UUID) -> String
    private let paneScreenTimeout: Duration
    private let probeStableDuration: Duration
    private let probeTimeout: Duration

    private var activeOperations: [UUID: ActiveOperation] = [:]
    private var leases: [LeaseKey: LeaseRecord] = [:]
    private var mutationAuditBlocks: [TurnKey: MutationAuditBlock] = [:]
    private var preparedTurns: [AgentThreadID: PreparedTurn] = [:]
    private var turnLifecycles: [TurnKey: TurnLifecycle] = [:]
    private var activationTasks: [TurnKey: ActivationTask] = [:]
    private var activeBindings: [TurnKey: TerminalEndpointBinding] = [:]
    private var terminationTasks: [TurnKey: TerminationTask] = [:]
    private var terminationReasons: [TurnKey: TemporaryPaneRetentionReason] = [:]
    private var turnIdentityOwners: [
        ThreadTurnIdentity: AgentTurnHandle
    ] = [:]

    public init(
        registry: TerminalEndpointRegistry,
        approvalBroker: TerminalApprovalBroker,
        journal: any TerminalOperationJournaling,
        nonce: @escaping @Sendable (UUID) -> String = { leaseID in
            String(
                leaseID.uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .prefix(4)
            ).uppercased()
        },
        paneScreenTimeout: Duration = .seconds(5),
        probeStableDuration: Duration = .milliseconds(200),
        probeTimeout: Duration = .seconds(5)
    ) {
        self.registry = registry
        self.approvalBroker = approvalBroker
        self.journal = journal
        self.policy = TerminalPermissionPolicy()
        self.nonce = nonce
        self.paneScreenTimeout = paneScreenTimeout
        self.probeStableDuration = probeStableDuration
        self.probeTimeout = probeTimeout
    }

    @discardableResult
    public func beginTurn(
        threadID: AgentThreadID,
        conversationKey: TerminalConversationKey
    ) async throws -> AgentTurnHandle {
        guard preparedTurns[threadID] == nil else {
            throw TerminalEndpointRegistryError.threadAlreadyPrepared
        }
        let handle = AgentTurnHandle(threadID: threadID)
        let bindingToken = TerminalEndpointBindingToken()
        let registry = self.registry
        let task = Task.detached {
            try await registry.prepareTurn(
                handle: handle,
                token: bindingToken,
                conversationKey: conversationKey
            )
        }
        preparedTurns[threadID] = PreparedTurn(
            handle: handle,
            bindingToken: bindingToken,
            conversationKey: conversationKey,
            task: task
        )
        do {
            let preparedBinding = try await task.value
            guard preparedBinding.token == bindingToken else {
                throw TerminalToolRouterError.turnUnavailable
            }
            guard preparedTurns[threadID]?.handle == handle else {
                throw TerminalToolRouterError.turnUnavailable
            }
            try Task.checkCancellation()
            return handle
        } catch {
            if takePreparedTurn(threadID: threadID, handle: handle) != nil {
                await registry.releasePrepared(
                    handle: handle,
                    token: bindingToken,
                    conversationKey: conversationKey
                )
            }
            throw error
        }
    }

    public func confirmTurnID(
        handle: AgentTurnHandle,
        turnID: AgentTurnID
    ) async throws {
        let turn = TurnKey(handle: handle, turnID: turnID)
        do {
            _ = try await activateTurn(turn)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw TerminalToolRouterError.interrupted
        } catch let error as TerminalToolRouterError {
            throw error
        } catch {
            throw mapRegistryError(error)
        }
    }

    public func execute(
        handle: AgentTurnHandle,
        turnID: AgentTurnID,
        conversationKey: TerminalConversationKey,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        let operationID = UUID()
        let turn = TurnKey(handle: handle, turnID: turnID)
        let binding: TerminalEndpointBinding
        do {
            binding = try await activateTurn(
                turn,
                conversationKey: conversationKey
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw TerminalToolRouterError.interrupted
        } catch let error as TerminalToolRouterError {
            throw error
        } catch {
            throw mapRegistryError(error)
        }
        let task = Task {
            return try await self.runSerialized(
                turn: turn,
                binding: binding,
                call: call
            )
        }
        activeOperations[operationID] = ActiveOperation(turn: turn, task: task)
        defer { activeOperations.removeValue(forKey: operationID) }

        return try await withTaskCancellationHandler {
            do {
                return try await task.value
            } catch is CancellationError {
                throw TerminalToolRouterError.interrupted
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        let identity = ThreadTurnIdentity(
            threadID: threadID,
            turnID: turnID
        )
        let candidates = turnLifecycles.keys.filter {
            $0.threadID == threadID && $0.turnID == turnID
        }
        guard candidates.count <= 1 else {
            throw TerminalToolRouterError.turnUnavailable
        }

        if let turn = candidates.first {
            guard turnIdentityOwners[identity] == turn.handle else {
                throw TerminalToolRouterError.turnUnavailable
            }
            let conversationKey: TerminalConversationKey?
            switch turnLifecycles[turn] {
            case .activating:
                conversationKey = activationTasks[turn]?.conversationKey
            case .active:
                conversationKey = activeBindings[turn]?.conversationKey
            case .terminating, nil:
                throw TerminalToolRouterError.turnUnavailable
            }
            guard let conversationKey else {
                throw TerminalToolRouterError.turnUnavailable
            }
            return try await execute(
                handle: turn.handle,
                turnID: turnID,
                conversationKey: conversationKey,
                call: call
            )
        }

        guard turnIdentityOwners[identity] == nil,
            let prepared = preparedTurns[threadID]
        else {
            throw TerminalToolRouterError.turnUnavailable
        }
        return try await execute(
            handle: prepared.handle,
            turnID: turnID,
            conversationKey: prepared.conversationKey,
            call: call
        )
    }

    public func pendingApprovals() async -> [TerminalApprovalRequest] {
        await approvalBroker.pendingRequests()
    }

    func testingStateSnapshot() -> TerminalToolRouterStateSnapshot {
        TerminalToolRouterStateSnapshot(
            activeOperationCount: activeOperations.count,
            preparedTurnCount: preparedTurns.count,
            activationTaskCount: activationTasks.count,
            activeBindingCount: activeBindings.count,
            turnLifecycleCount: turnLifecycles.count,
            terminationTaskCount: terminationTasks.count,
            terminationReasonCount: terminationReasons.count,
            observedTurnIdentityCount: turnIdentityOwners.count
        )
    }

    /// Releases stale-turn protection only after the owning coordinator has
    /// deleted a thread and fully terminated every one of its terminal turns.
    public func forgetThread(_ threadID: AgentThreadID) throws {
        let hasTurnState = preparedTurns[threadID] != nil
            || turnLifecycles.keys.contains { $0.threadID == threadID }
            || activationTasks.keys.contains { $0.threadID == threadID }
            || activeBindings.keys.contains { $0.threadID == threadID }
            || terminationTasks.keys.contains { $0.threadID == threadID }
            || terminationReasons.keys.contains { $0.threadID == threadID }
            || activeOperations.values.contains {
                $0.turn.threadID == threadID
            }
            || leases.keys.contains { $0.turn.threadID == threadID }
            || mutationAuditBlocks.keys.contains { $0.threadID == threadID }
        guard !hasTurnState else {
            throw TerminalToolRouterError.turnUnavailable
        }
        turnIdentityOwners = turnIdentityOwners.filter {
            $0.key.threadID != threadID
        }
    }

    @discardableResult
    public func approveOnce(_ requestID: UUID) async -> Bool {
        await approvalBroker.approveOnce(requestID)
    }

    @discardableResult
    public func denyApproval(_ requestID: UUID) async -> Bool {
        await approvalBroker.deny(requestID)
    }

    public func interruptTurn(
        handle: AgentTurnHandle,
        turnID: AgentTurnID
    ) async throws {
        try await terminateTurn(
            TurnKey(handle: handle, turnID: turnID),
            reason: .interrupted
        )
    }

    public func endTurn(
        handle: AgentTurnHandle,
        turnID: AgentTurnID
    ) async throws {
        try await terminateTurn(
            TurnKey(handle: handle, turnID: turnID),
            reason: .turnEnded
        )
    }

    public func crashTurn(
        handle: AgentTurnHandle,
        turnID: AgentTurnID
    ) async throws {
        try await terminateTurn(
            TurnKey(handle: handle, turnID: turnID),
            reason: .crashed
        )
    }

    private func runSerialized(
        turn: TurnKey,
        binding: TerminalEndpointBinding,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        try await gate.acquire(binding.conversationKey)
        do {
            try Task.checkCancellation()
            guard case .active = turnLifecycles[turn] else {
                throw TerminalToolRouterError.turnUnavailable
            }
            let result = try await perform(
                turn: turn,
                binding: binding,
                call: call
            )
            await gate.release(binding.conversationKey)
            return result
        } catch {
            await gate.release(binding.conversationKey)
            throw error
        }
    }

    private func runSerializedPinLossRetention(
        record: LeaseRecord,
        turn: TurnKey
    ) async throws -> TerminalToolResult {
        try await gate.acquire(record.binding.conversationKey)
        do {
            try Task.checkCancellation()
            guard case .active = turnLifecycles[turn] else {
                throw TerminalToolRouterError.turnUnavailable
            }
            let result = try await retainExistingLease(
                record,
                reason: pinLossRetentionReason(for: record),
                operationID: UUID(),
                turn: turn,
                binding: record.binding
            )
            await gate.release(record.binding.conversationKey)
            return result
        } catch {
            await gate.release(record.binding.conversationKey)
            throw error
        }
    }

    private func perform(
        turn: TurnKey,
        binding: TerminalEndpointBinding,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        try authorizeMutation(
            call: call,
            turn: turn,
            binding: binding
        )
        do {
            try await ensureBinding(turn: turn, binding: binding)
        } catch TerminalToolRouterError.pinLost {
            if case let .finishTemporaryPane(leaseID, _) = call,
                let record = leases[LeaseKey(turn: turn, leaseID: leaseID)]
            {
                return try await retainExistingLease(
                    record,
                    reason: pinLossRetentionReason(for: record),
                    operationID: UUID(),
                    turn: turn,
                    binding: record.binding
                )
            }
            throw TerminalToolRouterError.pinLost
        }
        do {
            try Task.checkCancellation()
        } catch {
            if case let .finishTemporaryPane(leaseID, _) = call,
                let record = leases[LeaseKey(turn: turn, leaseID: leaseID)]
            {
                return try await retainExistingLease(
                    record,
                    reason: .interrupted,
                    operationID: UUID(),
                    turn: turn,
                    binding: record.binding
                )
            }
            throw error
        }
        switch call {
        case .observeScreen:
            return try await observe(turn: turn, binding: binding)
        case let .waitForScreen(request):
            try validateWaitRequest(request)
            return try await wait(
                request,
                turn: turn,
                binding: binding
            )
        case let .sendInput(batch):
            try validateInputEnvelope(batch)
            return try await send(
                batch,
                turn: turn,
                binding: binding
            )
        case let .selectVisibleSurface(selection, expectedRevision):
            return try await select(
                selection,
                expectedRevision: expectedRevision,
                turn: turn,
                binding: binding
            )
        case let .createTemporaryPane(expectedRevision):
            return try await createTemporaryPane(
                expectedRevision: expectedRevision,
                turn: turn,
                binding: binding
            )
        case let .finishTemporaryPane(leaseID, expectedRevision):
            return try await finishTemporaryPane(
                leaseID: leaseID,
                expectedRevision: expectedRevision,
                turn: turn,
                binding: binding
            )
        }
    }

    private func observe(
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        let operationID = UUID()
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .request(
                    operation: "observeScreen",
                    purpose: "observe current visible terminal screen"
                )
            ),
            turn: turn,
            blocksMutations: false
        )
        do {
            let screen = try await binding.endpoint.terminal.observeScreen()
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .screen(screen)
                ),
                turn: turn,
                blocksMutations: false
            )
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .result(.success(nil))
                ),
                turn: turn,
                blocksMutations: false
            )
            return .screen(screen)
        } catch let error as TerminalToolRouterError {
            throw error
        } catch is CancellationError {
            try await appendFailure(
                "screen observation cancelled",
                operationID: operationID,
                turn: turn,
                binding: binding
            )
            throw TerminalToolRouterError.interrupted
        } catch {
            try await appendFailure(
                "screen observation failed",
                operationID: operationID,
                turn: turn,
                binding: binding
            )
            throw TerminalToolRouterError.terminalFailure
        }
    }

    private func wait(
        _ request: TerminalScreenWaitRequest,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        let operationID = UUID()
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .request(
                    operation: "waitForScreen",
                    purpose: "wait for current visible terminal screen"
                )
            ),
            turn: turn,
            blocksMutations: false
        )
        do {
            let result = try await binding.endpoint.terminal.waitForScreen(
                request
            )
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .screen(result.snapshot)
                ),
                turn: turn,
                blocksMutations: false
            )
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .result(.success(nil))
                ),
                turn: turn,
                blocksMutations: false
            )
            return .screenWait(result)
        } catch let error as TerminalToolRouterError {
            throw error
        } catch is CancellationError {
            try await appendFailure(
                "screen wait cancelled",
                operationID: operationID,
                turn: turn,
                binding: binding
            )
            throw TerminalToolRouterError.interrupted
        } catch {
            try await appendFailure(
                "screen wait failed",
                operationID: operationID,
                turn: turn,
                binding: binding
            )
            throw TerminalToolRouterError.terminalFailure
        }
    }

    private func send(
        _ batch: TerminalInputBatch,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        let screen = try await observedScreen(binding.endpoint.terminal)
        try verifyRevision(batch.expectedRevision, screen: screen)
        let preparation = try await prepareMutation(
            operation: "sendInput",
            batch: batch,
            initialScreen: screen,
            initialSurface: nil,
            turn: turn,
            binding: binding
        )
        do {
            try Task.checkCancellation()
            try await ensureBinding(turn: turn, binding: binding)
            try Task.checkCancellation()
            let receipt = try await binding.endpoint.terminal.sendInput(batch)
            try await appendResult(
                .success(receipt),
                preparation: preparation,
                turn: turn
            )
            return .inputAccepted(receipt)
        } catch is CancellationError {
            try await appendResult(
                .failure(reason: "terminal input was cancelled"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.interrupted
        } catch let error as TerminalToolRouterError {
            if error != .auditUnavailable {
                try await appendResult(
                    .failure(reason: "terminal input route became unavailable"),
                    preparation: preparation,
                    turn: turn
                )
            }
            throw error
        } catch {
            try await appendResult(
                .failure(reason: "terminal input was not acknowledged"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.terminalFailure
        }
    }

    private func select(
        _ selection: TmuxVisibleSelection,
        expectedRevision: UInt64,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        let screen = try await observedScreen(binding.endpoint.terminal)
        try verifyRevision(expectedRevision, screen: screen)
        let origin = try await currentSurface(binding)
        let batch = actionBatch(
            revision: expectedRevision,
            purpose: "select visible tmux surface: \(selection)"
        )
        let preparation = try await prepareMutation(
            operation: "selectVisibleSurface",
            batch: batch,
            initialScreen: screen,
            initialSurface: origin,
            turn: turn,
            binding: binding
        )
        do {
            try Task.checkCancellation()
            try await ensureBinding(turn: turn, binding: binding)
            try Task.checkCancellation()
            let selected = try await binding.endpoint.surfaces.select(
                selection,
                from: origin,
                route: binding.endpoint.route
            )
            try verifySurfaceIdentity(selected, binding: binding)
            try await ensureBinding(turn: turn, binding: binding)
            try Task.checkCancellation()
            let selectedScreen = try await observedScreen(
                binding.endpoint.terminal
            )
            try await appendResult(
                .success(nil),
                preparation: preparation,
                turn: turn
            )
            return .surfaceSelected(selected, screen: selectedScreen)
        } catch is CancellationError {
            try await appendResult(
                .failure(reason: "visible surface selection was cancelled"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.interrupted
        } catch let error as TerminalToolRouterError {
            if error != .auditUnavailable {
                try await appendResult(
                    .failure(reason: "visible surface selection failed"),
                    preparation: preparation,
                    turn: turn
                )
            }
            throw error
        } catch {
            try await appendResult(
                .failure(reason: "visible surface selection failed"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.surfaceFailure
        }
    }

    private func createTemporaryPane(
        expectedRevision: UInt64,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        guard liveLease(for: turn) == nil else {
            throw TerminalToolRouterError.liveLeaseExists
        }
        let screen = try await observedScreen(binding.endpoint.terminal)
        try verifyRevision(expectedRevision, screen: screen)
        let origin = try await currentSurface(binding)
        let batch = actionBatch(
            revision: expectedRevision,
            purpose: "create one visible temporary tmux pane"
        )
        let preparation = try await prepareMutation(
            operation: "createTemporaryPane",
            batch: batch,
            initialScreen: screen,
            initialSurface: origin,
            turn: turn,
            binding: binding
        )
        let leaseID = UUID()
        do {
            try Task.checkCancellation()
            try await ensureBinding(turn: turn, binding: binding)
            try Task.checkCancellation()
            let temporary = try await binding.endpoint.surfaces
                .createTemporaryPane(
                    from: origin,
                    route: binding.endpoint.route
                )
            let lease = TemporaryPaneLease(
                id: leaseID,
                conversationKey: binding.conversationKey,
                origin: origin,
                temporary: temporary
            )
            let provenance = retainedProvenance(
                lease: lease,
                route: binding.endpoint.route
            )
            leases[LeaseKey(turn: turn, leaseID: lease.id)] = LeaseRecord(
                binding: binding,
                provenance: provenance,
                lease: lease,
                retentionReason: nil,
                indeterminateReason: nil,
                isAutoCloseable: true
            )
            do {
                try await appendTemporary(
                    .created(
                        leaseID: lease.id,
                        pane: TerminalJournalPaneProvenance(
                            windowID: lease.temporary.windowID,
                            paneID: lease.temporary.paneID
                        )
                    ),
                    preparation: preparation,
                    turn: turn
                )
            } catch {
                updateLeaseRetention(
                    turn: turn,
                    leaseID: lease.id,
                    reason: .auditUnavailable
                )
                throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                    provenance,
                    reason: .auditUnavailable
                )
            }
            do {
                try Task.checkCancellation()
            } catch {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .interrupted,
                    preparation: preparation,
                    turn: turn
                )
            }
            guard temporary.sessionIdentity == binding.conversationKey.tmux,
                temporary.sessionIdentity == binding.endpoint.route.expectedIdentity
            else {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .controllerRetained(
                        .sessionIdentityMismatch(
                            expected: binding.endpoint.route.expectedIdentity,
                            actual: temporary.sessionIdentity
                        )
                    ),
                    isAutoCloseable: false,
                    preparation: preparation,
                    turn: turn
                )
            }
            guard temporary.paneID != origin.paneID else {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .controllerRetained(.unavailable),
                    isAutoCloseable: false,
                    preparation: preparation,
                    turn: turn
                )
            }
            let waitResult: TerminalScreenWaitResult
            do {
                waitResult = try await binding.endpoint.terminal.waitForScreen(
                    TerminalScreenWaitRequest(
                        condition: .changed(after: screen.revision),
                        timeout: paneScreenTimeout
                    )
                )
            } catch is CancellationError {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .interrupted,
                    preparation: preparation,
                    turn: turn
                )
            } catch {
                return try await retainCreatedLease(
                    lease,
                    reason: .disconnected,
                    preparation: preparation,
                    turn: turn
                )
            }
            if Task.isCancelled {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .interrupted,
                    preparation: preparation,
                    turn: turn
                )
            }
            do {
                try await ensureBinding(turn: turn, binding: binding)
            } catch TerminalToolRouterError.pinLost {
                return try await retainCreatedLease(
                    lease,
                    reason: .pinLost,
                    preparation: preparation,
                    turn: turn
                )
            }
            do {
                try Task.checkCancellation()
            } catch {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .interrupted,
                    preparation: preparation,
                    turn: turn
                )
            }
            guard !waitResult.timedOut,
                waitResult.snapshot.revision > screen.revision
            else {
                return try await retainCreatedLease(
                    lease,
                    reason: .probeTimedOut,
                    preparation: preparation,
                    turn: turn
                )
            }
            let current: TmuxSurface
            do {
                current = try await currentSurface(binding)
            } catch TerminalToolRouterError.interrupted {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .interrupted,
                    preparation: preparation,
                    turn: turn
                )
            } catch {
                return try await retainCreatedLease(
                    lease,
                    reason: .routeUnavailable,
                    preparation: preparation,
                    turn: turn
                )
            }
            if Task.isCancelled {
                try await throwRetainedCreatedLease(
                    lease,
                    provenance,
                    reason: .interrupted,
                    preparation: preparation,
                    turn: turn
                )
            }
            guard current == temporary else {
                return try await retainCreatedLease(
                    lease,
                    reason: .userSurfaceSwitch(
                        expectedPaneID: temporary.paneID,
                        actualPaneID: current.paneID
                    ),
                    preparation: preparation,
                    turn: turn
                )
            }
            return .temporaryPaneCreated(
                lease,
                screen: waitResult.snapshot
            )
        } catch let error as TmuxSurfaceControlError {
            if case let .temporaryPaneRetained(pane, reason) = error {
                let provenance = RetainedTemporaryPaneLease(
                    id: leaseID,
                    conversationKey: binding.conversationKey,
                    origin: origin,
                    route: binding.endpoint.route,
                    pane: pane
                )
                let retentionReason = TemporaryPaneRetentionReason
                    .controllerRetained(reason)
                leases[LeaseKey(turn: turn, leaseID: leaseID)] = LeaseRecord(
                    binding: binding,
                    provenance: provenance,
                    lease: nil,
                    retentionReason: retentionReason,
                    indeterminateReason: nil,
                    isAutoCloseable: false
                )
                do {
                    try await appendTemporary(
                        .retained(
                            leaseID: leaseID,
                            pane: TerminalJournalPaneProvenance(pane),
                            reason: TerminalJournalRetentionReasonCode(
                                retentionReason
                            )
                        ),
                        preparation: preparation,
                        turn: turn
                    )
                } catch {
                    updateLeaseRetention(
                        turn: turn,
                        leaseID: leaseID,
                        reason: .auditUnavailable
                    )
                    throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                        provenance,
                        reason: retentionReason
                    )
                }
                throw TerminalToolRouterError.temporaryPaneRetained(
                    provenance,
                    reason: retentionReason
                )
            }
            try await appendResult(
                .failure(reason: "temporary pane creation failed"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.surfaceFailure
        } catch is CancellationError {
            try await appendResult(
                .failure(reason: "temporary pane creation was cancelled"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.interrupted
        } catch let error as TerminalToolRouterError {
            if error == .pinLost
                || error == .turnUnavailable
                || error == .surfaceFailure
            {
                try await appendResult(
                    .failure(reason: "temporary pane creation route changed"),
                    preparation: preparation,
                    turn: turn
                )
            }
            throw error
        } catch {
            try await appendResult(
                .failure(reason: "temporary pane creation failed"),
                preparation: preparation,
                turn: turn
            )
            throw TerminalToolRouterError.surfaceFailure
        }
    }

    private func finishTemporaryPane(
        leaseID: UUID,
        expectedRevision: UInt64,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        let leaseKey = LeaseKey(turn: turn, leaseID: leaseID)
        guard let record = leases[leaseKey] else {
            throw TerminalToolRouterError.leaseNotFound
        }
        if !record.isAutoCloseable {
            return try await retainExistingLease(
                record,
                reason: record.retentionReason ?? .routeUnavailable,
                operationID: UUID(),
                turn: turn,
                binding: record.binding
            )
        }
        guard let lease = record.lease else {
            throw TerminalToolRouterError.temporaryPaneRetained(
                record.provenance,
                reason: record.retentionReason ?? .routeUnavailable
            )
        }
        let screen: TerminalScreenSnapshot
        do {
            screen = try await binding.endpoint.terminal.observeScreen()
        } catch is CancellationError {
            return try await retainExistingLease(
                record,
                reason: .interrupted,
                operationID: UUID(),
                turn: turn,
                binding: binding
            )
        } catch {
            return try await retainExistingLease(
                record,
                reason: .disconnected,
                operationID: UUID(),
                turn: turn,
                binding: binding
            )
        }
        guard screen.revision == expectedRevision else {
            return try await retainExistingLease(
                record,
                reason: .revisionDrift(
                    expected: expectedRevision,
                    actual: screen.revision
                ),
                operationID: UUID(),
                turn: turn,
                binding: binding
            )
        }

        let current: TmuxSurface
        do {
            current = try await currentSurface(binding)
        } catch TerminalToolRouterError.interrupted {
            return try await retainExistingLease(
                record,
                reason: .interrupted,
                operationID: UUID(),
                turn: turn,
                binding: binding
            )
        } catch {
            return try await retainExistingLease(
                record,
                reason: .routeUnavailable,
                operationID: UUID(),
                turn: turn,
                binding: binding
            )
        }
        guard current.paneID == lease.temporary.paneID,
            current.windowID == lease.temporary.windowID,
            current.sessionIdentity == lease.temporary.sessionIdentity
        else {
            return try await retainExistingLease(
                record,
                reason: .userSurfaceSwitch(
                    expectedPaneID: lease.temporary.paneID,
                    actualPaneID: current.paneID
                ),
                operationID: UUID(),
                turn: turn,
                binding: binding
            )
        }

        let probe = makeShellProbe(
            leaseID: lease.id,
            currentCommand: current.currentCommand,
            screen: screen
        )
        let batch: TerminalInputBatch
        switch probe {
        case let .supported(command, _, _):
            batch = TerminalInputBatch(
                expectedRevision: expectedRevision,
                events: [
                    .text(command),
                    .key(.enter, modifiers: []),
                ],
                purpose: "prove temporary pane idle before exact close",
                declaredRisk: .high
            )
        case .retain:
            batch = actionBatch(
                revision: expectedRevision,
                purpose: "finish temporary tmux pane \(lease.id.uuidString)"
            )
        }

        let preparation: MutationPreparation
        do {
            preparation = try await prepareMutation(
                operation: "finishTemporaryPane",
                batch: batch,
                initialScreen: screen,
                initialSurface: current,
                turn: turn,
                binding: binding,
                recoveryLeaseID: lease.id
            )
        } catch TerminalToolRouterError.auditUnavailable {
            if let reason = record.indeterminateReason {
                throw TerminalToolRouterError
                    .temporaryPaneCloseIndeterminateAuditUnavailable(
                        lease,
                        reason: reason
                    )
            }
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: .auditUnavailable
            )
        } catch TerminalToolRouterError.interrupted {
            return try await retainExistingLease(
                record,
                reason: .interrupted,
                operationID: UUID(),
                turn: turn,
                binding: record.binding
            )
        } catch is CancellationError {
            return try await retainExistingLease(
                record,
                reason: .interrupted,
                operationID: UUID(),
                turn: turn,
                binding: record.binding
            )
        }

        switch probe {
        case let .retain(reason):
            return try await retainExistingLease(
                record,
                reason: reason,
                preparation: preparation,
                turn: turn
            )
        case let .supported(_, begin, end):
            do {
                try Task.checkCancellation()
                do {
                    try await ensureBinding(turn: turn, binding: binding)
                } catch TerminalToolRouterError.pinLost {
                    return try await retainExistingLease(
                        record,
                        reason: .pinLost,
                        preparation: preparation,
                        turn: turn
                    )
                }
                try Task.checkCancellation()
                let receipt = try await binding.endpoint.terminal.sendInput(
                    batch
                )
                if Task.isCancelled {
                    return try await retainExistingLease(
                        record,
                        reason: .interrupted,
                        preparation: preparation,
                        turn: turn
                    )
                }
                try await appendResult(
                    .success(receipt),
                    preparation: preparation,
                    turn: turn
                )
                if Task.isCancelled {
                    return try await retainExistingLease(
                        record,
                        reason: .interrupted,
                        preparation: preparation,
                        turn: turn
                    )
                }
                let waitResult = try await binding.endpoint.terminal
                    .waitForScreen(
                        TerminalScreenWaitRequest(
                            condition: .stable(
                                after: screen.revision,
                                for: probeStableDuration
                            ),
                            timeout: probeTimeout
                        )
                    )
                if Task.isCancelled {
                    return try await retainExistingLease(
                        record,
                        reason: .interrupted,
                        preparation: preparation,
                        turn: turn
                    )
                }
                guard !waitResult.timedOut else {
                    return try await retainExistingLease(
                        record,
                        reason: .probeTimedOut,
                        preparation: preparation,
                        turn: turn
                    )
                }
                do {
                    try await ensureBinding(turn: turn, binding: binding)
                } catch TerminalToolRouterError.pinLost {
                    return try await retainExistingLease(
                        record,
                        reason: .pinLost,
                        preparation: preparation,
                        turn: turn
                    )
                }
                try Task.checkCancellation()
                guard waitResult.snapshot.revision > screen.revision else {
                    let nextRevision = screen.revision == UInt64.max
                        ? UInt64.max
                        : screen.revision + 1
                    return try await retainExistingLease(
                        record,
                        reason: .revisionDrift(
                            expected: nextRevision,
                            actual: waitResult.snapshot.revision
                        ),
                        preparation: preparation,
                        turn: turn
                    )
                }
                if let reason = probeRetentionReason(
                    text: waitResult.snapshot.text,
                    begin: begin,
                    end: end
                ) {
                    return try await retainExistingLease(
                        record,
                        reason: reason,
                        preparation: preparation,
                        turn: turn
                    )
                }
                let afterProbe: TmuxSurface
                do {
                    afterProbe = try await currentSurface(binding)
                } catch TerminalToolRouterError.interrupted {
                    return try await retainExistingLease(
                        record,
                        reason: .interrupted,
                        preparation: preparation,
                        turn: turn
                    )
                } catch {
                    return try await retainExistingLease(
                        record,
                        reason: .routeUnavailable,
                        preparation: preparation,
                        turn: turn
                    )
                }
                if Task.isCancelled {
                    return try await retainExistingLease(
                        record,
                        reason: .interrupted,
                        preparation: preparation,
                        turn: turn
                    )
                }
                guard afterProbe.paneID == lease.temporary.paneID,
                    afterProbe.windowID == lease.temporary.windowID,
                    afterProbe.sessionIdentity == lease.temporary.sessionIdentity
                else {
                    return try await retainExistingLease(
                        record,
                        reason: .userSurfaceSwitch(
                            expectedPaneID: lease.temporary.paneID,
                            actualPaneID: afterProbe.paneID
                        ),
                        preparation: preparation,
                        turn: turn
                    )
                }
                let closeOutcome: TmuxTemporaryPaneCloseOutcome
                do {
                    try Task.checkCancellation()
                    try await ensureBinding(turn: turn, binding: binding)
                    try Task.checkCancellation()
                    closeOutcome = try await binding.endpoint.surfaces
                        .closeTemporaryPane(
                            lease.temporary.paneID,
                            restoring: lease.origin,
                            route: binding.endpoint.route
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch TerminalToolRouterError.pinLost {
                    return try await retainExistingLease(
                        record,
                        reason: .pinLost,
                        preparation: preparation,
                        turn: turn
                    )
                } catch {
                    return try await retainExistingLease(
                        record,
                        reason: .routeUnavailable,
                        preparation: preparation,
                        turn: turn
                    )
                }
                let restoration: TmuxOriginRestoreOutcome
                switch closeOutcome {
                case let .notCommitted(reason):
                    let resolvedRecord = resolveLeaseIndeterminate(
                        turn: turn,
                        leaseID: lease.id
                    ) ?? record
                    return try await retainExistingLease(
                        resolvedRecord,
                        reason: reason == .cancelled
                            ? .interrupted
                            : .closeNotCommitted(reason),
                        preparation: preparation,
                        turn: turn
                    )
                case let .closed(outcome):
                    restoration = outcome
                case let .indeterminate(reason):
                    return try await reportIndeterminateLease(
                        record,
                        reason: reason,
                        preparation: preparation,
                        turn: turn
                    )
                }
                leases.removeValue(forKey: leaseKey)
                do {
                    let promotedRecovery = promoteRecoveryBlockToAllMutations(
                        turn: turn,
                        leaseID: lease.id,
                        binding: binding
                    )
                    try await appendTemporary(
                        .closed(
                            leaseID: lease.id,
                            pane: TerminalJournalPaneProvenance(
                                windowID: lease.temporary.windowID,
                                paneID: lease.temporary.paneID
                            ),
                            restoration: restoration
                        ),
                        preparation: preparation,
                        turn: turn
                    )
                    if promotedRecovery {
                        mutationAuditBlocks.removeValue(forKey: turn)
                    }
                } catch {
                    throw TerminalToolRouterError
                        .temporaryPaneCloseAuditUnavailable(
                            lease,
                            restoration: restoration
                        )
                }
                return switch restoration {
                case .restored:
                    .temporaryPaneFinished(.closed(lease))
                case let .failed(reason):
                    .temporaryPaneFinished(
                        .closedWithRestoreFailure(lease, reason: reason)
                    )
                }
            } catch is CancellationError {
                if leases[leaseKey]?.lease?.id == lease.id {
                    return try await retainExistingLease(
                        record,
                        reason: .interrupted,
                        preparation: preparation,
                        turn: turn
                    )
                }
                throw TerminalToolRouterError.interrupted
            } catch TerminalToolRouterError.auditUnavailable {
                throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                    record.provenance,
                    reason: .auditUnavailable
                )
            } catch let error as TerminalToolRouterError {
                throw error
            } catch {
                return try await retainExistingLease(
                    record,
                    reason: .disconnected,
                    preparation: preparation,
                    turn: turn
                )
            }
        }
    }

    private func prepareMutation(
        operation: String,
        batch: TerminalInputBatch,
        initialScreen: TerminalScreenSnapshot,
        initialSurface: TmuxSurface?,
        turn: TurnKey,
        binding: TerminalEndpointBinding,
        recoveryLeaseID: UUID? = nil
    ) async throws -> MutationPreparation {
        try authorizeMutation(
            recoveryLeaseID: recoveryLeaseID,
            turn: turn,
            binding: binding
        )
        let operationID = UUID()
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .request(operation: operation, purpose: batch.purpose)
            ),
            turn: turn
        )
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .screen(initialScreen)
            ),
            turn: turn
        )
        let evaluation = try policy.evaluate(
            batch: batch,
            endpointID: binding.endpoint.id,
            screen: initialScreen
        )
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .risk(
                    agentDeclared: batch.declaredRisk,
                    deterministic: evaluation.deterministicRisk,
                    effective: evaluation.effectiveRisk
                )
            ),
            turn: turn
        )

        switch evaluation.decision {
        case let .deny(reason):
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .result(.failure(reason: reason))
                ),
                turn: turn
            )
            throw TerminalToolRouterError.denied(reason: reason)
        case .allow:
            break
        case let .requireApproval(request):
            let grant: TerminalApprovalGrant
            do {
                grant = try await approvalBroker.awaitApproval(
                    for: request,
                    turnID: brokerTurnID(turn)
                )
            } catch TerminalApprovalError.denied {
                try await appendApproval(
                    request: request,
                    outcome: .denied,
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                try await appendFailure(
                    "approval denied",
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                throw TerminalToolRouterError.approvalDenied
            } catch TerminalApprovalError.expired {
                try await appendApproval(
                    request: request,
                    outcome: .expired,
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                try await appendFailure(
                    "approval expired",
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                throw TerminalToolRouterError.approvalExpired
            } catch TerminalApprovalError.cancelled {
                try await appendApproval(
                    request: request,
                    outcome: .cancelled,
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                try await appendFailure(
                    "approval cancelled",
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                throw TerminalToolRouterError.interrupted
            }

            do {
                guard !Task.isCancelled else {
                    try await appendApproval(
                        request: request,
                        outcome: .cancelled,
                        operationID: operationID,
                        turn: turn,
                        binding: binding
                    )
                    try await appendFailure(
                        "approval cancelled",
                        operationID: operationID,
                        turn: turn,
                        binding: binding
                    )
                    throw TerminalToolRouterError.interrupted
                }
                try await ensureBinding(turn: turn, binding: binding)
                try Task.checkCancellation()
                let currentScreen = try await observedScreen(
                    binding.endpoint.terminal
                )
                guard currentScreen.revision == initialScreen.revision else {
                    await approvalBroker.invalidateScreen(
                        endpointID: binding.endpoint.id,
                        currentRevision: currentScreen.revision
                    )
                    try await appendApproval(
                        request: request,
                        outcome: .expired,
                        operationID: operationID,
                        turn: turn,
                        binding: binding
                    )
                    try await appendFailure(
                        "screen changed after approval",
                        operationID: operationID,
                        turn: turn,
                        binding: binding
                    )
                    throw TerminalToolRouterError.approvalExpired
                }
                if let initialSurface {
                    let current = try await currentSurface(binding)
                    guard current == initialSurface else {
                        await approvalBroker.invalidateRoute(
                            binding.endpoint.id
                        )
                        try await appendApproval(
                            request: request,
                            outcome: .expired,
                            operationID: operationID,
                            turn: turn,
                            binding: binding
                        )
                        try await appendFailure(
                            "surface changed after approval",
                            operationID: operationID,
                            turn: turn,
                            binding: binding
                        )
                        throw TerminalToolRouterError.approvalExpired
                    }
                }
            } catch let error as TerminalToolRouterError {
                throw error
            } catch {
                await approvalBroker.invalidateRoute(binding.endpoint.id)
                try await appendApproval(
                    request: request,
                    outcome: .expired,
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                try await appendFailure(
                    "route unavailable after approval",
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                throw TerminalToolRouterError.approvalExpired
            }
            guard await approvalBroker.consume(
                grant,
                matching: request.scope
            ) else {
                try await appendFailure(
                    "approval grant expired before use",
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                throw TerminalToolRouterError.approvalExpired
            }
            try await appendApproval(
                request: request,
                outcome: .approvedOnce,
                operationID: operationID,
                turn: turn,
                binding: binding
            )
        }

        try await ensureBinding(turn: turn, binding: binding)
        try Task.checkCancellation()
        let finalScreen = try await observedScreen(binding.endpoint.terminal)
        guard finalScreen.revision == initialScreen.revision else {
            try await appendFailure(
                "screen changed before execution",
                operationID: operationID,
                turn: turn,
                binding: binding
            )
            if evaluation.effectiveRisk == .high {
                throw TerminalToolRouterError.approvalExpired
            }
            throw TerminalToolRouterError.staleRevision(
                expected: initialScreen.revision,
                actual: finalScreen.revision
            )
        }
        if let initialSurface {
            let finalSurface = try await currentSurface(binding)
            guard finalSurface == initialSurface else {
                try await appendFailure(
                    "surface changed before execution",
                    operationID: operationID,
                    turn: turn,
                    binding: binding
                )
                if evaluation.effectiveRisk == .high {
                    throw TerminalToolRouterError.approvalExpired
                }
                throw TerminalToolRouterError.surfaceFailure
            }
        }
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .endpoint(binding.endpoint.id)
            ),
            turn: turn
        )
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .emittedBatch(batch)
            ),
            turn: turn
        )
        guard !Task.isCancelled else {
            throw TerminalToolRouterError.interrupted
        }
        return MutationPreparation(
            operationID: operationID,
            binding: binding,
            screen: initialScreen,
            batch: batch,
            evaluation: evaluation
        )
    }

    private func terminateTurn(
        _ turn: TurnKey,
        reason: TemporaryPaneRetentionReason
    ) async throws {
        if let existing = terminationTasks[turn] {
            do {
                try await existing.task.value
                cleanupTerminationWaiter(
                    turn: turn,
                    token: existing.token
                )
                return
            } catch {
                cleanupTerminationWaiter(
                    turn: turn,
                    token: existing.token
                )
                throw error
            }
        }

        let prepared: PreparedTurn?
        let activationTask: Task<TerminalEndpointBinding, any Error>?
        switch turnLifecycles[turn] {
        case .activating:
            guard let activation = activationTasks[turn] else {
                throw TerminalToolRouterError.turnUnavailable
            }
            prepared = nil
            activationTask = activation.task
            turnLifecycles[turn] = .terminating
        case .active:
            prepared = nil
            activationTask = nil
            turnLifecycles[turn] = .terminating
        case .terminating:
            if let existing = terminationTasks[turn] {
                return try await existing.task.value
            }
            return
        case nil:
            guard let currentPrepared = preparedTurns[turn.threadID],
                currentPrepared.handle == turn.handle,
                takePreparedTurn(
                    threadID: turn.threadID,
                    handle: turn.handle
                ) != nil
            else { return }
            prepared = currentPrepared
            activationTask = nil
            turnLifecycles[turn] = .terminating
        }

        let preexistingReasons: [LeaseKey: TemporaryPaneRetentionReason]
            = Dictionary(
            uniqueKeysWithValues: leases.compactMap { key, record in
                guard key.turn == turn, let reason = record.retentionReason else {
                    return nil
                }
                return (key, reason)
            }
        )
        terminationReasons[turn] = reason
        let token = UUID()
        let task = Task.detached {
            try await self.performTermination(
                turn,
                reason: reason,
                prepared: prepared,
                preexistingReasons: preexistingReasons,
                activationTask: activationTask
            )
        }
        terminationTasks[turn] = TerminationTask(
            token: token,
            task: task
        )
        do {
            try await task.value
            cleanupTerminationWaiter(
                turn: turn,
                token: token
            )
        } catch {
            cleanupTerminationWaiter(
                turn: turn,
                token: token
            )
            throw error
        }
    }

    private func performTermination(
        _ turn: TurnKey,
        reason: TemporaryPaneRetentionReason,
        prepared: PreparedTurn?,
        preexistingReasons: [LeaseKey: TemporaryPaneRetentionReason],
        activationTask: Task<TerminalEndpointBinding, any Error>?
    ) async throws {
        if let activationTask {
            _ = await activationTask.result
        }
        await approvalBroker.cancelTurn(brokerTurnID(turn))
        let tasks = activeOperations.values
            .filter { $0.turn == turn }
            .map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = await task.result
        }
        var retainedAuditFailures: [TerminalTurnRetainedPaneAudit] = []
        var indeterminateAuditFailures: [TerminalTurnIndeterminatePaneAudit]
            = []
        let retainedKeys = leases.keys.filter { $0.turn == turn }
        for key in retainedKeys {
            guard let record = leases.removeValue(forKey: key) else { continue }
            let operationID = UUID()
            let retainedReason = preexistingReasons[key] ?? reason
            do {
                let paneEvent: TerminalJournalTemporaryPaneEvent
                if let indeterminateReason = record.indeterminateReason {
                    paneEvent = .indeterminate(
                        leaseID: record.provenance.id,
                        pane: TerminalJournalPaneProvenance(
                            record.provenance.pane
                        ),
                        reason: indeterminateReason
                    )
                } else {
                    paneEvent = .retained(
                        leaseID: record.provenance.id,
                        pane: TerminalJournalPaneProvenance(
                            record.provenance.pane
                        ),
                        reason: TerminalJournalRetentionReasonCode(
                            retainedReason
                        )
                    )
                }
                try await append(
                    event(
                        binding: record.binding,
                        turn: turn,
                        operationID: operationID,
                        kind: .temporaryPane(paneEvent)
                    ),
                    turn: turn,
                    blocksMutations: false
                )
            } catch {
                if let indeterminateReason = record.indeterminateReason {
                    indeterminateAuditFailures.append(
                        TerminalTurnIndeterminatePaneAudit(
                            provenance: record.provenance,
                            reason: indeterminateReason
                        )
                    )
                } else {
                    retainedAuditFailures.append(
                        TerminalTurnRetainedPaneAudit(
                            provenance: record.provenance,
                            reason: .auditUnavailable
                        )
                    )
                }
            }
        }
        if let prepared {
            _ = await prepared.task.result
            await registry.releasePrepared(
                handle: turn.handle,
                token: prepared.bindingToken,
                conversationKey: prepared.conversationKey
            )
        } else if let binding = activeBindings[turn] {
            await registry.releaseTurn(
                handle: turn.handle,
                token: binding.token,
                turnID: turn.turnID
            )
        }
        activeBindings.removeValue(forKey: turn)
        activationTasks.removeValue(forKey: turn)
        if case .terminating = turnLifecycles[turn] {
            turnLifecycles.removeValue(forKey: turn)
        }
        terminationReasons.removeValue(forKey: turn)
        mutationAuditBlocks.removeValue(forKey: turn)
        if !indeterminateAuditFailures.isEmpty {
            throw TerminalTurnTerminationError.indeterminateAuditUnavailable(
                indeterminateAuditFailures
            )
        }
        if !retainedAuditFailures.isEmpty {
            throw TerminalTurnTerminationError.auditUnavailable(
                retainedAuditFailures
            )
        }
    }

    private func retainCreatedLease(
        _ lease: TemporaryPaneLease,
        reason: TemporaryPaneRetentionReason,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws -> TerminalToolResult {
        let reason = effectiveRetentionReason(reason, turn: turn)
        updateLeaseRetention(
            turn: turn,
            leaseID: lease.id,
            reason: reason
        )
        do {
            try await appendTemporary(
                .retained(
                    leaseID: lease.id,
                    pane: TerminalJournalPaneProvenance(
                        windowID: lease.temporary.windowID,
                        paneID: lease.temporary.paneID
                    ),
                    reason: TerminalJournalRetentionReasonCode(reason)
                ),
                preparation: preparation,
                turn: turn
            )
        } catch {
            updateLeaseRetention(
                turn: turn,
                leaseID: lease.id,
                reason: .auditUnavailable
            )
            let provenance = retainedProvenance(
                lease: lease,
                route: preparation.binding.endpoint.route
            )
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                provenance,
                reason: reason
            )
        }
        return .temporaryPaneRetained(lease, reason: reason)
    }

    private func throwRetainedCreatedLease(
        _ lease: TemporaryPaneLease,
        _ provenance: RetainedTemporaryPaneLease,
        reason: TemporaryPaneRetentionReason,
        isAutoCloseable: Bool = true,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws -> Never {
        let reason = effectiveRetentionReason(reason, turn: turn)
        updateLeaseRetention(
            turn: turn,
            leaseID: lease.id,
            reason: reason,
            isAutoCloseable: isAutoCloseable
        )
        do {
            try await appendTemporary(
                .retained(
                    leaseID: lease.id,
                    pane: TerminalJournalPaneProvenance(
                        windowID: lease.temporary.windowID,
                        paneID: lease.temporary.paneID
                    ),
                    reason: TerminalJournalRetentionReasonCode(reason)
                ),
                preparation: preparation,
                turn: turn
            )
        } catch {
            updateLeaseRetention(
                turn: turn,
                leaseID: lease.id,
                reason: .auditUnavailable
            )
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                provenance,
                reason: reason
            )
        }
        throw TerminalToolRouterError.temporaryPaneRetained(
            provenance,
            reason: reason
        )
    }

    private func retainExistingLease(
        _ record: LeaseRecord,
        reason: TemporaryPaneRetentionReason,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws -> TerminalToolResult {
        if let reason = record.indeterminateReason {
            return try await reportIndeterminateLease(
                record,
                reason: reason,
                preparation: preparation,
                turn: turn
            )
        }
        let retainedReason = retentionReason(
            for: record,
            requested: reason,
            turn: turn
        )
        updateLeaseRetention(
            turn: turn,
            leaseID: record.provenance.id,
            reason: retainedReason
        )
        do {
            try await appendTemporary(
                .retained(
                    leaseID: record.provenance.id,
                    pane: TerminalJournalPaneProvenance(record.provenance.pane),
                    reason: TerminalJournalRetentionReasonCode(
                        retainedReason
                    )
                ),
                preparation: preparation,
                turn: turn
            )
        } catch {
            updateLeaseRetention(
                turn: turn,
                leaseID: record.provenance.id,
                reason: .auditUnavailable
            )
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: retainedReason
            )
        }
        clearRecoveryBlock(
            turn: turn,
            leaseID: record.provenance.id,
            binding: preparation.binding
        )
        guard let lease = record.lease else {
            throw TerminalToolRouterError.temporaryPaneRetained(
                record.provenance,
                reason: retainedReason
            )
        }
        return .temporaryPaneFinished(
            .retained(lease, reason: retainedReason)
        )
    }

    private func retainExistingLease(
        _ record: LeaseRecord,
        reason: TemporaryPaneRetentionReason,
        operationID: UUID,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        if let reason = record.indeterminateReason {
            return try await reportIndeterminateLease(
                record,
                reason: reason,
                operationID: operationID,
                turn: turn,
                binding: binding
            )
        }
        let retainedReason = retentionReason(
            for: record,
            requested: reason,
            turn: turn
        )
        updateLeaseRetention(
            turn: turn,
            leaseID: record.provenance.id,
            reason: retainedReason
        )
        do {
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .request(
                        operation: "finishTemporaryPane",
                        purpose: "retain temporary pane after uncertainty"
                    )
                ),
                turn: turn
            )
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .temporaryPane(
                        .retained(
                            leaseID: record.provenance.id,
                            pane: TerminalJournalPaneProvenance(
                                record.provenance.pane
                            ),
                            reason: TerminalJournalRetentionReasonCode(
                                retainedReason
                            )
                        ),
                    )
                ),
                turn: turn
            )
        } catch {
            updateLeaseRetention(
                turn: turn,
                leaseID: record.provenance.id,
                reason: .auditUnavailable
            )
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: retainedReason
            )
        }
        clearRecoveryBlock(
            turn: turn,
            leaseID: record.provenance.id,
            binding: binding
        )
        guard let lease = record.lease else {
            throw TerminalToolRouterError.temporaryPaneRetained(
                record.provenance,
                reason: retainedReason
            )
        }
        return .temporaryPaneFinished(
            .retained(lease, reason: retainedReason)
        )
    }

    private func reportIndeterminateLease(
        _ record: LeaseRecord,
        reason: TmuxTemporaryPaneCloseIndeterminateReason,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws -> TerminalToolResult {
        try await reportIndeterminateLease(
            record,
            reason: reason,
            operationID: preparation.operationID,
            binding: preparation.binding,
            requestAlreadyAudited: true,
            turn: turn
        )
    }

    private func reportIndeterminateLease(
        _ record: LeaseRecord,
        reason: TmuxTemporaryPaneCloseIndeterminateReason,
        operationID: UUID,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        try await reportIndeterminateLease(
            record,
            reason: reason,
            operationID: operationID,
            binding: binding,
            requestAlreadyAudited: false,
            turn: turn
        )
    }

    private func reportIndeterminateLease(
        _ record: LeaseRecord,
        reason: TmuxTemporaryPaneCloseIndeterminateReason,
        operationID: UUID,
        binding: TerminalEndpointBinding,
        requestAlreadyAudited: Bool,
        turn: TurnKey
    ) async throws -> TerminalToolResult {
        updateLeaseIndeterminate(
            turn: turn,
            leaseID: record.provenance.id,
            reason: reason
        )
        do {
            if !requestAlreadyAudited {
                try await append(
                    event(
                        binding: binding,
                        turn: turn,
                        operationID: operationID,
                        kind: .request(
                            operation: "finishTemporaryPane",
                            purpose: "recover indeterminate temporary pane close"
                        )
                    ),
                    turn: turn
                )
            }
            try await append(
                event(
                    binding: binding,
                    turn: turn,
                    operationID: operationID,
                    kind: .temporaryPane(
                        .indeterminate(
                            leaseID: record.provenance.id,
                            pane: TerminalJournalPaneProvenance(
                                record.provenance.pane
                            ),
                            reason: reason
                        )
                    )
                ),
                turn: turn
            )
        } catch {
            guard let lease = record.lease else {
                throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                    record.provenance,
                    reason: .auditUnavailable
                )
            }
            throw TerminalToolRouterError
                .temporaryPaneCloseIndeterminateAuditUnavailable(
                    lease,
                    reason: reason
                )
        }
        guard let lease = record.lease else {
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: .auditUnavailable
            )
        }
        return .temporaryPaneFinished(
            .indeterminate(lease, reason: reason)
        )
    }

    private func appendApproval(
        request: TerminalApprovalRequest,
        outcome: TerminalJournalApprovalOutcome,
        operationID: UUID,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws {
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .approval(
                    requestID: request.id,
                    scope: request.scope,
                    outcome: outcome
                )
            ),
            turn: turn
        )
    }

    private func appendFailure(
        _ reason: String,
        operationID: UUID,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws {
        try await append(
            event(
                binding: binding,
                turn: turn,
                operationID: operationID,
                kind: .result(.failure(reason: reason))
            ),
            turn: turn
        )
    }

    private func appendResult(
        _ result: TerminalJournalResult,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws {
        try await append(
            event(
                binding: preparation.binding,
                turn: turn,
                operationID: preparation.operationID,
                kind: .result(result)
            ),
            turn: turn
        )
    }

    private func appendTemporary(
        _ value: TerminalJournalTemporaryPaneEvent,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws {
        try await append(
            event(
                binding: preparation.binding,
                turn: turn,
                operationID: preparation.operationID,
                kind: .temporaryPane(value)
            ),
            turn: turn
        )
    }

    private func append(
        _ event: TerminalJournalEvent,
        turn: TurnKey,
        blocksMutations: Bool = true
    ) async throws {
        do {
            try await journal.append(event)
        } catch {
            if blocksMutations {
                if mutationAuditBlocks[turn] == nil {
                    mutationAuditBlocks[turn] = .allMutations
                }
            }
            throw TerminalToolRouterError.auditUnavailable
        }
    }

    private func event(
        binding: TerminalEndpointBinding,
        turn: TurnKey,
        operationID: UUID,
        kind: TerminalJournalEventKind
    ) -> TerminalJournalEvent {
        TerminalJournalEvent(
            key: binding.conversationKey,
            operationID: operationID,
            turnID: turn.turnID.rawValue,
            kind: kind
        )
    }

    private func ensureBinding(
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws {
        do {
            let current = try await registry.binding(
                handle: turn.handle,
                token: binding.token,
                turnID: turn.turnID,
                conversationKey: binding.conversationKey
            )
            guard current.token == binding.token,
                current.endpoint.id == binding.endpoint.id
            else {
                throw TerminalToolRouterError.pinLost
            }
        } catch TerminalEndpointRegistryError.pinLost {
            throw TerminalToolRouterError.pinLost
        } catch let error as TerminalToolRouterError {
            throw error
        } catch {
            throw TerminalToolRouterError.turnUnavailable
        }
    }

    private func observedScreen(
        _ terminal: any TerminalSessionPort
    ) async throws -> TerminalScreenSnapshot {
        do {
            return try await terminal.observeScreen()
        } catch is CancellationError {
            throw TerminalToolRouterError.interrupted
        } catch {
            throw TerminalToolRouterError.terminalFailure
        }
    }

    private func currentSurface(
        _ binding: TerminalEndpointBinding
    ) async throws -> TmuxSurface {
        do {
            let surface = try await binding.endpoint.surfaces.currentSurface(
                route: binding.endpoint.route
            )
            try verifySurfaceIdentity(surface, binding: binding)
            return surface
        } catch let error as TerminalToolRouterError {
            throw error
        } catch is CancellationError {
            throw TerminalToolRouterError.interrupted
        } catch {
            throw TerminalToolRouterError.surfaceFailure
        }
    }

    private func verifySurfaceIdentity(
        _ surface: TmuxSurface,
        binding: TerminalEndpointBinding
    ) throws {
        guard surface.sessionIdentity == binding.conversationKey.tmux,
            surface.sessionIdentity == binding.endpoint.route.expectedIdentity
        else {
            throw TerminalToolRouterError.surfaceFailure
        }
    }

    private func verifyRevision(
        _ expected: UInt64,
        screen: TerminalScreenSnapshot
    ) throws {
        guard expected == screen.revision else {
            throw TerminalToolRouterError.staleRevision(
                expected: expected,
                actual: screen.revision
            )
        }
    }

    private func validateInputEnvelope(
        _ batch: TerminalInputBatch
    ) throws {
        guard batch.events.count <= TerminalPermissionPolicy.maximumEventCount
        else {
            throw TerminalToolRouterError.denied(
                reason: "Input batch exceeds 256 semantic events"
            )
        }
        guard batch.purpose.unicodeScalars.count
            <= TerminalPermissionPolicy.maximumPurposeScalarCount
        else {
            throw TerminalToolRouterError.denied(
                reason: "Input purpose exceeds 500 Unicode scalars"
            )
        }
        do {
            let normal = try TerminalInputEncoder.encode(
                events: batch.events,
                keyboardMode: .normal
            ).count
            let application = try TerminalInputEncoder.encode(
                events: batch.events,
                keyboardMode: .applicationCursor
            ).count
            guard max(normal, application)
                <= TerminalPermissionPolicy.maximumEncodedByteCount
            else {
                throw TerminalToolRouterError.denied(
                    reason: "Encoded input exceeds 32 KiB"
                )
            }
        } catch let error as TerminalToolRouterError {
            throw error
        } catch {
            throw TerminalToolRouterError.denied(
                reason: "Input contains an unsupported semantic key combination"
            )
        }
    }

    private func validateWaitRequest(
        _ request: TerminalScreenWaitRequest
    ) throws {
        guard request.timeout >= .zero,
            request.timeout <= .seconds(120)
        else {
            throw TerminalToolRouterError.denied(
                reason: "Wait timeout must be between zero and 120 seconds"
            )
        }
        if case let .stable(_, duration) = request.condition {
            guard duration >= .zero, duration <= .seconds(120) else {
                throw TerminalToolRouterError.denied(
                    reason: "Wait stability duration must be between zero and 120 seconds"
                )
            }
        }
    }

    private func actionBatch(
        revision: UInt64,
        purpose: String
    ) -> TerminalInputBatch {
        TerminalInputBatch(
            expectedRevision: revision,
            events: [.key(.enter, modifiers: [])],
            purpose: purpose,
            declaredRisk: .high
        )
    }

    private func makeShellProbe(
        leaseID: UUID,
        currentCommand: String,
        screen: TerminalScreenSnapshot
    ) -> ShellProbe {
        let shell = URL(fileURLWithPath: currentCommand).lastPathComponent
        let token = sanitizedNonce(nonce(leaseID))
        let begin = "B\(token)"
        let end = "E\(token)"
        let command: String
        switch shell {
        case "bash", "zsh", "sh":
            command = "b=\(begin);e=\(end);printf '\\n%s\\n' $b;jobs -p;printf '%s\\n' $e"
        case "fish":
            command = "set b \(begin);set e \(end);printf '\\n%s\\n' $b;jobs -p;printf '%s\\n' $e"
        case "dash", "ksh", "csh", "tcsh", "pwsh":
            return .retain(.unsupportedShell(shell))
        default:
            return .retain(.foregroundProcess(shell))
        }

        let available = max(0, screen.columns - screen.cursor.column)
        let required = command.count
        guard required <= available else {
            return .retain(
                .terminalWidthUncertain(
                    required: required,
                    available: available
                )
            )
        }
        return .supported(command: command, begin: begin, end: end)
    }

    private func sanitizedNonce(_ value: String) -> String {
        let result = value.uppercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return String(result.prefix(8)).isEmpty
            ? "0000"
            : String(result.prefix(8))
    }

    private func probeRetentionReason(
        text: String,
        begin: String,
        end: String
    ) -> TemporaryPaneRetentionReason? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let endIndex = lines.lastIndex(of: end) else {
            return .markerAmbiguity
        }
        let suffixStart = endIndex + 1
        if suffixStart < lines.count,
            lines[suffixStart...].contains(where: {
                $0 == begin || $0 == end
            })
        {
            return .markerAmbiguity
        }
        let previousEnd = lines[..<endIndex].lastIndex(of: end)
        let searchStart = previousEnd.map { $0 + 1 } ?? lines.startIndex
        let beginIndexes = lines[searchStart..<endIndex].indices.filter {
            lines[$0] == begin
        }
        guard beginIndexes.count == 1, let beginIndex = beginIndexes.first else {
            return .markerAmbiguity
        }
        let payload = lines[(beginIndex + 1)..<endIndex]
            .filter { !$0.isEmpty }
        guard !payload.isEmpty else { return nil }
        if payload.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return .backgroundJobs(Array(payload))
        }
        return .markerAmbiguity
    }

    private func brokerTurnID(_ turn: TurnKey) -> String {
        let thread = turn.threadID.rawValue
        let turnID = turn.turnID.rawValue
        let generation = turn.handle.generationID.uuidString
        return "\(thread.utf8.count):\(thread)"
            + "\(generation.utf8.count):\(generation)"
            + "\(turnID.utf8.count):\(turnID)"
    }

    private func retainedProvenance(
        lease: TemporaryPaneLease,
        route: TmuxRoute
    ) -> RetainedTemporaryPaneLease {
        RetainedTemporaryPaneLease(
            id: lease.id,
            conversationKey: lease.conversationKey,
            origin: lease.origin,
            route: route,
            pane: RetainedTemporaryPane(
                windowID: lease.temporary.windowID,
                paneID: lease.temporary.paneID
            )
        )
    }

    private func liveLease(for turn: TurnKey) -> LeaseRecord? {
        leases.first(where: { $0.key.turn == turn })?.value
    }

    private func authorizeMutation(
        call: TerminalToolCall,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) throws {
        switch call {
        case .observeScreen, .waitForScreen:
            return
        case let .finishTemporaryPane(leaseID, _):
            try authorizeMutation(
                recoveryLeaseID: leaseID,
                turn: turn,
                binding: binding
            )
        case .sendInput, .selectVisibleSurface, .createTemporaryPane:
            try authorizeMutation(
                recoveryLeaseID: nil,
                turn: turn,
                binding: binding
            )
        }
    }

    private func authorizeMutation(
        recoveryLeaseID: UUID?,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) throws {
        guard let block = mutationAuditBlocks[turn] else { return }
        switch block {
        case .allMutations:
            throw TerminalToolRouterError.auditUnavailable
        case let .indeterminateRecovery(leaseID, handle, bindingToken):
            guard recoveryLeaseID == leaseID,
                turn.handle == handle,
                binding.token == bindingToken
            else {
                throw TerminalToolRouterError.auditUnavailable
            }
        }
    }

    private func clearRecoveryBlock(
        turn: TurnKey,
        leaseID: UUID,
        binding: TerminalEndpointBinding
    ) {
        guard case let .indeterminateRecovery(
            blockedLeaseID,
            handle,
            bindingToken
        ) = mutationAuditBlocks[turn],
            blockedLeaseID == leaseID,
            handle == turn.handle,
            bindingToken == binding.token
        else { return }
        mutationAuditBlocks.removeValue(forKey: turn)
    }

    @discardableResult
    private func promoteRecoveryBlockToAllMutations(
        turn: TurnKey,
        leaseID: UUID,
        binding: TerminalEndpointBinding
    ) -> Bool {
        guard case let .indeterminateRecovery(
            blockedLeaseID,
            handle,
            bindingToken
        ) = mutationAuditBlocks[turn],
            blockedLeaseID == leaseID,
            handle == turn.handle,
            bindingToken == binding.token
        else { return false }
        mutationAuditBlocks[turn] = .allMutations
        return true
    }

    private func updateLeaseRetention(
        turn: TurnKey,
        leaseID: UUID,
        reason: TemporaryPaneRetentionReason,
        isAutoCloseable: Bool? = nil
    ) {
        let key = LeaseKey(turn: turn, leaseID: leaseID)
        guard var record = leases[key] else { return }
        record.retentionReason = reason
        record.indeterminateReason = nil
        if let isAutoCloseable {
            record.isAutoCloseable = isAutoCloseable
        }
        leases[key] = record
    }

    private func updateLeaseIndeterminate(
        turn: TurnKey,
        leaseID: UUID,
        reason: TmuxTemporaryPaneCloseIndeterminateReason
    ) {
        let key = LeaseKey(turn: turn, leaseID: leaseID)
        guard var record = leases[key] else { return }
        record.retentionReason = nil
        record.indeterminateReason = reason
        leases[key] = record
        mutationAuditBlocks[turn] = .indeterminateRecovery(
            leaseID: leaseID,
            handle: turn.handle,
            bindingToken: record.binding.token
        )
    }

    private func resolveLeaseIndeterminate(
        turn: TurnKey,
        leaseID: UUID
    ) -> LeaseRecord? {
        let key = LeaseKey(turn: turn, leaseID: leaseID)
        guard var record = leases[key] else { return nil }
        record.indeterminateReason = nil
        leases[key] = record
        return record
    }

    private func pinLossRetentionReason(
        for record: LeaseRecord
    ) -> TemporaryPaneRetentionReason {
        if !record.isAutoCloseable, let reason = record.retentionReason {
            return reason
        }
        return .pinLost
    }

    private func effectiveRetentionReason(
        _ requested: TemporaryPaneRetentionReason,
        turn: TurnKey
    ) -> TemporaryPaneRetentionReason {
        guard requested == .interrupted,
            let terminationReason = terminationReasons[turn]
        else {
            return requested
        }
        return terminationReason
    }

    private func retentionReason(
        for record: LeaseRecord,
        requested: TemporaryPaneRetentionReason,
        turn: TurnKey
    ) -> TemporaryPaneRetentionReason {
        if !record.isAutoCloseable, let existing = record.retentionReason {
            return existing
        }
        return effectiveRetentionReason(requested, turn: turn)
    }

    private func activateTurn(
        _ turn: TurnKey,
        conversationKey: TerminalConversationKey? = nil
    ) async throws -> TerminalEndpointBinding {
        let task: Task<TerminalEndpointBinding, any Error>
        switch turnLifecycles[turn] {
        case .activating:
            guard let activation = activationTasks[turn],
                conversationKey == nil
                    || activation.conversationKey == conversationKey
            else {
                throw TerminalToolRouterError.turnUnavailable
            }
            task = activation.task
        case .active:
            guard let binding = activeBindings[turn],
                conversationKey == nil
                    || binding.conversationKey == conversationKey
            else {
                throw TerminalToolRouterError.turnUnavailable
            }
            try Task.checkCancellation()
            return binding
        case .terminating:
            throw TerminalToolRouterError.turnUnavailable
        case nil:
            guard let prepared = preparedTurns[turn.threadID],
                prepared.handle == turn.handle,
                conversationKey == nil
                    || prepared.conversationKey == conversationKey,
                takePreparedTurn(
                    threadID: turn.threadID,
                    handle: turn.handle
                ) != nil
            else {
                throw TerminalToolRouterError.turnUnavailable
            }
            let identity = ThreadTurnIdentity(
                threadID: turn.threadID,
                turnID: turn.turnID
            )
            if turnIdentityOwners[identity] == nil {
                turnIdentityOwners[identity] = turn.handle
            }
            turnLifecycles[turn] = .activating
            let token = UUID()
            let activationTask = Task.detached {
                try await self.performActivation(
                    turn,
                    prepared: prepared,
                    activationToken: token
                )
            }
            activationTasks[turn] = ActivationTask(
                token: token,
                conversationKey: prepared.conversationKey,
                task: activationTask
            )
            task = activationTask
        }
        let binding = try await task.value
        try Task.checkCancellation()
        guard case .active = turnLifecycles[turn] else {
            throw TerminalToolRouterError.turnUnavailable
        }
        guard conversationKey == nil
            || binding.conversationKey == conversationKey
        else {
            throw TerminalToolRouterError.turnUnavailable
        }
        return binding
    }

    private func performActivation(
        _ turn: TurnKey,
        prepared: PreparedTurn,
        activationToken: UUID
    ) async throws -> TerminalEndpointBinding {
        do {
            let preparedValue = try await prepared.task.value
            let binding = try await registry.claimPreparedTurn(
                handle: turn.handle,
                token: prepared.bindingToken,
                conversationKey: prepared.conversationKey,
                turnID: turn.turnID
            )
            guard preparedValue.token == prepared.bindingToken,
                binding.token == prepared.bindingToken
            else {
                throw TerminalEndpointRegistryError.bindingMismatch
            }
            guard activationTasks[turn]?.token == activationToken else {
                throw TerminalToolRouterError.turnUnavailable
            }
            activeBindings[turn] = binding
            if case .activating = turnLifecycles[turn] {
                turnLifecycles[turn] = .active
            }
            activationTasks.removeValue(forKey: turn)
            return binding
        } catch {
            await registry.releasePrepared(
                handle: turn.handle,
                token: prepared.bindingToken,
                conversationKey: prepared.conversationKey
            )
            if activationTasks[turn]?.token == activationToken {
                activationTasks.removeValue(forKey: turn)
                activeBindings.removeValue(forKey: turn)
                if case .activating = turnLifecycles[turn] {
                    turnLifecycles.removeValue(forKey: turn)
                }
            }
            if let error = error as? TerminalToolRouterError {
                throw error
            }
            throw mapRegistryError(error)
        }
    }

    private func takePreparedTurn(
        threadID: AgentThreadID,
        handle: AgentTurnHandle
    ) -> PreparedTurn? {
        guard let prepared = preparedTurns[threadID],
            prepared.handle == handle
        else { return nil }
        preparedTurns.removeValue(forKey: threadID)
        return prepared
    }

    private func cleanupTerminationWaiter(
        turn: TurnKey,
        token: UUID
    ) {
        guard terminationTasks[turn]?.token == token else { return }
        terminationTasks.removeValue(forKey: turn)
    }

    private func mapRegistryError(_ error: any Error) -> TerminalToolRouterError {
        switch error {
        case TerminalEndpointRegistryError.pinLost:
            .pinLost
        case TerminalEndpointRegistryError.noFocusedEndpoint,
            TerminalEndpointRegistryError.endpointNotFound:
            .endpointUnavailable
        default:
            .turnUnavailable
        }
    }
}
