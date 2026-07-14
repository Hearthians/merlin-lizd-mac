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
        await registry.register(
            TerminalToolFixtures.endpoint(
                id: firstID,
                port: firstPort,
                controller: firstSurface
            )
        )
        await registry.register(
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
        await registry.register(
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
        await registry.register(
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
                    conversationKey: TerminalToolFixtures.key,
                    endpointID: endpointID
                )
            )
        )
    }
}
