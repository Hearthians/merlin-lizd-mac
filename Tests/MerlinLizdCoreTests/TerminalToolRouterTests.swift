import Testing
@testable import MerlinLizdCore

@Suite("Terminal tool router", .serialized)
struct TerminalToolRouterTests {
    @Test("all six tools use the pinned endpoint and journal before each action")
    func routesAllToolsThroughPinnedEndpoint() async throws {
        let log = TerminalToolTestLog()
        let initial = TerminalToolFixtures.screen(revision: 10)
        let changed = TerminalToolFixtures.screen(revision: 11, text: "typed")
        let paneScreen = TerminalToolFixtures.screen(revision: 12, text: "$ ")
        let probeScreen = TerminalToolFixtures.screen(
            revision: 13,
            text: "$ probe B7F3A E7F3A\nB7F3A\nE7F3A\n$ "
        )
        let port = FakeTerminalToolPort(snapshot: initial, log: log)
        await port.enqueueWait(.init(snapshot: changed, timedOut: false))
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        await port.enqueueWait(.init(snapshot: probeScreen, timedOut: false))
        let original = TerminalToolFixtures.surface()
        let selectedSurface = TerminalToolFixtures.surface(paneID: "%2")
        let temporary = TerminalToolFixtures.surface(paneID: "%3")
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: selectedSurface,
            log: log
        )
        let journal = MemoryTerminalToolJournal(log: log)
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal,
            nonce: "7F3A"
        )

        let observed = try await router.execute(
            threadID: threadID,
            turnID: turnID,
            conversationKey: TerminalToolFixtures.key,
            call: .observeScreen
        )
        #expect(observed == .screen(initial))

        let input = TerminalToolFixtures.input(revision: 10)
        let sent = try await router.execute(
            threadID: threadID,
            turnID: turnID,
            conversationKey: TerminalToolFixtures.key,
            call: .sendInput(input)
        )
        #expect(sent == .inputAccepted(.init(acceptedRevision: 10, byteCount: 1)))

        let waited = try await router.execute(
            threadID: threadID,
            turnID: turnID,
            conversationKey: TerminalToolFixtures.key,
            call: .waitForScreen(.init(condition: .changed(after: 10), timeout: .seconds(1)))
        )
        #expect(waited == .screenWait(.init(snapshot: changed, timedOut: false)))

        await port.setSnapshot(changed)
        let selectionTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .selectVisibleSurface(.nextPane, expectedRevision: 11)
            )
        }
        try await approveNextRequest(router: router)
        _ = try await selectionTask.value

        await port.setSnapshot(changed)
        await surfaces.setCreatedSurface(temporary)
        let createTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 11)
            )
        }
        try await approveNextRequest(router: router)
        let created = try await createTask.value
        guard case let .temporaryPaneCreated(lease, screen) = created else {
            Issue.record("expected a temporary pane lease")
            return
        }
        #expect(lease.origin == selectedSurface)
        #expect(lease.temporary == temporary)
        #expect(screen == paneScreen)

        await port.setSnapshot(paneScreen)
        let finishTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: paneScreen.revision
                )
            )
        }
        try await approveNextRequest(router: router)
        let finished = try await finishTask.value
        #expect(finished == .temporaryPaneFinished(.closed(lease)))

        let values = await log.snapshot()
        let actionIndexes = values.indices.filter {
            values[$0].contains(":send:")
                || values[$0] == "surface:select"
                || values[$0] == "surface:create"
                || values[$0] == "surface:close"
        }
        for index in actionIndexes {
            #expect(values[..<index].last(where: { $0 == "journal:endpoint" }) != nil)
        }
    }

    @Test("stale revision denies before input and failed receipts are never replayed")
    func staleAndFailedInputDoNotReplay() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 4)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )

        await #expect(
            throws: TerminalToolRouterError.staleRevision(expected: 3, actual: 4)
        ) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(TerminalToolFixtures.input(revision: 3))
            )
        }
        #expect(await port.counts().send == 0)

        await port.enqueueSendFailure(.send)
        await #expect(throws: TerminalToolRouterError.terminalFailure) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(TerminalToolFixtures.input(revision: 4))
            )
        }
        #expect(await port.counts().send == 1)
    }

    @Test("exact approval can be denied, interrupted, or expired after route drift")
    func approvalLifecycle() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 5)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )
        let action = TerminalInputBatch(
            expectedRevision: 5,
            events: [.key(.enter, modifiers: [])],
            purpose: "submit exact line",
            declaredRisk: .routine
        )

        let deniedTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(action)
            )
        }
        let denied = try await pendingRequest(router: router)
        #expect(denied.batch == action)
        #expect(await router.denyApproval(denied.id))
        await #expect(throws: TerminalToolRouterError.approvalDenied) {
            try await deniedTask.value
        }

        let interruptedTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(action)
            )
        }
        _ = try await pendingRequest(router: router)
        await router.interruptTurn(threadID: threadID, turnID: turnID)
        await #expect(throws: TerminalToolRouterError.interrupted) {
            try await interruptedTask.value
        }
        #expect(await port.counts().send == 0)

        let secondTurn = AgentTurnID(rawValue: "turn-after-interrupt")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let driftTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: secondTurn,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(action)
            )
        }
        let approval = try await pendingRequest(router: router)
        await port.setSnapshot(TerminalToolFixtures.screen(revision: 6))
        #expect(await router.approveOnce(approval.id))
        await #expect(throws: TerminalToolRouterError.approvalExpired) {
            try await driftTask.value
        }
        #expect(await port.counts().send == 0)
    }

    @Test("same conversation serializes acknowledged input while different keys overlap")
    func serializesPerConversation() async throws {
        let gate = TerminalToolTestGate()
        let firstPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1),
            label: "first"
        )
        await firstPort.blockSends(on: gate)
        let firstSurfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let firstJournal = MemoryTerminalToolJournal()
        let registry = TerminalEndpointRegistry()
        let broker = TerminalApprovalBroker()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: broker,
            journal: firstJournal
        )
        await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: firstPort,
                controller: firstSurfaces
            )
        )
        let thread = AgentThreadID(rawValue: "thread-serial")
        let turn = AgentTurnID(rawValue: "turn-serial")
        _ = try await router.beginTurn(
            threadID: thread,
            conversationKey: TerminalToolFixtures.key
        )

        let first = Task {
            try await router.execute(
                threadID: thread,
                turnID: turn,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(TerminalToolFixtures.input(revision: 1, purpose: "first"))
            )
        }
        while await firstPort.counts().send == 0 { await Task.yield() }
        let second = Task {
            try await router.execute(
                threadID: thread,
                turnID: turn,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(TerminalToolFixtures.input(revision: 1, purpose: "second"))
            )
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await firstPort.counts().send == 1)

        let otherIdentity = TmuxSessionIdentity(
            serverSessionID: "$9",
            createdAtEpoch: 99
        )
        let otherKey = TerminalConversationKey(target: .local, tmux: otherIdentity)
        let otherRoute = TmuxRoute(
            target: .local,
            sessionName: "other",
            expectedIdentity: otherIdentity
        )
        let otherPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let otherSurfaceValue = TmuxSurface(
            sessionIdentity: otherIdentity,
            windowID: "@9",
            paneID: "%9",
            currentCommand: "zsh"
        )
        let otherSurfaces = FakeTerminalSurfaceController(
            surface: otherSurfaceValue
        )
        await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                key: otherKey,
                port: otherPort,
                controller: otherSurfaces,
                route: otherRoute
            )
        )
        let otherThread = AgentThreadID(rawValue: "thread-other")
        let otherTurn = AgentTurnID(rawValue: "turn-other")
        _ = try await router.beginTurn(threadID: otherThread, conversationKey: otherKey)
        _ = try await router.execute(
            threadID: otherThread,
            turnID: otherTurn,
            conversationKey: otherKey,
            call: .sendInput(TerminalToolFixtures.input(revision: 1))
        )
        #expect(await otherPort.counts().send == 1)

        await gate.open()
        _ = try await first.value
        _ = try await second.value
        #expect(await firstPort.counts().send == 2)
    }

    @Test("temporary pane uncertainty retains typed provenance and interruption never probes")
    func temporaryPaneRetention() async throws {
        let initial = TerminalToolFixtures.screen(revision: 20)
        let paneScreen = TerminalToolFixtures.screen(revision: 21)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let original = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(
            paneID: "%3",
            command: "python"
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )

        let createTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 20)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await createTask.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)

        let finishTask = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 21
                )
            )
        }
        try await approveNextRequest(router: router)
        #expect(
            try await finishTask.value
                == .temporaryPaneFinished(
                    .retained(lease, reason: .foregroundProcess("python"))
                )
        )
        #expect(await port.counts().send == 0)
        let surfaceCalls = await surfaces.recordedCalls()
        #expect(!surfaceCalls.contains { $0.hasPrefix("close:") })

        await router.interruptTurn(threadID: threadID, turnID: turnID)
        #expect(await port.counts().send == 0)
    }

    @Test("cancelling queued input does not release the active conversation lane")
    func queuedCancellationKeepsLaneOwned() async throws {
        let sendGate = TerminalToolTestGate()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 40)
        )
        await port.blockSends(on: sendGate)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )
        let first = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 40,
                        purpose: "active"
                    )
                )
            )
        }
        while await port.counts().send == 0 { await Task.yield() }

        let cancelled = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 40,
                        purpose: "cancelled queued input"
                    )
                )
            )
        }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        for _ in 0..<20 { await Task.yield() }

        let third = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 40,
                        purpose: "third"
                    )
                )
            )
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await port.counts().send == 1)

        await sendGate.open()
        _ = try await first.value
        await #expect(throws: TerminalToolRouterError.interrupted) {
            try await cancelled.value
        }
        _ = try await third.value
        #expect(await port.counts().send == 2)
    }

    @Test("split success followed by screen disconnect retains the exact created pane")
    func createDisconnectRetainsCreatedPane() async throws {
        let initial = TerminalToolFixtures.screen(revision: 50)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWaitFailure(.wait)
        let original = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%8")
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )

        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 50)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneRetained(lease, reason) = try await create.value else {
            Issue.record("expected retained created pane")
            return
        }
        #expect(lease.origin == original)
        #expect(lease.temporary == temporary)
        #expect(reason == .disconnected)
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("close:") })
    }

    @Test("duplicate exact probe markers are ambiguous and never close the pane")
    func duplicateProbeMarkersRetain() async throws {
        let initial = TerminalToolFixtures.screen(revision: 60)
        let paneScreen = TerminalToolFixtures.screen(revision: 61)
        let ambiguous = TerminalToolFixtures.screen(
            revision: 62,
            text: "BCAFE\nBCAFE\nECAFE\n$ "
        )
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        await port.enqueueWait(.init(snapshot: ambiguous, timedOut: false))
        let original = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%9")
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal,
            nonce: "CAFE"
        )

        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 60)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 61
                )
            )
        }
        try await approveNextRequest(router: router)
        #expect(
            try await finish.value == .temporaryPaneFinished(
                .retained(lease, reason: .markerAmbiguity)
            )
        )
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("close:") })
    }

    @Test("oversized input and waits are rejected before journal or terminal access")
    func oversizedRequestsFailBeforeAccess() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 70)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )
        let oversized = TerminalInputBatch(
            expectedRevision: 70,
            events: Array(repeating: .text("x"), count: 257),
            purpose: "oversized",
            declaredRisk: .routine
        )

        await #expect(
            throws: TerminalToolRouterError.denied(
                reason: "Input batch exceeds 256 semantic events"
            )
        ) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(oversized)
            )
        }
        #expect(await port.counts().observe == 0)
        #expect(await journal.snapshot().isEmpty)

        await #expect(
            throws: TerminalToolRouterError.denied(
                reason: "Wait timeout must be between zero and 120 seconds"
            )
        ) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .waitForScreen(
                    .init(
                        condition: .changed(after: 70),
                        timeout: .seconds(121)
                    )
                )
            )
        }
        #expect(await port.counts().wait == 0)
        #expect(await journal.snapshot().isEmpty)
    }

    @Test("failed result journaling overrides a PTY failure and blocks later mutation")
    func postActionAuditFailureBlocksTurn() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 80)
        )
        await port.enqueueSendFailure(.send)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let journal = MemoryTerminalToolJournal()
        await journal.failOnAppend(6)
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )

        await #expect(throws: TerminalToolRouterError.auditUnavailable) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(revision: 80)
                )
            )
        }
        await journal.failOnAppend(nil)
        await #expect(throws: TerminalToolRouterError.auditUnavailable) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 80,
                        purpose: "must remain blocked"
                    )
                )
            )
        }
        #expect(await port.counts().send == 1)
    }

    @Test("probe markers on an unchanged screen revision retain instead of close")
    func unchangedProbeScreenRetains() async throws {
        let initial = TerminalToolFixtures.screen(revision: 90)
        let paneScreen = TerminalToolFixtures.screen(revision: 91)
        let unchanged = TerminalToolFixtures.screen(
            revision: 91,
            text: "B1A2B\nE1A2B\n$ "
        )
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        await port.enqueueWait(.init(snapshot: unchanged, timedOut: false))
        let original = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%10")
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal,
            nonce: "1A2B"
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 90)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 91
                )
            )
        }
        try await approveNextRequest(router: router)
        #expect(
            try await finish.value == .temporaryPaneFinished(
                .retained(
                    lease,
                    reason: .revisionDrift(expected: 92, actual: 91)
                )
            )
        )
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("close:") })
    }

    @Test("surface route drift after approval expires without selecting")
    func surfaceDriftAfterApprovalExpires() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 100)
        )
        let original = TerminalToolFixtures.surface()
        let switched = TerminalToolFixtures.surface(paneID: "%11")
        let selected = TerminalToolFixtures.surface(paneID: "%12")
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: selected
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )
        let selection = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .selectVisibleSurface(
                    .nextPane,
                    expectedRevision: 100
                )
            )
        }
        let request = try await pendingRequest(router: router)
        await surfaces.setSurface(switched)
        #expect(await router.approveOnce(request.id))

        await #expect(throws: TerminalToolRouterError.approvalExpired) {
            try await selection.value
        }
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains("select"))
    }

    @Test("interrupt retains a live lease without probing or closing")
    func interruptRetainsLiveLease() async throws {
        let initial = TerminalToolFixtures.screen(revision: 110)
        let paneScreen = TerminalToolFixtures.screen(revision: 111)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let original = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%13")
        let surfaces = FakeTerminalSurfaceController(
            surface: original,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 110)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)

        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 111)
            )
        }
        await router.interruptTurn(threadID: threadID, turnID: turnID)

        #expect(await port.counts().send == 0)
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("close:") })
        let events = await journal.snapshot()
        #expect(events.contains { event in
            guard case let .temporaryPane(.retained(id, paneID, reason))
                = event.kind
            else { return false }
            return id == lease.id
                && paneID == temporary.paneID
                && reason == "interrupted"
        })
        #expect(await port.keyboardOwners() == [.codex, .user])
    }

    private func makeRouter(
        port: FakeTerminalToolPort,
        surfaces: FakeTerminalSurfaceController,
        journal: MemoryTerminalToolJournal,
        nonce: String = "ABCD"
    ) async throws -> (
        TerminalToolRouter,
        AgentThreadID,
        AgentTurnID
    ) {
        let registry = TerminalEndpointRegistry()
        await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal,
            nonce: { _ in nonce }
        )
        let threadID = AgentThreadID(rawValue: "thread")
        let turnID = AgentTurnID(rawValue: "turn")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        return (router, threadID, turnID)
    }

    private func pendingRequest(
        router: TerminalToolRouter
    ) async throws -> TerminalApprovalRequest {
        for _ in 0..<100 {
            if let request = await router.pendingApprovals().first {
                return request
            }
            await Task.yield()
        }
        Issue.record("approval did not become pending")
        throw CancellationError()
    }

    private func approveNextRequest(router: TerminalToolRouter) async throws {
        let request = try await pendingRequest(router: router)
        #expect(await router.approveOnce(request.id))
    }
}
