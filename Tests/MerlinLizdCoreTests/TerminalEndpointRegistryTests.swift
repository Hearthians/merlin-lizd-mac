import Testing
@testable import MerlinLizdCore

@Suite("Terminal endpoint registry", .serialized)
struct TerminalEndpointRegistryTests {
    @Test("stale exact registry calls cannot consume a reused raw turn ID")
    func staleExactCallsCannotConsumeReusedRawTurnID() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 101)
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: port,
                controller: FakeTerminalSurfaceController(
                    surface: TerminalToolFixtures.surface()
                )
            )
        )
        let threadID = AgentThreadID(rawValue: "registry-generation-thread")
        let reusedTurnID = AgentTurnID(rawValue: "registry-reused-turn")
        let firstHandle = AgentTurnHandle(
            threadID: threadID,
            generationID: TerminalToolFixtures.uuid(
                "91000000-0000-0000-0000-000000000001"
            )
        )
        let firstPrepared = try await registry.prepareTurn(
            handle: firstHandle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.claimPreparedTurn(
            handle: firstHandle,
            token: firstPrepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: reusedTurnID
        )
        await registry.releaseTurn(
            handle: firstHandle,
            token: firstPrepared.token,
            turnID: reusedTurnID
        )

        let successorHandle = AgentTurnHandle(
            threadID: threadID,
            generationID: TerminalToolFixtures.uuid(
                "91000000-0000-0000-0000-000000000002"
            )
        )
        let successorPrepared = try await registry.prepareTurn(
            handle: successorHandle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        await #expect(
            throws: TerminalEndpointRegistryError.preparedBindingNotFound
        ) {
            try await registry.confirmTurnID(
                handle: firstHandle,
                token: firstPrepared.token,
                turnID: reusedTurnID
            )
        }
        await #expect(
            throws: TerminalEndpointRegistryError.preparedBindingNotFound
        ) {
            _ = try await registry.binding(
                handle: firstHandle,
                token: firstPrepared.token,
                turnID: reusedTurnID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        await registry.releaseTurn(
            handle: firstHandle,
            token: firstPrepared.token,
            turnID: reusedTurnID
        )
        await registry.releasePrepared(
            handle: firstHandle,
            token: firstPrepared.token,
            conversationKey: TerminalToolFixtures.key
        )

        let successor = try await registry.claimPreparedTurn(
            handle: successorHandle,
            token: successorPrepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: reusedTurnID
        )
        try await registry.confirmTurnID(
            handle: successorHandle,
            token: successorPrepared.token,
            turnID: reusedTurnID
        )
        #expect(
            try await registry.binding(
                handle: successorHandle,
                token: successorPrepared.token,
                turnID: reusedTurnID,
                conversationKey: TerminalToolFixtures.key
            ).token == successor.token
        )
        await registry.releaseTurn(
            handle: successorHandle,
            token: successorPrepared.token,
            turnID: reusedTurnID
        )
        #expect(await port.keyboardOwners() == [.codex, .user, .codex, .user])
    }

    @Test("most recent focus pins only while idle and turn confirmation is exact")
    func focusPinsOnlyWhileIdle() async throws {
        let registry = TerminalEndpointRegistry()
        let firstPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1),
            label: "first"
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1),
            label: "second"
        )
        let firstSurface = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let secondSurface = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let firstID = TerminalToolFixtures.uuid("10000000-0000-0000-0000-000000000001")
        let secondID = TerminalToolFixtures.uuid("10000000-0000-0000-0000-000000000002")
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: firstID,
                port: firstPort,
                controller: firstSurface
            )
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: secondID,
                port: secondPort,
                controller: secondSurface
            )
        )
        try await registry.focus(
            TerminalEndpointID(rawValue: firstID)
        )
        try await registry.focus(
            TerminalEndpointID(rawValue: secondID)
        )

        let threadID = AgentThreadID(rawValue: "thread-1")
        let handle = AgentTurnHandle(threadID: threadID)
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        #expect(prepared.endpoint.id.rawValue == secondID)

        try await registry.focus(TerminalEndpointID(rawValue: firstID))
        let turnID = AgentTurnID(rawValue: "turn-1")
        let claimed = try await registry.claimPreparedTurn(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        #expect(claimed.endpoint.id.rawValue == secondID)
        try await registry.confirmTurnID(
            handle: handle,
            token: prepared.token,
            turnID: turnID
        )

        await #expect(throws: TerminalEndpointRegistryError.turnIDMismatch) {
            try await registry.confirmTurnID(
                handle: handle,
                token: prepared.token,
                turnID: AgentTurnID(rawValue: "other")
            )
        }
    }

    @Test("unregistering the pinned endpoint records pin loss without migration")
    func unregisterRecordsPinLoss() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.uuid("20000000-0000-0000-0000-000000000001")
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: surfaces
            )
        )
        try await registry.focus(endpointID)
        let threadID = AgentThreadID(rawValue: "thread-loss")
        let handle = AgentTurnHandle(threadID: threadID)
        let turnID = AgentTurnID(rawValue: "turn-loss")
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.claimPreparedTurn(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        let subscription = await registry.subscribe()
        let eventTask = Task {
            var iterator = subscription.events.makeAsyncIterator()
            return await iterator.next()
        }

        await registry.unregister(endpointID)

        let expectedPin = TerminalEndpointPin(
            handle: handle,
            bindingToken: prepared.token,
            turnID: turnID,
            phase: .active,
            conversationKey: TerminalToolFixtures.key,
            endpointID: endpointID
        )
        guard case let .pinLost(loss, revision) = await eventTask.value else {
            Issue.record("expected pin-loss event")
            return
        }
        #expect(loss.pin == expectedPin)
        #expect(revision > subscription.snapshot.revision)
        await #expect(throws: TerminalEndpointRegistryError.pinLost) {
            try await registry.binding(
                handle: handle,
                token: prepared.token,
                turnID: turnID,
                conversationKey: TerminalToolFixtures.key
            )
        }
    }

    @Test("pin loss is emitted to active registry event subscribers")
    func pinLossEventStream() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.uuid(
                "30000000-0000-0000-0000-000000000001"
            )
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: surfaces
            )
        )
        let threadID = AgentThreadID(rawValue: "thread-event")
        let handle = AgentTurnHandle(threadID: threadID)
        let turnID = AgentTurnID(rawValue: "turn-event")
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.claimPreparedTurn(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        let subscription = await registry.subscribe()
        let eventTask = Task {
            var iterator = subscription.events.makeAsyncIterator()
            return await iterator.next()
        }

        await registry.unregister(endpointID)

        guard case let .pinLost(loss, revision) = await eventTask.value else {
            Issue.record("expected pin-loss event")
            return
        }
        #expect(
            loss.pin == TerminalEndpointPin(
                handle: handle,
                bindingToken: prepared.token,
                turnID: turnID,
                phase: .active,
                conversationKey: TerminalToolFixtures.key,
                endpointID: endpointID
            )
        )
        #expect(revision > subscription.snapshot.revision)
    }

    @Test("route mismatch is rejected without registering the endpoint")
    func routeMismatchHasNoStateChange() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let mismatchedRoute = TmuxRoute(
            target: .local,
            sessionName: "wrong",
            expectedIdentity: TmuxSessionIdentity(
                serverSessionID: "$mismatch",
                createdAtEpoch: 42
            )
        )

        await #expect(throws: TerminalEndpointRegistryError.endpointRouteMismatch) {
            try await registry.register(
                TerminalToolFixtures.endpoint(
                    id: TerminalToolFixtures.newID(),
                    port: port,
                    controller: surfaces,
                    route: mismatchedRoute
                )
            )
        }
        await #expect(throws: TerminalEndpointRegistryError.noFocusedEndpoint) {
            try await registry.prepareTurn(
                handle: AgentTurnHandle(
                    threadID: AgentThreadID(rawValue: "route-mismatch")
                ),
                token: TerminalEndpointBindingToken(),
                conversationKey: TerminalToolFixtures.key
            )
        }
        #expect(await port.keyboardOwners().isEmpty)
    }

    @Test("duplicate endpoint identity is rejected until unregister completes")
    func duplicateEndpointIdentityIsRejected() async throws {
        let registry = TerminalEndpointRegistry()
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        let originalScreen = TerminalToolFixtures.screen(revision: 41)
        let replacementScreen = TerminalToolFixtures.screen(revision: 42)
        let originalPort = FakeTerminalToolPort(snapshot: originalScreen)
        let replacementPort = FakeTerminalToolPort(snapshot: replacementScreen)
        let replacementIdentity = TmuxSessionIdentity(
            serverSessionID: "$duplicate-replacement",
            createdAtEpoch: 42
        )
        let replacementKey = TerminalConversationKey(
            target: .local,
            tmux: replacementIdentity
        )
        let replacementRoute = TmuxRoute(
            target: .local,
            sessionName: "duplicate-replacement",
            expectedIdentity: replacementIdentity
        )
        let original = TerminalToolFixtures.endpoint(
            id: endpointID.rawValue,
            port: originalPort,
            controller: FakeTerminalSurfaceController(
                surface: TerminalToolFixtures.surface()
            )
        )
        let sameConversationReplacement = TerminalToolFixtures.endpoint(
            id: endpointID.rawValue,
            port: replacementPort,
            controller: FakeTerminalSurfaceController(
                surface: TerminalToolFixtures.surface()
            )
        )
        let differentConversationReplacement = TerminalToolFixtures.endpoint(
            id: endpointID.rawValue,
            key: replacementKey,
            port: replacementPort,
            controller: FakeTerminalSurfaceController(
                surface: TmuxSurface(
                    sessionIdentity: replacementIdentity,
                    windowID: "@replacement",
                    paneID: "%replacement",
                    currentCommand: "zsh"
                )
            ),
            route: replacementRoute
        )
        try await registry.register(original)
        let threadID = AgentThreadID(rawValue: "duplicate-endpoint")
        let handle = AgentTurnHandle(threadID: threadID)
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )

        await #expect(
            throws: TerminalEndpointRegistryError.endpointAlreadyRegistered(
                endpointID
            )
        ) {
            try await registry.register(sameConversationReplacement)
        }
        let turnID = AgentTurnID(rawValue: "duplicate-endpoint-turn")
        let claimed = try await registry.claimPreparedTurn(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        #expect(try await claimed.endpoint.terminal.observeScreen() == originalScreen)

        await #expect(
            throws: TerminalEndpointRegistryError.endpointAlreadyRegistered(
                endpointID
            )
        ) {
            try await registry.register(differentConversationReplacement)
        }
        #expect(await replacementPort.keyboardOwners().isEmpty)

        let userGate = TerminalToolTestGate()
        await originalPort.blockKeyboardOwner(.user, on: userGate)
        let unregister = Task { await registry.unregister(endpointID) }
        while !(await originalPort.keyboardOwnerTransitionsStarted().contains(.user)) {
            await Task.yield()
        }
        await #expect(
            throws: TerminalEndpointRegistryError.endpointAlreadyRegistered(
                endpointID
            )
        ) {
            try await registry.register(differentConversationReplacement)
        }
        await userGate.open()
        await unregister.value
        await registry.releaseTurn(
            handle: handle,
            token: prepared.token,
            turnID: turnID
        )
        try await registry.register(differentConversationReplacement)
        let replacementThread = AgentThreadID(rawValue: "replacement-endpoint")
        let replacementHandle = AgentTurnHandle(threadID: replacementThread)
        let rebound = try await registry.prepareTurn(
            handle: replacementHandle,
            token: TerminalEndpointBindingToken(),
            conversationKey: replacementKey
        )
        #expect(try await rebound.endpoint.terminal.observeScreen() == replacementScreen)
        #expect(await originalPort.keyboardOwners() == [.codex, .user])
        #expect(await replacementPort.keyboardOwners() == [.codex])
    }

    @Test("active release cannot consume an unclaimed prepared binding")
    func activeReleaseDoesNotReleasePreparedBinding() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
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
        let threadID = AgentThreadID(rawValue: "prepared-release")
        let handle = AgentTurnHandle(threadID: threadID)
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )

        await registry.releaseTurn(
            handle: handle,
            token: prepared.token,
            turnID: AgentTurnID(rawValue: "unrelated")
        )

        _ = try await registry.claimPreparedTurn(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: AgentTurnID(rawValue: "actual")
        )
        #expect(await port.keyboardOwners() == [.codex])
    }

    @Test("prepared release requires the exact conversation key")
    func exactPreparedRelease() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
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
        let threadID = AgentThreadID(rawValue: "exact-prepared-release")
        let handle = AgentTurnHandle(threadID: threadID)
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        let otherKey = TerminalConversationKey(
            target: .local,
            tmux: TmuxSessionIdentity(
                serverSessionID: "$other",
                createdAtEpoch: 43
            )
        )

        await registry.releasePrepared(
            handle: handle,
            token: prepared.token,
            conversationKey: otherKey
        )
        await #expect(throws: TerminalEndpointRegistryError.threadAlreadyPrepared) {
            try await registry.prepareTurn(
                handle: AgentTurnHandle(threadID: threadID),
                token: TerminalEndpointBindingToken(),
                conversationKey: TerminalToolFixtures.key
            )
        }
        await registry.releasePrepared(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.prepareTurn(
            handle: AgentTurnHandle(threadID: threadID),
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        #expect(await port.keyboardOwners() == [.codex, .user, .codex])
    }

    @Test("prepared pin loss is emitted with prepared phase and no turn ID")
    func preparedPinLossIsEmitted() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let endpointID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: surfaces
            )
        )
        let threadID = AgentThreadID(rawValue: "prepared-pin-loss")
        let handle = AgentTurnHandle(threadID: threadID)
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        let subscription = await registry.subscribe()
        let eventTask = Task {
            var iterator = subscription.events.makeAsyncIterator()
            return await iterator.next()
        }

        await registry.unregister(endpointID)

        let expected = TerminalEndpointPinLoss(
            pin: TerminalEndpointPin(
                handle: handle,
                bindingToken: prepared.token,
                turnID: nil,
                phase: .prepared,
                conversationKey: TerminalToolFixtures.key,
                endpointID: endpointID
            )
        )
        guard case let .pinLost(loss, revision) = await eventTask.value else {
            Issue.record("expected prepared pin-loss event")
            return
        }
        #expect(loss == expected)
        #expect(revision > subscription.snapshot.revision)
    }

    @Test("release waits for preparing ownership and blocks replacement")
    func preparingReleaseIsSerialized() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let codexGate = TerminalToolTestGate()
        await port.blockKeyboardOwner(.codex, on: codexGate)
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                port: port,
                controller: surfaces
            )
        )
        let threadID = AgentThreadID(rawValue: "preparing-release")
        let handle = AgentTurnHandle(threadID: threadID)
        let token = TerminalEndpointBindingToken()
        let prepare = Task {
            try await registry.prepareTurn(
                handle: handle,
                token: token,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while await port.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }

        let release = Task {
            await registry.releasePrepared(
                handle: handle,
                token: token,
                conversationKey: TerminalToolFixtures.key
            )
        }
        let replacementProbe = TerminalRegistryCompletionProbe()
        let replacement = Task {
            do {
                _ = try await registry.prepareTurn(
                    handle: AgentTurnHandle(threadID: threadID),
                    token: TerminalEndpointBindingToken(),
                    conversationKey: TerminalToolFixtures.key
                )
                await replacementProbe.complete(with: nil)
            } catch let error as TerminalEndpointRegistryError {
                await replacementProbe.complete(with: error)
            } catch {
                await replacementProbe.complete(with: nil)
            }
        }
        for _ in 0..<100 { await Task.yield() }

        let replacementState = await replacementProbe.snapshot()
        #expect(replacementState.didComplete)
        #expect(replacementState.error == .threadAlreadyPrepared)
        #expect(await port.keyboardOwnerTransitionsStarted() == [.codex])
        #expect(await port.keyboardOwners().isEmpty)

        await codexGate.open()
        await release.value
        await replacement.value
        await #expect(throws: TerminalEndpointRegistryError.preparedBindingNotFound) {
            _ = try await prepare.value
        }
        #expect(await port.keyboardOwners() == [.codex, .user])
    }

    @Test("release retains ownership until the user transition completes")
    func releasingBlocksReplacement() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
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
        let threadID = AgentThreadID(rawValue: "releasing")
        let handle = AgentTurnHandle(threadID: threadID)
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        let userGate = TerminalToolTestGate()
        await port.blockKeyboardOwner(.user, on: userGate)

        let release = Task {
            await registry.releasePrepared(
                handle: handle,
                token: prepared.token,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while !(await port.keyboardOwnerTransitionsStarted().contains(.user)) {
            await Task.yield()
        }
        await #expect(throws: TerminalEndpointRegistryError.threadAlreadyPrepared) {
            _ = try await registry.prepareTurn(
                handle: AgentTurnHandle(threadID: threadID),
                token: TerminalEndpointBindingToken(),
                conversationKey: TerminalToolFixtures.key
            )
        }
        #expect(await port.keyboardOwners() == [.codex])

        await userGate.open()
        await release.value
        await port.blockKeyboardOwner(.user, on: nil)
        _ = try await registry.prepareTurn(
            handle: AgentTurnHandle(threadID: threadID),
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        #expect(await port.keyboardOwners() == [.codex, .user, .codex])
    }

    @Test("unregister serializes pin loss cleanup behind preparing ownership")
    func unregisterWhilePreparingIsSerialized() async throws {
        let registry = TerminalEndpointRegistry()
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        let endpointID = TerminalEndpointID(rawValue: TerminalToolFixtures.newID())
        let codexGate = TerminalToolTestGate()
        await port.blockKeyboardOwner(.codex, on: codexGate)
        let endpoint = TerminalToolFixtures.endpoint(
            id: endpointID.rawValue,
            port: port,
            controller: surfaces
        )
        try await registry.register(endpoint)
        let threadID = AgentThreadID(rawValue: "unregister-preparing")
        let handle = AgentTurnHandle(threadID: threadID)
        let token = TerminalEndpointBindingToken()
        let prepare = Task {
            try await registry.prepareTurn(
                handle: handle,
                token: token,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while await port.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }

        let unregister = Task { await registry.unregister(endpointID) }
        for _ in 0..<100 { await Task.yield() }
        await #expect(throws: TerminalEndpointRegistryError.threadAlreadyPrepared) {
            _ = try await registry.prepareTurn(
                handle: AgentTurnHandle(threadID: threadID),
                token: TerminalEndpointBindingToken(),
                conversationKey: TerminalToolFixtures.key
            )
        }
        #expect(await port.keyboardOwnerTransitionsStarted() == [.codex])

        await codexGate.open()
        await unregister.value
        await #expect(throws: TerminalEndpointRegistryError.pinLost) {
            _ = try await prepare.value
        }
        #expect(await port.keyboardOwners() == [.codex, .user])

        await port.blockKeyboardOwner(.codex, on: nil)
        try await registry.register(endpoint)
        _ = try await registry.prepareTurn(
            handle: AgentTurnHandle(threadID: threadID),
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        #expect(await port.keyboardOwners() == [.codex, .user, .codex])
    }

    @Test("keyboard transitions on different endpoints remain parallel")
    func differentEndpointsRemainParallel() async throws {
        let registry = TerminalEndpointRegistry()
        let firstPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let secondPort = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1)
        )
        let firstGate = TerminalToolTestGate()
        await firstPort.blockKeyboardOwner(.codex, on: firstGate)
        let firstKey = TerminalToolFixtures.key
        let secondIdentity = TmuxSessionIdentity(
            serverSessionID: "$parallel",
            createdAtEpoch: 123
        )
        let secondKey = TerminalConversationKey(
            target: .local,
            tmux: secondIdentity
        )
        let secondRoute = TmuxRoute(
            target: .local,
            sessionName: "parallel",
            expectedIdentity: secondIdentity
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                key: firstKey,
                port: firstPort,
                controller: FakeTerminalSurfaceController(
                    surface: TerminalToolFixtures.surface()
                )
            )
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: TerminalToolFixtures.newID(),
                key: secondKey,
                port: secondPort,
                controller: FakeTerminalSurfaceController(
                    surface: TmuxSurface(
                        sessionIdentity: secondIdentity,
                        windowID: "@2",
                        paneID: "%2",
                        currentCommand: "zsh"
                    )
                ),
                route: secondRoute
            )
        )
        let firstPrepare = Task {
            try await registry.prepareTurn(
                handle: AgentTurnHandle(
                    threadID: AgentThreadID(rawValue: "parallel-first")
                ),
                token: TerminalEndpointBindingToken(),
                conversationKey: firstKey
            )
        }
        while await firstPort.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }

        _ = try await registry.prepareTurn(
            handle: AgentTurnHandle(
                threadID: AgentThreadID(rawValue: "parallel-second")
            ),
            token: TerminalEndpointBindingToken(),
            conversationKey: secondKey
        )
        #expect(await secondPort.keyboardOwners() == [.codex])
        #expect(await firstPort.keyboardOwners().isEmpty)

        await firstGate.open()
        _ = try await firstPrepare.value
    }

    @Test("endpoint churn leaves no keyboard transition or ownership tombstones")
    func endpointChurnPrunesTransientState() async throws {
        let registry = TerminalEndpointRegistry()
        let subscription = await registry.subscribe()
        var iterator = subscription.events.makeAsyncIterator()
        var events: [TerminalEndpointRegistryEvent] = []
        for index in 0..<25 {
            let port = FakeTerminalToolPort(
                snapshot: TerminalToolFixtures.screen(revision: UInt64(index))
            )
            let endpointID = TerminalEndpointID(
                rawValue: TerminalToolFixtures.newID()
            )
            try await registry.register(
                TerminalToolFixtures.endpoint(
                    id: endpointID.rawValue,
                    port: port,
                    controller: FakeTerminalSurfaceController(
                        surface: TerminalToolFixtures.surface()
                    )
                )
            )
            let threadID = AgentThreadID(rawValue: "churn-\(index)")
            _ = try await registry.prepareTurn(
                handle: AgentTurnHandle(threadID: threadID),
                token: TerminalEndpointBindingToken(),
                conversationKey: TerminalToolFixtures.key
            )
            await registry.unregister(endpointID)
            if let event = await iterator.next() {
                events.append(event)
            }
        }

        #expect(events.count == 25)
        #expect(events.allSatisfy { event in
            guard case let .pinLost(loss, _) = event else { return false }
            return loss.phase == .prepared && loss.turnID == nil
        })
        #expect(events.map(\.revision) == Array(1...25).map(UInt64.init))
        let snapshot = await registry.testingStateSnapshot()
        #expect(snapshot.endpointCount == 0)
        #expect(snapshot.bindingCount == 0)
        #expect(snapshot.conversationOwnerCount == 0)
        #expect(snapshot.keyboardTransitionCount == 0)
        #expect(snapshot.pinLossHistoryCount == 0)
        #expect(snapshot.retiringEndpointCount == 0)
    }

    @Test("slow event subscribers receive bounded overflow reconciliation")
    func slowSubscriberReceivesOverflowReconciliation() async throws {
        let registry = TerminalEndpointRegistry()
        let subscription = await registry.subscribe()

        for index in 0..<5 {
            let endpointID = TerminalEndpointID(
                rawValue: TerminalToolFixtures.newID()
            )
            try await registry.register(
                TerminalToolFixtures.endpoint(
                    id: endpointID.rawValue,
                    port: FakeTerminalToolPort(
                        snapshot: TerminalToolFixtures.screen(
                            revision: UInt64(index)
                        )
                    ),
                    controller: FakeTerminalSurfaceController(
                        surface: TerminalToolFixtures.surface()
                    )
                )
            )
            _ = try await registry.prepareTurn(
                handle: AgentTurnHandle(
                    threadID: AgentThreadID(rawValue: "slow-\(index)")
                ),
                token: TerminalEndpointBindingToken(),
                conversationKey: TerminalToolFixtures.key
            )
            await registry.unregister(endpointID)
        }

        var iterator = subscription.events.makeAsyncIterator()
        guard case let .reconciliationRequired(revision) = await iterator.next()
        else {
            Issue.record("expected overflow reconciliation")
            return
        }
        #expect(revision > subscription.snapshot.revision)
        let snapshot = await registry.testingStateSnapshot()
        #expect(snapshot.eventSubscriberCount == 1)
        #expect(snapshot.eventBufferCapacity == 1)
        #expect(snapshot.bindingCount == 0)
        #expect(snapshot.conversationOwnerCount == 0)
        #expect(snapshot.pinLossHistoryCount == 0)
    }

    @Test("subscription atomically snapshots exact pins before later loss events")
    func subscriptionAtomicallySnapshotsExactPins() async throws {
        let registry = TerminalEndpointRegistry()
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1601)
                ),
                controller: FakeTerminalSurfaceController(
                    surface: TerminalToolFixtures.surface()
                )
            )
        )
        let handle = AgentTurnHandle(
            threadID: AgentThreadID(rawValue: "atomic-subscription")
        )
        let turnID = AgentTurnID(rawValue: "atomic-turn")
        let prepared = try await registry.prepareTurn(
            handle: handle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.claimPreparedTurn(
            handle: handle,
            token: prepared.token,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        let expectedPin = TerminalEndpointPin(
            handle: handle,
            bindingToken: prepared.token,
            turnID: turnID,
            phase: .active,
            conversationKey: TerminalToolFixtures.key,
            endpointID: endpointID
        )

        let subscription = await registry.subscribe()
        #expect(subscription.snapshot.pins == [expectedPin])
        let eventTask = Task {
            var iterator = subscription.events.makeAsyncIterator()
            return await iterator.next()
        }

        await registry.unregister(endpointID)

        guard case let .pinLost(loss, revision) = await eventTask.value else {
            Issue.record("expected exact pin-loss event")
            return
        }
        #expect(loss.pin == expectedPin)
        #expect(revision > subscription.snapshot.revision)
        let reconciled = await registry.pinSnapshot()
        #expect(reconciled.revision == revision)
        #expect(reconciled.pins.isEmpty)
    }

    @Test("subscription after unregister publication starts from reconciled state")
    func subscriptionAfterUnregisterPublicationHasNoGap() async throws {
        let registry = TerminalEndpointRegistry()
        let endpointID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        let port = FakeTerminalToolPort(
            snapshot: TerminalToolFixtures.screen(revision: 1604)
        )
        let userGate = TerminalToolTestGate()
        await port.blockKeyboardOwner(.user, on: userGate)
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: endpointID.rawValue,
                port: port,
                controller: FakeTerminalSurfaceController(
                    surface: TerminalToolFixtures.surface()
                )
            )
        )
        _ = try await registry.prepareTurn(
            handle: AgentTurnHandle(
                threadID: AgentThreadID(rawValue: "unregister-first")
            ),
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        let unregister = Task { await registry.unregister(endpointID) }
        while !(
            await port.keyboardOwnerTransitionsStarted().contains(.user)
        ) {
            await Task.yield()
        }

        let subscription = await registry.subscribe()
        #expect(subscription.snapshot.revision == 1)
        #expect(subscription.snapshot.pins.isEmpty)

        await userGate.open()
        await unregister.value
    }

    @Test("overflow reconciliation snapshots all current exact pins")
    func overflowReconciliationSnapshotsCurrentExactPins() async throws {
        let registry = TerminalEndpointRegistry()
        let firstID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        let secondID = TerminalEndpointID(
            rawValue: TerminalToolFixtures.newID()
        )
        let secondIdentity = TmuxSessionIdentity(
            serverSessionID: "$overflow-second",
            createdAtEpoch: 1_602
        )
        let secondKey = TerminalConversationKey(
            target: .local,
            tmux: secondIdentity
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: firstID.rawValue,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1602)
                ),
                controller: FakeTerminalSurfaceController(
                    surface: TerminalToolFixtures.surface()
                )
            )
        )
        try await registry.register(
            TerminalToolFixtures.endpoint(
                id: secondID.rawValue,
                key: secondKey,
                port: FakeTerminalToolPort(
                    snapshot: TerminalToolFixtures.screen(revision: 1603)
                ),
                controller: FakeTerminalSurfaceController(
                    surface: TmuxSurface(
                        sessionIdentity: secondIdentity,
                        windowID: "@overflow",
                        paneID: "%overflow",
                        currentCommand: "zsh"
                    )
                ),
                route: TmuxRoute(
                    target: .local,
                    sessionName: "overflow-second",
                    expectedIdentity: secondIdentity
                )
            )
        )
        let firstHandle = AgentTurnHandle(
            threadID: AgentThreadID(rawValue: "overflow-first")
        )
        let secondHandle = AgentTurnHandle(
            threadID: AgentThreadID(rawValue: "overflow-second")
        )
        let first = try await registry.prepareTurn(
            handle: firstHandle,
            token: TerminalEndpointBindingToken(),
            conversationKey: TerminalToolFixtures.key
        )
        let second = try await registry.prepareTurn(
            handle: secondHandle,
            token: TerminalEndpointBindingToken(),
            conversationKey: secondKey
        )
        let expectedPins: Set<TerminalEndpointPin> = [
            TerminalEndpointPin(
                handle: firstHandle,
                bindingToken: first.token,
                turnID: nil,
                phase: .prepared,
                conversationKey: TerminalToolFixtures.key,
                endpointID: firstID
            ),
            TerminalEndpointPin(
                handle: secondHandle,
                bindingToken: second.token,
                turnID: nil,
                phase: .prepared,
                conversationKey: secondKey,
                endpointID: secondID
            ),
        ]
        let subscription = await registry.subscribe()
        #expect(subscription.snapshot.pins == expectedPins)
        var consumerRevision = subscription.snapshot.revision
        var consumerPins = subscription.snapshot.pins

        await registry.unregister(firstID)
        await registry.unregister(secondID)

        var iterator = subscription.events.makeAsyncIterator()
        guard case let .reconciliationRequired(revision) = await iterator.next()
        else {
            Issue.record("expected bounded overflow reconciliation")
            return
        }
        guard revision > consumerRevision else {
            Issue.record("expected a newer reconciliation revision")
            return
        }
        let authoritative = await registry.pinSnapshot()
        let lostPins = consumerPins.subtracting(authoritative.pins)
        consumerPins = authoritative.pins
        consumerRevision = authoritative.revision

        #expect(consumerRevision == revision)
        #expect(lostPins == expectedPins)
        #expect(consumerPins.isEmpty)
    }

    @Test("cancelled subscriptions promptly release bounded subscriber state")
    func cancelledSubscriptionReleasesSubscriberState() async {
        let registry = TerminalEndpointRegistry()
        let subscription = await registry.subscribe()
        let consumer = Task {
            var iterator = subscription.events.makeAsyncIterator()
            _ = await iterator.next()
        }
        #expect(await registry.testingStateSnapshot().eventSubscriberCount == 1)

        consumer.cancel()
        await consumer.value
        for _ in 0..<100
        where await registry.testingStateSnapshot().eventSubscriberCount != 0
        {
            await Task.yield()
        }

        #expect(await registry.testingStateSnapshot().eventSubscriberCount == 0)
    }
}
