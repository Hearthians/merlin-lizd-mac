import Testing
@testable import MerlinLizdCore
@testable import MerlinLizdCodexAdapter

private struct AcceptanceEndpoint: Sendable {
    let key: TerminalConversationKey
    let threadID: AgentThreadID
    let endpointID: TerminalEndpointID
    let terminal: any TerminalSessionPort
    let surfaces: FakeTerminalSurfaceController
}

private enum AcceptanceRuntimeError: Error {
    case missingSession
    case unexpectedResult
    case waitTimedOut(TerminalConversationKey, CodexSessionPhase)
}

private final class CodexTerminalAcceptanceRuntime: @unchecked Sendable {
    let fixture: CodexSessionPersistenceFixture
    let store: FileCodexConversationStore
    let journal: FileTerminalOperationJournal
    let registry: TerminalEndpointRegistry
    let router: TerminalToolRouter
    let coordinator: CodexSessionCoordinator
    let probe: CodexSessionStateProbe
    let endpoints: [TerminalConversationKey: AcceptanceEndpoint]

    private init(
        fixture: CodexSessionPersistenceFixture,
        store: FileCodexConversationStore,
        journal: FileTerminalOperationJournal,
        registry: TerminalEndpointRegistry,
        router: TerminalToolRouter,
        coordinator: CodexSessionCoordinator,
        probe: CodexSessionStateProbe,
        endpoints: [TerminalConversationKey: AcceptanceEndpoint]
    ) {
        self.fixture = fixture
        self.store = store
        self.journal = journal
        self.registry = registry
        self.router = router
        self.coordinator = coordinator
        self.probe = probe
        self.endpoints = endpoints
    }

    static func make(
        agent: any CodexAgentClient,
        endpoints: [AcceptanceEndpoint],
        nonce: String = "ACCEPT"
    ) async throws -> CodexTerminalAcceptanceRuntime {
        let fixture = try CodexSessionPersistenceFixture()
        do {
            let store = try FileCodexConversationStore(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            )
            let journal = try FileTerminalOperationJournal(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            )
            for endpoint in endpoints {
                _ = try await store.apply(.upsert(CodexConversationRecord(
                    key: endpoint.key,
                    threadID: endpoint.threadID
                )))
            }
            let registry = TerminalEndpointRegistry()
            let router = TerminalToolRouter(
                registry: registry,
                approvalBroker: TerminalApprovalBroker(),
                journal: journal,
                nonce: { _ in nonce }
            )
            let coordinator = CodexSessionCoordinator(
                agent: agent,
                store: store,
                registry: registry,
                router: router,
                journal: journal
            )
            for endpoint in endpoints {
                try await coordinator.registerEndpoint(TerminalEndpoint(
                    id: endpoint.endpointID,
                    conversationKey: endpoint.key,
                    terminal: endpoint.terminal,
                    surfaces: endpoint.surfaces,
                    route: acceptanceRoute(for: endpoint.key)
                ))
            }
            let probe = CodexSessionStateProbe()
            await probe.start(await coordinator.states())
            return CodexTerminalAcceptanceRuntime(
                fixture: fixture,
                store: store,
                journal: journal,
                registry: registry,
                router: router,
                coordinator: coordinator,
                probe: probe,
                endpoints: Dictionary(
                    uniqueKeysWithValues: endpoints.map { ($0.key, $0) }
                )
            )
        } catch {
            fixture.remove()
            throw error
        }
    }

    func start(
        _ key: TerminalConversationKey,
        prompt: String
    ) async throws -> CodexSessionState {
        await coordinator.submit(prompt, for: key)
        return try await wait(for: key, phase: .thinking)
    }

    func wait(
        for key: TerminalConversationKey,
        phase: CodexSessionPhase,
        containingMessage message: String? = nil
    ) async throws -> CodexSessionState {
        do {
            return try await codexSessionWithDeadline {
                await self.probe.wait(
                    for: key,
                    phase: phase,
                    containingMessage: message
                )
            }
        } catch is CodexSessionTestDeadlineError {
            throw AcceptanceRuntimeError.waitTimedOut(key, phase)
        }
    }

    func waitForApproval(
        for key: TerminalConversationKey
    ) async throws -> TerminalApprovalRequest {
        let state = try await wait(for: key, phase: .awaitingApproval)
        guard let request = state.pendingApprovals.first else {
            throw AcceptanceRuntimeError.missingSession
        }
        return request
    }

    func execute(
        _ call: TerminalToolCall,
        for key: TerminalConversationKey
    ) async throws -> TerminalToolResult {
        guard let state = await coordinator.snapshot()[key],
            let threadID = state.threadID,
            let turnID = state.activeTurnID
        else {
            throw AcceptanceRuntimeError.missingSession
        }
        return try await router.execute(
            threadID: threadID,
            turnID: turnID,
            call: call
        )
    }

    func observe(
        _ key: TerminalConversationKey
    ) async throws -> TerminalScreenSnapshot {
        guard case let .screen(screen) = try await execute(
            .observeScreen,
            for: key
        ) else {
            throw AcceptanceRuntimeError.unexpectedResult
        }
        return screen
    }

    func send(
        _ batch: TerminalInputBatch,
        for key: TerminalConversationKey
    ) async throws -> TerminalInputReceipt {
        guard case let .inputAccepted(receipt) = try await execute(
            .sendInput(batch),
            for: key
        ) else {
            throw AcceptanceRuntimeError.unexpectedResult
        }
        return receipt
    }

    func shutdown() async {
        await probe.stop()
        await coordinator.shutdown()
        fixture.remove()
    }
}

private func withAcceptanceRuntime<Value: Sendable>(
    agent: any CodexAgentClient,
    endpoints: [AcceptanceEndpoint],
    nonce: String = "ACCEPT",
    body: @escaping @Sendable (CodexTerminalAcceptanceRuntime) async throws
        -> Value
) async throws -> Value {
    let runtime = try await CodexTerminalAcceptanceRuntime.make(
        agent: agent,
        endpoints: endpoints,
        nonce: nonce
    )
    do {
        let result = try await body(runtime)
        await runtime.shutdown()
        return result
    } catch {
        await runtime.shutdown()
        throw error
    }
}

private func acceptanceKey(
    serverID: String = "$acceptance",
    createdAt: Int64 = 1
) -> TerminalConversationKey {
    TerminalConversationKey(
        target: .local,
        tmux: TmuxSessionIdentity(
            serverSessionID: serverID,
            createdAtEpoch: createdAt
        )
    )
}

private func acceptanceRoute(for key: TerminalConversationKey) -> TmuxRoute {
    let target: TerminalTarget
    switch key.target {
    case .local:
        target = .local
    case let .devbox(sid):
        target = .devbox(sid: sid, name: "acceptance", alias: "acceptance")
    case let .worker(devboxSID, workerID):
        target = .worker(
            devboxSID: devboxSID,
            devboxName: "acceptance",
            alias: "acceptance",
            workerID: workerID
        )
    }
    return TmuxRoute(
        target: target,
        sessionName: "acceptance-\(key.tmux.serverSessionID)",
        expectedIdentity: key.tmux
    )
}

private func acceptanceSurface(
    for key: TerminalConversationKey,
    paneID: String = "%1",
    command: String = "zsh"
) -> TmuxSurface {
    TmuxSurface(
        sessionIdentity: key.tmux,
        windowID: "@1",
        paneID: paneID,
        currentCommand: command
    )
}

private func acceptanceScreen(
    revision: UInt64,
    text: String,
    commandMode: TerminalScreenMode = .normal,
    columns: Int = 160,
    cursorColumn: Int = 2
) -> TerminalScreenSnapshot {
    TerminalScreenSnapshot(
        revision: revision,
        columns: columns,
        rows: 30,
        cursor: TerminalCursor(
            row: 0,
            column: cursorColumn,
            isVisible: true
        ),
        mode: commandMode,
        text: text,
        significantRuns: [],
        changedRows: [0]
    )
}

private func acceptanceEndpoint(
    key: TerminalConversationKey,
    threadID: AgentThreadID,
    terminal: any TerminalSessionPort,
    surfaces: FakeTerminalSurfaceController? = nil,
    endpointID: TerminalEndpointID = .init(
        rawValue: TerminalToolFixtures.newID()
    )
) -> AcceptanceEndpoint {
    AcceptanceEndpoint(
        key: key,
        threadID: threadID,
        endpointID: endpointID,
        terminal: terminal,
        surfaces: surfaces ?? FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: key)
        )
    )
}

private func nextCoordinatorApproval(
    from stream: AsyncStream<CodexSessionActivityEvent>,
    for key: TerminalConversationKey
) async throws -> TerminalApprovalRequest {
    try await codexSessionWithDeadline {
        for await event in stream {
            guard case let .approvalRequested(eventKey, request, _) = event,
                eventKey == key
            else { continue }
            return request
        }
        throw CancellationError()
    }
}

private actor AcceptanceBlockingTerminalPort: TerminalSessionPort {
    private let screen: TerminalScreenSnapshot
    private let sendGate: TerminalToolTestGate
    private var sent: [TerminalInputBatch] = []
    private var sendCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var owners: [TerminalKeyboardOwner] = []

    init(screen: TerminalScreenSnapshot, sendGate: TerminalToolTestGate) {
        self.screen = screen
        self.sendGate = sendGate
    }

    func observeScreen() -> TerminalScreenSnapshot { screen }

    func sendInput(_ batch: TerminalInputBatch) async -> TerminalInputReceipt {
        sent.append(batch)
        let ready = sendCountWaiters.keys.filter { $0 <= sent.count }
        for count in ready {
            let waiters = sendCountWaiters.removeValue(forKey: count) ?? []
            waiters.forEach { $0.resume() }
        }
        await sendGate.wait()
        return TerminalInputReceipt(
            acceptedRevision: batch.expectedRevision,
            byteCount: batch.events.count
        )
    }

    func waitForScreen(
        _ request: TerminalScreenWaitRequest
    ) -> TerminalScreenWaitResult {
        _ = request
        return TerminalScreenWaitResult(snapshot: screen, timedOut: false)
    }

    func setKeyboardOwner(_ owner: TerminalKeyboardOwner) {
        owners.append(owner)
    }

    func waitForSendCount(_ count: Int) async {
        if sent.count >= count { return }
        await withCheckedContinuation {
            sendCountWaiters[count, default: []].append($0)
        }
    }

    func batches() -> [TerminalInputBatch] { sent }
    func keyboardOwners() -> [TerminalKeyboardOwner] { owners }
}

@Suite("Codex terminal cross-layer acceptance", .serialized)
struct CodexTerminalAcceptanceTests {
    @Test("shell observe then routine input returns an acknowledgement and stable screen")
    func shellObserveInputAcknowledgementAndStableScreen() async throws {
        let key = acceptanceKey()
        let threadID = AgentThreadID(rawValue: "acceptance-thread")
        let turnID = AgentTurnID(rawValue: "acceptance-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let port = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 1, text: "$ ")
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port
            )]
        ) { runtime in
            let state = try await runtime.start(key, prompt: "inspect shell")
            let observed = try await runtime.observe(key)
            let batch = TerminalInputBatch(
                expectedRevision: 1,
                events: [.text("pwd")],
                purpose: "type routine shell input",
                declaredRisk: .routine
            )
            let receipt = try await runtime.send(batch, for: key)
            guard case let .screenWait(waited) = try await runtime.execute(
                .waitForScreen(.init(
                    condition: .stable(after: 1, for: .zero),
                    timeout: .seconds(1)
                )),
                for: key
            ) else {
                throw AcceptanceRuntimeError.unexpectedResult
            }

            #expect(state.threadID == threadID)
            #expect(state.activeTurnID == turnID)
            #expect(observed.revision == 1)
            #expect(receipt == .init(
                acceptedRevision: 1,
                byteCount: batch.events.count
            ))
            #expect(waited.snapshot.revision == 1)
            #expect(await port.batches() == [batch])
            let events = try await runtime.journal.entries(for: key)
            let endpointIndex = try #require(events.firstIndex {
                if case .endpoint = $0.kind { true } else { false }
            })
            let emittedIndex = try #require(events.firstIndex {
                if case .emittedBatch = $0.kind { true } else { false }
            })
            let resultIndex = try #require(events.lastIndex {
                if case .result = $0.kind { true } else { false }
            })
            #expect(endpointIndex < emittedIndex)
            #expect(emittedIndex < resultIndex)
        }
    }

    @Test("alternate-screen semantic navigation rejects stale revision until re-observed")
    func alternateScreenNavigationRequiresFreshRevision() async throws {
        let key = acceptanceKey(serverID: "$alternate", createdAt: 20)
        let threadID = AgentThreadID(rawValue: "alternate-thread")
        let turnID = AgentTurnID(rawValue: "alternate-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let alternate = TerminalScreenMode(
            isAlternateScreen: true,
            keyboardMode: .applicationCursor
        )
        let port = FakeTerminalToolPort(snapshot: acceptanceScreen(
            revision: 20,
            text: "VIM - NORMAL",
            commandMode: alternate
        ))
        let surfaces = FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: key, command: "vim")
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port,
                surfaces: surfaces
            )],
            nonce: "VIM"
        ) { runtime in
            _ = try await runtime.start(key, prompt: "navigate Vim")
            let navigation = TerminalInputBatch(
                expectedRevision: 20,
                events: [.key(.down, modifiers: [])],
                purpose: "move one visible Vim row",
                declaredRisk: .routine
            )
            _ = try await runtime.send(navigation, for: key)
            await port.setSnapshot(acceptanceScreen(
                revision: 21,
                text: "VIM - INSERT",
                commandMode: alternate
            ))
            await #expect(throws: TerminalToolRouterError.staleRevision(
                expected: 20,
                actual: 21
            )) {
                _ = try await runtime.send(navigation, for: key)
            }
            let refreshed = try await runtime.observe(key)
            #expect(refreshed.revision == 21)
            #expect(refreshed.mode == alternate)
            #expect(await port.batches() == [navigation])
            #expect(!(try await runtime.journal.entries(for: key)).isEmpty)
        }
    }

    @Test("destructive background approval expires after the visible route changes")
    func destructiveApprovalExpiresAfterRouteChange() async throws {
        let key = acceptanceKey(serverID: "$approval", createdAt: 30)
        let threadID = AgentThreadID(rawValue: "approval-thread")
        let turnID = AgentTurnID(rawValue: "approval-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let port = FakeTerminalToolPort(snapshot: acceptanceScreen(
            revision: 30,
            text: "Delete generated workspace? [y/N]"
        ))
        let surfaces = FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: key)
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port,
                surfaces: surfaces
            )]
        ) { runtime in
            _ = try await runtime.start(key, prompt: "handle prompt")
            let batch = TerminalInputBatch(
                expectedRevision: 30,
                events: [.key(.enter, modifiers: [])],
                purpose: "confirm destructive prompt",
                declaredRisk: .high
            )
            let mutation = Task { try await runtime.send(batch, for: key) }
            let approval = try await runtime.waitForApproval(for: key)
            #expect(approval.batch == batch)
            #expect(approval.scope.endpointID == runtime.endpoints[key]?.endpointID)
            await surfaces.setSurface(acceptanceSurface(
                for: key,
                paneID: "%route-changed"
            ))
            await runtime.coordinator.approve(approval.id)
            await #expect(throws: TerminalToolRouterError.approvalExpired) {
                _ = try await mutation.value
            }
            #expect(await port.batches().isEmpty)
            #expect((await runtime.coordinator.snapshot())[key]?
                .pendingApprovals.isEmpty == true)
            let events = try await runtime.journal.entries(for: key)
            #expect(events.contains {
                if case .approval(_, _, .expired) = $0.kind { true } else { false }
            })
        }
    }

    @Test("visible temporary pane closes only after the fixed jobs probe and restores origin")
    func temporaryPaneClosesAfterVisibleIdleProof() async throws {
        let key = acceptanceKey(serverID: "$temporary", createdAt: 40)
        let threadID = AgentThreadID(rawValue: "temporary-thread")
        let turnID = AgentTurnID(rawValue: "temporary-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let port = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 40, text: "$ ")
        )
        let origin = acceptanceSurface(for: key)
        let temporary = acceptanceSurface(for: key, paneID: "%temporary")
        let surfaces = FakeTerminalSurfaceController(surface: origin)
        await surfaces.setCreatedSurface(temporary)
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port,
                surfaces: surfaces
            )]
        ) { runtime in
            _ = try await runtime.start(key, prompt: "use a temporary pane")
            await port.enqueueWait(.init(
                snapshot: acceptanceScreen(revision: 41, text: "$ "),
                timedOut: false
            ))
            let creating = Task {
                try await runtime.execute(
                    .createTemporaryPane(expectedRevision: 40),
                    for: key
                )
            }
            let createApproval = try await runtime.waitForApproval(for: key)
            await runtime.coordinator.approve(createApproval.id)
            guard case let .temporaryPaneCreated(lease, paneScreen)
                = try await creating.value
            else { throw AcceptanceRuntimeError.unexpectedResult }
            _ = try await runtime.wait(for: key, phase: .thinking)
            #expect(lease.origin == origin)
            #expect(lease.temporary == temporary)
            #expect(paneScreen.revision == 41)

            await port.enqueueWait(.init(
                snapshot: acceptanceScreen(
                    revision: 42,
                    text: "BACCEPT\nEACCEPT\n$ "
                ),
                timedOut: false
            ))
            let finishing = Task {
                try await runtime.execute(.finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 41
                ), for: key)
            }
            let finishApproval = try await runtime.waitForApproval(for: key)
            await runtime.coordinator.approve(finishApproval.id)
            #expect(try await finishing.value
                == .temporaryPaneFinished(.closed(lease)))
            let probe = try #require(await port.batches().last)
            #expect(probe.events == [
                .text("b=BACCEPT;e=EACCEPT;printf '\\n%s\\n' $b;jobs -p;printf '%s\\n' $e"),
                .key(.enter, modifiers: []),
            ])
            #expect(await surfaces.recordedCalls().contains(
                "close:\(temporary.paneID)"
            ))
            #expect(try await surfaces.currentSurface(
                route: acceptanceRoute(for: key)
            ) == origin)
            #expect(!(try await runtime.journal.entries(for: key)).isEmpty)
        }
    }

    @Test("jobs found in a temporary pane retain typed provenance and report the exact jobs")
    func temporaryPaneJobsRetainTypedReport() async throws {
        let key = acceptanceKey(serverID: "$jobs", createdAt: 50)
        let threadID = AgentThreadID(rawValue: "jobs-thread")
        let turnID = AgentTurnID(rawValue: "jobs-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let port = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 50, text: "$ ")
        )
        let temporary = acceptanceSurface(for: key, paneID: "%jobs")
        let surfaces = FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: key)
        )
        await surfaces.setCreatedSurface(temporary)
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port,
                surfaces: surfaces
            )],
            nonce: "JOBS"
        ) { runtime in
            _ = try await runtime.start(key, prompt: "inspect background jobs")
            await port.enqueueWait(.init(
                snapshot: acceptanceScreen(revision: 51, text: "$ "),
                timedOut: false
            ))
            let creating = Task {
                try await runtime.execute(
                    .createTemporaryPane(expectedRevision: 50),
                    for: key
                )
            }
            let createApproval = try await runtime.waitForApproval(for: key)
            await runtime.coordinator.approve(createApproval.id)
            guard case let .temporaryPaneCreated(lease, _)
                = try await creating.value
            else { throw AcceptanceRuntimeError.unexpectedResult }
            _ = try await runtime.wait(for: key, phase: .thinking)

            await port.enqueueWait(.init(
                snapshot: acceptanceScreen(
                    revision: 52,
                    text: "BJOBS\n231\n904\nEJOBS\n$ "
                ),
                timedOut: false
            ))
            let finishing = Task {
                try await runtime.execute(.finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 51
                ), for: key)
            }
            let finishApproval = try await runtime.waitForApproval(for: key)
            await runtime.coordinator.approve(finishApproval.id)
            #expect(try await finishing.value == .temporaryPaneFinished(
                .retained(lease, reason: .backgroundJobs(["231", "904"]))
            ))
            #expect(!(await surfaces.recordedCalls()).contains {
                $0.hasPrefix("close:")
            })
            let events = try await runtime.journal.entries(for: key)
            #expect(events.contains { event in
                guard case let .temporaryPane(.retained(id, pane, reason))
                    = event.kind
                else { return false }
                return id == lease.id
                    && pane.paneID == temporary.paneID
                    && reason == .backgroundJobs
            })
        }
    }

    @Test("two conversations overlap while every mutation for one key stays serialized")
    func conversationsOverlapButOneKeySerializes() async throws {
        let firstKey = acceptanceKey(serverID: "$overlap-a", createdAt: 61)
        let secondKey = acceptanceKey(serverID: "$overlap-b", createdAt: 62)
        let firstThread = AgentThreadID(rawValue: "overlap-a")
        let secondThread = AgentThreadID(rawValue: "overlap-b")
        let firstTurn = AgentTurnID(rawValue: "turn-a")
        let secondTurn = AgentTurnID(rawValue: "turn-b")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(firstTurn, for: firstThread)
        await agent.enqueueTurn(secondTurn, for: secondThread)
        let gate = TerminalToolTestGate()
        let firstPort = AcceptanceBlockingTerminalPort(
            screen: acceptanceScreen(revision: 60, text: "$ "),
            sendGate: gate
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 60, text: "$ ")
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [
                acceptanceEndpoint(
                    key: firstKey,
                    threadID: firstThread,
                    terminal: firstPort
                ),
                acceptanceEndpoint(
                    key: secondKey,
                    threadID: secondThread,
                    terminal: secondPort
                ),
            ]
        ) { runtime in
            _ = try await runtime.start(firstKey, prompt: "first")
            _ = try await runtime.start(secondKey, prompt: "second")
            let firstBatch = TerminalToolFixtures.input(
                revision: 60,
                purpose: "first serialized mutation"
            )
            let queuedBatch = TerminalToolFixtures.input(
                revision: 60,
                purpose: "second serialized mutation"
            )
            let otherBatch = TerminalToolFixtures.input(
                revision: 60,
                purpose: "independent mutation"
            )
            let first = Task {
                try await runtime.send(firstBatch, for: firstKey)
            }
            try await codexSessionWithDeadline {
                await firstPort.waitForSendCount(1)
            }
            let queued = Task {
                try await runtime.send(queuedBatch, for: firstKey)
            }
            let independent = try await runtime.send(otherBatch, for: secondKey)

            #expect(independent == .init(
                acceptedRevision: 60,
                byteCount: otherBatch.events.count
            ))
            #expect(await firstPort.batches() == [firstBatch])
            #expect(await secondPort.batches() == [otherBatch])
            await gate.open()
            _ = try await first.value
            _ = try await queued.value
            #expect(await firstPort.batches() == [firstBatch, queuedBatch])
            #expect(!(try await runtime.journal.entries(for: firstKey)).isEmpty)
            #expect(!(try await runtime.journal.entries(for: secondKey)).isEmpty)
        }
    }

    @Test("duplicate tabs share one conversation transcript badges and pinned endpoint")
    func duplicateTabsShareConversationAndOnePin() async throws {
        let key = acceptanceKey(serverID: "$duplicate", createdAt: 70)
        let threadID = AgentThreadID(rawValue: "duplicate-thread")
        let turnID = AgentTurnID(rawValue: "duplicate-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let port = FakeTerminalToolPort(snapshot: acceptanceScreen(
            revision: 70,
            text: "Proceed? [y/N]"
        ))
        let originalID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port,
                endpointID: originalID
            )]
        ) { runtime in
            _ = try await runtime.start(key, prompt: "inspect")
            await agent.emit(.userMessage("inspect"), for: threadID)
            await agent.emit(.assistantMessageCompleted("working"), for: threadID)
            _ = try await runtime.wait(
                for: key,
                phase: .thinking,
                containingMessage: "working"
            )
            let activity = await runtime.coordinator.activityEvents()
            let batch = TerminalInputBatch(
                expectedRevision: 70,
                events: [.key(.enter, modifiers: [])],
                purpose: "confirm duplicate-tab acceptance",
                declaredRisk: .high
            )
            let mutation = Task { try await runtime.send(batch, for: key) }
            let streamedApproval = Task {
                try await nextCoordinatorApproval(from: activity, for: key)
            }
            let awaiting = try await runtime.wait(
                for: key,
                phase: .awaitingApproval
            )
            let approval = try #require(awaiting.pendingApprovals.first)
            #expect(try await streamedApproval.value == approval)

            let duplicateID = TerminalEndpointID(
                rawValue: TerminalToolFixtures.newID()
            )
            try await runtime.coordinator.registerEndpoint(TerminalEndpoint(
                id: duplicateID,
                conversationKey: key,
                terminal: FakeTerminalToolPort(snapshot: acceptanceScreen(
                    revision: 70,
                    text: "duplicate"
                )),
                surfaces: FakeTerminalSurfaceController(
                    surface: acceptanceSurface(for: key, paneID: "%duplicate")
                ),
                route: acceptanceRoute(for: key)
            ))
            try await runtime.coordinator.focusEndpoint(duplicateID)
            let tabs = [
                TerminalTabRecord(
                    id: "duplicate-a",
                    title: "A",
                    target: .local,
                    sessionName: "acceptance",
                    tmuxIdentity: key.tmux
                ),
                TerminalTabRecord(
                    id: "duplicate-b",
                    title: "B",
                    target: .local,
                    sessionName: "renamed-display-only",
                    tmuxIdentity: key.tmux
                ),
            ]
            var drawer = CodexDrawerState(availability: .ready)
            drawer.reduce(.selectTerminal(.connected(key)))
            drawer.reduce(.receiveSessions(await runtime.coordinator.snapshot()))

            #expect(drawer.selectedSession?.messages == [
                AgentMessage(role: .user, text: "inspect"),
                AgentMessage(role: .assistant, text: "working"),
            ])
            #expect(drawer.selectedSession?.phase == .awaitingApproval)
            #expect(drawer.selectedSession?.pendingApprovals == [approval])
            #expect(drawer.badges(for: tabs)["duplicate-a"]
                == drawer.badges(for: tabs)["duplicate-b"])
            #expect(drawer.badges(for: tabs)["duplicate-a"] == .init(
                phase: .awaitingApproval,
                approvalCount: 1
            ))
            let pins = await runtime.registry.pinSnapshot().pins.values
            #expect(pins.count == 1)
            #expect(pins.first?.endpointID == originalID)
            await runtime.coordinator.deny(approval.id)
            await #expect(throws: TerminalToolRouterError.approvalDenied) {
                _ = try await mutation.value
            }
            #expect(!(try await runtime.journal.entries(for: key)).isEmpty)
        }
    }

    @Test("closing a pinned tab interrupts only local ownership without terminal control bytes")
    func pinnedTabCloseInterruptsWithoutControlBytes() async throws {
        let key = acceptanceKey(serverID: "$pinned-close", createdAt: 80)
        let threadID = AgentThreadID(rawValue: "pinned-close-thread")
        let turnID = AgentTurnID(rawValue: "pinned-close-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        let port = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 80, text: "$ ")
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: key)
        )
        let endpoint = acceptanceEndpoint(
            key: key,
            threadID: threadID,
            terminal: port,
            surfaces: surfaces
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [endpoint]
        ) { runtime in
            _ = try await runtime.start(key, prompt: "begin")
            await runtime.coordinator.unregisterEndpoint(endpoint.endpointID)
            let state = try await runtime.wait(for: key, phase: .interrupted)
            #expect(state.activeTurnID == nil)
            #expect(await agent.recordedInterruptCalls() == [
                .init(threadID: threadID, turnID: turnID),
            ])
            #expect(await port.batches().isEmpty)
            #expect(await surfaces.recordedCalls().isEmpty)
            #expect(await port.keyboardOwners() == [.codex, .user])
            #expect(try await runtime.journal.entries(for: key) == [])
        }
    }

    @Test("agent transport crash quiesces only its owning key without replay or remote mutation")
    func crashContainsFailureToOwningConversation() async throws {
        let firstKey = acceptanceKey(serverID: "$crash-a", createdAt: 90)
        let secondKey = acceptanceKey(serverID: "$crash-b", createdAt: 91)
        let firstThread = AgentThreadID(rawValue: "crash-thread-a")
        let secondThread = AgentThreadID(rawValue: "crash-thread-b")
        let firstTurn = AgentTurnID(rawValue: "crash-turn-a")
        let secondTurn = AgentTurnID(rawValue: "crash-turn-b")
        let replacementTurn = AgentTurnID(rawValue: "crash-turn-a-2")
        let failedGeneration = ScriptedSupervisorGeneration(
            turnIDs: [secondTurn.rawValue, firstTurn.rawValue]
        )
        let recoveredGeneration = ScriptedSupervisorGeneration(
            turnIDs: [replacementTurn.rawValue]
        )
        let factory = ScriptedSupervisorGenerationFactory(outcomes: [
            .generation(failedGeneration),
            .generation(recoveredGeneration),
        ])
        let supervisor = CodexAppServerSupervisor(
            generationFactory: { try await factory.makeGeneration() },
            sleeper: { _ in }
        )
        let firstPort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 90, text: "$ ")
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 90, text: "$ ")
        )
        let firstSurfaces = FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: firstKey)
        )
        let secondSurfaces = FakeTerminalSurfaceController(
            surface: acceptanceSurface(for: secondKey)
        )
        let firstEndpoint = acceptanceEndpoint(
            key: firstKey,
            threadID: firstThread,
            terminal: firstPort,
            surfaces: firstSurfaces
        )
        try await withAcceptanceRuntime(
            agent: supervisor,
            endpoints: [
                firstEndpoint,
                acceptanceEndpoint(
                    key: secondKey,
                    threadID: secondThread,
                    terminal: secondPort,
                    surfaces: secondSurfaces
                ),
            ]
        ) { runtime in
            _ = try await runtime.start(secondKey, prompt: "second")
            await failedGeneration.waitForEventSubscriberCount(
                1,
                threadID: secondThread
            )
            await failedGeneration.emit(
                .events([
                    .init(sequence: 1, event: .turnStarted(secondTurn)),
                    .init(sequence: 2, event: .turnCompleted(secondTurn)),
                ]),
                for: secondThread
            )
            let forwarded = await supervisor.events(
                for: secondThread,
                after: nil
            )
            let firstForwarded = try await codexSessionWithDeadline {
                var iterator = forwarded.makeAsyncIterator()
                return await iterator.next()
            }
            #expect(firstForwarded == .event(.init(
                sequence: 1,
                event: .turnStarted(secondTurn)
            )))
            let completed = try await runtime.wait(
                for: secondKey,
                phase: .waitingForUser
            )
            _ = try await runtime.start(firstKey, prompt: "first")
            await failedGeneration.waitForEventSubscriberCount(
                1,
                threadID: firstThread
            )

            await failedGeneration.crash()
            let failed = try await runtime.wait(
                for: firstKey,
                phase: .failed(.crashed)
            )
            try await recoveredGeneration.waitForResumeCount(
                1,
                timeout: .seconds(1)
            )
            let afterCrash = await runtime.coordinator.snapshot()
            #expect(failed.activeTurnID == nil)
            #expect(afterCrash[secondKey] == completed)
            #expect(await failedGeneration.recordedCalls.filter {
                if case .startTurn = $0 { true } else { false }
            }.count == 2)
            #expect(await recoveredGeneration.recordedCalls.filter {
                if case .startTurn = $0 { true } else { false }
            }.isEmpty)

            _ = try await runtime.start(firstKey, prompt: "after recovery")
            await runtime.coordinator.unregisterEndpoint(firstEndpoint.endpointID)
            let interrupted = try await runtime.wait(
                for: firstKey,
                phase: .interrupted
            )
            #expect(interrupted.activeTurnID == nil)
            #expect((await runtime.coordinator.snapshot())[secondKey] == completed)
            #expect(await recoveredGeneration.recordedCalls.filter {
                if case .startTurn = $0 { true } else { false }
            }.count == 1)
            #expect(await firstPort.batches().isEmpty)
            #expect(await secondPort.batches().isEmpty)
            #expect(await firstSurfaces.recordedCalls().isEmpty)
            #expect(await secondSurfaces.recordedCalls().isEmpty)
            #expect(try await runtime.journal.entries(for: firstKey) == [])
            #expect(try await runtime.journal.entries(for: secondKey) == [])
        }
    }

    @Test("journal and store reopen while archive preserves and confirmed delete removes both")
    func persistenceReopenArchiveAndConfirmedDelete() async throws {
        let key = acceptanceKey(serverID: "$durable", createdAt: 100)
        let threadID = AgentThreadID(rawValue: "durable-thread")
        let agent = FakeCodexSessionAgent(threadIDs: [])
        let port = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 100, text: "$ ")
        )
        try await withAcceptanceRuntime(
            agent: agent,
            endpoints: [acceptanceEndpoint(
                key: key,
                threadID: threadID,
                terminal: port
            )]
        ) { runtime in
            let event = terminalTestJournalEvent(
                key: key,
                operationID: TerminalToolFixtures.newID(),
                turnID: "durable-turn",
                kind: .request(
                    operation: "observeScreen",
                    purpose: "durability acceptance"
                )
            )
            try await runtime.journal.append(event)
            try await runtime.coordinator.setArchived(true, for: key)
            let reopenedStore = try FileCodexConversationStore(
                applicationSupportDirectory:
                    runtime.fixture.applicationSupportDirectory
            )
            let reopenedJournal = try FileTerminalOperationJournal(
                applicationSupportDirectory:
                    runtime.fixture.applicationSupportDirectory
            )
            #expect(try await reopenedStore.snapshot().records[key]?.archived
                == true)
            #expect(try await reopenedJournal.entries(for: key) == [event])
            #expect(await agent.recordedArchiveCalls() == [threadID])

            try await runtime.coordinator.deleteConversation(
                key,
                confirmation: .confirmed
            )
            let afterDeleteStore = try FileCodexConversationStore(
                applicationSupportDirectory:
                    runtime.fixture.applicationSupportDirectory
            )
            let afterDeleteJournal = try FileTerminalOperationJournal(
                applicationSupportDirectory:
                    runtime.fixture.applicationSupportDirectory
            )
            #expect(try await afterDeleteStore.snapshot().records[key] == nil)
            #expect(try await afterDeleteJournal.entries(for: key).isEmpty)
            #expect(await agent.recordedDeleteCalls() == [threadID])
        }
    }
}
