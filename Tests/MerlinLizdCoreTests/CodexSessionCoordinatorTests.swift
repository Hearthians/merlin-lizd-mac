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
        let waiterCalls = CodexSessionCallProbe()
        await coordinator.setPendingStartWaitHookForTesting {
            await waiterCalls.record("pending-wait")
        }
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
        try await codexSessionWithDeadline {
            await waiterCalls.wait(for: "pending-wait")
        }
        waiter.cancel()
        var waiterReturnedBeforeSharedStart = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(50)) {
                await waiter.value
            }
            waiterReturnedBeforeSharedStart = true
        } catch {}
        #expect(waiterReturnedBeforeSharedStart)
        await gate.open()
        await first.value
        await waiter.value

        #expect(await agent.recordedSteerCalls().isEmpty)
        #expect(await coordinator.snapshot()[key]?.activeTurnID == turnID)
    }

    @Test("cancelling a termination waiter returns before shared cleanup")
    func cancelledTerminationWaiterIsRemovedWithoutCancellingCleanup() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "termination-wait-thread")
        let turnID = AgentTurnID(rawValue: "termination-wait-turn")
        let terminationGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await router.setTurnTerminationHookForTesting {
            await calls.record("router-terminating")
            await terminationGate.wait()
        }
        let coordinator = CodexSessionCoordinator(
            agent: agent,
            store: store,
            registry: registry,
            router: router,
            journal: journal
        )
        await coordinator.setTerminationWaitHookForTesting {
            await calls.record("termination-waiter")
        }
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)

        await agent.emit(.turnCompleted(turnID), for: threadID)
        try await codexSessionWithDeadline {
            await calls.wait(for: "router-terminating")
        }
        let waiter = Task { await coordinator.submit("cancelled-next", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "termination-waiter")
        }
        waiter.cancel()
        var returnedBeforeCleanup = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(50)) {
                await waiter.value
            }
            returnedBeforeCleanup = true
        } catch {}
        #expect(returnedBeforeCleanup)
        #expect(await agent.recordedStartCalls().count == 1)

        await terminationGate.open()
        await waiter.value
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

    @Test("stop joins stale steer cleanup before publishing its outcome")
    func stopJoinsStaleSteerFailureOutcome() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stale-steer-thread")
        let turnID = AgentTurnID(rawValue: "stale-steer-turn")
        let terminationGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)
        await agent.setFailure(.steer)
        await router.setTurnTerminationHookForTesting {
            await calls.record("stale-cleanup")
            await terminationGate.wait()
        }

        let steering = Task { await coordinator.submit("fails", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "stale-cleanup")
        }
        let stopping = Task {
            await coordinator.stopAndTakeOver(key)
            await calls.record("stop-complete")
        }
        var completedBeforeTermination = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(150)) {
                await calls.wait(for: "stop-complete")
            }
            completedBeforeTermination = true
        } catch {}
        #expect(!completedBeforeTermination)
        await terminationGate.open()
        await stopping.value
        await steering.value

        #expect(await coordinator.snapshot()[key]?.phase == .interrupted)
        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
    }

    @Test("shutdown drains stale steer-failure termination ownership")
    func shutdownDrainsSteerFailureAcrossLifecycleRevisionChange() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "shutdown-steer-thread")
        let turnID = AgentTurnID(rawValue: "shutdown-steer-turn")
        let terminationGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)
        await agent.setFailure(.steer)
        await router.setTurnTerminationHookForTesting {
            await calls.record("steer-terminating")
            await terminationGate.wait()
        }

        let steering = Task { await coordinator.submit("fails", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "steer-terminating")
        }
        let shutdown = Task {
            await coordinator.shutdown()
            await calls.record("shutdown-complete")
        }

        while true {
            let stream = await coordinator.states()
            var iterator = stream.makeAsyncIterator()
            if await iterator.next() == nil { break }
            await Task.yield()
        }
        await terminationGate.open()
        var shutdownCompleted = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(250)) {
                await calls.wait(for: "shutdown-complete")
            }
            shutdownCompleted = true
        } catch {
            shutdown.cancel()
        }
        #expect(shutdownCompleted)

        await shutdown.value
        await steering.value
        #expect(await agent.recordedCallCount("shutdown") == 1)
    }

    @Test("canceled shutdown registers one resistant exact termination drain")
    func canceledShutdownDoesNotSpinOnTerminationOwner() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "canceled-shutdown-thread")
        let turnID = AgentTurnID(rawValue: "canceled-shutdown-turn")
        let terminationGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setTerminationWaitHookForTesting {
            await calls.record("termination-wait")
        }
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)
        await agent.setFailure(.steer)
        await router.setTurnTerminationHookForTesting {
            await calls.record("steer-terminating")
            await terminationGate.wait()
        }

        let steering = Task { await coordinator.submit("fails", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "steer-terminating")
        }
        let shutdown = Task {
            await coordinator.shutdown()
            await calls.record("shutdown-complete")
        }
        shutdown.cancel()

        try await codexSessionWithDeadline {
            while true {
                let state = await coordinator.terminationStateForTesting()
                let waitCalls = await calls.count("termination-wait")
                if state.waiterCount == 1
                    || waitCalls >= 2
                {
                    return
                }
                await Task.yield()
            }
        }
        #expect(await calls.count("termination-wait") == 1)
        #expect(await coordinator.terminationStateForTesting().waiterCount == 1)
        #expect(await calls.count("shutdown-complete") == 0)

        await terminationGate.open()
        await steering.value
        await shutdown.value
        #expect(await calls.count("shutdown-complete") == 1)
        #expect(await agent.recordedCallCount("shutdown") == 1)
    }

    @Test("Stop and shutdown join the exact suspended steer termination")
    func stopAndShutdownDrainExactSteerTerminationOwner() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "exact-stop-shutdown-thread")
        let turnID = AgentTurnID(rawValue: "exact-stop-shutdown-turn")
        let terminationGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setTerminationWaitHookForTesting {
            await calls.record("termination-wait")
        }
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)
        await agent.setFailure(.steer)
        await router.setTurnTerminationHookForTesting {
            await calls.record("steer-terminating")
            await terminationGate.wait()
        }

        let steering = Task { await coordinator.submit("fails", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "steer-terminating")
        }
        let stopping = Task {
            await coordinator.stopAndTakeOver(key)
            await calls.record("stop-complete")
        }
        try await codexSessionWithDeadline {
            while await calls.count("termination-wait") == 0,
                await calls.count("stop-complete") == 0
            {
                await Task.yield()
            }
        }
        let shutdown = Task {
            await coordinator.shutdown()
            await calls.record("shutdown-complete")
        }

        var shutdownCompletedBeforeTermination = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(150)) {
                await calls.wait(for: "shutdown-complete")
            }
            shutdownCompletedBeforeTermination = true
        } catch {}
        #expect(!shutdownCompletedBeforeTermination)
        #expect(await agent.recordedCallCount("shutdown") == 0)

        await terminationGate.open()
        await steering.value
        await stopping.value
        await shutdown.value

        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID)
        ])
        #expect(await agent.recordedCallCount("shutdown") == 1)
    }

    @Test("Delete waits for exact steer termination before remote delete and forget")
    func deletionDrainsExactSteerTerminationBeforeForget() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "exact-delete-thread")
        let turnID = AgentTurnID(rawValue: "exact-delete-turn")
        let terminationGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setTerminationWaitHookForTesting {
            await calls.record("termination-wait")
        }
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)
        await agent.setFailure(.steer)
        await router.setTurnTerminationHookForTesting {
            await calls.record("steer-terminating")
            await terminationGate.wait()
        }

        let steering = Task { await coordinator.submit("fails", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "steer-terminating")
        }
        let deleting = Task {
            do {
                try await coordinator.deleteConversation(
                    key,
                    confirmation: .confirmed
                )
                return true
            } catch {
                return false
            }
        }

        try await codexSessionWithDeadline {
            await calls.wait(for: "termination-wait")
        }
        #expect(await agent.recordedDeleteCalls().isEmpty)

        await terminationGate.open()
        await steering.value
        #expect(await deleting.value)

        #expect(await agent.recordedDeleteCalls() == [threadID])
        #expect(try await store.snapshot().records[key] == nil)
        #expect(await router.testingStateSnapshot().observedTurnIdentityCount == 0)
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

    @Test("post-rename sync ambiguity never compensates the durable winner")
    func postRenameSyncFailureRecoversObservedWinner() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "post-rename-winner")
        let turnID = AgentTurnID(rawValue: "post-rename-turn")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        let startGate = CodexSessionTestGate()
        await agent.blockStartThread(on: startGate)
        await agent.enqueueTurn(turnID, for: threadID)
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

        let submitting = Task {
            await coordinator.submit("keep the winner", for: key)
        }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startThread")
        }
        let sync = CodexSynchronousFailureScript(failures: 1)
        await store.setPostRenameSyncHookForTesting { try sync.call() }
        await startGate.open()
        await submitting.value

        #expect(try await store.snapshot().records[key]?.threadID == threadID)
        #expect(await agent.recordedDeleteCalls().isEmpty)
        #expect(await agent.recordedResumeCalls() == [threadID])
        #expect(await agent.recordedStartCalls().count == 1)
        #expect(sync.calls() == 2)
    }

    @Test("repeated post-rename sync failure stays indeterminate")
    func repeatedPostRenameSyncFailureNeverAcceptsOrDeletesCandidate() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "post-rename-indeterminate")
        let turnID = AgentTurnID(rawValue: "post-rename-indeterminate-turn")
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        let startGate = CodexSessionTestGate()
        await agent.blockStartThread(on: startGate)
        await agent.enqueueTurn(turnID, for: threadID)
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

        let submitting = Task {
            await coordinator.submit("fail closed", for: key)
        }
        try await codexSessionWithDeadline {
            await agent.waitForCall("startThread")
        }
        let sync = CodexSynchronousFailureScript(failures: .max)
        await store.setPostRenameSyncHookForTesting { try sync.call() }
        await startGate.open()
        await submitting.value

        #expect(
            await coordinator.snapshot()[key]?.phase
                == .failed(.persistenceUnavailable)
        )
        #expect(await agent.recordedDeleteCalls().isEmpty)
        #expect(await agent.recordedResumeCalls().isEmpty)
        #expect(await agent.recordedStartCalls().isEmpty)
        #expect(sync.calls() >= 2)
    }

    @Test("authoritative reread failure never compensates an unknown winner")
    func authoritativeRereadFailureNeverDeletesCandidate() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "reread-indeterminate")
        let turnID = AgentTurnID(rawValue: "reread-indeterminate-turn")
        let base = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let store = IndeterminateRereadCodexConversationStore(base: base)
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
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

        await coordinator.submit("preserve unknown winner", for: key)

        #expect(
            await coordinator.snapshot()[key]?.phase
                == .failed(.persistenceUnavailable)
        )
        #expect(try await base.snapshot().records[key]?.threadID == threadID)
        #expect(await agent.recordedDeleteCalls().isEmpty)
        #expect(await agent.recordedResumeCalls().isEmpty)
        #expect(await agent.recordedStartCalls().isEmpty)
    }

    @Test("indeterminate pre-rename candidate is retained then compensated before retry")
    func indeterminateCandidateIsReconciledBeforeAnotherCreate() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let firstThread = AgentThreadID(rawValue: "indeterminate-first")
        let secondThread = AgentThreadID(rawValue: "indeterminate-second")
        let secondTurn = AgentTurnID(rawValue: "indeterminate-second-turn")
        let base = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let store = TransientIndeterminateCodexConversationStore(
            base: base,
            persistFirstInsert: false
        )
        let deleteGate = CodexSessionTestGate()
        let agent = FakeCodexSessionAgent(threadIDs: [firstThread, secondThread])
        await agent.enqueueTurn(secondTurn, for: secondThread)
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))

        await coordinator.submit("retain candidate", for: key)

        #expect(
            await coordinator.snapshot()[key]?.orphanedThreads.map(\.threadID)
                == [firstThread]
        )
        #expect(await agent.recordedDeleteCalls().isEmpty)

        let retrying = Task { await coordinator.submit("retry", for: key) }
        var observedCompensation = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(250)) {
                await agent.waitForCall("delete:\(firstThread.rawValue)")
            }
            observedCompensation = true
        } catch {}
        #expect(observedCompensation)
        #expect(await agent.recordedCallCount("startThread") == 1)

        await deleteGate.open()
        await retrying.value

        #expect(await agent.recordedDeleteCalls() == [firstThread])
        #expect(await agent.recordedCallCount("startThread") == 2)
        #expect(try await base.snapshot().records[key]?.threadID == secondThread)
        #expect(await coordinator.snapshot()[key]?.orphanedThreads.isEmpty == true)
    }

    @Test("indeterminate candidate proven winner is never compensated")
    func indeterminateCandidateWinnerClearsVolatileOwnership() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "indeterminate-winner")
        let turnID = AgentTurnID(rawValue: "indeterminate-winner-turn")
        let base = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let store = TransientIndeterminateCodexConversationStore(
            base: base,
            persistFirstInsert: true
        )
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
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

        await coordinator.submit("indeterminate", for: key)
        #expect(
            await coordinator.snapshot()[key]?.orphanedThreads.map(\.threadID)
                == [threadID]
        )

        await coordinator.submit("recover winner", for: key)

        #expect(await agent.recordedDeleteCalls().isEmpty)
        #expect(await agent.recordedCallCount("startThread") == 1)
        #expect(await coordinator.snapshot()[key]?.threadID == threadID)
        #expect(await coordinator.snapshot()[key]?.orphanedThreads.isEmpty == true)
    }

    @Test("failed compensation of a proven loser is persisted before replacement")
    func indeterminateLoserPersistsFailedCompensation() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let firstThread = AgentThreadID(rawValue: "indeterminate-failed-delete")
        let secondThread = AgentThreadID(rawValue: "replacement-after-failed-delete")
        let base = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let store = TransientIndeterminateCodexConversationStore(
            base: base,
            persistFirstInsert: false
        )
        let agent = FakeCodexSessionAgent(threadIDs: [firstThread, secondThread])
        await agent.enqueueTurn(
            AgentTurnID(rawValue: "replacement-turn"),
            for: secondThread
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

        await coordinator.submit("retain unknown candidate", for: key)
        await agent.setFailure(.delete)
        await coordinator.submit("replace proven loser", for: key)

        let snapshot = try await base.snapshot()
        #expect(snapshot.records[key]?.threadID == secondThread)
        #expect(snapshot.orphans[firstThread]?.failure == .remoteUnavailable)
        #expect(await agent.recordedDeleteCalls() == [firstThread])
        #expect(
            await coordinator.snapshot()[key]?.orphanedThreads.map(\.threadID)
                == [firstThread]
        )
    }

    @Test("an already-open coordinator observes another store's deletion")
    func openCoordinatorRefreshesTombstoneAndCompletedDeletion() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let oldThreadID = AgentThreadID(rawValue: "cross-instance-old")
        let newThreadID = AgentThreadID(rawValue: "cross-instance-new")
        let turnID = AgentTurnID(rawValue: "cross-instance-turn")
        let writer = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let reader = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let agent = FakeCodexSessionAgent(threadIDs: [newThreadID])
        await agent.enqueueTurn(turnID, for: newThreadID)
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let coordinator = CodexSessionCoordinator(
            agent: agent,
            store: reader,
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

        let record = codexTestRecord(
            key: key,
            threadID: oldThreadID.rawValue
        )
        _ = try await writer.apply(.upsert(record))
        _ = try await writer.apply(.beginDeletion(
            key: key,
            updatedAt: record.updatedAt
        ))
        await coordinator.submit("blocked by tombstone", for: key)
        #expect(await agent.recordedResumeCalls().isEmpty)
        #expect(await agent.recordedStartCalls().isEmpty)

        for stage in [
            CodexDeletionStage.remoteThreadDeleted,
            .journalDeleted,
            .routerForgotten,
        ] {
            _ = try await writer.apply(.advanceDeletion(
                key: key,
                stage: stage,
                updatedAt: record.updatedAt
            ))
        }
        _ = try await writer.apply(.completeDeletion(key: key))
        await coordinator.submit("new after completed deletion", for: key)

        #expect(await agent.recordedResumeCalls() == [newThreadID])
        #expect(await agent.recordedStartCalls().count == 1)
        #expect(try await reader.snapshot().records[key]?.threadID == newThreadID)
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
        #expect(try await base.snapshot().records.isEmpty)
        #expect(try await base.snapshot().orphans.isEmpty)
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

    @Test("stalled nil cursor receives current reconciliation before transitions")
    func stalledNilActivityCursorReconcilesCurrentSnapshot() async throws {
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
            Issue.record("stalled nil cursor did not reconcile before transitions")
            return
        }
        #expect(snapshot.revision == 2)
        #expect(snapshot.states[key]?.pendingApprovals.isEmpty == true)
        await stateProbe.stop()
    }

    @Test("slow cursor receives one gap before any post-gap approval transition")
    func slowActivityCursorReconcilesBeforePostGapTransitions() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "slow-activity-cursor-thread")
        let turnID = AgentTurnID(rawValue: "slow-activity-cursor-turn")
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
                snapshot: TerminalToolFixtures.screen(revision: 12)
            )
        ))
        await coordinator.submit("start", for: key)

        let seed = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 12,
                    text: "sudo reboot",
                    purpose: "seed",
                    risk: .high
                ))
            )
        }
        let seedApproval = try await codexSessionWithDeadline {
            while true {
                if let approval = await router.activitySnapshot()
                    .approvals.values.first
                {
                    return approval
                }
                await Task.yield()
            }
        }
        #expect(await router.denyApproval(seedApproval.request.id))
        await #expect(throws: TerminalToolRouterError.self) {
            try await seed.value
        }
        try await codexSessionWithDeadline {
            while await coordinator.activityHistoryForTesting().revision < 2 {
                await Task.yield()
            }
        }

        let stream = await coordinator.activityEvents(after: 2)
        let pauseGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
        let consuming = Task {
            var iterator = stream.makeAsyncIterator()
            let requested = await iterator.next()
            await calls.record("requested-consumed")
            let resolved = await iterator.next()
            await calls.record("cursor-paused")
            await pauseGate.wait()
            let overflow = await iterator.next()
            return (requested, resolved, overflow)
        }
        let beforeOverflow = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 12,
                    text: "sudo reboot",
                    purpose: "before-overflow",
                    risk: .high
                ))
            )
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "requested-consumed")
        }
        let exactApproval = try #require(
            await router.activitySnapshot().approvals.values.first
        )
        #expect(await router.denyApproval(exactApproval.request.id))
        await #expect(throws: TerminalToolRouterError.self) {
            try await beforeOverflow.value
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "cursor-paused")
        }

        for index in 0..<33 {
            let operation = Task {
                try await router.execute(
                    threadID: threadID,
                    turnID: turnID,
                    call: .sendInput(TerminalToolFixtures.input(
                        revision: 12,
                        text: "sudo reboot",
                        purpose: "overflow-\(index)",
                        risk: .high
                    ))
                )
            }
            let approval = try await codexSessionWithDeadline {
                while true {
                    if let approval = await router.activitySnapshot()
                        .approvals.values.first
                    {
                        return approval
                    }
                    await Task.yield()
                }
            }
            #expect(await router.denyApproval(approval.request.id))
            await #expect(throws: TerminalToolRouterError.self) {
                try await operation.value
            }
        }

        await pauseGate.open()
        let events = await consuming.value
        guard case .approvalRequested(key, exactApproval.request, 3)? = events.0,
            case .approvalResolved(key, exactApproval.request.id, 4)? = events.1,
            case let .transitionHistoryGap(snapshot)? = events.2
        else {
            Issue.record("post-gap approval transition was delivered before reconciliation")
            return
        }
        #expect(snapshot.revision == 70)
        #expect(snapshot.states[key]?.pendingApprovals.isEmpty == true)
    }

    @Test("router replay preserves approval lifecycle after total live loss")
    func routerReplayPreservesTotallyDroppedApprovalLifecycle() async throws {
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
            guard case .operationUpserted = event else { return }
            guard await calls.count("router-event") == 0 else { return }
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
        let blocker = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .observeScreen
            )
        }
        try await codexSessionWithDeadline {
            await calls.wait(for: "router-event")
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
        let approval = try await codexSessionWithDeadline {
            while true {
                if let approval = await router.activitySnapshot()
                    .approvals.values.first
                {
                    return approval
                }
                await Task.yield()
            }
        }
        _ = await router.denyApproval(approval.request.id)
        for _ in 0..<16 {
            _ = try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .observeScreen
            )
        }
        await eventGate.open()
        _ = try await blocker.value
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
        #expect(await coordinator.activityHistoryForTesting().revision == 2)
    }

    @Test("a stale router snapshot cannot overwrite a newer live revision")
    func staleRouterSnapshotCannotOverwriteNewerLiveActivity() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stale-activity-thread")
        let turnID = AgentTurnID(rawValue: "stale-activity-turn")
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
        let observeGate = TerminalToolTestGate()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 10)
        )
        await port.blockObserves(on: observeGate)
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        let snapshotGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
        await router.setActivitySnapshotHookForTesting {
            await calls.record("snapshot-captured")
            await snapshotGate.wait()
        }
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())
        let starting = Task { await coordinator.submit("start", for: key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "snapshot-captured")
        }

        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .observeScreen
            )
        }
        _ = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .controlling)
        }
        await snapshotGate.open()
        await starting.value

        let routerState = await coordinator.routerActivityStateForTesting()
        #expect(routerState.revision == 1)
        #expect(routerState.operationCount == 1)
        #expect(await coordinator.snapshot()[key]?.phase == .controlling)

        await observeGate.open()
        _ = try await operation.value
        await router.setActivitySnapshotHookForTesting(nil)
        await stateProbe.stop()
    }

    @Test("coordinator activity cursor reports exhausted transition history")
    func coordinatorActivityCursorReportsHistoryGap() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "activity-history-thread")
        let turnID = AgentTurnID(rawValue: "activity-history-turn")
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
                snapshot: TerminalToolFixtures.screen(revision: 11)
            )
        ))
        await coordinator.submit("start", for: key)

        for index in 0..<33 {
            let operation = Task {
                try await router.execute(
                    threadID: threadID,
                    turnID: turnID,
                    call: .sendInput(TerminalToolFixtures.input(
                        revision: 11,
                        text: "sudo reboot",
                        purpose: "history-\(index)",
                        risk: .high
                    ))
                )
            }
            let approval = try await codexSessionWithDeadline {
                while true {
                    if let approval = await router.activitySnapshot()
                        .approvals.values.first
                    {
                        return approval
                    }
                    await Task.yield()
                }
            }
            #expect(await router.denyApproval(approval.request.id))
            await #expect(throws: TerminalToolRouterError.self) {
                try await operation.value
            }
        }
        try await codexSessionWithDeadline {
            while await coordinator.activityHistoryForTesting().revision < 66 {
                await Task.yield()
            }
        }
        let history = await coordinator.activityHistoryForTesting()
        #expect(history.count == history.limit)

        let stream = await coordinator.activityEvents(after: 0)
        var iterator = stream.makeAsyncIterator()
        guard case let .transitionHistoryGap(snapshot)? = await iterator.next()
        else {
            Issue.record("expected an explicit coordinator history gap")
            return
        }
        #expect(snapshot.revision == 66)
        #expect(snapshot.states[key]?.pendingApprovals.isEmpty == true)
    }

    @Test("two activity iterators wait independently and cancel one exact pull")
    func concurrentActivityIteratorsOwnExactWaiters() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let coordinator = CodexSessionCoordinator(
            agent: FakeCodexSessionAgent(threadIDs: []),
            store: store,
            registry: registry,
            router: TerminalToolRouter(
                registry: registry,
                approvalBroker: TerminalApprovalBroker(),
                journal: journal
            ),
            journal: journal
        )
        let stream = await coordinator.activityEvents(after: 0)
        let first = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let second = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        try await codexSessionWithDeadline {
            while await coordinator.activityHistoryForTesting().waiterCount != 2 {
                await Task.yield()
            }
        }

        first.cancel()
        #expect(await first.value == nil)
        try await codexSessionWithDeadline {
            while await coordinator.activityHistoryForTesting().waiterCount != 1 {
                await Task.yield()
            }
        }
        #expect(
            await coordinator.activityHistoryForTesting().subscriberCount == 1
        )

        await coordinator.shutdown()
        #expect(try await codexSessionWithDeadline { await second.value } == nil)
        let final = await coordinator.activityHistoryForTesting()
        #expect(final.subscriberCount == 0)
        #expect(final.waiterCount == 0)
    }

    @Test("activity stream deinit owns drop, early break, and late cleanup")
    func activityStreamLifetimeIsExplicitAndIdempotent() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let coordinator = CodexSessionCoordinator(
            agent: FakeCodexSessionAgent(threadIDs: []),
            store: store,
            registry: registry,
            router: TerminalToolRouter(
                registry: registry,
                approvalBroker: TerminalApprovalBroker(),
                journal: journal
            ),
            journal: journal
        )

        do {
            let stream = await coordinator.activityEvents(after: 0)
            #expect(
                await coordinator.activityHistoryForTesting().subscriberCount == 1
            )
            _ = stream
        }
        try await codexSessionWithDeadline {
            while await coordinator.activityHistoryForTesting().subscriberCount != 0 {
                await Task.yield()
            }
        }

        func consumeInitialReconciliation() async {
            let stream = await coordinator.activityEvents()
            for await _ in stream { break }
        }
        await consumeInitialReconciliation()
        try await codexSessionWithDeadline {
            while await coordinator.activityHistoryForTesting().subscriberCount != 0 {
                await Task.yield()
            }
        }

        var retained: AsyncStream<CodexSessionActivityEvent>? = await coordinator
            .activityEvents(after: 0)
        #expect(
            await coordinator.activityHistoryForTesting().subscriberCount == 1
        )
        await coordinator.shutdown()
        retained = nil
        _ = retained
        for _ in 0..<20 { await Task.yield() }
        let final = await coordinator.activityHistoryForTesting()
        #expect(final.subscriberCount == 0)
        #expect(final.waiterCount == 0)
    }

    @Test("maximum activity cursor ends without a lower reconciliation revision")
    func maximumActivityCursorEndsFailClosed() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        let registry = TerminalEndpointRegistry()
        let journal = CodexSessionJournalSpy()
        let coordinator = CodexSessionCoordinator(
            agent: FakeCodexSessionAgent(threadIDs: []),
            store: store,
            registry: registry,
            router: TerminalToolRouter(
                registry: registry,
                approvalBroker: TerminalApprovalBroker(),
                journal: journal
            ),
            journal: journal
        )
        let stream = await coordinator.activityEvents(after: UInt64.max)
        let ending = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let ended: CodexSessionActivityEvent?
        do {
            ended = try await codexSessionWithDeadline { await ending.value }
        } catch {
            ending.cancel()
            _ = await ending.value
            throw error
        }
        #expect(ended == nil)
        let state = await coordinator.activityHistoryForTesting()
        #expect(state.subscriberCount == 0)
        #expect(state.revision == 0)
        await coordinator.shutdown()
    }

    @Test("activity publisher reaches UInt64.max then reconciles and ends")
    func activityPublisherExhaustionIsTerminal() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "activity-counter-thread")
        let turnID = AgentTurnID(rawValue: "activity-counter-turn")
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
        await coordinator.setActivityRevisionForTesting(UInt64.max - 1)
        let stream = await coordinator.activityEvents(after: UInt64.max - 1)
        let operation = Task {
            try await router.execute(
                threadID: threadID,
                turnID: turnID,
                call: .sendInput(TerminalToolFixtures.input(
                    revision: 9,
                    text: "sudo reboot",
                    purpose: "exhaust",
                    risk: .high
                ))
            )
        }
        let approval = try await codexSessionWithDeadline {
            while true {
                if let approval = await router.activitySnapshot()
                    .approvals.values.first
                {
                    return approval
                }
                await Task.yield()
            }
        }
        #expect(await router.denyApproval(approval.request.id))
        await #expect(throws: TerminalToolRouterError.self) {
            try await operation.value
        }

        let consuming = Task {
            var iterator = stream.makeAsyncIterator()
            return (
                await iterator.next(),
                await iterator.next(),
                await iterator.next()
            )
        }
        let events: (
            CodexSessionActivityEvent?,
            CodexSessionActivityEvent?,
            CodexSessionActivityEvent?
        )
        do {
            events = try await codexSessionWithDeadline { await consuming.value }
        } catch {
            consuming.cancel()
            _ = await consuming.value
            throw error
        }
        guard case .approvalRequested(key, approval.request, UInt64.max)? = events.0,
            case let .transitionHistoryGap(snapshot)? = events.1
        else {
            Issue.record("counter exhaustion did not reconcile at UInt64.max")
            return
        }
        #expect(snapshot.revision == UInt64.max)
        #expect(snapshot.states[key]?.pendingApprovals.isEmpty == true)
        #expect(events.2 == nil)
        let history = await coordinator.activityHistoryForTesting()
        #expect(history.revision == UInt64.max)
        #expect(history.subscriberCount == 0)
        await coordinator.shutdown()
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
        var snapshot = try await store.snapshot()
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
        snapshot = try await store.snapshot()
        #expect(
            snapshot.deletions[key]?.lastCompletedStage
                == .remoteThreadDeleted
        )
        #expect(snapshot.deletions[key]?.failure == .journalUnavailable)
        #expect(snapshot.records[key]?.threadID == threadID)

        await journal.setFailDelete(false)
        try await coordinator.deleteConversation(key, confirmation: .confirmed)
        snapshot = try await store.snapshot()
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

                #expect(
                    try await base.snapshot().records[key]?.archived == desired
                )
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
        #expect(try await store.snapshot().records[key] == nil)
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
            #expect(try await base.snapshot().records[key] == nil)
            #expect(try await base.snapshot().deletions[key] == nil)
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
        #expect(try await store.snapshot().orphans.isEmpty)
        #expect(await coordinator.snapshot()[key]?.orphanedThreads.isEmpty != false)
    }

    @Test("orphan capacity is reserved before creating a remote thread")
    func fullOrphanCapacityRejectsBeforeRemoteCreate() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        for index in 0..<64 {
            _ = try await store.apply(.recordOrphan(CodexOrphanedThread(
                threadID: AgentThreadID(rawValue: "retained-orphan-\(index)"),
                attemptedKey: codexTestKey(
                    createdAtEpoch: 1_721_010_000 + Int64(index)
                ),
                failure: .remoteUnavailable,
                updatedAt: codexTestRecord().updatedAt
            )))
        }
        let candidate = AgentThreadID(rawValue: "must-not-create")
        let agent = FakeCodexSessionAgent(threadIDs: [candidate])
        await agent.enqueueTurn(.init(rawValue: "must-not-turn"), for: candidate)
        await agent.setFailure(.delete)
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

        await coordinator.submit("capacity full", for: key)

        #expect(await agent.recordedCallCount("startThread") == 0)
        #expect(try await store.snapshot().orphans.count == 64)
        #expect(try await store.snapshot().records[key] == nil)
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
        #expect(try await store.snapshot().records[key] == nil)
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

    @Test("stop quiesces approval before draining its event consumer")
    func stopQuiescesBeforeEventConsumerDrain() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stop-drain-thread")
        let turnID = AgentTurnID(rawValue: "stop-drain-turn")
        let drainGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setEventConsumerCancellationHookForTesting {
            await calls.record("event-drain")
            await drainGate.wait()
        }
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 4)
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
                    revision: 4,
                    text: "sudo reboot",
                    purpose: "restart",
                    risk: .high
                ))
            )
        }
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())
        let approvalState = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .awaitingApproval)
        }
        let requestID = try #require(approvalState.pendingApprovals.first?.id)

        let stopping = Task { await coordinator.stopAndTakeOver(key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "event-drain")
        }
        let routerState = await router.testingStateSnapshot()
        #expect(routerState.turnLifecycleCount == 0)
        #expect(routerState.approvalActivityCount == 0)
        await coordinator.approve(requestID)
        #expect(await port.batches().isEmpty)

        await drainGate.open()
        await stopping.value
        await #expect(throws: TerminalToolRouterError.self) {
            try await operation.value
        }
        await stateProbe.stop()
    }

    @Test("deletion joins an admitted stop before removing durable state")
    func deletionJoinsAdmittedStopWithoutLateStateResurrection() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stop-delete-shared-thread")
        let turnID = AgentTurnID(rawValue: "stop-delete-shared-turn")
        let firstDrainGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setEventConsumerCancellationHookForTesting {
            await calls.record("event-drain")
            if await calls.count("event-drain") == 1 {
                await firstDrainGate.wait()
            }
        }
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("start", for: key)

        let stopping = Task { await coordinator.stopAndTakeOver(key) }
        try await codexSessionWithDeadline {
            await calls.wait(for: "event-drain")
        }
        let deleting = Task {
            do {
                try await coordinator.deleteConversation(
                    key,
                    confirmation: .confirmed
                )
                await calls.record("delete-complete")
            } catch {
                await calls.record("delete-failed")
            }
        }

        var deletionCompletedBeforeAdmittedStop = false
        do {
            try await codexSessionWithDeadline(timeout: .milliseconds(100)) {
                await calls.wait(for: "delete-complete")
            }
            deletionCompletedBeforeAdmittedStop = true
        } catch {}
        #expect(!deletionCompletedBeforeAdmittedStop)

        await firstDrainGate.open()
        await stopping.value
        await deleting.value

        #expect(await calls.count("delete-failed") == 0)
        #expect(await calls.count("event-drain") == 1)
        #expect(try await store.snapshot().records[key] == nil)
        #expect(await coordinator.snapshot()[key] == nil)
    }

    @Test("stop cancels a router-prepared start before remote turn creation")
    func stopCancelsStartSuspendedInsideRouterBeginTurn() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stop-router-prepared-thread")
        let turnID = AgentTurnID(rawValue: "stop-router-prepared-turn")
        let preparationGate = TerminalToolTestGate()
        let drainGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setEventConsumerCancellationHookForTesting {
            await calls.record("event-drain")
            await drainGate.wait()
        }
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        await port.blockKeyboardOwner(.codex, on: preparationGate)
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())

        let submitting = Task { await coordinator.submit("start", for: key) }
        await port.waitForKeyboardOwnerStart(.codex)
        let stopping = Task { await coordinator.stopAndTakeOver(key) }
        _ = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .interrupted)
        }

        await preparationGate.open()
        await submitting.value
        #expect(await agent.recordedStartCalls().isEmpty)

        await drainGate.open()
        await stopping.value
        #expect(await agent.recordedStartCalls().isEmpty)
        #expect(await router.testingStateSnapshot().preparedTurnCount == 0)
        #expect(await coordinator.snapshot()[key]?.phase == .interrupted)
        await stateProbe.stop()
    }

    @Test("deletion cancels a router-prepared start before remote turn creation")
    func deletionCancelsStartSuspendedInsideRouterBeginTurn() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "delete-router-prepared-thread")
        let turnID = AgentTurnID(rawValue: "delete-router-prepared-turn")
        let preparationGate = TerminalToolTestGate()
        let drainGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
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
        await coordinator.setEventConsumerCancellationHookForTesting {
            await calls.record("event-drain")
            await drainGate.wait()
        }
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        await port.blockKeyboardOwner(.codex, on: preparationGate)
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: port
        ))
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())

        let submitting = Task { await coordinator.submit("start", for: key) }
        await port.waitForKeyboardOwnerStart(.codex)
        let deleting = Task {
            try await coordinator.deleteConversation(
                key,
                confirmation: .confirmed
            )
        }
        _ = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .interrupted)
        }

        await preparationGate.open()
        await submitting.value
        #expect(await agent.recordedStartCalls().isEmpty)

        await drainGate.open()
        try await deleting.value
        #expect(await agent.recordedStartCalls().isEmpty)
        #expect(await router.testingStateSnapshot().preparedTurnCount == 0)
        #expect(try await store.snapshot().records[key] == nil)
        #expect(await coordinator.snapshot()[key] == nil)
        await stateProbe.stop()
    }

    @Test("concurrent stops single-flight one stopping guard")
    func concurrentStopsCannotClearGuardBeforeRemoteInterrupt() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "stop-single-flight-thread")
        let turnID = AgentTurnID(rawValue: "stop-single-flight-turn")
        let replacementTurn = AgentTurnID(rawValue: "stop-replacement-turn")
        let interruptGate = CodexSessionTestGate()
        let calls = CodexSessionCallProbe()
        let agent = FakeCodexSessionAgent(threadIDs: [threadID])
        await agent.enqueueTurn(turnID, for: threadID)
        await agent.enqueueTurn(replacementTurn, for: threadID)
        await agent.blockInterrupt(on: interruptGate)
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
        await coordinator.submit("first", for: key)

        let first = Task { await coordinator.stopAndTakeOver(key) }
        try await codexSessionWithDeadline {
            await agent.waitForCall("interrupt:\(threadID.rawValue)")
        }
        let second = Task {
            await coordinator.stopAndTakeOver(key)
            await calls.record("second-finished")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await calls.count("second-finished") == 0)
        await coordinator.submit("must remain blocked", for: key)
        #expect(await agent.recordedStartCalls().count == 1)

        await interruptGate.open()
        await first.value
        await second.value
        #expect(await calls.count("second-finished") == 1)
        #expect(await agent.recordedInterruptCalls().count == 1)
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
        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID)
        ])

        let replacementTurn = AgentTurnID(rawValue: "event-eof-replacement")
        await agent.enqueueTurn(replacementTurn, for: threadID)
        await coordinator.submit("resume after EOF", for: key)
        #expect(await agent.recordedResumeCalls() == [threadID, threadID])
        #expect(await coordinator.snapshot()[key]?.activeTurnID == replacementTurn)
        await probe.stop()
    }

    @Test("crash terminal event survives the following owned stream end")
    func crashTerminalStateIsNotOverwrittenByEOF() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "crash-terminal-thread")
        let turnID = AgentTurnID(rawValue: "crash-terminal-turn")
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
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("start", for: key)
        let probe = CodexSessionStateProbe()
        await probe.start(await coordinator.states())

        await agent.emit(.turnFailed(turnID, .crashed), for: threadID)
        await agent.finishEvents(for: threadID)
        _ = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .failed(.crashed))
        }
        for _ in 0..<50 { await Task.yield() }

        #expect(await coordinator.snapshot()[key]?.phase == .failed(.crashed))
        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
        #expect(await router.testingStateSnapshot().turnLifecycleCount == 0)
        #expect(await agent.recordedInterruptCalls().isEmpty)
        await probe.stop()
    }

    @Test("agent replay gaps fail and quiesce the exact active turn")
    func eventReplayGapIsExplicitAndQuiescent() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "event-gap-thread")
        let turnID = AgentTurnID(rawValue: "event-gap-turn")
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

        await agent.emitReplayGap(
            after: nil,
            oldestAvailable: 7,
            for: threadID
        )
        _ = try await codexSessionWithDeadline {
            await probe.wait(for: key, phase: .failed(.protocolFailure))
        }

        #expect(await coordinator.snapshot()[key]?.activeTurnID == nil)
        #expect(await port.keyboardOwners().last == .user)
        #expect(await router.testingStateSnapshot().turnLifecycleCount == 0)
        #expect(await agent.recordedInterruptCalls() == [
            .init(threadID: threadID, turnID: turnID)
        ])
        await probe.stop()
    }

    @Test("replacement event replay reduces a partial overlap exactly once")
    func replacementEventReplayDeduplicatesPartialOverlap() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let key = codexTestKey()
        let threadID = AgentThreadID(rawValue: "event-sequence-thread")
        let firstTurn = AgentTurnID(rawValue: "event-sequence-first")
        let secondTurn = AgentTurnID(rawValue: "event-sequence-second")
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
        try await coordinator.registerEndpoint(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        await coordinator.submit("first", for: key)
        await agent.emitSequenced(
            .init(sequence: 1, event: .assistantMessageDelta("A")),
            for: threadID
        )
        await agent.emitSequenced(
            .init(sequence: 2, event: .assistantMessageDelta("B")),
            for: threadID
        )
        await Task.yield()
        await agent.finishEvents(for: threadID)
        let stateProbe = CodexSessionStateProbe()
        await stateProbe.start(await coordinator.states())
        _ = try await codexSessionWithDeadline {
            await stateProbe.wait(for: key, phase: .failed(.protocolFailure))
        }
        await agent.setReplacementReplay([
            .init(sequence: 2, event: .assistantMessageDelta("B")),
            .init(sequence: 3, event: .assistantMessageDelta("C")),
        ], for: threadID)

        await coordinator.submit("second", for: key)

        let messages = await coordinator.snapshot()[key]?.messages ?? []
        #expect(messages.last?.text == "ABC")
        #expect(await agent.recordedEventCursors(for: threadID) == [nil, 2])
        await stateProbe.stop()
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

    @Test("shutdown drains archive and deletion before agent shutdown")
    func shutdownAwaitsLifecycleMutationTasks() async throws {
        let fixture = try CodexSessionPersistenceFixture()
        defer { fixture.remove() }
        let archiveKey = codexTestKey(createdAtEpoch: 1_721_009_001)
        let deleteKey = codexTestKey(createdAtEpoch: 1_721_009_002)
        let archiveThread = AgentThreadID(rawValue: "shutdown-archive")
        let deleteThread = AgentThreadID(rawValue: "shutdown-delete")
        let archiveGate = CodexSessionTestGate()
        let deleteGate = CodexSessionTestGate()
        let store = try FileCodexConversationStore(
            applicationSupportDirectory: fixture.applicationSupportDirectory
        )
        _ = try await store.apply(.upsert(codexTestRecord(
            key: archiveKey,
            threadID: archiveThread.rawValue
        )))
        _ = try await store.apply(.upsert(codexTestRecord(
            key: deleteKey,
            threadID: deleteThread.rawValue
        )))
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

        let archiving = Task {
            try await coordinator.setArchived(true, for: archiveKey)
        }
        let deleting = Task {
            try await coordinator.deleteConversation(
                deleteKey,
                confirmation: .confirmed
            )
        }
        try await codexSessionWithDeadline {
            async let archiveStarted: Void = agent.waitForCall(
                "archive:\(archiveThread.rawValue)"
            )
            async let deleteStarted: Void = agent.waitForCall(
                "delete:\(deleteThread.rawValue)"
            )
            _ = await (archiveStarted, deleteStarted)
        }
        let shuttingDown = Task { await coordinator.shutdown() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await agent.recordedCallCount("shutdown") == 0)

        await archiveGate.open()
        await deleteGate.open()
        try await archiving.value
        try await deleting.value
        await shuttingDown.value
        #expect(await agent.recordedCallCount("shutdown") == 1)
        #expect(try await store.snapshot().records[archiveKey]?.archived == true)
        #expect(try await store.snapshot().records[deleteKey] == nil)
        await #expect(throws: CancellationError.self) {
            try await coordinator.setArchived(false, for: archiveKey)
        }
        var states = await coordinator.states().makeAsyncIterator()
        #expect(await states.next() == nil)
    }
}

@Suite("Terminal tool activity stream", .serialized)
struct TerminalToolActivityStreamTests {
    @Test("router transition history is hard-bounded and reports exhaustion")
    func routerTransitionHistoryIsBoundedAndReportsGap() async throws {
        let key = codexTestKey()
        let registry = TerminalEndpointRegistry()
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: CodexSessionJournalSpy()
        )
        try await registry.register(codexTestEndpoint(
            key: key,
            port: FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: 1)
            )
        ))
        let threadID = AgentThreadID(rawValue: "activity-ring-thread")
        let turnID = AgentTurnID(rawValue: "activity-ring-turn")
        let handle = try await router.beginTurn(
            threadID: threadID,
            conversationKey: key
        )
        try await router.confirmTurnID(handle: handle, turnID: turnID)
        let limit = await router.testingStateSnapshot().activityTransitionLimit

        for _ in 0..<(limit / 2 + 1) {
            _ = try await router.execute(
                handle: handle,
                turnID: turnID,
                conversationKey: key,
                call: .observeScreen
            )
        }

        let state = await router.testingStateSnapshot()
        #expect(state.activityTransitionCount == limit)
        guard case let .historyGap(snapshot, oldestAvailableRevision) =
            await router.reconcileActivity(after: 0)
        else {
            Issue.record("expected exhausted router transition history")
            return
        }
        #expect(oldestAvailableRevision > 1)
        #expect(snapshot.operations.isEmpty)
        #expect(snapshot.approvals.isEmpty)
        try await router.endTurn(handle: handle, turnID: turnID)
    }

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
