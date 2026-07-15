import Testing
@testable import MerlinLizdCore

@Suite("Codex session coordinator", .serialized)
struct CodexSessionCoordinatorTests {
    @Test("endpoint registration restores persisted tab state without resuming the agent")
    func registrationRestoresPersistedStateLazily() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let record = codexTestRecord(key: key, threadID: "restored-thread")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(record))
        let agent = FakeCodexSessionAgent(threadIDs: [])
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let coordinator = CodexSessionCoordinator(
            agent: agent,
            store: store,
            registry: registry,
            router: TerminalToolRouter(
                registry: registry,
                approvalBroker: TerminalApprovalBroker(),
                journal: journal
            ),
            journal: journal
        )

        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )

        #expect(await coordinator.snapshot()[key]?.threadID == record.threadID)
        #expect(await coordinator.snapshot()[key]?.phase == .idle)
        #expect(await agent.recordedResumeCalls().isEmpty)
    }

    @Test("persisted conversation resumes its exact thread and pins the latest endpoint")
    func resumesExactIdentityAndPinsLatestEndpoint() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "persisted-thread")
        let turnID = AgentTurnID(rawValue: "persisted-turn")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(
            .upsert(codexTestRecord(key: key, threadID: threadID.rawValue))
        )
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
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
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let latestPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 2)
        )
        let first = codexTestEndpoint(key: key, port: firstPort)
        let latest = codexTestEndpoint(key: key, port: latestPort)

        try await coordinator.registerEndpoint(first)
        try await coordinator.registerEndpoint(latest)
        await coordinator.submit("inspect", for: key)

        #expect(await agent.recordedResumeCalls() == [threadID])
        #expect(await agent.recordedStartCalls().count == 1)
        #expect(await firstPort.keyboardOwners().isEmpty)
        #expect(await latestPort.keyboardOwners() == [.codex])
        let state = await coordinator.snapshot()[key]
        #expect(state?.threadID == threadID)
        #expect(state?.activeTurnID == turnID)
        #expect(state?.phase == .thinking)
    }

    @Test("same-key pending start single-flights then steers the exact established turn")
    func sameKeyPendingStartSteersExactTurn() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "single-flight-thread")
        let turnID = AgentTurnID(rawValue: "single-flight-turn")
        let gate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.blockStartTurn(for: threadID, on: gate)
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
        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )

        let first = Task { await coordinator.submit("first", for: key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startTurn:\(threadID.rawValue)")
        }
        let second = Task { await coordinator.submit("second", for: key) }
        await gate.open()
        await first.value
        await second.value

        #expect(await agent.recordedStartCalls().count == 1)
        #expect(
            await agent.recordedSteerCalls() == [
                FakeCodexSessionAgent.SteerCall(
                    threadID: threadID,
                    turnID: turnID,
                    prompt: "second"
                )
            ]
        )
    }

    @Test("different conversation keys begin turns concurrently")
    func differentKeysStartConcurrently() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let firstKey = codexTestKey(createdAtEpoch: 1_721_000_001)
        let secondKey = codexTestKey(createdAtEpoch: 1_721_000_002)
        let firstThread = AgentThreadID(rawValue: "parallel-one")
        let secondThread = AgentThreadID(rawValue: "parallel-two")
        let firstGate = CodexSessionTestGate()
        let secondGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [firstThread, secondThread])
        await agent.enqueueTurn(AgentTurnID(rawValue: "turn-one"), for: firstThread)
        await agent.enqueueTurn(AgentTurnID(rawValue: "turn-two"), for: secondThread)
        await agent.blockStartTurn(for: firstThread, on: firstGate)
        await agent.blockStartTurn(for: secondThread, on: secondGate)
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
        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: firstKey,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )
        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: secondKey,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )

        let first = Task { await coordinator.submit("one", for: firstKey) }
        let second = Task { await coordinator.submit("two", for: secondKey) }
        try await codexSessionWithDeadline {
            async let firstReached: Void = agent.waitForCall(
                "startTurn:\(firstThread.rawValue)"
            )
            async let secondReached: Void = agent.waitForCall(
                "startTurn:\(secondThread.rawValue)"
            )
            _ = await (firstReached, secondReached)
        }
        await firstGate.open()
        await secondGate.open()
        await first.value
        await second.value

        #expect(await agent.recordedStartCalls().count == 2)
        #expect(await coordinator.snapshot()[firstKey]?.activeTurnID != nil)
        #expect(await coordinator.snapshot()[secondKey]?.activeTurnID != nil)
    }

    @Test("agent completion releases exact pin and keeps bounded protocol-neutral history")
    func completionReleasesPinAndBoundsHistory() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "history-thread")
        let turnID = AgentTurnID(rawValue: "history-turn")
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
            journal: journal,
            messageLimit: 3
        )
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        try await coordinator.registerEndpoint(
            codexTestEndpoint(key: key, port: port)
        )
        await coordinator.submit("begin", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await agent.emit(
            .history(
                (0..<5).map {
                    AgentMessage(role: .assistant, text: "message-\($0)")
                }
            ),
            for: threadID
        )
        await agent.emit(.turnCompleted(turnID), for: threadID)
        let state = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .waitingForUser)
        }

        #expect(state.activeTurnID == nil)
        #expect(state.messages.map(\.text) == ["message-2", "message-3", "message-4"])
        #expect(await port.keyboardOwners() == [.codex, .user])
        await probe.stop()
    }

    @Test("assistant deltas do not overwrite the last restored assistant message")
    func assistantDeltaPreservesCompletedHistory() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "delta-thread")
        let turnID = AgentTurnID(rawValue: "delta-turn")
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
        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )
        await coordinator.submit("begin", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await agent.emit(
            .history([AgentMessage(role: .assistant, text: "restored")]),
            for: threadID
        )
        await agent.emit(.assistantMessageDelta("new "), for: threadID)
        await agent.emit(.assistantMessageDelta("reply"), for: threadID)
        await agent.emit(
            .assistantMessageCompleted("new reply"),
            for: threadID
        )
        await agent.emit(.turnCompleted(turnID), for: threadID)
        let state = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .waitingForUser)
        }

        #expect(state.messages.map(\.text) == ["restored", "new reply"])
        await probe.stop()
    }

    @Test("history emitted by resume is reduced before resume returns")
    func historyDuringResumeIsNotDropped() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "resume-history-thread")
        let turnID = AgentTurnID(rawValue: "resume-history-turn")
        let resumeGate = CodexSessionTestGate()
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(
            .upsert(codexTestRecord(key: key, threadID: threadID.rawValue))
        )
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.emitWhileResuming(
            [.history([AgentMessage(role: .assistant, text: "restored")])],
            threadID: threadID,
            gate: resumeGate
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
        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())
        let submit = Task { await coordinator.submit("continue", for: key) }

        do {
            let state = try await codexSessionWithDeadline {
                await probe.wait(
                    for: key,
                    phase: .idle,
                    containingMessage: "restored"
                )
            }
            #expect(state.threadID == threadID)
        } catch {
            await resumeGate.open()
            await submit.value
            throw error
        }
        await resumeGate.open()
        await submit.value
        await coordinator.stopAndTakeOver(key)
        await probe.stop()
    }

    @Test("terminal event arriving before start reply is applied after exact confirmation")
    func earlyTerminalEventWaitsForConfirmation() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "early-event-thread")
        let turnID = AgentTurnID(rawValue: "early-event-turn")
        let startGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.blockStartTurn(for: threadID, on: startGate)
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
        try await coordinator.registerEndpoint(
            codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())
        let submit = Task { await coordinator.submit("quick", for: key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startTurn:\(threadID.rawValue)")
        }
        await agent.emit(.turnCompleted(turnID), for: threadID)
        await agent.emit(
            .assistantMessageCompleted("delivered-after-terminal"),
            for: threadID
        )
        _ = try await codexSessionWithDeadline {
            await probe.wait(
                for: key,
                phase: .thinking,
                containingMessage: "delivered-after-terminal"
            )
        }
        await startGate.open()
        await submit.value
        do {
            _ = try await codexSessionWithDeadline {
                await probe.wait(for: key, phase: .waitingForUser)
            }
        } catch {
            await coordinator.stopAndTakeOver(key)
            throw error
        }
        await probe.stop()
    }

    @Test("closing the pinned endpoint interrupts only its owning conversation")
    func pinnedEndpointClosureInterruptsOnlyOwner() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "pin-loss-thread")
        let turnID = AgentTurnID(rawValue: "pin-loss-turn")
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
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let endpoint = codexTestEndpoint(key: key, port: port)
        try await coordinator.registerEndpoint(endpoint)
        await coordinator.submit("begin", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await coordinator.unregisterEndpoint(endpoint.id)
        let state = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .interrupted)
        }

        #expect(state.activeTurnID == nil)
        #expect(
            await agent.recordedInterruptCalls() == [
                FakeCodexSessionAgent.InterruptCall(
                    threadID: threadID,
                    turnID: turnID
                )
            ]
        )
        #expect(await port.keyboardOwners() == [.codex, .user])
        await probe.stop()
    }

    @Test("pin loss before turn confirmation aborts the pin and interrupts the returned turn")
    func pinLossBeforeConfirmationInterruptsReturnedTurn() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "prepared-pin-loss-thread")
        let turnID = AgentTurnID(rawValue: "prepared-pin-loss-turn")
        let startGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.blockStartTurn(for: threadID, on: startGate)
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
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let endpoint = codexTestEndpoint(key: key, port: port)
        try await coordinator.registerEndpoint(endpoint)
        let submit = Task { await coordinator.submit("begin", for: key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startTurn:\(threadID.rawValue)")
        }

        await coordinator.unregisterEndpoint(endpoint.id)
        await startGate.open()
        await submit.value

        #expect(
            await agent.recordedInterruptCalls() == [
                FakeCodexSessionAgent.InterruptCall(
                    threadID: threadID,
                    turnID: turnID
                )
            ]
        )
        #expect(await coordinator.snapshot()[key]?.phase == .interrupted)
        #expect(await port.keyboardOwners() == [.codex, .user])
        let routerState = await router.testingStateSnapshot()
        #expect(routerState.preparedTurnCount == 0)
        #expect(routerState.activeBindingCount == 0)
        #expect(routerState.turnLifecycleCount == 0)
    }

    @Test("start failure aborts prepared keyboard ownership")
    func startFailureAbortsPreparedOwnership() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "failed-start-thread")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(
            .upsert(codexTestRecord(key: key, threadID: threadID.rawValue))
        )
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.setFailure(.start)
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
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        try await coordinator.registerEndpoint(
            codexTestEndpoint(key: key, port: port)
        )

        await coordinator.submit("begin", for: key)

        #expect(await coordinator.snapshot()[key]?.phase == .failed(.protocolFailure))
        #expect(await port.keyboardOwners() == [.codex, .user])
        let routerState = await router.testingStateSnapshot()
        #expect(routerState.preparedTurnCount == 0)
        #expect(routerState.activeBindingCount == 0)
        #expect(routerState.turnLifecycleCount == 0)
    }

    @Test("stop and take over interrupts protocol ownership without terminal bytes")
    func stopInterruptsWithoutTerminalBytes() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stop-thread")
        let turnID = AgentTurnID(rawValue: "stop-turn")
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
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        try await coordinator.registerEndpoint(
            codexTestEndpoint(key: key, port: port)
        )
        await coordinator.submit("begin", for: key)

        await coordinator.stopAndTakeOver(key)

        #expect(await coordinator.snapshot()[key]?.phase == .interrupted)
        #expect(await port.batches().isEmpty)
        #expect(await port.keyboardOwners() == [.codex, .user])
        #expect(
            await agent.recordedInterruptCalls().last
                == FakeCodexSessionAgent.InterruptCall(
                    threadID: threadID,
                    turnID: turnID
                )
        )
    }

    @Test("terminal activity exposes exact approval only to its owning key")
    func terminalActivityPublishesApprovalState() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "approval-thread")
        let turnID = AgentTurnID(rawValue: "approval-turn")
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
            snapshot: TerminalToolFixtures.screen(revision: 5)
        )
        try await coordinator.registerEndpoint(
            codexTestEndpoint(key: key, port: port)
        )
        await coordinator.submit("begin", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(
                    TerminalToolFixtures.input(
                        revision: 5,
                        text: "sudo reboot",
                        purpose: "restart",
                        risk: .high
                    )
                )
            )
        }
        let awaiting = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .awaitingApproval)
        }
        let request = try #require(awaiting.pendingApprovals.first)
        await coordinator.approve(request.id)
        _ = try await operation.value

        #expect(await port.batches().count == 1)
        #expect(await coordinator.snapshot()[key]?.pendingApprovals.isEmpty == true)
        await probe.stop()
    }

    @Test("archive preserves identity and journal while staged delete retries locally")
    func archiveAndRetryableDeletionReconcile() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "lifecycle-thread")
        let record = codexTestRecord(key: key, threadID: threadID.rawValue)
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(record))
        let agent = FakeCodexSessionAgent(threadIDs: [])
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

        try await coordinator.setArchived(true, for: key)
        var snapshot = await store.snapshot()
        #expect(snapshot.records[key]?.threadID == threadID)
        #expect(snapshot.records[key]?.archived == true)
        #expect(await journal.deletions().isEmpty)
        await journal.setFailDelete(true)
        await #expect(throws: CodexSessionCoordinatorError.deletionPending) {
            try await coordinator.deleteConversation(
                key,
                confirmation: .confirmed
            )
        }
        snapshot = await store.snapshot()
        #expect(
            snapshot.deletions[key]?.lastCompletedStage
                == .remoteThreadDeleted
        )
        #expect(snapshot.deletions[key]?.failure == .journalUnavailable)
        #expect(snapshot.records[key]?.threadID == threadID)

        await journal.setFailDelete(false)
        try await coordinator.deleteConversation(key, confirmation: .confirmed)
        snapshot = await store.snapshot()
        #expect(snapshot.records[key] == nil)
        #expect(snapshot.deletions[key] == nil)
        #expect(await agent.recordedDeleteCalls() == [threadID])
    }

    @Test("delete cancels an active approval before forgetting the quiescent thread")
    func deleteQuiescesActiveApprovalBeforeForget() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "delete-active-thread")
        let turnID = AgentTurnID(rawValue: "delete-active-turn")
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
            snapshot: TerminalToolFixtures.screen(revision: 8)
        )
        try await coordinator.registerEndpoint(
            codexTestEndpoint(key: key, port: port)
        )
        await coordinator.submit("begin", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())
        let operation = Task {
            do {
                return Result<TerminalToolResult, any Error>.success(
                    try await router.execute(
                        threadID: threadID,
                        turnID: turnID,
                        call: .sendInput(
                            TerminalToolFixtures.input(
                                revision: 8,
                                text: "sudo reboot",
                                purpose: "restart",
                                risk: .high
                            )
                        )
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        _ = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .awaitingApproval)
        }

        try await coordinator.deleteConversation(key, confirmation: .confirmed)
        let operationResult = await operation.value

        #expect(throws: TerminalToolRouterError.self) {
            try operationResult.get()
        }
        #expect(await port.batches().isEmpty)
        #expect(await agent.recordedDeleteCalls() == [threadID])
        #expect(await store.snapshot().records[key] == nil)
        let routerState = await router.testingStateSnapshot()
        #expect(routerState.preparedTurnCount == 0)
        #expect(routerState.activeOperationCount == 0)
        #expect(routerState.turnLifecycleCount == 0)
        #expect(routerState.observedTurnIdentityCount == 0)
        await probe.stop()
    }
}

@Suite("Terminal tool activity stream", .serialized)
struct TerminalToolActivityStreamTests {
    @Test("slow activity subscribers receive bounded reconciliation")
    func slowSubscribersReconcileWithinBoundedCapacity() async throws {
        let key = codexTestKey()
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        try await registry.register(
            codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            )
        )
        let threadID = AgentThreadID(rawValue: "activity-overflow-thread")
        let turnID = AgentTurnID(rawValue: "activity-overflow-turn")
        let handle = try await router.beginTurn(
            threadID: threadID,
            conversationKey: key
        )
        try await router.confirmTurnID(handle: handle, turnID: turnID)
        let subscription = await router.subscribeActivity()
        let capacity = await router.testingStateSnapshot()
            .activityEventBufferCapacity

        for _ in 0..<(capacity + 1) {
            _ = try await router.execute(
                handle: handle,
                turnID: turnID,
                conversationKey: key,
                call: .observeScreen
            )
        }

        var iterator = subscription.events.makeAsyncIterator()
        var sawReconciliation = false
        for _ in 0..<capacity {
            guard let event = await iterator.next() else { break }
            if case .reconciliationRequired = event {
                sawReconciliation = true
                break
            }
        }
        #expect(sawReconciliation)
        let snapshot = await router.activitySnapshot()
        #expect(snapshot.operations.isEmpty)
        #expect(snapshot.approvals.isEmpty)
        try await router.endTurn(handle: handle, turnID: turnID)
    }

    @Test("cancelled activity subscribers are removed without polling")
    func cancelledSubscribersAreRemoved() async throws {
        let router = TerminalToolRouter(
            registry: TerminalEndpointRegistry(),
            approvalBroker: TerminalApprovalBroker(),
            journal: CodexSessionJournalSpy()
        )
        let subscription = await router.subscribeActivity()
        #expect(
            await router.testingStateSnapshot().activitySubscriberCount == 1
        )
        let consumer = Task {
            for await _ in subscription.events {
                if Task.isCancelled { return }
            }
        }

        consumer.cancel()
        await consumer.value
        try await codexSessionWithDeadline {
            await router.waitUntilActivitySubscriberCount(0)
        }
        #expect(
            await router.testingStateSnapshot().activitySubscriberCount == 0
        )
    }
}
