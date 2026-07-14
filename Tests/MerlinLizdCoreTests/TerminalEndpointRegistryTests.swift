import Testing
@testable import MerlinLizdCore

@Suite("Terminal endpoint registry", .serialized)
struct TerminalEndpointRegistryTests {
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
        let prepared = try await registry.prepareTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        #expect(prepared.endpoint.id.rawValue == secondID)

        try await registry.focus(TerminalEndpointID(rawValue: firstID))
        let turnID = AgentTurnID(rawValue: "turn-1")
        let claimed = try await registry.claimPreparedTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        #expect(claimed.endpoint.id.rawValue == secondID)
        try await registry.confirmTurnID(
            threadID: threadID,
            turnID: turnID
        )

        await #expect(throws: TerminalEndpointRegistryError.turnIDMismatch) {
            try await registry.confirmTurnID(
                threadID: threadID,
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
        let turnID = AgentTurnID(rawValue: "turn-loss")
        _ = try await registry.prepareTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.claimPreparedTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )

        await registry.unregister(endpointID)

        #expect(
            await registry.pinLossEvents() == [
                TerminalEndpointPinLoss(
                    threadID: threadID,
                    turnID: turnID,
                    phase: .active,
                    conversationKey: TerminalToolFixtures.key,
                    endpointID: endpointID
                )
            ]
        )
        await #expect(throws: TerminalEndpointRegistryError.pinLost) {
            try await registry.binding(
                threadID: threadID,
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
        let turnID = AgentTurnID(rawValue: "turn-event")
        _ = try await registry.prepareTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.claimPreparedTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key,
            turnID: turnID
        )
        let stream = await registry.events()
        let eventTask = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await registry.unregister(endpointID)

        #expect(
            await eventTask.value == .pinLost(
                TerminalEndpointPinLoss(
                    threadID: threadID,
                    turnID: turnID,
                    phase: .active,
                    conversationKey: TerminalToolFixtures.key,
                    endpointID: endpointID
                )
            )
        )
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
                threadID: AgentThreadID(rawValue: "route-mismatch"),
                conversationKey: TerminalToolFixtures.key
            )
        }
        #expect(await port.keyboardOwners().isEmpty)
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
        _ = try await registry.prepareTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )

        await registry.releaseTurn(
            threadID: threadID,
            turnID: AgentTurnID(rawValue: "unrelated")
        )

        _ = try await registry.claimPreparedTurn(
            threadID: threadID,
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
        _ = try await registry.prepareTurn(
            threadID: threadID,
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
            threadID: threadID,
            conversationKey: otherKey
        )
        await #expect(throws: TerminalEndpointRegistryError.threadAlreadyPrepared) {
            try await registry.prepareTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        await registry.releasePrepared(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        _ = try await registry.prepareTurn(
            threadID: threadID,
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
        _ = try await registry.prepareTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let stream = await registry.events()
        let eventTask = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await registry.unregister(endpointID)

        let expected = TerminalEndpointPinLoss(
            threadID: threadID,
            turnID: nil,
            phase: .prepared,
            conversationKey: TerminalToolFixtures.key,
            endpointID: endpointID
        )
        #expect(
            await registry.pinLossEvents() == [
                expected
            ]
        )
        #expect(await eventTask.value == .pinLost(expected))
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
        let prepare = Task {
            try await registry.prepareTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while await port.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }

        let release = Task {
            await registry.releasePrepared(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        let replacementProbe = TerminalRegistryCompletionProbe()
        let replacement = Task {
            do {
                _ = try await registry.prepareTurn(
                    threadID: threadID,
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
        _ = try await registry.prepareTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let userGate = TerminalToolTestGate()
        await port.blockKeyboardOwner(.user, on: userGate)

        let release = Task {
            await registry.releasePrepared(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        while !(await port.keyboardOwnerTransitionsStarted().contains(.user)) {
            await Task.yield()
        }
        await #expect(throws: TerminalEndpointRegistryError.threadAlreadyPrepared) {
            _ = try await registry.prepareTurn(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
        }
        #expect(await port.keyboardOwners() == [.codex])

        await userGate.open()
        await release.value
        await port.blockKeyboardOwner(.user, on: nil)
        _ = try await registry.prepareTurn(
            threadID: threadID,
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
        let prepare = Task {
            try await registry.prepareTurn(
                threadID: threadID,
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
                threadID: threadID,
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
            threadID: threadID,
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
                threadID: AgentThreadID(rawValue: "parallel-first"),
                conversationKey: firstKey
            )
        }
        while await firstPort.keyboardOwnerTransitionsStarted().isEmpty {
            await Task.yield()
        }

        _ = try await registry.prepareTurn(
            threadID: AgentThreadID(rawValue: "parallel-second"),
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
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
            await registry.releasePrepared(
                threadID: threadID,
                conversationKey: TerminalToolFixtures.key
            )
            await registry.unregister(endpointID)
        }

        let snapshot = await registry.testingStateSnapshot()
        #expect(snapshot.endpointCount == 0)
        #expect(snapshot.bindingCount == 0)
        #expect(snapshot.conversationOwnerCount == 0)
        #expect(snapshot.keyboardTransitionCount == 0)
    }
}
