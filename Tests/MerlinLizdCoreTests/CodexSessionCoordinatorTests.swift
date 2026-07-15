import Testing
@testable import MerlinLizdCore

@Suite("Codex session coordinator", .serialized)
struct CodexSessionCoordinatorTests {
    @Test("concurrent first use owns one registry and router subscription")
    func subscriptionInstallationIsSingleFlight() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let registryGate = CodexSessionTestGate()
        let routerGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
        let registry = TerminalEndpointRegistry()
        await registry.setSubscriptionHookForTesting {
            await calls.record("registry-subscribe")
            await registryGate.wait()
        }
        let journal = CodexSessionJournalSpy()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        await router.setActivitySubscriptionHookForTesting {
            await calls.record("router-subscribe")
            await routerGate.wait()
        }
        let coordinator = CodexSessionCoordinator(
            agent: FakeCodexSessionAgent(threadIDs: []),
            store: try FileCodexConversationStore(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            ),
            registry: registry,
            router: router,
            journal: journal
        )

        let focusing = (0..<16).map { _ in
            Task {
                let missing = codexTestEndpoint(
                    key: key,
                    port: FakeTerminalToolPort(
                        snapshot: TerminalToolFixtures.screen(revision: 1)
                    )
                )
                try? await coordinator.focusEndpoint(missing.id)
            }
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "registry-subscribe")
        }
        for _ in 0..<32 { await Task.yield() }
        await registryGate.open()
        for task in focusing { await task.value }

        let registering = (0..<16).map { _ in
            Task {
                try await coordinator.registerEndpoint(codexTestEndpoint(
                    key: key,
                    port: FakeTerminalToolPort(
                        snapshot: TerminalToolFixtures.screen(revision: 1)
                    )
                ))
            }
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "router-subscribe")
        }
        for _ in 0..<32 { await Task.yield() }
        await routerGate.open()
        for task in registering { try await task.value }

        #expect(await calls.count("registry-subscribe") == 1)
        #expect(await calls.count("router-subscribe") == 1)
        #expect(await registry.testingStateSnapshot().eventSubscriberCount == 1)
        #expect(await router.testingStateSnapshot().activitySubscriberCount == 1)
        await coordinator.shutdown()
        #expect(await registry.testingStateSnapshot().eventSubscriberCount == 0)
        #expect(await router.testingStateSnapshot().activitySubscriberCount == 0)
    }

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

    @Test("cancelling the initiating submit interrupts and unwinds ownership")
    func cancelledInitiatingSubmitUnwindsTurn() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "cancel-owner-thread")
        let turnID = AgentTurnID(rawValue: "cancel-owner-turn")
        let gate = CodexSessionTestGate()
        let interruptGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.blockStartTurn(for: threadID, on: gate)
        await agent.blockInterrupt(on: interruptGate)
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))

        let submit = Task { await coordinator.submit("cancel", for: key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startTurn:\(threadID.rawValue)")
        }
        submit.cancel()
        await gate.open()
        try await codexSessionWithDeadline {
            await agent.waitForCall("interrupt:\(threadID.rawValue)")
        }

        #expect(await port.keyboardOwners().last == .user)
        #expect(await router.testingStateSnapshot().turnLifecycleCount == 0)
        await interruptGate.open()
        await submit.value

        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
        #expect(await coordinator.snapshot()[key]?.phase == .interrupted)
        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID)
        ])
    }

    @Test("cancelling a submit waiting on the first start never steers")
    func cancelledPendingSubmitDoesNotSteer() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "cancel-waiter-thread")
        let turnID = AgentTurnID(rawValue: "cancel-waiter-turn")
        let gate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.blockStartTurn(for: threadID, on: gate)
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))

        let first = Task { await coordinator.submit("first", for: key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startTurn:\(threadID.rawValue)")
        }
        let waiter = Task { await coordinator.submit("cancelled", for: key) }
        waiter.cancel()
        await gate.open()
        await first.value
        await waiter.value

        #expect(await agent.recordedSteerCalls().isEmpty)
        #expect(await coordinator.snapshot()[key]?.activeTurnID == turnID)
    }

    @Test("steer failure releases the exact active router ownership")
    func steerFailureReleasesActiveOwnership() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "steer-failure-thread")
        let turnID = AgentTurnID(rawValue: "steer-failure-turn")
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        await coordinator.submit("first", for: key)
        await agent.setFailure(.steer)

        await coordinator.submit("fails", for: key)

        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
        #expect(await coordinator.snapshot()[key]?.phase == .failed(.protocolFailure))
        #expect(await port.keyboardOwners().last == .user)
        #expect(await router.testingStateSnapshot().turnLifecycleCount == 0)
        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID)
        ])
    }

    @Test("two coordinators keep one mapping and compensate the losing thread")
    func concurrentCoordinatorsCompareInsertAndCompensateLoser() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let gate = CodexSessionTestGate()
        let firstThread = AgentThreadID(rawValue: "multi-instance-first")
        let secondThread = AgentThreadID(rawValue: "multi-instance-second")
        let firstAgent = FakeCodexSessionAgent(threadIDs: [firstThread])
        let secondAgent = FakeCodexSessionAgent(threadIDs: [secondThread])
        await firstAgent.blockStartThread(on: gate)
        await secondAgent.blockStartThread(on: gate)
        await firstAgent.enqueueTurn(.init(rawValue: "first-turn"), for: firstThread)
        await secondAgent.enqueueTurn(.init(rawValue: "second-turn"), for: secondThread)
        let firstStore = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let secondStore = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let firstRegistry = TerminalEndpointRegistry()
        let secondRegistry = TerminalEndpointRegistry()
        let firstJournal = CodexSessionJournalSpy()
        let secondJournal = CodexSessionJournalSpy()
        let firstCoordinator = CodexSessionCoordinator(
            agent: firstAgent,
            store: firstStore,
            registry: firstRegistry,
            router: TerminalToolRouter(
                registry: firstRegistry,
                approvalBroker: TerminalApprovalBroker(),
                journal: firstJournal
            ),
            journal: firstJournal
        )
        let secondCoordinator = CodexSessionCoordinator(
            agent: secondAgent,
            store: secondStore,
            registry: secondRegistry,
            router: TerminalToolRouter(
                registry: secondRegistry,
                approvalBroker: TerminalApprovalBroker(),
                journal: secondJournal
            ),
            journal: secondJournal
        )
        let first = Task { await firstCoordinator.submit("first", for: key) }
        let second = Task { await secondCoordinator.submit("second", for: key) }
        try await codexSessionWithDeadline {
            async let firstStarted: Void = firstAgent.waitForCall("startThread")
            async let secondStarted: Void = secondAgent.waitForCall("startThread")
            _ = await (firstStarted, secondStarted)
        }
        await gate.open()
        await first.value
        await second.value

        let winner = try #require(
            await FileCodexConversationStore(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            ).snapshot().records[key]?.threadID
        )
        let allDeletes = await firstAgent.recordedDeleteCalls()
            + secondAgent.recordedDeleteCalls()
        #expect(await firstAgent.recordedStartCalls().isEmpty)
        #expect(await secondAgent.recordedStartCalls().isEmpty)
        #expect(Set(allDeletes) == Set([firstThread, secondThread]).subtracting([winner]))
    }

    @Test("failed insert cleanup and orphan persistence retain recoverable identity")
    func orphanDoubleFailureRemainsVisibleInCoordinatorState() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "volatile-orphan")
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.setFailure(.delete)
        let base = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let store = FaultInjectingCodexConversationStore(
            base: base,
            failures: [.insertIfAbsent: 2, .recordOrphan: 1]
        )
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

        await coordinator.submit("retain me", for: key)

        let state = try #require(await coordinator.snapshot()[key])
        #expect(state.phase == .failed(.persistenceUnavailable))
        #expect(state.orphanedThreads.map(\.threadID) == [threadID])
        #expect(state.orphanedThreads.first?.failure == .persistenceUnavailable)
        #expect(await agent.recordedDeleteCalls() == [threadID])
        #expect(await base.snapshot().records.isEmpty)
        #expect(await base.snapshot().orphans.isEmpty)
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

    @Test("submit racing completion starts one new turn after router cleanup")
    func submitWaitsForTerminatingTurnCleanup() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "terminating-thread")
        let firstTurn = AgentTurnID(rawValue: "terminating-first")
        let secondTurn = AgentTurnID(rawValue: "terminating-second")
        let releaseGate = TerminalToolTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(firstTurn, for: threadID)
        await agent.enqueueTurn(secondTurn, for: threadID)
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
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
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        await port.blockKeyboardOwner(.user, on: releaseGate)
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        await coordinator.submit("first", for: key)

        await agent.emit(.turnCompleted(firstTurn), for: threadID)
        try await codexSessionWithDeadline {
            await port.waitForKeyboardOwnerStart(.user)
        }
        let next = Task { await coordinator.submit("second", for: key) }
        await releaseGate.open()
        await next.value

        #expect(await agent.recordedSteerCalls().isEmpty)
        #expect(await agent.recordedStartCalls().map(\.1) == ["first", "second"])
        #expect(await coordinator.snapshot()[key]?.activeTurnID == secondTurn)
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

    @Test("registry overflow reconciles a dropped active pin loss")
    func registryReconciliationInterruptsMissingExactPin() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let noiseKey = codexTestKey(createdAtEpoch: 1_721_003_001)
        let threadID = AgentThreadID(rawValue: "registry-reconcile-thread")
        let turnID = AgentTurnID(rawValue: "registry-reconcile-turn")
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
        let activeEndpoint = codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        )
        let noiseEndpoint = codexTestEndpoint(
            key: noiseKey,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        )
        try await coordinator.registerEndpoint(activeEndpoint)
        try await coordinator.registerEndpoint(noiseEndpoint)
        await coordinator.submit("start", for: key)
        let eventGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
        await coordinator.setRegistryEventHookForTesting { _ in
            await calls.record("registry-event")
            await eventGate.wait()
        }
        let noiseRouter = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: journal
        )
        let noiseHandleTask = Task {
            try await noiseRouter.beginTurn(
                threadID: .init(rawValue: "noise-thread"),
                conversationKey: noiseKey
            )
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "registry-event")
        }
        await coordinator.unregisterEndpoint(activeEndpoint.id)
        let noiseHandle = try await noiseHandleTask.value
        try await noiseRouter.abortTurn(handle: noiseHandle)
        await eventGate.open()
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        _ = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .interrupted)
        }

        #expect(await agent.recordedInterruptCalls().contains(
            .init(threadID: threadID, turnID: turnID)
        ))
        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
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

    @Test("approval activity emits one requested and one resolved revision")
    func approvalActivityLifecycleIsExact() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "activity-exact-thread")
        let turnID = AgentTurnID(rawValue: "activity-exact-turn")
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 4)
            )
        ))
        await coordinator.submit("start", for: key)
        let stream = await coordinator.activityEvents()
        let collecting = Task {
            var iterator = stream.makeAsyncIterator()
            var events: [CodexSessionActivityEvent] = []
            while events.count < 3, let event = await iterator.next() {
                events.append(event)
            }
            return events
        }
        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 4,
                    text: "sudo reboot",
                    purpose: "restart",
                    risk: .high
                ))
            )
        }
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())
        let awaiting = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .awaitingApproval)
        }
        let request = try #require(awaiting.pendingApprovals.first)
        await coordinator.deny(request.id)
        await #expect(throws: TerminalToolRouterError.self) {
            try await operation.value
        }
        let events = try await codexSessionWithDeadline {
            await collecting.value
        }

        #expect(events.map(\.revision) == [0, 1, 2])
        guard case .approvalRequested(key, request, 1) = events[1] else {
            Issue.record("missing exact approval requested event")
            return
        }
        guard case .approvalResolved(key, request.id, 2) = events[2] else {
            Issue.record("missing exact approval resolved event")
            return
        }
        await stateProbe.stop()
    }

    @Test("stalled activity stream receives authoritative reconciliation")
    func activityOverflowPublishesReconciliationSnapshot() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "activity-overflow-thread")
        let turnID = AgentTurnID(rawValue: "activity-overflow-turn")
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 6)
            )
        ))
        await coordinator.submit("start", for: key)
        let stalled = await coordinator.activityEvents()
        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 6,
                    text: "sudo reboot",
                    purpose: "restart",
                    risk: .high
                ))
            )
        }
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())
        let awaiting = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .awaitingApproval)
        }
        let request = try #require(awaiting.pendingApprovals.first)
        await coordinator.deny(request.id)
        await #expect(throws: TerminalToolRouterError.self) {
            try await operation.value
        }

        let next = Task {
            var iterator = stalled.makeAsyncIterator()
            return await iterator.next()
        }
        let event = try #require(try await codexSessionWithDeadline {
            await next.value
        })
        guard case let .reconciliationRequired(snapshot) = event else {
            Issue.record("activity overflow did not reconcile")
            return
        }
        #expect(snapshot.revision == 2)
        #expect(snapshot.states[key]?.pendingApprovals.isEmpty == true)
        await stateProbe.stop()
    }

    @Test("router overflow reconciles exact approval notification lifecycle")
    func routerApprovalReconciliationEmitsRequestedThenResolved() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "router-reconcile-thread")
        let turnID = AgentTurnID(rawValue: "router-reconcile-turn")
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 9)
            )
        ))
        await coordinator.submit("start", for: key)
        let eventGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
        await coordinator.setRouterActivityEventHookForTesting { event in
            guard case .approvalUpserted = event else { return }
            await calls.record("router-event")
            await eventGate.wait()
        }
        let activityStream = await coordinator.activityEvents()
        let collecting = Task {
            var iterator = activityStream.makeAsyncIterator()
            var events: [CodexSessionActivityEvent] = []
            while events.count < 3, let event = await iterator.next() {
                events.append(event)
            }
            return events
        }
        let approvalOperation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 9,
                    text: "sudo reboot",
                    purpose: "restart",
                    risk: .high
                ))
            )
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "router-event")
        }
        let approval = try #require(
            await router.activitySnapshot().approvals.values.first
        )
        _ = await router.denyApproval(approval.request.id)
        let noise = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .observeScreen
            )
        }
        _ = try await noise.value
        await eventGate.open()
        await #expect(throws: TerminalToolRouterError.self) {
            try await approvalOperation.value
        }
        let events = try await codexSessionWithDeadline {
            await collecting.value
        }

        #expect(events.map(\.revision) == [0, 1, 2])
        guard case .approvalRequested = events[1],
            case .approvalResolved = events[2]
        else {
            Issue.record("approval reconciliation lifecycle was not exact")
            return
        }
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

    @Test("archive reconciliation executes durable intent and rejects its opposite")
    func archiveReconciliationUsesPersistedDirectionAtEveryStage() async throws {
        for desired in [true, false] {
            for failureKind in [
                CodexSessionStoreMutationKind.advanceArchive(.remoteApplied),
                .completeArchive,
            ] {
                let fixture = try CodexSessionPersistenceFixture()
                defer { fixture.remove() }
                let key = codexTestKey(
                    createdAtEpoch: desired ? 1_721_000_901 : 1_721_000_902
                )
                let threadID = AgentThreadID(rawValue:
                    "archive-\(desired)-\(failureKind)")
                let base = try FileCodexConversationStore(
                    applicationSupportDirectory: fixture.applicationSupportDirectory
                )
                _ = try await base.apply(.upsert(codexTestRecord(
                    key: key,
                    threadID: threadID.rawValue,
                    archived: !desired
                )))
                let store = FaultInjectingCodexConversationStore(
                    base: base,
                    failures: [failureKind: 1]
                )
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

                await #expect(throws: CodexSessionCoordinatorError.self) {
                    try await coordinator.setArchived(desired, for: key)
                }
                await #expect(
                    throws: CodexSessionCoordinatorError.archiveChangeConflict
                ) {
                    try await coordinator.setArchived(!desired, for: key)
                }
                try await coordinator.setArchived(desired, for: key)

                #expect(await base.snapshot().records[key]?.archived == desired)
                if desired {
                    #expect(await agent.recordedUnarchiveCalls().isEmpty)
                } else {
                    #expect(await agent.recordedArchiveCalls().isEmpty)
                }
            }
        }
    }

    @Test("deletion drains an admitted archive before any delete side effect")
    func deletionSerializesBehindAnAdmittedArchive() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "archive-delete-thread")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(codexTestRecord(
            key: key,
            threadID: threadID.rawValue
        )))
        let archiveGate = CodexSessionTestGate()
        let deleteGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.blockArchive(on: archiveGate)
        await agent.blockDelete(on: deleteGate)
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

        let archive = Task {
            try await coordinator.setArchived(true, for: key)
        }
        try await codexSessionWithDeadline {
            await agent.waitForCall("archive:\(threadID.rawValue)")
        }
        let deletion = Task {
            try await coordinator.deleteConversation(
                key,
                confirmation: .confirmed
            )
        }
        try await codexSessionWithDeadline {
            while true {
                do {
                    try await coordinator.setArchived(false, for: key)
                    Issue.record("opposite archive unexpectedly succeeded")
                    return
                } catch CodexSessionCoordinatorError.deletionPending {
                    return
                } catch CodexSessionCoordinatorError.archiveChangeConflict {
                    await Task.yield()
                }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await agent.recordedDeleteCalls().isEmpty)
        await archiveGate.open()
        try await archive.value
        try await codexSessionWithDeadline {
            await agent.waitForCall("delete:\(threadID.rawValue)")
        }
        await deleteGate.open()
        try await deletion.value
        #expect(await agent.recordedArchiveCalls() == [threadID])
        #expect(await agent.recordedDeleteCalls() == [threadID])
    }

    @Test("deletion exclusively blocks submit and single-flights two callers")
    func deletionIsExclusiveAcrossSubmitAndTwoCallers() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "exclusive-delete-thread")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(codexTestRecord(
            key: key,
            threadID: threadID.rawValue
        )))
        let gate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [])
        await agent.blockDelete(on: gate)
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

        let firstDelete = Task {
            try await coordinator.deleteConversation(key, confirmation: .confirmed)
        }
        try await codexSessionWithDeadline {
            await agent.waitForCall("delete:\(threadID.rawValue)")
        }
        let submit = Task { await coordinator.submit("must not revive", for: key) }
        let secondDelete = Task {
            try await coordinator.deleteConversation(key, confirmation: .confirmed)
        }
        await #expect(
            throws: CodexSessionCoordinatorError.deletionPending
        ) {
            try await coordinator.setArchived(true, for: key)
        }
        await gate.open()

        try await firstDelete.value
        try await secondDelete.value
        await submit.value
        #expect(await agent.recordedDeleteCalls() == [threadID])
        #expect(await agent.recordedResumeCalls().isEmpty)
        #expect(await agent.recordedStartCalls().isEmpty)
        #expect(await agent.recordedSteerCalls().isEmpty)
        #expect(await store.snapshot().records[key] == nil)
    }

    @Test("relaunch from every deletion stage blocks conversation revival")
    func deletionTombstonesBlockSubmitAtEveryStage() async throws {
        for targetStage in CodexDeletionStage.allCasesForTesting {
            let fixture = try CodexSessionPersistenceFixture()
            let key = codexTestKey(createdAtEpoch:
                1_721_001_000 + Int64(targetStage.rawValue))
            let threadID = AgentThreadID(rawValue:
                "tombstone-\(targetStage.rawValue)")
            let store = try FileCodexConversationStore(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            )
            _ = try await store.apply(.upsert(codexTestRecord(
                key: key,
                threadID: threadID.rawValue
            )))
            _ = try await store.apply(.beginDeletion(
                key: key,
                updatedAt: codexTestRecord().updatedAt
            ))
            if targetStage > .intentPersisted {
                for stage in CodexDeletionStage.allCasesForTesting
                where stage > .intentPersisted && stage <= targetStage {
                    _ = try await store.apply(.advanceDeletion(
                        key: key,
                        stage: stage,
                        updatedAt: codexTestRecord().updatedAt
                    ))
                }
            }
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
            try await coordinator.registerEndpoint(codexTestEndpoint(
                key: key,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1)
                )
            ))

            await coordinator.submit("must stay deleted", for: key)

            #expect(await agent.recordedResumeCalls().isEmpty)
            #expect(await agent.recordedStartCalls().isEmpty)
            #expect(await agent.recordedSteerCalls().isEmpty)
            #expect(await coordinator.snapshot()[key]?.deletionRetry?.stage
                == targetStage)
            fixture.remove()
        }
    }

    @Test("deletion retries safely after persistence fails after each side effect")
    func deletionSideEffectPersistenceMatrixIsRetrySafe() async throws {
        for failedStage in [
            CodexDeletionStage.remoteThreadDeleted,
            .journalDeleted,
            .routerForgotten,
        ] {
            let fixture = try CodexSessionPersistenceFixture()
            let key = codexTestKey(createdAtEpoch:
                1_721_002_000 + Int64(failedStage.rawValue))
            let threadID = AgentThreadID(rawValue:
                "side-effect-\(failedStage.rawValue)")
            let base = try FileCodexConversationStore(
                applicationSupportDirectory: fixture.applicationSupportDirectory
            )
            _ = try await base.apply(.upsert(codexTestRecord(
                key: key,
                threadID: threadID.rawValue
            )))
            let store = FaultInjectingCodexConversationStore(
                base: base,
                failures: [.advanceDeletion(failedStage): 1]
            )
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

            await #expect(throws: CodexSessionCoordinatorError.deletionPending) {
                try await coordinator.deleteConversation(
                    key,
                    confirmation: .confirmed
                )
            }
            try await coordinator.deleteConversation(key, confirmation: .confirmed)

            #expect(await agent.recordedDeleteCalls() == [threadID])
            #expect(await base.snapshot().records[key] == nil)
            #expect(await base.snapshot().deletions[key] == nil)
            fixture.remove()
        }
    }

    @Test("relaunch retries and removes a durable orphan thread")
    func relaunchRecoversDurableOrphan() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "durable-orphan")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.recordOrphan(CodexOrphanedThread(
            threadID: threadID,
            attemptedKey: key,
            failure: .remoteUnavailable,
            updatedAt: codexTestRecord().updatedAt
        )))
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

        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))

        #expect(await agent.recordedDeleteCalls() == [threadID])
        #expect(await store.snapshot().orphans.isEmpty)
        #expect(await coordinator.snapshot()[key]?.orphanedThreads.isEmpty != false)
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

    @Test("stop disables router progress before remote interrupt returns")
    func stopQuiescesRouterBeforeAwaitingRemoteInterrupt() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stop-order-thread")
        let turnID = AgentTurnID(rawValue: "stop-order-turn")
        let interruptGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.blockInterrupt(on: interruptGate)
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
            snapshot: TerminalToolFixtures.screen(revision: 3)
        )
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        await coordinator.submit("start", for: key)
        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 3,
                    text: "sudo reboot",
                    purpose: "restart",
                    risk: .high
                ))
            )
        }
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())
        _ = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .awaitingApproval)
        }

        let stopping = Task { await coordinator.stopAndTakeOver(key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("interrupt:\(threadID.rawValue)")
        }

        let routerState = await router.testingStateSnapshot()
        #expect(routerState.activeOperationCount == 0)
        #expect(routerState.approvalActivityCount == 0)
        #expect(await port.batches().isEmpty)
        await interruptGate.open()
        await stopping.value
        await #expect(throws: TerminalToolRouterError.self) {
            try await operation.value
        }
        await stateProbe.stop()
    }

    @Test("late events after stop cannot revive the interrupted session")
    func stopRejectsQueuedLateAgentEvents() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "late-stop-thread")
        let turnID = AgentTurnID(rawValue: "late-stop-turn")
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("start", for: key)
        await coordinator.stopAndTakeOver(key)

        await agent.emit(.turnStarted(turnID), for: threadID)
        await agent.emit(.assistantMessageDelta("late"), for: threadID)
        await agent.emit(.turnCompleted(turnID), for: threadID)
        await Task.yield()
        await Task.yield()

        let state = try #require(await coordinator.snapshot()[key])
        #expect(state.phase == .interrupted)
        #expect(state.activeTurnID == nil)
        #expect(state.messages.allSatisfy { $0.text != "late" })
    }

    @Test("owned agent event EOF fails and releases the exact active turn")
    func eventConsumerEOFIsExplicitAndQuiescent() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "event-eof-thread")
        let turnID = AgentTurnID(rawValue: "event-eof-turn")
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        await coordinator.submit("start", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await agent.finishEvents(for: threadID)
        _ = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .failed(.protocolFailure))
        }

        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
        #expect(await port.keyboardOwners().last == .user)
        #expect(await router.testingStateSnapshot().turnLifecycleCount == 0)
        await probe.stop()
    }

    @Test("shutdown drains active approval and exact turn ownership")
    func shutdownQuiescesActiveTurnAndOwnedTasks() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "shutdown-thread")
        let turnID = AgentTurnID(rawValue: "shutdown-turn")
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
            snapshot: TerminalToolFixtures.screen(revision: 7)
        )
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        await coordinator.submit("start", for: key)
        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 7,
                    text: "sudo reboot",
                    purpose: "restart",
                    risk: .high
                ))
            )
        }
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())
        _ = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .awaitingApproval)
        }

        await coordinator.shutdown()

        await #expect(throws: TerminalToolRouterError.self) {
            try await operation.value
        }
        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID)
        ])
        #expect(await port.keyboardOwners().last == .user)
        let routerState = await router.testingStateSnapshot()
        #expect(routerState.activeOperationCount == 0)
        #expect(routerState.approvalActivityCount == 0)
        #expect(routerState.turnLifecycleCount == 0)
        #expect(await registry.testingStateSnapshot().eventSubscriberCount == 0)
        #expect(routerState.activitySubscriberCount == 0)
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
