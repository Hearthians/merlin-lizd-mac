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
        try await router.interruptTurn(threadID: threadID, turnID: turnID)
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
        try await registry.register(
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
        try await registry.register(
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

        let retryFinish = Task {
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
        for _ in 0..<100 {
            if let request = await router.pendingApprovals().first {
                #expect(await router.approveOnce(request.id))
                break
            }
            if retryFinish.isCancelled { break }
            await Task.yield()
        }
        #expect(
            try await retryFinish.value == .temporaryPaneFinished(
                .retained(lease, reason: .foregroundProcess("python"))
            )
        )
        let duplicateCreate = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 21)
            )
        }
        for _ in 0..<100 {
            if let request = await router.pendingApprovals().first {
                _ = await router.denyApproval(request.id)
                break
            }
            await Task.yield()
        }
        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await duplicateCreate.value
        }

        try await router.interruptTurn(threadID: threadID, turnID: turnID)
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
        #expect(lease.temporary.windowID == "@1")
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("close:") })
        let duplicateCreate = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 50)
            )
        }
        for _ in 0..<100 {
            if let request = await router.pendingApprovals().first {
                _ = await router.denyApproval(request.id)
                break
            }
            await Task.yield()
        }
        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await duplicateCreate.value
        }
    }

    @Test("Task4 retained split preserves full provenance and one live lease")
    func controllerRetainedSplitPreservesProvenance() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 55)
        )
        let origin = TerminalToolFixtures.surface()
        let retainedPane = RetainedTemporaryPane(windowID: "@77", paneID: "%77")
        let surfaces = FakeTerminalSurfaceController(surface: origin)
        await surfaces.setRetainedCreateError(
            pane: retainedPane,
            reason: .transportUnavailable
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
                call: .createTemporaryPane(expectedRevision: 55)
            )
        }
        try await approveNextRequest(router: router)

        var retainedProvenance: RetainedTemporaryPaneLease?
        let retainedReason = TemporaryPaneRetentionReason.controllerRetained(
            .transportUnavailable
        )
        do {
            _ = try await create.value
            Issue.record("expected retained split error")
        } catch let TerminalToolRouterError.temporaryPaneRetained(
            provenance,
            reason
        ) {
            #expect(provenance.conversationKey == TerminalToolFixtures.key)
            #expect(provenance.origin == origin)
            #expect(provenance.route == TerminalToolFixtures.route)
            #expect(provenance.pane == retainedPane)
            #expect(reason == retainedReason)
            retainedProvenance = provenance
        } catch {
            Issue.record("unexpected error: \(error)")
            return
        }
        guard let retainedProvenance else {
            Issue.record("expected retained provenance")
            return
        }

        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 55)
            )
        }
        let events = await journal.snapshot()
        #expect(events.contains { event in
            guard case let .temporaryPane(.retained(_, pane, journalReason))
                = event.kind
            else { return false }
            return pane.windowID == retainedPane.windowID
                && pane.paneID == retainedPane.paneID
                && journalReason == .controllerTransportUnavailable
        })

        let countsBeforeFinish = await port.counts()
        let callsBeforeFinish = await surfaces.recordedCalls()
        for _ in 0..<2 {
            await #expect(
                throws: TerminalToolRouterError.temporaryPaneRetained(
                    retainedProvenance,
                    reason: retainedReason
                )
            ) {
                _ = try await router.execute(
                    threadID: threadID,
                    turnID: turnID,
                    conversationKey: TerminalToolFixtures.key,
                    call: .finishTemporaryPane(
                        leaseID: retainedProvenance.id,
                        expectedRevision: 55
                    )
                )
            }
        }
        #expect(await port.counts() == countsBeforeFinish)
        #expect(await surfaces.recordedCalls() == callsBeforeFinish)
        let afterRetries = await journal.snapshot()
        #expect(afterRetries.count == events.count + 4)

        await journal.setFailAppend(true)
        await #expect(
            throws: TerminalToolRouterError.temporaryPaneAuditUnavailable(
                retainedProvenance,
                reason: retainedReason
            )
        ) {
            _ = try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: retainedProvenance.id,
                    expectedRevision: 55
                )
            )
        }
        await journal.setFailAppend(false)
        try await router.endTurn(threadID: threadID, turnID: turnID)
    }

    @Test("pin loss finish audits controller-retained provenance without terminal access")
    func controllerRetainedPinLossFinishPreservesProvenance() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 550)
        )
        let origin = TerminalToolFixtures.surface()
        let retainedPane = RetainedTemporaryPane(windowID: "@550", paneID: "%550")
        let surfaces = FakeTerminalSurfaceController(surface: origin)
        await surfaces.setRetainedCreateError(
            pane: retainedPane,
            reason: .transportUnavailable
        )
        let journal = MemoryTerminalToolJournal()
        let registry = TerminalEndpointRegistry()
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let threadID = AgentThreadID(rawValue: "controller-pin-loss-thread")
        let turnID = AgentTurnID(rawValue: "controller-pin-loss-turn")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        try await router.confirmTurnID(threadID: threadID, turnID: turnID)
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 550)
            )
        }
        try await approveNextRequest(router: router)
        let provenance: RetainedTemporaryPaneLease
        do {
            _ = try await create.value
            Issue.record("expected controller-retained split")
            return
        } catch let TerminalToolRouterError.temporaryPaneRetained(
            retained,
            reason
        ) {
            provenance = retained
            #expect(
                reason == .controllerRetained(.transportUnavailable)
            )
        }
        let countsBeforeFinish = await port.counts()
        let callsBeforeFinish = await surfaces.recordedCalls()
        let eventsBeforeFinish = await journal.snapshot().count
        await registry.unregister(endpointID)

        await #expect(
            throws: TerminalToolRouterError.temporaryPaneRetained(
                provenance,
                reason: .controllerRetained(.transportUnavailable)
            )
        ) {
            _ = try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: provenance.id,
                    expectedRevision: 550
                )
            )
        }
        #expect(await port.counts() == countsBeforeFinish)
        #expect(await surfaces.recordedCalls() == callsBeforeFinish)
        let events = await journal.snapshot()
        #expect(events.count == eventsBeforeFinish + 2)
        guard events.count >= 2 else { return }
        if case let .temporaryPane(.retained(id, pane, reason))
            = events[events.count - 1].kind
        {
            #expect(id == provenance.id)
            #expect(pane == TerminalJournalPaneProvenance(retainedPane))
            #expect(reason == .controllerTransportUnavailable)
        } else {
            Issue.record("expected retained pin-loss audit")
        }
        try await router.endTurn(threadID: threadID, turnID: turnID)
    }

    @Test("returned split is owned before identity verification")
    func splitIsStoredBeforeIdentityVerification() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 55)
        )
        let origin = TerminalToolFixtures.surface()
        let mismatchedIdentity = TmuxSessionIdentity(
            serverSessionID: "$unexpected",
            createdAtEpoch: 551
        )
        let temporary = TmuxSurface(
            sessionIdentity: mismatchedIdentity,
            windowID: "@88",
            paneID: "%88",
            currentCommand: "zsh"
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
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
                call: .createTemporaryPane(expectedRevision: 55)
            )
        }
        try await approveNextRequest(router: router)

        var retainedLease: TemporaryPaneLease?
        let retainedReason = TemporaryPaneRetentionReason.controllerRetained(
            .sessionIdentityMismatch(
                expected: TerminalToolFixtures.identity,
                actual: mismatchedIdentity
            )
        )
        do {
            _ = try await create.value
            Issue.record("expected retained identity mismatch")
        } catch let TerminalToolRouterError.temporaryPaneRetained(
            provenance,
            reason
        ) {
            #expect(provenance.pane.windowID == temporary.windowID)
            #expect(provenance.pane.paneID == temporary.paneID)
            #expect(reason == retainedReason)
            retainedLease = TemporaryPaneLease(
                id: provenance.id,
                conversationKey: provenance.conversationKey,
                origin: provenance.origin,
                temporary: temporary
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let paneEvents = await journal.snapshot().compactMap { event in
            if case let .temporaryPane(value) = event.kind { return value }
            return nil
        }
        #expect(paneEvents.count == 2)
        if paneEvents.count == 2 {
            if case let .created(id, pane) = paneEvents[0] {
                #expect(id == retainedLease?.id)
                #expect(pane.windowID == temporary.windowID)
                #expect(pane.paneID == temporary.paneID)
            } else {
                Issue.record("expected created journal event first")
            }
            if case let .retained(id, pane, reason) = paneEvents[1] {
                #expect(id == retainedLease?.id)
                #expect(pane.windowID == temporary.windowID)
                #expect(pane.paneID == temporary.paneID)
                #expect(reason == .controllerSessionIdentityMismatch)
            } else {
                Issue.record("expected retained journal event second")
            }
        }

        guard let retainedLease else {
            Issue.record("expected reconstructable retained lease")
            return
        }
        let countsBeforeFinish = await port.counts()
        let callsBeforeFinish = await surfaces.recordedCalls()
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: retainedLease.id,
                    expectedRevision: 55
                )
            )
        }
        for _ in 0..<1_000 {
            if !(await router.pendingApprovals()).isEmpty { break }
            await Task.yield()
        }
        let unexpectedApprovals = await router.pendingApprovals()
        #expect(unexpectedApprovals.isEmpty)
        for request in unexpectedApprovals {
            _ = await router.denyApproval(request.id)
        }
        if unexpectedApprovals.isEmpty {
            finish.cancel()
        }
        do {
            #expect(
                try await finish.value == .temporaryPaneFinished(
                    .retained(retainedLease, reason: retainedReason)
                )
            )
        } catch {
            Issue.record("unexpected finish error: \(error)")
        }
        #expect(await port.counts() == countsBeforeFinish)
        #expect(await surfaces.recordedCalls() == callsBeforeFinish)

        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 55)
            )
        }
        try await router.endTurn(threadID: threadID, turnID: turnID)
        let finalEvents = await journal.snapshot()
        let retainedReasons: [TerminalJournalRetentionReasonCode]
            = finalEvents.compactMap { event in
            guard case let .temporaryPane(.retained(id, _, reason)) = event.kind,
                id == retainedLease.id
            else { return nil }
            return reason
        }
        #expect(retainedReasons.last == .controllerSessionIdentityMismatch)
    }

    @Test("same-pane split is non-auto-closeable and journals bounded retention")
    func samePaneSplitNeverAutoCloses() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 551)
        )
        let origin = TerminalToolFixtures.surface()
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: origin
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
                call: .createTemporaryPane(expectedRevision: 551)
            )
        }
        try await approveNextRequest(router: router)
        let reason = TemporaryPaneRetentionReason.controllerRetained(.unavailable)
        let lease: TemporaryPaneLease
        do {
            _ = try await create.value
            Issue.record("expected same-pane retention")
            return
        } catch let TerminalToolRouterError.temporaryPaneRetained(
            provenance,
            actualReason
        ) {
            #expect(actualReason == reason)
            lease = TemporaryPaneLease(
                id: provenance.id,
                conversationKey: provenance.conversationKey,
                origin: provenance.origin,
                temporary: origin
            )
        }
        let callsBeforeFinish = await surfaces.recordedCalls()
        let countsBeforeFinish = await port.counts()
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 551
                )
            )
        }
        for _ in 0..<1_000 {
            if !(await router.pendingApprovals()).isEmpty { break }
            await Task.yield()
        }
        let unexpectedApprovals = await router.pendingApprovals()
        #expect(unexpectedApprovals.isEmpty)
        for request in unexpectedApprovals {
            _ = await router.denyApproval(request.id)
        }
        if unexpectedApprovals.isEmpty {
            finish.cancel()
        }
        do {
            #expect(
                try await finish.value == .temporaryPaneFinished(
                    .retained(lease, reason: reason)
                )
            )
        } catch {
            Issue.record("unexpected finish error: \(error)")
        }
        #expect(await surfaces.recordedCalls() == callsBeforeFinish)
        #expect(await port.counts() == countsBeforeFinish)
        #expect(!(await surfaces.recordedCalls()).contains { $0.hasPrefix("close:") })

        let paneEvents = await journal.snapshot().compactMap { event in
            if case let .temporaryPane(value) = event.kind { return value }
            return nil
        }
        #expect(paneEvents.count == 3)
        if paneEvents.count >= 2,
            case let .retained(_, pane, journalReason) = paneEvents[1]
        {
            #expect(pane.windowID == origin.windowID)
            #expect(pane.paneID == origin.paneID)
            #expect(journalReason == .controllerUnavailable)
        }
    }

    @Test("identity mismatch retained audit failure preserves exact provenance")
    func identityMismatchRetainedAuditFailure() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 552)
        )
        let origin = TerminalToolFixtures.surface()
        let mismatchedIdentity = TmuxSessionIdentity(
            serverSessionID: "$audit-mismatch",
            createdAtEpoch: 552
        )
        let temporary = TmuxSurface(
            sessionIdentity: mismatchedIdentity,
            windowID: "@audit",
            paneID: "%audit",
            currentCommand: "zsh"
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        await journal.failOnAppend(8)
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
                call: .createTemporaryPane(expectedRevision: 552)
            )
        }
        try await approveNextRequest(router: router)

        do {
            _ = try await create.value
            Issue.record("expected retained audit failure")
        } catch let TerminalToolRouterError.temporaryPaneAuditUnavailable(
            provenance,
            reason
        ) {
            #expect(provenance.origin == origin)
            #expect(provenance.route == TerminalToolFixtures.route)
            #expect(provenance.pane.windowID == temporary.windowID)
            #expect(provenance.pane.paneID == temporary.paneID)
            #expect(
                reason == .controllerRetained(
                    .sessionIdentityMismatch(
                        expected: TerminalToolFixtures.identity,
                        actual: mismatchedIdentity
                    )
                )
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("post-split audit failure returns full provenance and keeps the lease live")
    func postSplitAuditFailurePreservesLease() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 56)
        )
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%78")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        await journal.failOnAppend(7)
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
                call: .createTemporaryPane(expectedRevision: 56)
            )
        }
        try await approveNextRequest(router: router)

        do {
            _ = try await create.value
            Issue.record("expected post-split audit failure")
        } catch let TerminalToolRouterError.temporaryPaneAuditUnavailable(
            provenance,
            reason
        ) {
            #expect(provenance.origin == origin)
            #expect(provenance.route == TerminalToolFixtures.route)
            #expect(provenance.pane.windowID == temporary.windowID)
            #expect(provenance.pane.paneID == temporary.paneID)
            #expect(reason == .auditUnavailable)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        await journal.failOnAppend(nil)
        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 56)
            )
        }
        try await router.endTurn(threadID: threadID, turnID: turnID)
        let retainedReasons: [TerminalJournalRetentionReasonCode]
            = await journal.snapshot().compactMap {
            event in
            guard case let .temporaryPane(.retained(_, _, reason)) = event.kind
            else { return nil }
            return reason
        }
        #expect(retainedReasons.last == .auditUnavailable)
    }

    @Test("successful split followed by cancellation returns full retained provenance")
    func postSplitCancellationReturnsProvenance() async throws {
        let waitGate = TerminalToolTestGate()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 56)
        )
        await port.blockWaits(
            on: waitGate,
            checkCancellationAfterGate: true
        )
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%80")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
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
                call: .createTemporaryPane(expectedRevision: 56)
            )
        }
        try await approveNextRequest(router: router)
        while await port.counts().wait == 0 { await Task.yield() }
        create.cancel()
        await waitGate.open()

        do {
            _ = try await create.value
            Issue.record("expected retained cancellation")
        } catch let TerminalToolRouterError.temporaryPaneRetained(
            provenance,
            reason
        ) {
            #expect(provenance.origin == origin)
            #expect(provenance.pane.windowID == temporary.windowID)
            #expect(provenance.pane.paneID == temporary.paneID)
            #expect(reason == .interrupted)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 56)
            )
        }
    }

    @Test("finish current-surface cancellation retains as interrupted for retry")
    func finishCurrentSurfaceCancellationIsInterrupted() async throws {
        let initial = TerminalToolFixtures.screen(revision: 57)
        let paneScreen = TerminalToolFixtures.screen(revision: 58)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%79")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
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
                call: .createTemporaryPane(expectedRevision: 57)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)
        await surfaces.setFailure(.currentCancelled)

        #expect(
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 58
                )
            ) == .temporaryPaneFinished(.retained(lease, reason: .interrupted))
        )
        await #expect(throws: TerminalToolRouterError.liveLeaseExists) {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 58)
            )
        }
    }

    @Test("finish preserves a live lease after pre-existing endpoint pin loss")
    func finishAfterPinLossRetainsWithoutAccess() async throws {
        let initial = TerminalToolFixtures.screen(revision: 581)
        let paneScreen = TerminalToolFixtures.screen(revision: 582)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%pin-lost")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let registry = TerminalEndpointRegistry()
        let endpointID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let threadID = AgentThreadID(rawValue: "pin-loss-thread")
        let turnID = AgentTurnID(rawValue: "pin-loss-turn")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 581)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        let countsBeforeLoss = await port.counts()
        let callsBeforeLoss = await surfaces.recordedCalls()
        await registry.unregister(endpointID)

        #expect(
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 582
                )
            ) == .temporaryPaneFinished(.retained(lease, reason: .pinLost))
        )
        #expect(
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 582
                )
            ) == .temporaryPaneFinished(.retained(lease, reason: .pinLost))
        )
        #expect(await port.counts() == countsBeforeLoss)
        #expect(await surfaces.recordedCalls() == callsBeforeLoss)
        #expect(!(await surfaces.recordedCalls()).contains { $0.hasPrefix("close:") })

        try await router.endTurn(threadID: threadID, turnID: turnID)
        let retainedReasons: [TerminalJournalRetentionReasonCode]
            = await journal.snapshot().compactMap { event in
            guard case let .temporaryPane(.retained(id, pane, reason)) = event.kind,
                id == lease.id,
                pane.windowID == temporary.windowID,
                pane.paneID == temporary.paneID
            else { return nil }
            return reason
        }
        #expect(retainedReasons == [.pinLost, .pinLost, .pinLost])
    }

    @Test("pin-loss finish audit failure returns full live provenance")
    func finishAfterPinLossAuditFailure() async throws {
        let initial = TerminalToolFixtures.screen(revision: 583)
        let paneScreen = TerminalToolFixtures.screen(revision: 584)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%pin-audit")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let registry = TerminalEndpointRegistry()
        let endpointID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let threadID = AgentThreadID(rawValue: "pin-audit-thread")
        let turnID = AgentTurnID(rawValue: "pin-audit-turn")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 583)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await registry.unregister(endpointID)
        await journal.setFailAppend(true)
        let provenance = RetainedTemporaryPaneLease(
            id: lease.id,
            conversationKey: lease.conversationKey,
            origin: origin,
            route: TerminalToolFixtures.route,
            pane: RetainedTemporaryPane(
                windowID: temporary.windowID,
                paneID: temporary.paneID
            )
        )

        await #expect(
            throws: TerminalToolRouterError.temporaryPaneAuditUnavailable(
                provenance,
                reason: .pinLost
            )
        ) {
            _ = try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 584
                )
            )
        }
    }

    @Test("finish cancellation during an ignoring probe wait retains interrupted")
    func finishCancellationDuringProbeWaitRetains() async throws {
        let initial = TerminalToolFixtures.screen(revision: 585)
        let paneScreen = TerminalToolFixtures.screen(revision: 586)
        let probed = TerminalToolFixtures.screen(
            revision: 587,
            text: "BD00D\nED00D\n$ "
        )
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%cancel-wait")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal,
            nonce: "D00D"
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 585)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)
        await port.enqueueWait(.init(snapshot: probed, timedOut: false))
        let waitGate = TerminalToolTestGate()
        await port.blockWaits(on: waitGate)
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 586
                )
            )
        }
        try await approveNextRequest(router: router)
        while await port.counts().wait < 2 { await Task.yield() }
        finish.cancel()
        await waitGate.open()

        #expect(
            try await finish.value == .temporaryPaneFinished(
                .retained(lease, reason: .interrupted)
            )
        )
        #expect(!(await surfaces.recordedCalls()).contains { $0.hasPrefix("close:") })
        #expect(await port.counts().send == 1)
        #expect(await port.counts().wait == 2)
        #expect(await journal.snapshot().contains { event in
            guard case let .temporaryPane(.retained(id, pane, reason)) = event.kind
            else { return false }
            return id == lease.id
                && pane.windowID == temporary.windowID
                && pane.paneID == temporary.paneID
                && reason == .interrupted
        })
    }

    @Test("crash reason wins over finish cancellation retention")
    func crashReasonWinsFinishCancellationRace() async throws {
        let initial = TerminalToolFixtures.screen(revision: 5871)
        let paneScreen = TerminalToolFixtures.screen(revision: 5872)
        let probed = TerminalToolFixtures.screen(
            revision: 5873,
            text: "BF00D\nEF00D\n$ "
        )
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%crash-race")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal,
            nonce: "F00D"
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 5871)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)
        await port.enqueueWait(.init(snapshot: probed, timedOut: false))
        let waitGate = TerminalToolTestGate()
        await port.blockWaits(on: waitGate)
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 5872
                )
            )
        }
        try await approveNextRequest(router: router)
        while await port.counts().wait < 2 { await Task.yield() }
        let crash = Task {
            try await router.crashTurn(threadID: threadID, turnID: turnID)
        }
        for _ in 0..<100 { await Task.yield() }
        await waitGate.open()

        #expect(
            try await finish.value == .temporaryPaneFinished(
                .retained(lease, reason: .crashed)
            )
        )
        try await crash.value
        let retainedReasons: [TerminalJournalRetentionReasonCode]
            = await journal.snapshot().compactMap {
            event in
            guard case let .temporaryPane(.retained(id, _, reason)) = event.kind,
                id == lease.id
            else { return nil }
            return reason
        }
        #expect(retainedReasons.suffix(2) == [.crashed, .crashed])
        #expect(!(await surfaces.recordedCalls()).contains { $0.hasPrefix("close:") })
    }

    @Test("finish cancellation during ignoring post-probe surface read retains")
    func finishCancellationDuringPostProbeSurfaceRetains() async throws {
        let initial = TerminalToolFixtures.screen(revision: 588)
        let paneScreen = TerminalToolFixtures.screen(revision: 589)
        let probed = TerminalToolFixtures.screen(
            revision: 590,
            text: "BE11E\nEE11E\n$ "
        )
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%cancel-current")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal,
            nonce: "E11E"
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 588)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        await port.setSnapshot(paneScreen)
        await port.enqueueWait(.init(snapshot: probed, timedOut: false))
        let waitGate = TerminalToolTestGate()
        let currentGate = TerminalToolTestGate()
        await port.blockWaits(on: waitGate)
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 589
                )
            )
        }
        try await approveNextRequest(router: router)
        while await port.counts().wait < 2 { await Task.yield() }
        await surfaces.blockCurrentSurface(on: currentGate)
        await waitGate.open()
        while await surfaces.recordedCalls().filter({ $0 == "current" }).count < 5 {
            await Task.yield()
        }
        finish.cancel()
        await currentGate.open()

        #expect(
            try await finish.value == .temporaryPaneFinished(
                .retained(lease, reason: .interrupted)
            )
        )
        #expect(!(await surfaces.recordedCalls()).contains { $0.hasPrefix("close:") })
        #expect(await port.counts().send == 1)
        #expect(await port.counts().wait == 2)
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
        try await router.interruptTurn(threadID: threadID, turnID: turnID)

        #expect(await port.counts().send == 0)
        let calls = await surfaces.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("close:") })
        let events = await journal.snapshot()
        #expect(events.contains { event in
            guard case let .temporaryPane(.retained(id, pane, reason))
                = event.kind
            else { return false }
            return id == lease.id
                && pane.windowID == temporary.windowID
                && pane.paneID == temporary.paneID
                && reason == .interrupted
        })
        #expect(await port.keyboardOwners() == [.codex, .user])
    }

    @Test("termination returns full audit failure after releasing the endpoint")
    func terminationAuditFailureStillReleasesEndpoint() async throws {
        let initial = TerminalToolFixtures.screen(revision: 115)
        let paneScreen = TerminalToolFixtures.screen(revision: 116)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%14")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
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
                call: .createTemporaryPane(expectedRevision: 115)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        let provenance = RetainedTemporaryPaneLease(
            id: lease.id,
            conversationKey: lease.conversationKey,
            origin: origin,
            route: TerminalToolFixtures.route,
            pane: RetainedTemporaryPane(
                windowID: temporary.windowID,
                paneID: temporary.paneID
            )
        )
        await journal.setFailAppend(true)
        let userGate = TerminalToolTestGate()
        await port.blockKeyboardOwner(.user, on: userGate)
        let firstProbe = TerminalTerminationCompletionProbe()
        let secondProbe = TerminalTerminationCompletionProbe()
        let first = Task {
            do {
                try await router.interruptTurn(
                    threadID: threadID,
                    turnID: turnID
                )
                await firstProbe.complete(with: nil)
            } catch let error as TerminalTurnTerminationError {
                await firstProbe.complete(with: error)
            } catch {
                await firstProbe.complete(with: nil)
            }
        }
        while !(await port.keyboardOwnerTransitionsStarted().contains(.user)) {
            await Task.yield()
        }
        let second = Task {
            do {
                try await router.crashTurn(
                    threadID: threadID,
                    turnID: turnID
                )
                await secondProbe.complete(with: nil)
            } catch let error as TerminalTurnTerminationError {
                await secondProbe.complete(with: error)
            } catch {
                await secondProbe.complete(with: nil)
            }
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!(await firstProbe.snapshot().didComplete))
        #expect(!(await secondProbe.snapshot().didComplete))

        await userGate.open()
        await first.value
        await second.value
        let expected = TerminalTurnTerminationError.auditUnavailable([
            TerminalTurnRetainedPaneAudit(
                provenance: provenance,
                reason: .auditUnavailable
            )
        ])
        #expect(await firstProbe.snapshot().error == expected)
        #expect(await secondProbe.snapshot().error == expected)
        #expect(await port.keyboardOwners() == [.codex, .user])
    }

    @Test("same-turn activation survives cancellation and is joined exactly once")
    func sameTurnActivationIsSharedAndNonCancelling() async throws {
        let codexGate = TerminalToolTestGate()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1161)
        )
        await port.blockKeyboardOwner(.codex, on: codexGate)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let registry = TerminalEndpointRegistry()
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let threadID = AgentThreadID(rawValue: "shared-activation-thread")
        let turnID = AgentTurnID(rawValue: "shared-activation-turn")
        let begin = Task {
            try await router.beginTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while await port.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }
        let first = Task {
            try await router.confirmTurnID(
                threadID: threadID,
                turnID: turnID
            )
        }
        for _ in 0..<100 { await Task.yield() }
        let second = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .observeScreen
            )
        }
        for _ in 0..<100 { await Task.yield() }
        first.cancel()
        await codexGate.open()

        _ = try await begin.value
        await #expect(throws: TerminalToolRouterError.interrupted) {
            try await first.value
        }
        #expect(
            try await second.value == .screen(
                TerminalToolFixtures.screen(revision: 1161)
            )
        )
        #expect(await port.keyboardOwners() == [.codex])
        await #expect(throws: TerminalToolRouterError.turnUnavailable) {
            _ = try await router.execute(
                threadID: threadID,
                turnID: AgentTurnID(rawValue: "mismatched-turn"),
                conversationKey: TerminalToolFixtures.key,
                call: .observeScreen
            )
        }

        try await router.endTurn(threadID: threadID, turnID: turnID)
        #expect(await port.keyboardOwners() == [.codex, .user])
    }

    @Test("cancelled begin still prunes an exact failed preparation")
    func cancelledBeginPrunesFailedPreparation() async throws {
        let codexGate = TerminalToolTestGate()
        let firstPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1162)
        )
        await firstPort.blockKeyboardOwner(.codex, on: codexGate)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let registry = TerminalEndpointRegistry()
        let firstEndpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: firstEndpointID.rawValue,
                port: firstPort,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let threadID = AgentThreadID(rawValue: "failed-begin-thread")
        let begin = Task {
            try await router.beginTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while await firstPort.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }
        let stream = await registry.events()
        let eventTask = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let unregister = Task {
            await registry.unregister(firstEndpointID)
        }
        #expect(await eventTask.value != nil)
        begin.cancel()
        await codexGate.open()

        await #expect(throws: TerminalEndpointRegistryError.pinLost) {
            _ = try await begin.value
        }
        await unregister.value

        let replacementPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1163)
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: replacementPort,
                controller: surfaces
            )
        )
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let turnID = AgentTurnID(rawValue: "replacement-turn")
        try await router.confirmTurnID(threadID: threadID, turnID: turnID)
        try await router.endTurn(threadID: threadID, turnID: turnID)
    }

    @Test("cancellation during binding validation prevents unsent terminal input")
    func validationCancellationPreventsSend() async throws {
        let validationGate = TerminalToolTestGate()
        let validation = TerminalBindingValidationGate(
            blockedCall: 3,
            gate: validationGate
        )
        let registry = TerminalEndpointRegistry(
            bindingValidationHook: { await validation.validate() }
        )
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1162)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let threadID = AgentThreadID(rawValue: "validation-cancel-thread")
        let turnID = AgentTurnID(rawValue: "validation-cancel-turn")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let execute = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(revision: 1162)
                )
            )
        }
        while await validation.count() < 3 { await Task.yield() }
        execute.cancel()
        await validationGate.open()

        await #expect(throws: TerminalToolRouterError.interrupted) {
            _ = try await execute.value
        }
        #expect(await port.counts().send == 0)
    }

    @Test("finish cancellation during validation audits and retains the live lease")
    func finishValidationCancellationRetains() async throws {
        let validationGate = TerminalToolTestGate()
        let validation = TerminalBindingValidationGate(
            blockedCall: 8,
            gate: validationGate
        )
        let registry = TerminalEndpointRegistry(
            bindingValidationHook: { await validation.validate() }
        )
        let initial = TerminalToolFixtures.screen(revision: 1163)
        let paneScreen = TerminalToolFixtures.screen(revision: 1164)
        let port = FakeTerminalToolPort(snapshot: initial)
        await port.enqueueWait(.init(snapshot: paneScreen, timedOut: false))
        let origin = TerminalToolFixtures.surface()
        let temporary = TerminalToolFixtures.surface(paneID: "%validation-live")
        let surfaces = FakeTerminalSurfaceController(
            surface: origin,
            createdSurface: temporary
        )
        let journal = MemoryTerminalToolJournal()
        try await registry.register(
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
            nonce: { _ in "A11A" }
        )
        let threadID = AgentThreadID(rawValue: "validation-live-thread")
        let turnID = AgentTurnID(rawValue: "validation-live-turn")
        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let create = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .createTemporaryPane(expectedRevision: 1163)
            )
        }
        try await approveNextRequest(router: router)
        guard case let .temporaryPaneCreated(lease, _) = try await create.value else {
            Issue.record("expected lease")
            return
        }
        #expect(await validation.count() == 5)
        await port.setSnapshot(paneScreen)
        let finish = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .finishTemporaryPane(
                    leaseID: lease.id,
                    expectedRevision: 1164
                )
            )
        }
        try await approveNextRequest(router: router)
        while await validation.count() < 8 { await Task.yield() }
        finish.cancel()
        await validationGate.open()

        #expect(
            try await finish.value == .temporaryPaneFinished(
                .retained(lease, reason: .interrupted)
            )
        )
        #expect(await port.counts().send == 0)
        #expect(await journal.snapshot().contains { event in
            guard case let .temporaryPane(.retained(id, pane, reason)) = event.kind
            else { return false }
            return id == lease.id
                && pane.windowID == temporary.windowID
                && pane.paneID == temporary.paneID
                && reason == .interrupted
        })
    }

    @Test("concurrent termination callers join admitted work and endpoint release")
    func concurrentTerminationCallersJoinTeardown() async throws {
        let sendGate = TerminalToolTestGate()
        let userGate = TerminalToolTestGate()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 117)
        )
        await port.blockSends(on: sendGate)
        await port.blockKeyboardOwner(.user, on: userGate)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: MemoryTerminalToolJournal()
        )
        let admitted = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 117,
                        purpose: "cancellation-ignoring admitted operation"
                    )
                )
            )
        }
        while await port.counts().send == 0 { await Task.yield() }

        let firstProbe = TerminalTerminationCompletionProbe()
        let secondProbe = TerminalTerminationCompletionProbe()
        let first = Task {
            do {
                try await router.interruptTurn(
                    threadID: threadID,
                    turnID: turnID
                )
                await firstProbe.complete(with: nil)
            } catch let error as TerminalTurnTerminationError {
                await firstProbe.complete(with: error)
            } catch {
                await firstProbe.complete(with: nil)
            }
        }
        for _ in 0..<10 { await Task.yield() }
        let second = Task {
            do {
                try await router.endTurn(threadID: threadID, turnID: turnID)
                await secondProbe.complete(with: nil)
            } catch let error as TerminalTurnTerminationError {
                await secondProbe.complete(with: error)
            } catch {
                await secondProbe.complete(with: nil)
            }
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!(await firstProbe.snapshot().didComplete))
        #expect(!(await secondProbe.snapshot().didComplete))
        #expect(await port.keyboardOwners() == [.codex])
        first.cancel()

        await sendGate.open()
        while !(await port.keyboardOwnerTransitionsStarted().contains(.user)) {
            await Task.yield()
        }
        #expect(!(await firstProbe.snapshot().didComplete))
        #expect(!(await secondProbe.snapshot().didComplete))
        #expect(await port.keyboardOwners() == [.codex])

        await userGate.open()
        _ = try? await admitted.value
        await first.value
        await second.value
        #expect(await firstProbe.snapshot().error == nil)
        #expect(await secondProbe.snapshot().error == nil)
        #expect(await port.keyboardOwners() == [.codex, .user])
    }

    @Test("termination rejects late admission and releases only after admitted work finishes")
    func terminationAdmissionBarrier() async throws {
        let gate = TerminalToolTestGate()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 120)
        )
        await port.blockSends(on: gate)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let journal = MemoryTerminalToolJournal()
        let (router, threadID, turnID) = try await makeRouter(
            port: port,
            surfaces: surfaces,
            journal: journal
        )
        let admitted = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 120,
                        purpose: "cancellation-ignoring send"
                    )
                )
            )
        }
        while await port.counts().send == 0 { await Task.yield() }
        let admittedCounts = await port.counts()

        let termination = Task {
            try await router.interruptTurn(threadID: threadID, turnID: turnID)
        }
        for _ in 0..<100 { await Task.yield() }

        let lateProbe = TerminalToolCompletionProbe()
        let late = Task {
            do {
                _ = try await router.execute(
                    threadID: threadID,
                    turnID: turnID,
                    conversationKey: TerminalToolFixtures.key,
                    call: .observeScreen
                )
                await lateProbe.complete(with: nil)
            } catch let error as TerminalToolRouterError {
                await lateProbe.complete(with: error)
            } catch {
                await lateProbe.complete(with: nil)
            }
        }
        for _ in 0..<100 { await Task.yield() }

        let lateSnapshot = await lateProbe.snapshot()
        #expect(lateSnapshot.didComplete)
        #expect(lateSnapshot.error == .turnUnavailable)
        let countsBeforeRelease = await port.counts()
        #expect(countsBeforeRelease.observe == admittedCounts.observe)
        #expect(countsBeforeRelease.send == admittedCounts.send)
        #expect(countsBeforeRelease.wait == admittedCounts.wait)
        await #expect(throws: TerminalEndpointRegistryError.threadAlreadyPrepared) {
            try await router.beginTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        #expect(await port.keyboardOwners() == [.codex])

        await gate.open()
        _ = try? await admitted.value
        try await termination.value
        await late.value
        #expect(await port.keyboardOwners() == [.codex, .user])

        _ = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
    }

    @Test("formerly colliding turn IDs cancel approvals independently")
    func approvalTurnKeyCollisionIsolation() async throws {
        let firstPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 130)
        )
        let firstSurfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let otherIdentity = TmuxSessionIdentity(
            serverSessionID: "$collision-2",
            createdAtEpoch: 130
        )
        let otherKey = TerminalConversationKey(target: .local, tmux: otherIdentity)
        let otherRoute = TmuxRoute(
            target: .local,
            sessionName: "collision-2",
            expectedIdentity: otherIdentity
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 130)
        )
        let secondSurfaces = FakeTerminalSurfaceController(
            surface: TmuxSurface(
                sessionIdentity: otherIdentity,
                windowID: "@2",
                paneID: "%2",
                currentCommand: "zsh"
            )
        )
        let registry = TerminalEndpointRegistry()
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: firstPort,
                controller: firstSurfaces
            )
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                key: otherKey,
                port: secondPort,
                controller: secondSurfaces,
                route: otherRoute
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let firstThread = AgentThreadID(rawValue: "a")
        let firstTurn = AgentTurnID(rawValue: "b\u{1F}c")
        let secondThread = AgentThreadID(rawValue: "a\u{1F}b")
        let secondTurn = AgentTurnID(rawValue: "c")
        _ = try await router.beginTurn(
            threadID: firstThread,
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await router.beginTurn(
            threadID: secondThread,
            conversationKey: otherKey
        )
        let action = TerminalInputBatch(
            expectedRevision: 130,
            events: [.key(.enter, modifiers: [])],
            purpose: "collision isolation",
            declaredRisk: .routine
        )
        let first = Task {
            try await router.execute(
                threadID: firstThread,
                turnID: firstTurn,
                conversationKey: TerminalToolFixtures.key,
                call: .sendInput(action)
            )
        }
        let second = Task {
            try await router.execute(
                threadID: secondThread,
                turnID: secondTurn,
                conversationKey: otherKey,
                call: .sendInput(action)
            )
        }
        for _ in 0..<100 {
            if await router.pendingApprovals().count == 2 { break }
            await Task.yield()
        }
        #expect(await router.pendingApprovals().count == 2)

        try await router.interruptTurn(threadID: firstThread, turnID: firstTurn)
        await #expect(throws: TerminalToolRouterError.interrupted) {
            try await first.value
        }
        let remaining = await router.pendingApprovals()
        #expect(remaining.count == 1)
        if let request = remaining.first {
            #expect(await router.approveOnce(request.id))
        }
        _ = try await second.value
        #expect(await secondPort.counts().send == 1)
    }

    @Test("turn churn prunes activation termination and lifecycle state")
    func turnChurnPrunesTransientState() async throws {
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 140)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let registry = TerminalEndpointRegistry()
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: port,
                controller: surfaces
            )
        )
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let threadID = AgentThreadID(rawValue: "router-churn")
        for index in 0..<25 {
            let turnID = AgentTurnID(rawValue: "turn-\(index)")
            _ = try await router.beginTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
            _ = try await router.execute(
                threadID: threadID,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key,
                call: .observeScreen
            )
            try await router.endTurn(threadID: threadID, turnID: turnID)
        }

        let snapshot = await router.testingStateSnapshot()
        #expect(snapshot.activeOperationCount == 0)
        #expect(snapshot.preparedTurnCount == 0)
        #expect(snapshot.activationTaskCount == 0)
        #expect(snapshot.activeBindingCount == 0)
        #expect(snapshot.turnLifecycleCount == 0)
        #expect(snapshot.terminationTaskCount == 0)
        #expect(snapshot.terminationReasonCount == 0)
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
        try await registry.register(
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
