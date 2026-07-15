import Testing
@testable import MerlinLizdCore
@testable import MerlinLizdCodexAdapter

@Suite("Codex Dynamic Tools")
struct CodexDynamicToolsTests {
    @Test("terminal executor binds idempotently and rejects conflicting routes")
    func executorBindingIdentityIsExact() async throws {
        let router = TerminalToolRouter(
            registry: TerminalEndpointRegistry(),
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let executor = CodexTerminalToolExecutor(router: router)
        let threadID = AgentThreadID(rawValue: "thread")
        let otherThreadID = AgentThreadID(rawValue: "other")
        let handle = AgentTurnHandle(threadID: threadID)
        let conflictingHandle = AgentTurnHandle(threadID: threadID)
        let otherKey = TerminalConversationKey(
            target: .local,
            tmux: .init(serverSessionID: "$8", createdAtEpoch: 2)
        )

        await #expect(throws: CodexTerminalToolExecutorError.mismatchedThread) {
            try await executor.bindPreparedTurn(
                threadID: otherThreadID,
                handle: handle,
                conversationKey: TerminalToolFixtures.key
            )
        }
        try await executor.bindPreparedTurn(
            threadID: threadID,
            handle: handle,
            conversationKey: TerminalToolFixtures.key
        )
        try await executor.bindPreparedTurn(
            threadID: threadID,
            handle: handle,
            conversationKey: TerminalToolFixtures.key
        )
        await #expect(throws: CodexTerminalToolExecutorError.bindingExists) {
            try await executor.bindPreparedTurn(
                threadID: threadID,
                handle: conflictingHandle,
                conversationKey: TerminalToolFixtures.key
            )
        }
        await #expect(throws: CodexTerminalToolExecutorError.bindingExists) {
            try await executor.bindPreparedTurn(
                threadID: threadID,
                handle: handle,
                conversationKey: otherKey
            )
        }

        await executor.unbind(
            threadID: threadID,
            handle: conflictingHandle
        )
        await #expect(throws: TerminalToolRouterError.turnUnavailable) {
            try await executor.execute(
                threadID: threadID,
                turnID: .init(rawValue: "turn"),
                call: .observeScreen
            )
        }
        await executor.unbind(threadID: threadID, handle: handle)
        await #expect(
            throws: CodexTerminalToolExecutorError.bindingUnavailable
        ) {
            try await executor.execute(
                threadID: threadID,
                turnID: .init(rawValue: "turn"),
                call: .observeScreen
            )
        }
    }

    @Test("prepared tool requests activate one exact turn before confirmation")
    func executorRoutesPreparedToolRaceToExactTurn() async throws {
        let registry = TerminalEndpointRegistry()
        let screen = TerminalToolFixtures.screen(revision: 7)
        let port = FakeTerminalToolPort(snapshot: screen)
        let surfaces = FakeTerminalSurfaceController(
            surface: TerminalToolFixtures.surface()
        )
        try await registry.register(TerminalToolFixtures.endpoint(
            id: TerminalToolFixtures.newID(),
            port: port,
            controller: surfaces
        ))
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let executor = CodexTerminalToolExecutor(router: router)
        let threadID = AgentThreadID(rawValue: "thread")
        let turnID = AgentTurnID(rawValue: "turn-1")
        let handle = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        try await executor.bindPreparedTurn(
            threadID: threadID,
            handle: handle,
            conversationKey: TerminalToolFixtures.key
        )

        #expect(try await executor.execute(
            threadID: threadID,
            turnID: turnID,
            call: .observeScreen
        ) == .screen(screen))
        await #expect(throws: TerminalToolRouterError.turnUnavailable) {
            try await executor.execute(
                threadID: threadID,
                turnID: .init(rawValue: "turn-2"),
                call: .observeScreen
            )
        }

        try await router.endTurn(handle: handle, turnID: turnID)
        await executor.unbind(threadID: threadID, handle: handle)
    }

    @Test("catalog exposes exactly six closed tools in one namespace")
    func exactNamespacedCatalog() {
        let tools = CodexDynamicToolCatalog.tools
        #expect(tools.map(\.name) == [
            "observe_screen",
            "send_input",
            "wait_for_screen",
            "select_visible_surface",
            "create_temporary_pane",
            "finish_temporary_pane",
        ])
        #expect(tools.allSatisfy { $0.namespace == "merlin_tmux" })
        #expect(tools.allSatisfy {
            $0.description.contains("current visible pane")
                && $0.description.contains("Observe")
                && $0.description.contains("expected revision")
                && $0.description.contains("wait_for_screen")
                && $0.description.contains("hidden pane")
                && $0.description.contains("approval")
        })
        for tool in tools {
            guard case let .object(schema) = tool.inputSchema else {
                Issue.record("schema must be an object")
                continue
            }
            #expect(schema["type"] == .string("object"))
            #expect(schema["additionalProperties"] == .bool(false))
        }
    }

    @Test("all six wire calls decode into protocol-neutral Core values")
    func decodesTerminalCalls() throws {
        #expect(try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "observe_screen",
            arguments: .object([:])
        ) == .observeScreen)

        let send = try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "send_input",
            arguments: .object([
                "expectedRevision": .number(9),
                "events": .array([
                    .object(["type": .string("text"), "text": .string("ls")]),
                    .object([
                        "type": .string("key"),
                        "key": .string("enter"),
                        "modifiers": .array([]),
                    ]),
                ]),
                "purpose": .string("inspect visible files"),
                "declaredRisk": .string("routine"),
            ])
        )
        #expect(send == .sendInput(.init(
            expectedRevision: 9,
            events: [
                .text("ls"),
                .key(.enter, modifiers: []),
            ],
            purpose: "inspect visible files",
            declaredRisk: .routine
        )))

        #expect(try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "wait_for_screen",
            arguments: .object([
                "condition": .string("stable"),
                "afterRevision": .number(9),
                "stableMilliseconds": .number(250),
                "timeoutMilliseconds": .number(5_000),
            ])
        ) == .waitForScreen(.init(
            condition: .stable(after: 9, for: .milliseconds(250)),
            timeout: .seconds(5)
        )))

        #expect(try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "select_visible_surface",
            arguments: .object([
                "selection": .string("window_index"),
                "windowIndex": .number(3),
                "expectedRevision": .number(9),
            ])
        ) == .selectVisibleSurface(.windowIndex(3), expectedRevision: 9))

        #expect(try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "create_temporary_pane",
            arguments: .object(["expectedRevision": .number(9)])
        ) == .createTemporaryPane(expectedRevision: 9))

        let finish = try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "finish_temporary_pane",
            arguments: .object([
                "leaseId": .string("A80F963B-58B0-4C6C-B759-88F3196D8888"),
                "expectedRevision": .number(10),
            ])
        )
        guard case let .finishTemporaryPane(leaseID, revision) = finish else {
            Issue.record("finish call was not decoded")
            return
        }
        #expect(leaseID.uuidString == "A80F963B-58B0-4C6C-B759-88F3196D8888")
        #expect(revision == 10)
    }

    @Test("unknown and malformed calls fail closed before routing")
    func rejectsBeforeRouting() {
        #expect(throws: CodexDynamicToolError.unknownNamespace) {
            try CodexDynamicToolCatalog.decode(
                namespace: "shell",
                tool: "observe_screen",
                arguments: .object([:])
            )
        }
        #expect(throws: CodexDynamicToolError.unknownTool) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "shell",
                arguments: .object([:])
            )
        }
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "send_input",
                arguments: .object([
                    "expectedRevision": .number(1),
                    "events": .array([]),
                    "purpose": .string("empty batch"),
                    "declaredRisk": .string("routine"),
                ])
            )
        }
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "wait_for_screen",
                arguments: .object([
                    "condition": .string("changed"),
                    "afterRevision": .number(1),
                    "timeoutMilliseconds": .number(120_001),
                ])
            )
        }
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "create_temporary_pane",
                arguments: .object([
                    "expectedRevision": .number(9_007_199_254_740_992),
                ])
            )
        }
    }

    @Test("conditional optional keys accept only their valid combinations")
    func validatesConditionalOptionalKeys() throws {
        #expect(try CodexDynamicToolCatalog.decode(
            namespace: "merlin_tmux",
            tool: "wait_for_screen",
            arguments: .object([
                "condition": .string("changed"),
                "afterRevision": .number(4),
                "timeoutMilliseconds": .number(1_000),
            ])
        ) == .waitForScreen(.init(
            condition: .changed(after: 4),
            timeout: .seconds(1)
        )))
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "wait_for_screen",
                arguments: .object([
                    "condition": .string("stable"),
                    "afterRevision": .number(4),
                    "timeoutMilliseconds": .number(1_000),
                ])
            )
        }

        for (selection, expected) in [
            ("next_window", TmuxVisibleSelection.nextWindow),
            ("previous_window", .previousWindow),
            ("pane_left", .paneLeft),
            ("pane_right", .paneRight),
            ("pane_up", .paneUp),
            ("pane_down", .paneDown),
            ("next_pane", .nextPane),
            ("previous_pane", .previousPane),
        ] {
            #expect(try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "select_visible_surface",
                arguments: .object([
                    "selection": .string(selection),
                    "expectedRevision": .number(8),
                ])
            ) == .selectVisibleSurface(expected, expectedRevision: 8))
        }
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "select_visible_surface",
                arguments: .object([
                    "selection": .string("next_window"),
                    "windowIndex": .number(2),
                    "expectedRevision": .number(8),
                ])
            )
        }
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "select_visible_surface",
                arguments: .object([
                    "selection": .string("window_index"),
                    "expectedRevision": .number(8),
                ])
            )
        }
        #expect(throws: CodexDynamicToolError.invalidArguments) {
            try CodexDynamicToolCatalog.decode(
                namespace: "merlin_tmux",
                tool: "select_visible_surface",
                arguments: .object([
                    "selection": .string("next_window"),
                    "expectedRevision": .number(8),
                    "future": .bool(true),
                ])
            )
        }
    }

    @Test("tool responses contain one inputText and never expose raw errors")
    func neutralResponses() throws {
        let snapshot = TerminalScreenSnapshot(
            revision: 12,
            columns: 80,
            rows: 24,
            cursor: .init(row: 0, column: 2, isVisible: true),
            mode: .normal,
            text: "$ ",
            significantRuns: [],
            changedRows: [0]
        )
        let success = try CodexDynamicToolCatalog.response(
            for: .screen(snapshot)
        )
        guard case let .object(successFields) = success,
            case let .array(items)? = successFields["contentItems"],
            case let .object(item) = items.first
        else {
            Issue.record("missing inputText response")
            return
        }
        #expect(successFields["success"] == .bool(true))
        #expect(item["type"] == .string("inputText"))
        #expect(item["text"] != nil)

        let failure = CodexDynamicToolCatalog.failureResponse(
            for: PrivateFixtureError(secret: "sk-live-private")
        )
        #expect(String(describing: failure).contains("sk-live-private") == false)
        #expect(String(describing: failure).contains("PrivateFixtureError") == false)
    }
}

private struct PrivateFixtureError: Error {
    let secret: String
}
