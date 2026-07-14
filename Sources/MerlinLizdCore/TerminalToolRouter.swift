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

public actor TerminalToolRouter {
    private struct TurnKey: Hashable, Sendable {
        let threadID: AgentThreadID
        let turnID: AgentTurnID
    }

    private struct ActiveOperation {
        let turn: TurnKey
        let task: Task<TerminalToolResult, any Error>
    }

    private enum TurnLifecycle: Sendable {
        case active
        case terminating
        case ended
    }

    private struct LeaseRecord: Sendable {
        let binding: TerminalEndpointBinding
        let provenance: RetainedTemporaryPaneLease
        let lease: TemporaryPaneLease?
        let retentionReason: TemporaryPaneRetentionReason?
    }

    private struct LeaseKey: Hashable, Sendable {
        let turn: TurnKey
        let leaseID: UUID
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
    private var blockedTurns: Set<TurnKey> = []
    private var preparedTurns: [AgentThreadID: TerminalConversationKey] = [:]
    private var turnLifecycles: [TurnKey: TurnLifecycle] = [:]

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
    ) async throws -> TerminalEndpointBinding {
        guard preparedTurns[threadID] == nil else {
            throw TerminalEndpointRegistryError.threadAlreadyPrepared
        }
        preparedTurns[threadID] = conversationKey
        do {
            return try await registry.prepareTurn(
                threadID: threadID,
                conversationKey: conversationKey
            )
        } catch {
            if preparedTurns[threadID] == conversationKey {
                preparedTurns.removeValue(forKey: threadID)
            }
            throw error
        }
    }

    public func confirmTurnID(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async throws {
        let turn = TurnKey(threadID: threadID, turnID: turnID)
        let preparedKey = try activateTurn(turn)
        do {
            try await registry.confirmTurnID(threadID: threadID, turnID: turnID)
        } catch {
            if let preparedKey {
                turnLifecycles[turn] = .ended
                await registry.releasePrepared(
                    threadID: threadID,
                    conversationKey: preparedKey
                )
            }
            throw mapRegistryError(error)
        }
    }

    public func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        conversationKey: TerminalConversationKey,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        let operationID = UUID()
        let turn = TurnKey(threadID: threadID, turnID: turnID)
        let preparedKey = try activateTurn(
            turn,
            conversationKey: conversationKey
        )
        let task = Task {
            let binding: TerminalEndpointBinding
            do {
                binding = try await self.registry.claimPreparedTurn(
                    threadID: threadID,
                    conversationKey: conversationKey,
                    turnID: turnID
                )
            } catch {
                if let preparedKey {
                    self.turnLifecycles[turn] = .ended
                    await self.registry.releasePrepared(
                        threadID: threadID,
                        conversationKey: preparedKey
                    )
                }
                throw self.mapRegistryError(error)
            }
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

    public func pendingApprovals() async -> [TerminalApprovalRequest] {
        await approvalBroker.pendingRequests()
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
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async throws {
        try await terminateTurn(
            TurnKey(threadID: threadID, turnID: turnID),
            reason: .interrupted
        )
    }

    public func endTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async throws {
        try await terminateTurn(
            TurnKey(threadID: threadID, turnID: turnID),
            reason: .turnEnded
        )
    }

    public func crashTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async throws {
        try await terminateTurn(
            TurnKey(threadID: threadID, turnID: turnID),
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

    private func perform(
        turn: TurnKey,
        binding: TerminalEndpointBinding,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        try await ensureBinding(turn: turn, binding: binding)
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
            let selected = try await binding.endpoint.surfaces.select(
                selection,
                from: origin,
                route: binding.endpoint.route
            )
            try verifySurfaceIdentity(selected, binding: binding)
            try await ensureBinding(turn: turn, binding: binding)
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
                retentionReason: nil
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
                throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                    provenance,
                    reason: .auditUnavailable
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
            guard temporary.sessionIdentity == binding.conversationKey.tmux,
                temporary.sessionIdentity == binding.endpoint.route.expectedIdentity
            else {
                throw TerminalToolRouterError.temporaryPaneRetained(
                    provenance,
                    reason: .controllerRetained(
                        .sessionIdentityMismatch(
                            expected: binding.endpoint.route.expectedIdentity,
                            actual: temporary.sessionIdentity
                        )
                    )
                )
            }
            guard temporary.paneID != origin.paneID else {
                throw TerminalToolRouterError.temporaryPaneRetained(
                    provenance,
                    reason: .controllerRetained(.unavailable)
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
                    retentionReason: retentionReason
                )
                do {
                    try await appendTemporary(
                        .retained(
                            leaseID: leaseID,
                            pane: TerminalJournalPaneProvenance(pane),
                            reason: String(describing: retentionReason)
                        ),
                        preparation: preparation,
                        turn: turn
                    )
                } catch {
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
            throw TerminalToolRouterError.interrupted
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
                binding: binding
            )
        } catch TerminalToolRouterError.auditUnavailable {
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: .auditUnavailable
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
                let receipt = try await binding.endpoint.terminal.sendInput(
                    batch
                )
                try await appendResult(
                    .success(receipt),
                    preparation: preparation,
                    turn: turn
                )
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
                    throw TerminalToolRouterError.interrupted
                } catch {
                    return try await retainExistingLease(
                        record,
                        reason: .routeUnavailable,
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
                do {
                    try Task.checkCancellation()
                    try await ensureBinding(turn: turn, binding: binding)
                    try await binding.endpoint.surfaces.closeTemporaryPane(
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
                leases.removeValue(forKey: leaseKey)
                do {
                    try await appendTemporary(
                        .closed(
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
                    throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                        record.provenance,
                        reason: .auditUnavailable
                    )
                }
                return .temporaryPaneFinished(.closed(lease))
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
        binding: TerminalEndpointBinding
    ) async throws -> MutationPreparation {
        guard !blockedTurns.contains(turn) else {
            throw TerminalToolRouterError.auditUnavailable
        }
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
        let preparedKey: TerminalConversationKey?
        switch turnLifecycles[turn] {
        case .active:
            turnLifecycles[turn] = .terminating
            preparedKey = nil
        case .terminating, .ended:
            return
        case nil:
            preparedKey = preparedTurns.removeValue(forKey: turn.threadID)
            turnLifecycles[turn] = .terminating
        }
        await approvalBroker.cancelTurn(brokerTurnID(turn))
        let tasks = activeOperations.values
            .filter { $0.turn == turn }
            .map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = await task.result
        }
        var auditFailures: [TerminalTurnRetainedPaneAudit] = []
        let retainedKeys = leases.keys.filter { $0.turn == turn }
        for key in retainedKeys {
            guard let record = leases.removeValue(forKey: key) else { continue }
            let operationID = UUID()
            do {
                try await append(
                    event(
                        binding: record.binding,
                        turn: turn,
                        operationID: operationID,
                        kind: .temporaryPane(
                            .retained(
                                leaseID: record.provenance.id,
                                pane: TerminalJournalPaneProvenance(
                                    record.provenance.pane
                                ),
                                reason: String(describing: reason)
                            )
                        )
                    ),
                    turn: turn,
                    blocksMutations: false
                )
            } catch {
                auditFailures.append(
                    TerminalTurnRetainedPaneAudit(
                        provenance: record.provenance,
                        reason: reason
                    )
                )
            }
        }
        blockedTurns.remove(turn)
        if let preparedKey {
            await registry.releasePrepared(
                threadID: turn.threadID,
                conversationKey: preparedKey
            )
        } else {
            await registry.releaseTurn(
                threadID: turn.threadID,
                turnID: turn.turnID
            )
        }
        turnLifecycles[turn] = .ended
        if !auditFailures.isEmpty {
            throw TerminalTurnTerminationError.auditUnavailable(auditFailures)
        }
    }

    private func retainCreatedLease(
        _ lease: TemporaryPaneLease,
        reason: TemporaryPaneRetentionReason,
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws -> TerminalToolResult {
        do {
            try await appendTemporary(
                .retained(
                    leaseID: lease.id,
                    pane: TerminalJournalPaneProvenance(
                        windowID: lease.temporary.windowID,
                        paneID: lease.temporary.paneID
                    ),
                    reason: String(describing: reason)
                ),
                preparation: preparation,
                turn: turn
            )
        } catch {
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
        preparation: MutationPreparation,
        turn: TurnKey
    ) async throws -> Never {
        do {
            try await appendTemporary(
                .retained(
                    leaseID: lease.id,
                    pane: TerminalJournalPaneProvenance(
                        windowID: lease.temporary.windowID,
                        paneID: lease.temporary.paneID
                    ),
                    reason: String(describing: reason)
                ),
                preparation: preparation,
                turn: turn
            )
        } catch {
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
        guard let lease = record.lease else {
            throw TerminalToolRouterError.temporaryPaneRetained(
                record.provenance,
                reason: record.retentionReason ?? reason
            )
        }
        do {
            try await appendTemporary(
                .retained(
                    leaseID: record.provenance.id,
                    pane: TerminalJournalPaneProvenance(record.provenance.pane),
                    reason: String(describing: reason)
                ),
                preparation: preparation,
                turn: turn
            )
        } catch {
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: reason
            )
        }
        return .temporaryPaneFinished(
            .retained(lease, reason: reason)
        )
    }

    private func retainExistingLease(
        _ record: LeaseRecord,
        reason: TemporaryPaneRetentionReason,
        operationID: UUID,
        turn: TurnKey,
        binding: TerminalEndpointBinding
    ) async throws -> TerminalToolResult {
        guard let lease = record.lease else {
            throw TerminalToolRouterError.temporaryPaneRetained(
                record.provenance,
                reason: record.retentionReason ?? reason
            )
        }
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
                            reason: String(describing: reason)
                        ),
                    )
                ),
                turn: turn
            )
        } catch {
            throw TerminalToolRouterError.temporaryPaneAuditUnavailable(
                record.provenance,
                reason: reason
            )
        }
        return .temporaryPaneFinished(
            .retained(lease, reason: reason)
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
                blockedTurns.insert(turn)
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
                threadID: turn.threadID,
                turnID: turn.turnID,
                conversationKey: binding.conversationKey
            )
            guard current.endpoint.id == binding.endpoint.id else {
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
        return "\(thread.utf8.count):\(thread)\(turnID.utf8.count):\(turnID)"
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

    private func activateTurn(
        _ turn: TurnKey,
        conversationKey: TerminalConversationKey? = nil
    ) throws -> TerminalConversationKey? {
        switch turnLifecycles[turn] {
        case .active:
            return nil
        case .terminating, .ended:
            throw TerminalToolRouterError.turnUnavailable
        case nil:
            guard let preparedKey = preparedTurns[turn.threadID],
                conversationKey == nil || preparedKey == conversationKey
            else {
                throw TerminalToolRouterError.turnUnavailable
            }
            preparedTurns.removeValue(forKey: turn.threadID)
            turnLifecycles[turn] = .active
            return preparedKey
        }
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
