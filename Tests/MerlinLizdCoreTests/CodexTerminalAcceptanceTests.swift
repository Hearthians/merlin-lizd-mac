import Testing
@testable import MerlinLizdCore

private struct CodexTerminalAcceptanceHarness: Sendable {
    let key: TerminalConversationKey
    let endpointID: TerminalEndpointID
    let registry: TerminalEndpointRegistry
    let router: TerminalToolRouter
    let handle: AgentTurnHandle
    let turnID: AgentTurnID
    let port: FakeTerminalToolPort
    let surfaces: FakeTerminalSurfaceController
    let journal: MemoryTerminalToolJournal

    static func shell(
        revision: UInt64,
        text: String,
        key: TerminalConversationKey = TerminalToolFixtures.key,
        endpointID: TerminalEndpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        ),
        nonce: String = "ACCEPT"
    ) async throws -> Self {
        let screen = TerminalToolFixtures.screen(revision: revision, text: text)
        let port = FakeTerminalToolPort(snapshot: screen)
        let surfaces = FakeTerminalSurfaceController(
            surface: surface(for: key, command: "zsh")
        )
        let journal = MemoryTerminalToolJournal()
        let registry = TerminalEndpointRegistry()
        try await registry.register(TerminalEndpoint(
            id: endpointID,
            conversationKey: key,
            terminal: port,
            surfaces: surfaces,
            route: route(for: key)
        ))
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal,
            nonce: { _ in nonce }
        )
        let handle = try await router.beginTurn(
            threadID: AgentThreadID(rawValue: "acceptance-\(key.tmux.serverSessionID)"),
            conversationKey: key
        )
        return Self(
            key: key,
            endpointID: endpointID,
            registry: registry,
            router: router,
            handle: handle,
            turnID: AgentTurnID(rawValue: "acceptance-turn"),
            port: port,
            surfaces: surfaces,
            journal: journal
        )
    }

    func observe() async throws -> TerminalScreenSnapshot {
        guard case let .screen(screen) = try await router.execute(
            handle: handle,
            turnID: turnID,
            conversationKey: key,
            call: .observeScreen
        ) else {
            throw TerminalToolRouterError.terminalFailure
        }
        return screen
    }

    func sendRoutineText(
        _ text: String,
        revision: UInt64
    ) async throws -> TerminalInputReceipt {
        try await send(TerminalInputBatch(
                expectedRevision: revision,
                events: [.text(text)],
                purpose: "type routine shell input",
                declaredRisk: .routine
            ))
    }

    func send(_ batch: TerminalInputBatch) async throws
        -> TerminalInputReceipt
    {
        guard case let .inputAccepted(receipt) = try await execute(
            .sendInput(batch)
        ) else {
            throw TerminalToolRouterError.terminalFailure
        }
        return receipt
    }

    func execute(_ call: TerminalToolCall) async throws -> TerminalToolResult {
        try await router.execute(
            handle: handle,
            turnID: turnID,
            conversationKey: key,
            call: call
        )
    }

    func waitForStableScreen(after revision: UInt64) async throws
        -> TerminalScreenSnapshot
    {
        guard case let .screenWait(result) = try await router.execute(
            handle: handle,
            turnID: turnID,
            conversationKey: key,
            call: .waitForScreen(.init(
                condition: .stable(after: revision, for: .zero),
                timeout: .seconds(1)
            ))
        ) else {
            throw TerminalToolRouterError.terminalFailure
        }
        return result.snapshot
    }

    static func key(serverID: String, createdAt: Int64) -> TerminalConversationKey {
        TerminalConversationKey(
            target: .local,
            tmux: TmuxSessionIdentity(
                serverSessionID: serverID,
                createdAtEpoch: createdAt
            )
        )
    }

    static func route(for key: TerminalConversationKey) -> TmuxRoute {
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

    static func surface(
        for key: TerminalConversationKey,
        paneID: String = "%1",
        command: String
    ) -> TmuxSurface {
        TmuxSurface(
            sessionIdentity: key.tmux,
            windowID: "@1",
            paneID: paneID,
            currentCommand: command
        )
    }
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

private func nextAcceptanceApproval(
    from stream: AsyncStream<TerminalToolActivityEvent>,
    for key: TerminalConversationKey
) async throws -> TerminalApprovalRequest {
    for await event in stream {
        guard case let .approvalUpserted(activity, _) = event,
            activity.conversationKey == key
        else { continue }
        return activity.request
    }
    throw CancellationError()
}

private actor AcceptanceBlockingTerminalPort: TerminalSessionPort {
    private let screen: TerminalScreenSnapshot
    private let sendGate: TerminalToolTestGate
    private var sent: [TerminalInputBatch] = []
    private var sendCountWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var owners: [TerminalKeyboardOwner] = []

    init(screen: TerminalScreenSnapshot, sendGate: TerminalToolTestGate) {
        self.screen = screen
        self.sendGate = sendGate
    }

    func observeScreen() -> TerminalScreenSnapshot { screen }

    func sendInput(_ batch: TerminalInputBatch) async
        -> TerminalInputReceipt
    {
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

    func waitForScreen(_ request: TerminalScreenWaitRequest)
        -> TerminalScreenWaitResult
    {
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
        let harness = try await CodexTerminalAcceptanceHarness.shell(
            revision: 1,
            text: "$ "
        )

        let observed = try await harness.observe()
        let receipt = try await harness.sendRoutineText("pwd", revision: 1)
        let stable = try await harness.waitForStableScreen(after: 1)

        #expect(observed.revision == 1)
        #expect(receipt.acceptedRevision == 1)
        #expect(receipt.byteCount == TerminalInputBatch(
            expectedRevision: 1,
            events: [.text("pwd")],
            purpose: "type routine shell input",
            declaredRisk: .routine
        ).events.count)
        #expect(stable.revision == 1)
        #expect(await harness.port.batches().map(\.events) == [[.text("pwd")]])
        let events = await harness.journal.snapshot()
        let endpointIndex = try #require(events.firstIndex { event in
            guard case .endpoint = event.kind else { return false }
            return true
        })
        let emittedIndex = try #require(events.firstIndex { event in
            guard case .emittedBatch = event.kind else { return false }
            return true
        })
        #expect(endpointIndex < emittedIndex)
    }

    @Test("alternate-screen semantic navigation rejects stale revision until re-observed")
    func alternateScreenNavigationRequiresFreshRevision() async throws {
        let alternate = TerminalScreenMode(
            isAlternateScreen: true,
            keyboardMode: .applicationCursor
        )
        let harness = try await CodexTerminalAcceptanceHarness.shell(
            revision: 20,
            text: "VIM - NORMAL",
            nonce: "VIM"
        )
        await harness.surfaces.setSurface(
            CodexTerminalAcceptanceHarness.surface(
                for: harness.key,
                command: "vim"
            )
        )
        await harness.port.setSnapshot(acceptanceScreen(
            revision: 20,
            text: "VIM - NORMAL",
            commandMode: alternate
        ))
        let navigation = TerminalInputBatch(
            expectedRevision: 20,
            events: [.key(.down, modifiers: [])],
            purpose: "move one visible Vim row",
            declaredRisk: .routine
        )

        let receipt = try await harness.send(navigation)
        #expect(receipt.acceptedRevision == navigation.expectedRevision)
        #expect(receipt.byteCount == navigation.events.count)

        await harness.port.setSnapshot(acceptanceScreen(
            revision: 21,
            text: "VIM - INSERT",
            commandMode: alternate
        ))
        await #expect(
            throws: TerminalToolRouterError.staleRevision(
                expected: 20,
                actual: 21
            )
        ) {
            _ = try await harness.send(navigation)
        }

        let refreshed = try await harness.observe()
        #expect(refreshed.revision == 21)
        #expect(refreshed.mode == alternate)
        #expect(await harness.port.batches() == [navigation])
    }

    @Test("destructive background approval expires after the visible route changes")
    func destructiveApprovalExpiresAfterRouteChange() async throws {
        let harness = try await CodexTerminalAcceptanceHarness.shell(
            revision: 30,
            text: "Delete generated workspace? [y/N]"
        )
        let batch = TerminalInputBatch(
            expectedRevision: 30,
            events: [.key(.enter, modifiers: [])],
            purpose: "confirm destructive prompt",
            declaredRisk: .high
        )
        let subscription = await harness.router.subscribeActivity()
        let mutation = Task { try await harness.send(batch) }
        let approval = try await nextAcceptanceApproval(
            from: subscription.events,
            for: harness.key
        )

        #expect(approval.batch == batch)
        #expect(approval.scope.endpointID == harness.endpointID)
        #expect(approval.scope.screenRevision == 30)
        await harness.surfaces.setSurface(
            CodexTerminalAcceptanceHarness.surface(
                for: harness.key,
                paneID: "%route-changed",
                command: "zsh"
            )
        )
        #expect(await harness.router.approveOnce(approval.id))
        await #expect(throws: TerminalToolRouterError.approvalExpired) {
            _ = try await mutation.value
        }
        #expect(await harness.port.batches().isEmpty)
        #expect((await harness.router.activitySnapshot()).approvals.isEmpty)
    }

    @Test("visible temporary pane closes only after the fixed jobs probe and restores origin")
    func temporaryPaneClosesAfterVisibleIdleProof() async throws {
        let harness = try await CodexTerminalAcceptanceHarness.shell(
            revision: 40,
            text: "$ ",
            nonce: "ACCEPT"
        )
        let origin = CodexTerminalAcceptanceHarness.surface(
            for: harness.key,
            command: "zsh"
        )
        let temporary = CodexTerminalAcceptanceHarness.surface(
            for: harness.key,
            paneID: "%temporary",
            command: "zsh"
        )
        await harness.surfaces.setCreatedSurface(temporary)
        await harness.port.enqueueWait(.init(
            snapshot: acceptanceScreen(revision: 41, text: "$ "),
            timedOut: false
        ))
        let createSubscription = await harness.router.subscribeActivity()
        let creating = Task {
            try await harness.execute(
                .createTemporaryPane(expectedRevision: 40)
            )
        }
        let createApproval = try await nextAcceptanceApproval(
            from: createSubscription.events,
            for: harness.key
        )
        #expect(await harness.router.approveOnce(createApproval.id))
        guard case let .temporaryPaneCreated(lease, paneScreen)
            = try await creating.value
        else {
            Issue.record("expected a temporary pane lease")
            return
        }
        #expect(lease.origin == origin)
        #expect(lease.temporary == temporary)
        #expect(paneScreen.revision == 41)

        await harness.port.enqueueWait(.init(
            snapshot: acceptanceScreen(
                revision: 42,
                text: "BACCEPT\nEACCEPT\n$ "
            ),
            timedOut: false
        ))
        let finishSubscription = await harness.router.subscribeActivity()
        let finishing = Task {
            try await harness.execute(.finishTemporaryPane(
                leaseID: lease.id,
                expectedRevision: 41
            ))
        }
        let finishApproval = try await nextAcceptanceApproval(
            from: finishSubscription.events,
            for: harness.key
        )
        #expect(await harness.router.approveOnce(finishApproval.id))
        #expect(
            try await finishing.value
                == .temporaryPaneFinished(.closed(lease))
        )

        let probe = try #require(await harness.port.batches().last)
        #expect(probe.purpose == "prove temporary pane idle before exact close")
        #expect(probe.events == [
            .text("b=BACCEPT;e=EACCEPT;printf '\\n%s\\n' $b;jobs -p;printf '%s\\n' $e"),
            .key(.enter, modifiers: []),
        ])
        #expect(await harness.surfaces.recordedCalls().contains(
            "close:\(temporary.paneID)"
        ))
        #expect(try await harness.surfaces.currentSurface(
            route: CodexTerminalAcceptanceHarness.route(for: harness.key)
        ) == origin)
    }

    @Test("jobs found in a temporary pane retain typed provenance and report the exact jobs")
    func temporaryPaneJobsRetainTypedReport() async throws {
        let harness = try await CodexTerminalAcceptanceHarness.shell(
            revision: 50,
            text: "$ ",
            nonce: "JOBS"
        )
        let temporary = CodexTerminalAcceptanceHarness.surface(
            for: harness.key,
            paneID: "%jobs",
            command: "zsh"
        )
        await harness.surfaces.setCreatedSurface(temporary)
        await harness.port.enqueueWait(.init(
            snapshot: acceptanceScreen(revision: 51, text: "$ "),
            timedOut: false
        ))
        let createSubscription = await harness.router.subscribeActivity()
        let creating = Task {
            try await harness.execute(
                .createTemporaryPane(expectedRevision: 50)
            )
        }
        let createApproval = try await nextAcceptanceApproval(
            from: createSubscription.events,
            for: harness.key
        )
        #expect(await harness.router.approveOnce(createApproval.id))
        guard case let .temporaryPaneCreated(lease, _) = try await creating.value
        else {
            Issue.record("expected a temporary pane lease")
            return
        }

        await harness.port.enqueueWait(.init(
            snapshot: acceptanceScreen(
                revision: 52,
                text: "BJOBS\n231\n904\nEJOBS\n$ "
            ),
            timedOut: false
        ))
        let finishSubscription = await harness.router.subscribeActivity()
        let finishing = Task {
            try await harness.execute(.finishTemporaryPane(
                leaseID: lease.id,
                expectedRevision: 51
            ))
        }
        let finishApproval = try await nextAcceptanceApproval(
            from: finishSubscription.events,
            for: harness.key
        )
        #expect(await harness.router.approveOnce(finishApproval.id))
        #expect(
            try await finishing.value == .temporaryPaneFinished(
                .retained(lease, reason: .backgroundJobs(["231", "904"]))
            )
        )
        #expect(!(await harness.surfaces.recordedCalls()).contains {
            $0.hasPrefix("close:")
        })
        #expect((await harness.journal.snapshot()).contains { event in
            guard case let .temporaryPane(.retained(id, pane, reason))
                = event.kind
            else { return false }
            return id == lease.id
                && pane.paneID == temporary.paneID
                && reason == .backgroundJobs
        })
    }

    @Test("two conversations overlap while every mutation for one key stays serialized")
    func conversationsOverlapButOneKeySerializes() async throws {
        let firstKey = CodexTerminalAcceptanceHarness.key(
            serverID: "$overlap-a",
            createdAt: 61
        )
        let secondKey = CodexTerminalAcceptanceHarness.key(
            serverID: "$overlap-b",
            createdAt: 62
        )
        let gate = TerminalToolTestGate()
        let firstPort = AcceptanceBlockingTerminalPort(
            screen: acceptanceScreen(revision: 60, text: "$ "),
            sendGate: gate
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 60, text: "$ ")
        )
        let firstSurfaces = FakeTerminalSurfaceController(
            surface: CodexTerminalAcceptanceHarness.surface(
                for: firstKey,
                command: "zsh"
            )
        )
        let secondSurfaces = FakeTerminalSurfaceController(
            surface: CodexTerminalAcceptanceHarness.surface(
                for: secondKey,
                command: "zsh"
            )
        )
        let registry = TerminalEndpointRegistry()
        try await registry.register(TerminalEndpoint(
            id: TerminalEndpointID(rawValue: TerminalToolFixtures.newID()),
            conversationKey: firstKey,
            terminal: firstPort,
            surfaces: firstSurfaces,
            route: CodexTerminalAcceptanceHarness.route(for: firstKey)
        ))
        try await registry.register(TerminalEndpoint(
            id: TerminalEndpointID(rawValue: TerminalToolFixtures.newID()),
            conversationKey: secondKey,
            terminal: secondPort,
            surfaces: secondSurfaces,
            route: CodexTerminalAcceptanceHarness.route(for: secondKey)
        ))
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let firstHandle = try await router.beginTurn(
            threadID: .init(rawValue: "overlap-a"),
            conversationKey: firstKey
        )
        let secondHandle = try await router.beginTurn(
            threadID: .init(rawValue: "overlap-b"),
            conversationKey: secondKey
        )
        let firstTurn = AgentTurnID(rawValue: "turn-a")
        let secondTurn = AgentTurnID(rawValue: "turn-b")
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
            try await router.execute(
                handle: firstHandle,
                turnID: firstTurn,
                conversationKey: firstKey,
                call: .sendInput(firstBatch)
            )
        }
        await firstPort.waitForSendCount(1)
        let queued = Task {
            try await router.execute(
                handle: firstHandle,
                turnID: firstTurn,
                conversationKey: firstKey,
                call: .sendInput(queuedBatch)
            )
        }
        let independent = try await router.execute(
            handle: secondHandle,
            turnID: secondTurn,
            conversationKey: secondKey,
            call: .sendInput(otherBatch)
        )

        #expect(independent == .inputAccepted(.init(
            acceptedRevision: otherBatch.expectedRevision,
            byteCount: otherBatch.events.count
        )))
        #expect(await firstPort.batches() == [firstBatch])
        #expect(await secondPort.batches() == [otherBatch])

        await gate.open()
        _ = try await first.value
        _ = try await queued.value
        #expect(await firstPort.batches() == [firstBatch, queuedBatch])
    }

    @Test("duplicate tabs share one conversation transcript badges and pinned endpoint")
    func duplicateTabsShareConversationAndOnePin() async throws {
        let harness = try await CodexTerminalAcceptanceHarness.shell(
            revision: 70,
            text: "Proceed? [y/N]"
        )
        let batch = TerminalInputBatch(
            expectedRevision: 70,
            events: [.key(.enter, modifiers: [])],
            purpose: "confirm duplicate-tab acceptance",
            declaredRisk: .high
        )
        let subscription = await harness.router.subscribeActivity()
        let mutation = Task { try await harness.send(batch) }
        let approval = try await nextAcceptanceApproval(
            from: subscription.events,
            for: harness.key
        )
        let duplicatePort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 70, text: "duplicate")
        )
        let duplicateEndpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        try await harness.registry.register(TerminalEndpoint(
            id: duplicateEndpointID,
            conversationKey: harness.key,
            terminal: duplicatePort,
            surfaces: FakeTerminalSurfaceController(
                surface: CodexTerminalAcceptanceHarness.surface(
                    for: harness.key,
                    paneID: "%duplicate",
                    command: "zsh"
                )
            ),
            route: CodexTerminalAcceptanceHarness.route(for: harness.key)
        ))
        try await harness.registry.focus(duplicateEndpointID)
        let tabs = [
            TerminalTabRecord(
                id: "duplicate-a",
                title: "A",
                target: .local,
                sessionName: "acceptance",
                tmuxIdentity: harness.key.tmux
            ),
            TerminalTabRecord(
                id: "duplicate-b",
                title: "B",
                target: .local,
                sessionName: "renamed-display-only",
                tmuxIdentity: harness.key.tmux
            ),
        ]
        let transcript = [
            AgentMessage(role: .user, text: "inspect"),
            AgentMessage(role: .assistant, text: "working"),
        ]
        var drawer = CodexDrawerState(availability: .ready)
        drawer.reduce(.selectTerminal(.connected(harness.key)))
        drawer.reduce(.receiveSessions([
            harness.key: CodexSessionState(
                key: harness.key,
                threadID: harness.handle.threadID,
                activeTurnID: harness.turnID,
                phase: .awaitingApproval,
                messages: transcript,
                pendingApprovals: [approval]
            ),
        ]))

        #expect(drawer.selectedSession?.messages == transcript)
        #expect(drawer.badges(for: tabs)["duplicate-a"]
            == drawer.badges(for: tabs)["duplicate-b"])
        #expect(drawer.badges(for: tabs)["duplicate-a"] == .init(
            phase: .awaitingApproval,
            approvalCount: 1
        ))
        let pins = await harness.registry.pinSnapshot().pins.values
        #expect(pins.count == 1)
        #expect(pins.first?.endpointID == harness.endpointID)

        #expect(await harness.router.denyApproval(approval.id))
        await #expect(throws: TerminalToolRouterError.approvalDenied) {
            _ = try await mutation.value
        }
    }

    @Test("closing a pinned tab interrupts only local ownership without terminal control bytes")
    func pinnedTabCloseInterruptsWithoutControlBytes() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey(
            serverSessionID: "$pinned-close",
            createdAtEpoch: 80
        )
        let threadID = AgentThreadID(rawValue: "pinned-close-thread")
        let turnID = AgentTurnID(rawValue: "pinned-close-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let coordinator = CodexSessionCoordinator(
            agent: agent,
            store: store,
            registry: registry,
            router: router,
            journal: journal
        )
        let port = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 80, text: "$ ")
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: CodexTerminalAcceptanceHarness.surface(
                for: key,
                command: "zsh"
            )
        )
        let endpoint = TerminalEndpoint(
            id: TerminalEndpointID(rawValue: TerminalToolFixtures.newID()),
            conversationKey: key,
            terminal: port,
            surfaces: surfaces,
            route: CodexTerminalAcceptanceHarness.route(for: key)
        )
        try await coordinator.registerEndpoint(endpoint)
        await coordinator.submit("begin", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await coordinator.unregisterEndpoint(endpoint.id)
        let state = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .interrupted)
        }

        #expect(state.activeTurnID == nil)
        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID),
        ])
        #expect(await port.batches().isEmpty)
        #expect(await surfaces.recordedCalls().isEmpty)
        #expect(await port.keyboardOwners() == [.codex, .user])
        await probe.stop()
    }

    @Test("agent transport crash quiesces only its owning key without replay or remote mutation")
    func crashContainsFailureToOwningConversation() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let firstKey = codexTestKey(
            serverSessionID: "$crash-a",
            createdAtEpoch: 90
        )
        let secondKey = codexTestKey(
            serverSessionID: "$crash-b",
            createdAtEpoch: 91
        )
        let firstThread = AgentThreadID(rawValue: "crash-thread-a")
        let secondThread = AgentThreadID(rawValue: "crash-thread-b")
        let firstTurn = AgentTurnID(rawValue: "crash-turn-a")
        let secondTurn = AgentTurnID(rawValue: "crash-turn-b")
        let agent = FakeCodexSessionAgent(threadIDs: [firstThread, secondThread])
        await agent.enqueueTurn(firstTurn, for: firstThread)
        await agent.enqueueTurn(secondTurn, for: secondThread)
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let coordinator = CodexSessionCoordinator(
            agent: agent,
            store: store,
            registry: registry,
            router: router,
            journal: journal
        )
        let firstPort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 90, text: "$ ")
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: acceptanceScreen(revision: 90, text: "$ ")
        )
        let firstSurfaces = FakeTerminalSurfaceController(
            surface: CodexTerminalAcceptanceHarness.surface(
                for: firstKey,
                command: "zsh"
            )
        )
        let secondSurfaces = FakeTerminalSurfaceController(
            surface: CodexTerminalAcceptanceHarness.surface(
                for: secondKey,
                command: "zsh"
            )
        )
        try await coordinator.registerEndpoint(TerminalEndpoint(
            id: TerminalEndpointID(rawValue: TerminalToolFixtures.newID()),
            conversationKey: firstKey,
            terminal: firstPort,
            surfaces: firstSurfaces,
            route: CodexTerminalAcceptanceHarness.route(for: firstKey)
        ))
        try await coordinator.registerEndpoint(TerminalEndpoint(
            id: TerminalEndpointID(rawValue: TerminalToolFixtures.newID()),
            conversationKey: secondKey,
            terminal: secondPort,
            surfaces: secondSurfaces,
            route: CodexTerminalAcceptanceHarness.route(for: secondKey)
        ))
        await coordinator.submit("first", for: firstKey)
        await coordinator.submit("second", for: secondKey)
        let resumeCallsBeforeCrash = await agent.recordedResumeCalls()
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await agent.emit(.turnFailed(firstTurn, .crashed), for: firstThread)
        _ = try await codexSessionWithDeadline {
            await probe.wait(for: firstKey, phase: .failed(.crashed))
        }
        let snapshot = await coordinator.snapshot()

        #expect(snapshot[firstKey]?.activeTurnID == nil)
        #expect(snapshot[secondKey]?.activeTurnID == secondTurn)
        #expect(snapshot[secondKey]?.phase == .thinking)
        #expect(await agent.recordedStartCalls().map(\.0) == [
            firstThread,
            secondThread,
        ])
        #expect(resumeCallsBeforeCrash == [firstThread, secondThread])
        #expect(await agent.recordedResumeCalls() == resumeCallsBeforeCrash)
        #expect(await agent.recordedInterruptCalls().isEmpty)
        #expect(await firstPort.batches().isEmpty)
        #expect(await secondPort.batches().isEmpty)
        #expect(await firstSurfaces.recordedCalls().isEmpty)
        #expect(await secondSurfaces.recordedCalls().isEmpty)
        await probe.stop()
    }

    @Test("journal and store reopen while archive preserves and confirmed delete removes both")
    func persistenceReopenArchiveAndConfirmedDelete() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey(
            serverSessionID: "$durable",
            createdAtEpoch: 100
        )
        let threadID = AgentThreadID(rawValue: "durable-thread")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(CodexConversationRecord(
            key: key,
            threadID: threadID
        )))
        let journal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let event = terminalTestJournalEvent(
            key: key,
            operationID: TerminalToolFixtures.newID(),
            turnID: "durable-turn",
            kind: .request(
                operation: "observeScreen",
                purpose: "durability acceptance"
            )
        )
        try await journal.append(event)
        let agent = FakeCodexSessionAgent(threadIDs: [])
        let registry = TerminalEndpointRegistry()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let coordinator = CodexSessionCoordinator(
            agent: agent,
            store: store,
            registry: registry,
            router: router,
            journal: journal
        )

        try await coordinator.setArchived(true, for: key)
        let reopenedStore = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let reopenedJournal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        #expect(try await reopenedStore.snapshot().records[key]?.archived == true)
        #expect(try await reopenedJournal.entries(for: key) == [event])
        #expect(await agent.recordedArchiveCalls() == [threadID])

        try await coordinator.deleteConversation(
            key,
            confirmation: .confirmed
        )
        let afterDeleteStore = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let afterDeleteJournal = try FileTerminalOperationJournal(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        #expect(try await afterDeleteStore.snapshot().records[key] == nil)
        #expect(try await afterDeleteJournal.entries(for: key).isEmpty)
        #expect(await agent.recordedDeleteCalls() == [threadID])
    }
}
