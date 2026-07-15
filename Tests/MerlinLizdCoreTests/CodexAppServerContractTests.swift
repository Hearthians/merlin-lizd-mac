import Darwin
import Testing
@testable import MerlinLizdCore
@testable import MerlinLizdCodexAdapter

@Suite("Codex app-server 0.144.2 contract", .serialized)
struct CodexAppServerContractTests {
    @Test("initialize is acknowledged before any thread request")
    func sendsInitializedBeforeReady() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )

        let starting = Task { try await adapter.startThread() }
        await process.waitForWriteCount(1)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":1,"result":{"codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-cli/0.144.2"}}"#
        )))
        await process.waitForWriteCount(2)
        let initialized = try jsonObject(from: await process.writtenData()[1])
        #expect(Set(initialized.keys) == ["method"])
        #expect(initialized["method"] as? String == "initialized")
        guard initialized["method"] as? String == "initialized" else {
            starting.cancel()
            await adapter.shutdown()
            return
        }

        await process.waitForWriteCount(3)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        )))
        #expect(try await starting.value == .init(rawValue: "thread-1"))
        await adapter.shutdown()
    }

    @Test("failed initialized notification leaves the adapter unavailable")
    func initializedWriteFailureFailsStartup() async throws {
        let process = ScriptedAppServerProcess(failWriteAt: 2)
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )

        let starting = Task { try await adapter.startThread() }
        await process.waitForWriteCount(1)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":1,"result":{"codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-cli/0.144.2"}}"#
        )))

        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await starting.value
        }
        #expect(await adapter.availabilityForTesting == .crashed)
        #expect((await process.writtenData()).count == 1)
        await adapter.shutdown()
    }

    @Test("checked-in fixtures cover the complete frozen V1 method surface")
    func fixtureCoverage() throws {
        let initialize = try fixtureText("initialize")
        let thread = try fixtureText("thread-start-resume")
        let turn = try fixtureText("turn-stream")
        let dynamic = try fixtureText("dynamic-tools")
        let errors = try fixtureText("errors")
        #expect(initialize.contains(#"{"method":"initialized"}"#))
        for fixture in [initialize, thread, turn, dynamic, errors] {
            for line in fixture.split(separator: "\n") {
                let object = try jsonObject(from: testData(String(line)))
                #expect(object["jsonrpc"] == nil)
            }
        }
        for method in [
            "thread/start", "thread/resume", "thread/archive",
            "thread/unarchive", "thread/delete", "turn/start",
            "turn/steer", "turn/interrupt", "item/agentMessage/delta",
            "turn/completed",
        ] {
            #expect((thread + turn).contains(#""method":"\#(method)""#))
        }
        #expect(dynamic.contains(#""method":"item/tool/call""#))
        for field in ["arguments", "callId", "threadId", "tool", "turnId"] {
            #expect(dynamic.contains(#""\#(field)":"#))
        }
        #expect(dynamic.contains(#""namespace":"merlin_tmux""#))
        #expect(dynamic.contains(#""contentItems":[{"type":"inputText""#))
        #expect(dynamic.contains(#""success":true"#))
        #expect(errors.contains(#""method":"future/unknown""#))
        #expect(errors.contains(#""codexErrorInfo":"serverOverloaded""#))
        #expect(errors.contains(#""codexErrorInfo":"unauthorized""#))
        #expect(errors.contains(#""threadId":17"#))
        #expect(errors.contains(#""willRetry":false"#))
        #expect(errors.contains(#""fixture":"processCrash""#))

        let threadStart = try jsonObject(from: testData(String(
            try #require(thread.split(separator: "\n").first)
        )))
        let params = try #require(threadStart["params"] as? [String: Any])
        let namespaces = try #require(params["dynamicTools"] as? [[String: Any]])
        #expect(namespaces.count == 1)
        #expect((namespaces[0]["description"] as? String)?.isEmpty == false)
        let fixtureTools = try #require(
            namespaces[0]["tools"] as? [[String: Any]]
        )
        #expect(fixtureTools.compactMap { $0["name"] as? String } ==
            CodexDynamicToolCatalog.tools.map(\.name))
        #expect(fixtureTools.allSatisfy {
            $0["type"] as? String == "function"
                && ($0["description"] as? String)?.isEmpty == false
                && $0["inputSchema"] != nil
        })
        #expect(dynamic.contains(#""type":"dynamicToolCall""#))
    }

    @Test("turn and thread lifecycle methods use only frozen request fields")
    func lifecycleRequestsAreContained() async throws {
        let process = ScriptedAppServerProcess()
        let executor = RecordingCodexToolExecutor()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )

        let turnStart = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "hello")
        }
        await process.waitForWriteCount(4)
        let racingToolResult = try await adapter.handleServerRequestForTesting(
            method: "item/tool/call",
            params: .object([
                "arguments": .object([:]),
                "callId": .string("racing-call"),
                "threadId": .string(threadID.rawValue),
                "tool": .string("observe_screen"),
                "turnId": .string("turn-1"),
                "namespace": .string("merlin_tmux"),
            ])
        )
        guard case let .object(racingFields) = racingToolResult else {
            Issue.record("racing tool call did not return an object")
            return
        }
        #expect(racingFields["success"] == .bool(true))
        #expect(await executor.calls == [.observeScreen])
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#
        )))
        let turnID = try await turnStart.value

        let steer = Task {
            try await adapter.steerTurn(
                threadID: threadID,
                turnID: turnID,
                prompt: "more"
            )
        }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"turnId":"turn-1"}}"#
        )))
        try await steer.value

        let interrupt = Task {
            await adapter.interruptTurn(threadID: threadID, turnID: turnID)
        }
        await process.waitForWriteCount(6)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":5,"result":{}}"#
        )))
        await interrupt.value

        let archive = Task { try await adapter.archiveThread(threadID) }
        await process.waitForWriteCount(7)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":6,"result":{}}"#
        )))
        try await archive.value

        let unarchive = Task { try await adapter.unarchiveThread(threadID) }
        await process.waitForWriteCount(8)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":7,"result":{}}"#
        )))
        try await unarchive.value

        let delete = Task { try await adapter.deleteThread(threadID) }
        await process.waitForWriteCount(9)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":8,"result":{}}"#
        )))
        try await delete.value

        let writes = await process.writtenData()
        let allMessages = try writes.map(jsonObject)
        #expect(allMessages.compactMap { $0["method"] as? String } == [
            "initialize", "initialized", "thread/start", "turn/start",
            "turn/steer", "turn/interrupt", "thread/archive",
            "thread/unarchive", "thread/delete",
        ])
        let requests = allMessages.filter { $0["id"] != nil }
        #expect(requests.compactMap { $0["method"] as? String } == [
            "initialize", "thread/start", "turn/start", "turn/steer",
            "turn/interrupt", "thread/archive", "thread/unarchive",
            "thread/delete",
        ])
        for request in requests.dropFirst() {
            let params = request["params"] as! [String: Any]
            #expect(params["model"] == nil)
            #expect(params["shell"] == nil)
        }
        let startParams = requests[2]["params"] as! [String: Any]
        #expect(startParams["threadId"] as? String == "thread-1")
        #expect(startParams["input"] != nil)
        let steerParams = requests[3]["params"] as! [String: Any]
        #expect(steerParams["turnId"] as? String == "turn-1")
        #expect(steerParams["input"] != nil)

        await #expect(throws: CodexAppServerAdapterError.unmappedThread) {
            try await adapter.resumeThread(threadID)
        }
        await adapter.shutdown()
    }

    @Test("retryable errors keep the exact turn active for later output")
    func retryableErrorDoesNotTerminateTurn() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let turnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "retry-turn",
            requestID: 3,
            writeCount: 4
        )
        let beforeRetry = await adapter.replayedEventsForTesting(threadID)

        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "error": .object([
                    "message": .string("private transient diagnostic"),
                    "codexErrorInfo": .string("serverOverloaded"),
                ]),
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "willRetry": .bool(true),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == beforeRetry)

        await adapter.handleNotificationForTesting(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "delta": .string("continued"),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string(turnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID).suffix(2) == [
            .assistantMessageDelta("continued"),
            .turnCompleted(turnID),
        ])

        await adapter.consumerFailedForTesting()
        #expect(await adapter.replayedEventsForTesting(threadID).last ==
            .turnCompleted(turnID))
        #expect(String(describing: await adapter.replayedEventsForTesting(threadID))
            .contains("private transient diagnostic") == false)
        await adapter.shutdown()
    }

    @Test("final errors fail only the exact active turn once")
    func finalErrorRequiresExactActiveTurn() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let turnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "exact-error-turn",
            requestID: 3,
            writeCount: 4
        )
        let before = await adapter.replayedEventsForTesting(threadID)

        for (wrongThread, wrongTurn) in [
            (threadID.rawValue, "wrong-turn"),
            ("wrong-thread", turnID.rawValue),
        ] {
            await adapter.handleNotificationForTesting(
                method: "error",
                params: .object([
                    "error": .object([
                        "message": .string("private wrong identity"),
                        "codexErrorInfo": .string("unauthorized"),
                    ]),
                    "threadId": .string(wrongThread),
                    "turnId": .string(wrongTurn),
                    "willRetry": .bool(false),
                ])
            )
        }
        #expect(await adapter.availabilityForTesting == .ready)
        #expect(await adapter.replayedEventsForTesting(threadID) == before)

        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "error": .object([
                    "message": .string("private overload diagnostic"),
                    "codexErrorInfo": .string("serverOverloaded"),
                ]),
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "willRetry": .bool(false),
            ])
        )
        let afterFinal = await adapter.replayedEventsForTesting(threadID)
        #expect(afterFinal.last == .turnFailed(turnID, .overloaded))
        #expect(await adapter.availabilityForTesting == .overloaded)

        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "error": .object([
                    "message": .string("private duplicate diagnostic"),
                    "codexErrorInfo": .string("unauthorized"),
                ]),
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "willRetry": .bool(false),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == afterFinal)
        #expect(await adapter.availabilityForTesting == .overloaded)
        await adapter.shutdown()
    }

    @Test("process crash fails active turns but leaves idle threads untouched")
    func crashFailsOnlyActiveTurnsOnce() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let activeThreadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let idleStarting = Task { try await adapter.startThread() }
        await process.waitForWriteCount(4)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"thread":{"id":"idle-thread"}}}"#
        )))
        let idleThreadID = try await idleStarting.value

        let archiving = Task { try await adapter.archiveThread(idleThreadID) }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{}}"#
        )))
        try await archiving.value
        let resuming = Task { try await adapter.resumeThread(idleThreadID) }
        await process.waitForWriteCount(6)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":5,"result":{"thread":{"id":"idle-thread","turns":[]}}}"#
        )))
        try await resuming.value

        let turnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: activeThreadID,
            turnID: "crash-turn",
            requestID: 6,
            writeCount: 7
        )

        await adapter.consumerFailedForTesting()
        let afterCrash = await adapter.replayedEventsForTesting(activeThreadID)
        #expect(afterCrash.last == .turnFailed(turnID, .crashed))
        #expect(await adapter.replayedEventsForTesting(idleThreadID) == [
            .history([]),
        ])
        await adapter.consumerFailedForTesting()
        #expect(await adapter.replayedEventsForTesting(activeThreadID) ==
            afterCrash)

        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(activeThreadID.rawValue),
                "turn": .object([
                    "id": .string(turnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(activeThreadID) ==
            afterCrash)
        await adapter.shutdown()
    }

    @Test("late terminal events cannot clear a newer active turn")
    func staleCompletionDoesNotClearNewTurn() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let oldTurnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "old-turn",
            requestID: 3,
            writeCount: 4
        )
        let newTurnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "new-turn",
            requestID: 4,
            writeCount: 5
        )
        let beforeStale = await adapter.replayedEventsForTesting(threadID)

        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string(oldTurnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == beforeStale)

        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string(newTurnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID).last ==
            .turnCompleted(newTurnID))
        await adapter.shutdown()
    }

    @Test("missing empty and unknown terminal status fail the exact turn")
    func terminalStatusIsRequiredAndClosed() async throws {
        for status in [JSONValue?.none, .some(.string("")), .some(.string("future"))] {
            let process = ScriptedAppServerProcess()
            let adapter = CodexAppServerAdapter(
                transport: JSONLAppServerTransport(process: process),
                launchConfiguration: testLaunchConfiguration(),
                toolExecutor: RecordingCodexToolExecutor()
            )
            let threadID = try await startMappedThread(
                adapter: adapter,
                process: process
            )
            let turnID = try await startMappedTurn(
                adapter: adapter,
                process: process,
                threadID: threadID,
                turnID: "status-turn",
                requestID: 3,
                writeCount: 4
            )
            var turn: [String: JSONValue] = ["id": .string(turnID.rawValue)]
            if let status { turn["status"] = status }

            await adapter.handleNotificationForTesting(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turn": .object(turn),
                ])
            )
            let failed = await adapter.replayedEventsForTesting(threadID)
            #expect(failed.last == .turnFailed(turnID, .protocolFailure))
            #expect(failed.contains(.turnCompleted(turnID)) == false)

            await adapter.handleNotificationForTesting(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turn": .object([
                        "id": .string(turnID.rawValue),
                        "status": .string("completed"),
                    ]),
                ])
            )
            await adapter.consumerFailedForTesting()
            #expect(await adapter.replayedEventsForTesting(threadID) == failed)
            await adapter.shutdown()
        }
    }

    @Test("all stale turn notifications are ignored before decoding content")
    func staleTurnNotificationsCannotPolluteSuccessor() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let oldTurnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "old-owned-turn",
            requestID: 3,
            writeCount: 4
        )
        let newTurnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "new-owned-turn",
            requestID: 4,
            writeCount: 5
        )
        let before = await adapter.replayedEventsForTesting(threadID)

        await adapter.handleNotificationForTesting(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(oldTurnID.rawValue),
                "delta": .string("stale secret"),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(oldTurnID.rawValue),
                "item": .object([
                    "type": .string("agentMessage"),
                    "text": .string("stale completed secret"),
                ]),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object(["id": .string(oldTurnID.rawValue)]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == before)

        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string(newTurnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID).last ==
            .turnCompleted(newTurnID))
        await adapter.shutdown()
    }

    @Test("unknown thread notification floods do not allocate replay state")
    func unknownThreadFloodDoesNotGrowState() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        let before = await adapter.stateCountsForTesting
        for index in 0..<1_000 {
            await adapter.handleNotificationForTesting(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string("random-\(index)"),
                    "turnId": .string("turn-\(index)"),
                    "delta": .string("private"),
                ])
            )
        }
        #expect(await adapter.stateCountsForTesting == before)
        await adapter.shutdown()
    }

    @Test("turn start buffers exact notifications until ownership is installed")
    func startTurnReplaysExactBufferedNotifications() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "buffer me")
        }
        await process.waitForWriteCount(4)
        await adapter.handleNotificationForTesting(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("buffered-turn"),
                "delta": .string("early"),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string("buffered-turn"),
                    "status": .string("completed"),
                ]),
            ])
        )
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"buffered-turn"}}}"#
        )))
        let turnID = try await starting.value
        #expect(await adapter.replayedEventsForTesting(threadID) == [
            .userMessage("buffer me"),
            .turnStarted(turnID),
            .assistantMessageDelta("early"),
            .turnCompleted(turnID),
        ])
        await adapter.shutdown()
    }

    @Test("concurrent starts cannot replace the pending start owner")
    func concurrentStartsFailClosed() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let first = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "first")
        }
        await process.waitForWriteCount(4)
        await #expect(throws: CodexAppServerAdapterError.turnAlreadyStarting) {
            try await adapter.startTurn(threadID: threadID, prompt: "second")
        }
        #expect((await process.writtenData()).count == 4)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"first-turn"}}}"#
        )))
        #expect(try await first.value == .init(rawValue: "first-turn"))
        await adapter.shutdown()
    }

    @Test("pending start replays only the returned turn and preserves early errors")
    func pendingStartFiltersWrongTurnsAndReplaysErrors() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "own it")
        }
        await process.waitForWriteCount(4)
        await adapter.handleNotificationForTesting(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("wrong-turn"),
                "delta": .string("must be dropped"),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("owned-turn"),
                "willRetry": .bool(false),
                "error": .object([
                    "message": .string("private authentication detail"),
                    "codexErrorInfo": .string("unauthorized"),
                ]),
            ])
        )
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"owned-turn"}}}"#
        )))
        let turnID = try await starting.value
        #expect(await adapter.replayedEventsForTesting(threadID) == [
            .userMessage("own it"),
            .turnStarted(turnID),
            .turnFailed(turnID, .authenticationRequired),
        ])
        #expect(await adapter.availabilityForTesting == .authenticationRequired)
        #expect(String(describing: await adapter.replayedEventsForTesting(threadID))
            .contains("private authentication detail") == false)
        await adapter.shutdown()
    }

    @Test("malformed terminal buffered before start response fails closed")
    func pendingStartBuffersMalformedTerminalEvent() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "malformed")
        }
        await process.waitForWriteCount(4)
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object(["id": .string("malformed-turn")]),
            ])
        )
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"malformed-turn"}}}"#
        )))
        let turnID = try await starting.value
        #expect(await adapter.replayedEventsForTesting(threadID).last ==
            .turnFailed(turnID, .protocolFailure))
        await adapter.shutdown()
    }

    @Test("pending start notification buffering has a fixed fail-closed limit")
    func pendingStartNotificationBufferIsBounded() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "bounded")
        }
        await process.waitForWriteCount(4)
        for index in 0...128 {
            await adapter.handleNotificationForTesting(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string("bounded-turn"),
                    "delta": .string("\(index)"),
                ])
            )
        }
        #expect(await adapter.stateCountsForTesting.bufferedNotifications == 128)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"bounded-turn"}}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await starting.value
        }
        #expect(await adapter.stateCountsForTesting.pendingTurnStarts == 0)
        #expect(await adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await adapter.replayedEventsForTesting(threadID) == [])
        await adapter.shutdown()
    }

    @Test("delete cancels a pending turn start and prevents late resurrection")
    func deleteCancelsPendingStart() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "delete me")
        }
        await process.waitForWriteCount(4)
        let deleting = Task { try await adapter.deleteThread(threadID) }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(#"{"id":4,"result":{}}"#)))
        try await deleting.value
        await #expect(throws: CancellationError.self) {
            try await starting.value
        }
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"deleted-late-turn"}}}"#
        )))
        #expect(await adapter.replayedEventsForTesting(threadID) == [])
        #expect(await adapter.stateCountsForTesting.pendingTurnStarts == 0)
        await adapter.shutdown()
    }

    @Test("shutdown and crash cannot resurrect a pending start")
    func terminalProcessEndsPendingStart() async throws {
        for crashes in [false, true] {
            let process = ScriptedAppServerProcess()
            let adapter = CodexAppServerAdapter(
                transport: JSONLAppServerTransport(process: process),
                launchConfiguration: testLaunchConfiguration(),
                toolExecutor: RecordingCodexToolExecutor()
            )
            let threadID = try await startMappedThread(
                adapter: adapter,
                process: process
            )
            let starting = Task {
                try await adapter.startTurn(threadID: threadID, prompt: "pending")
            }
            await process.waitForWriteCount(4)
            if crashes {
                await process.emit(.terminated(exitCode: 9))
                let outcome = await captureCodexOperation {
                    _ = try await starting.value
                }
                #expect([
                    .adapterError(.invalidResponse),
                    .cancellationError,
                ].contains(outcome))
                await waitUntil {
                    await adapter.availabilityForTesting == .crashed
                }
                #expect(await adapter.availabilityForTesting == .crashed)
            } else {
                await adapter.shutdown()
                let outcome = await captureCodexOperation {
                    _ = try await starting.value
                }
                #expect([
                    .adapterError(.invalidResponse),
                    .cancellationError,
                ].contains(outcome))
            }
            #expect(await adapter.stateCountsForTesting.pendingTurnStarts == 0)
            #expect(await adapter.stateCountsForTesting.activeTurns == 0)
            #expect(await adapter.replayedEventsForTesting(threadID) == [])
            await adapter.shutdown()
        }
    }

    @Test("a suspended tool request does not block notifications or another thread")
    func toolRequestsDoNotBlockTheMessageConsumer() async throws {
        let process = ScriptedAppServerProcess()
        let executor = GateCodexToolExecutor(blockedThreads: ["thread-1"])
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor
        )
        #expect(await adapter.maximumInFlightToolRequestCountForTesting == 32)
        let firstThread = try await startMappedThread(adapter: adapter, process: process)
        let firstTurn = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: firstThread,
            turnID: "live-turn",
            requestID: 3,
            writeCount: 4
        )
        let secondStarting = Task { try await adapter.startThread() }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"thread":{"id":"thread-2"}}}"#
        )))
        let secondThread = try await secondStarting.value

        await process.emit(.standardOutput(jsonLine(
            #"{"id":700,"method":"item/tool/call","params":{"arguments":{},"callId":"slow","threadId":"thread-1","tool":"observe_screen","turnId":"live-turn","namespace":"merlin_tmux"}}"#
        )))
        await executor.waitForCallCount(1)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":701,"method":"item/tool/call","params":{"arguments":{},"callId":"fast","threadId":"thread-2","tool":"observe_screen","turnId":"other-turn","namespace":"merlin_tmux"}}"#
        )))
        await process.emit(.standardOutput(jsonLine(
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"live-turn","delta":"still flowing"}}"#
        )))
        await process.waitForWriteCount(6)
        await waitUntil {
            await adapter.replayedEventsForTesting(firstThread).last ==
                .assistantMessageDelta("still flowing")
        }
        #expect(await executor.calledThreads.contains(secondThread.rawValue))
        #expect(await adapter.replayedEventsForTesting(firstThread).last ==
            .assistantMessageDelta("still flowing"))

        await executor.release(threadID: firstThread.rawValue)
        await process.waitForWriteCount(7)
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(firstThread.rawValue),
                "turn": .object([
                    "id": .string(firstTurn.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        await adapter.shutdown()
    }

    @Test("tool request overload is bounded and sanitized")
    func toolRequestLimitFailsClosed() async throws {
        let process = ScriptedAppServerProcess()
        let executor = GateCodexToolExecutor(blockedThreads: ["thread-1"])
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor,
            maximumInFlightToolRequests: 1
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":800,"method":"item/tool/call","params":{"arguments":{},"callId":"one","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        )))
        await executor.waitForCallCount(1)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":801,"method":"item/tool/call","params":{"arguments":{},"callId":"two","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        )))
        await process.waitForWriteCount(4)
        let overload = try jsonObject(from: await process.writtenData()[3])
        #expect(overload["id"] as? Int == 801)
        #expect((overload["error"] as? [String: Any])?["message"] as? String ==
            "Server busy")
        #expect(await adapter.inFlightToolRequestCountForTesting == 1)
        #expect(await adapter.maximumInFlightToolRequestCountForTesting == 1)
        #expect(await adapter.replayedEventsForTesting(threadID) == [])

        await executor.release(threadID: threadID.rawValue)
        await process.waitForWriteCount(5)
        await adapter.shutdown()
    }

    @Test("duplicate request IDs are ignored while the original responds once")
    func duplicateToolRequestIDExecutesAndRespondsOnce() async throws {
        let process = ScriptedAppServerProcess()
        let executor = GateCodexToolExecutor(blockedThreads: ["thread-1"])
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        let request = #"{"id":"same","method":"item/tool/call","params":{"arguments":{},"callId":"duplicate","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        await process.emit(.standardOutput(jsonLine(request)))
        await executor.waitForCallCount(1)
        await process.emit(.standardOutput(jsonLine(request)))
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 3)
        #expect(await executor.calledThreads.count == 1)
        await executor.release(threadID: "thread-1")
        await process.waitForWriteCount(4)
        let response = try jsonObject(from: await process.writtenData()[3])
        #expect(response["id"] as? String == "same")
        #expect(response["result"] != nil)
        #expect(await adapter.inFlightToolRequestCountForTesting == 0)
        await adapter.shutdown()
    }

    @Test("shutdown cancels and drains in-flight tool requests")
    func shutdownDrainsToolRequests() async throws {
        let process = ScriptedAppServerProcess()
        let executor = GateCodexToolExecutor(blockedThreads: ["thread-1"])
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":900,"method":"item/tool/call","params":{"arguments":{},"callId":"cancel","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        )))
        await executor.waitForCallCount(1)
        await adapter.shutdown()
        await executor.waitForCancellationCount(1)
        #expect(await adapter.inFlightToolRequestCountForTesting == 0)
        #expect((await process.writtenData()).count == 3)
    }

    @Test("deleting a thread clears its active turn before late events")
    func deleteClearsActiveTurn() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let turnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "deleted-turn",
            requestID: 3,
            writeCount: 4
        )
        let deleting = Task { try await adapter.deleteThread(threadID) }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{}}"#
        )))
        try await deleting.value

        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string(turnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        await adapter.consumerFailedForTesting()
        #expect(await adapter.replayedEventsForTesting(threadID) == [])
        await adapter.shutdown()
    }

    @Test("real executor handles a tool call while turn start is suspended")
    func appServerToolRaceUsesPreparedCoreTurn() async throws {
        let screen = TerminalToolFixtures.screen(revision: 8)
        let registry = TerminalEndpointRegistry()
        try await registry.register(TerminalToolFixtures.endpoint(
            id: TerminalToolFixtures.newID(),
            port: FakeTerminalToolPort(snapshot: screen),
            controller: FakeTerminalSurfaceController(
                surface: TerminalToolFixtures.surface()
            )
        ))
        let router = TerminalToolRouter(
            registry: registry,
            approvalBroker: TerminalApprovalBroker(),
            journal: MemoryTerminalToolJournal()
        )
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: CodexTerminalToolExecutor(router: router)
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let handle = try await router.beginTurn(
            threadID: threadID,
            conversationKey: TerminalToolFixtures.key
        )
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "observe")
        }
        await process.waitForWriteCount(4)

        let response = try await adapter.handleServerRequestForTesting(
            method: "item/tool/call",
            params: .object([
                "arguments": .object([:]),
                "callId": .string("racing-core-call"),
                "threadId": .string(threadID.rawValue),
                "tool": .string("observe_screen"),
                "turnId": .string("racing-core-turn"),
                "namespace": .string("merlin_tmux"),
            ])
        )
        guard case let .object(responseFields) = response else {
            Issue.record("tool response was not an object")
            return
        }
        #expect(responseFields["success"] == .bool(true))
        #expect(String(describing: response).contains("\\\"revision\\\":8"))

        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"racing-core-turn"}}}"#
        )))
        let turnID = try await starting.value
        try await router.confirmTurnID(handle: handle, turnID: turnID)
        try await router.endTurn(handle: handle, turnID: turnID)
        await adapter.shutdown()
    }

    @Test("unknown and inactive failure notifications stay bounded")
    func notificationFailuresAreBounded() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )

        await adapter.handleNotificationForTesting(
            method: "future/unknown",
            params: .object(["secret": .string("must-not-escape")])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == [])

        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .null,
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == [])
        let beforeInactiveErrors = await adapter.replayedEventsForTesting(
            threadID
        )

        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "error": .object([
                    "message": .string("private diagnostic"),
                    "additionalDetails": .string("private details"),
                    "codexErrorInfo": .string("serverOverloaded"),
                ]),
                "threadId": .string(threadID.rawValue),
                "turnId": .string("turn-overloaded"),
                "willRetry": .bool(false),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "error": .object([
                    "message": .string("private limit diagnostic"),
                    "codexErrorInfo": .string("usageLimitExceeded"),
                ]),
                "threadId": .string(threadID.rawValue),
                "turnId": .string("turn-limit"),
                "willRetry": .bool(false),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "error": .object([
                    "message": .string("secret auth diagnostic"),
                    "codexErrorInfo": .string("unauthorized"),
                ]),
                "threadId": .string(threadID.rawValue),
                "turnId": .string("turn-auth"),
                "willRetry": .bool(false),
            ])
        )
        #expect(await adapter.availabilityForTesting == .ready)
        #expect(await adapter.replayedEventsForTesting(threadID) ==
            beforeInactiveErrors)

        await adapter.consumerFailedForTesting()
        #expect(await adapter.availabilityForTesting == .crashed)
        #expect(String(describing: await adapter.replayedEventsForTesting(threadID))
            .contains("private diagnostic") == false)
        #expect(String(describing: await adapter.replayedEventsForTesting(threadID))
            .contains("secret auth diagnostic") == false)
        await adapter.shutdown()
    }

    @Test("completed Dynamic Tool and additive items do not fail the turn")
    func completedNonMessageItemsAreAdditive() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        _ = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "turn-1",
            requestID: 3,
            writeCount: 4
        )
        let beforeItems = await adapter.replayedEventsForTesting(threadID)

        await adapter.handleNotificationForTesting(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("turn-1"),
                "item": .object([
                    "id": .string("call-1"),
                    "type": .string("dynamicToolCall"),
                    "tool": .string("observe_screen"),
                    "arguments": .object([:]),
                ]),
            ])
        )
        await adapter.handleNotificationForTesting(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("turn-1"),
                "item": .object([
                    "id": .string("future-1"),
                    "type": .string("futureItem"),
                    "secret": .string("never publish"),
                ]),
            ])
        )

        #expect(await adapter.replayedEventsForTesting(threadID) == beforeItems)
        await adapter.handleNotificationForTesting(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("turn-1"),
                "item": .object([
                    "id": .string("message-1"),
                    "type": .string("agentMessage"),
                    "text": .string("visible answer"),
                ]),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) ==
            beforeItems + [.assistantMessageCompleted("visible answer")])
        await adapter.shutdown()
    }

    @Test("steer publishes only after the server confirms the exact active turn")
    func steerRequiresMatchingTurnID() async throws {
        for result in [
            #"{"turnId":"other-turn"}"#,
            #"{}"#,
        ] {
            let process = ScriptedAppServerProcess()
            let adapter = CodexAppServerAdapter(
                transport: JSONLAppServerTransport(process: process),
                launchConfiguration: testLaunchConfiguration(),
                toolExecutor: RecordingCodexToolExecutor()
            )
            let threadID = try await startMappedThread(
                adapter: adapter,
                process: process
            )
            let starting = Task {
                try await adapter.startTurn(threadID: threadID, prompt: "hello")
            }
            await process.waitForWriteCount(4)
            await process.emit(.standardOutput(jsonLine(
                #"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#
            )))
            let turnID = try await starting.value
            let before = await adapter.replayedEventsForTesting(threadID)

            let steering = Task {
                try await adapter.steerTurn(
                    threadID: threadID,
                    turnID: turnID,
                    prompt: "must-not-publish"
                )
            }
            await process.waitForWriteCount(5)
            await process.emit(.standardOutput(jsonLine(
                "{\"id\":4,\"result\":\(result)}"
            )))
            await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
                try await steering.value
            }
            #expect(await adapter.replayedEventsForTesting(threadID) == before)
            await adapter.shutdown()
        }
    }

    @Test("start and resume use exact boundaries and replay history before live deltas")
    func historyPrecedesBufferedLiveEvents() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            knownServerRequestMethods: ["item/tool/call"]
        )
        let executor = RecordingCodexToolExecutor()
        let configuration = testLaunchConfiguration()
        let adapter = CodexAppServerAdapter(
            transport: transport,
            launchConfiguration: configuration,
            toolExecutor: executor
        )

        let starting = Task { try await adapter.startThread() }
        await process.waitForWriteCount(1)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":1,"result":{"codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-cli/0.144.2"}}"#
        )))
        await process.waitForWriteCount(3)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        )))
        let threadID = try await starting.value
        #expect(threadID == AgentThreadID(rawValue: "thread-1"))

        let stream = await adapter.events(for: threadID)
        let collected = Task { () -> [AgentEvent] in
            var iterator = stream.makeAsyncIterator()
            var events: [AgentEvent] = []
            while events.count < 2, let event = await iterator.next() {
                events.append(event)
            }
            return events
        }
        let resuming = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(4)
        await process.emit(.standardOutput(jsonLine(
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"live-turn","delta":"live"}}"#
        )))
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"thread":{"id":"thread-1","turns":[{"id":"old-turn","status":"completed","items":[{"id":"user-1","type":"userMessage","content":[{"type":"text","text":"old prompt"}]},{"id":"agent-1","type":"agentMessage","text":"old answer"}]},{"id":"live-turn","status":"inProgress","items":[]}]}}}"#
        )))
        try await resuming.value
        let events = await collected.value
        #expect(events == [
            .history([
                .init(role: .user, text: "old prompt"),
                .init(role: .assistant, text: "old answer"),
            ]),
            .assistantMessageDelta("live"),
        ])

        let writes = await process.writtenData()
        let resume = try jsonObject(from: writes[3])
        let resumeParams = resume["params"] as! [String: Any]
        #expect(resumeParams["threadId"] as? String == "thread-1")
        #expect(resumeParams["dynamicTools"] == nil)
        let resumedToolResult = try await adapter.handleServerRequestForTesting(
            method: "item/tool/call",
            params: .object([
                "arguments": .object([:]),
                "callId": .string("resumed-call"),
                "threadId": .string(threadID.rawValue),
                "tool": .string("observe_screen"),
                "turnId": .string("resumed-turn"),
                "namespace": .string("merlin_tmux"),
            ])
        )
        guard case let .object(resumedToolFields) = resumedToolResult else {
            Issue.record("resumed tool call did not return an object")
            return
        }
        #expect(resumedToolFields["success"] == .bool(true))
        #expect(await executor.calls == [.observeScreen])
        await adapter.shutdown()
    }

    @Test("resume rejects threads not created by the adapter mapping store")
    func unknownResumeFailsClosed() async {
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: ScriptedAppServerProcess(),
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        await #expect(throws: CodexAppServerAdapterError.unmappedThread) {
            try await adapter.resumeThread(.init(rawValue: "foreign"))
        }
        await adapter.shutdown()
    }

    @Test("tool requests are decoded before execution and return one sanitized inputText")
    func toolRequestsFailClosedAndSanitizeFailures() async throws {
        let executor = RecordingCodexToolExecutor()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: ScriptedAppServerProcess(),
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor,
            mappingStore: CodexAppServerThreadMappingStore(threadIDs: [
                AgentThreadID(rawValue: "thread-1"),
            ])
        )
        let valid = try await adapter.handleServerRequestForTesting(
            method: "item/tool/call",
            params: .object([
                "arguments": .object([:]),
                "callId": .string("call-1"),
                "threadId": .string("thread-1"),
                "tool": .string("observe_screen"),
                "turnId": .string("turn-1"),
                "namespace": .string("merlin_tmux"),
            ])
        )
        guard case let .object(validFields) = valid else {
            Issue.record("invalid response")
            return
        }
        #expect(validFields["success"] == .bool(true))
        #expect(await executor.calls == [.observeScreen])

        let invalid = try await adapter.handleServerRequestForTesting(
            method: "item/tool/call",
            params: .object([
                "arguments": .object([:]),
                "callId": .string("call-2"),
                "threadId": .string("thread-1"),
                "tool": .string("shell"),
                "turnId": .string("turn-1"),
                "namespace": .string("builtin"),
            ])
        )
        guard case let .object(invalidFields) = invalid else { return }
        #expect(invalidFields["success"] == .bool(false))
        #expect(await executor.calls.count == 1)
        #expect(String(describing: invalid).contains("shell") == false)

        await #expect(throws: CodexAppServerAdapterError.unsupportedServerRequest) {
            try await adapter.handleServerRequestForTesting(
                method: "command/exec",
                params: .object([:])
            )
        }
        #expect(await executor.calls.count == 1)
        await adapter.shutdown()
    }

    @Test("tool namespace defaults only when absent and rejects invalid presence")
    func toolNamespacePresenceFailsClosed() async throws {
        let executor = RecordingCodexToolExecutor()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: ScriptedAppServerProcess(),
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor,
            mappingStore: CodexAppServerThreadMappingStore(threadIDs: [
                AgentThreadID(rawValue: "thread-1"),
            ])
        )
        func params(namespace: JSONValue?) -> JSONValue {
            var fields: [String: JSONValue] = [
                "arguments": .object([:]),
                "callId": .string("namespace-call"),
                "threadId": .string("thread-1"),
                "tool": .string("observe_screen"),
                "turnId": .string("turn-1"),
            ]
            if let namespace { fields["namespace"] = namespace }
            return .object(fields)
        }

        for namespace in [nil, JSONValue.string("merlin_tmux")] {
            let result = try await adapter.handleServerRequestForTesting(
                method: "item/tool/call",
                params: params(namespace: namespace)
            )
            guard case let .object(fields) = result else {
                Issue.record("valid namespace response was not an object")
                continue
            }
            #expect(fields["success"] == .bool(true))
        }
        #expect(await executor.calls.count == 2)

        let invalidNamespaces: [JSONValue] = [
            .null,
            .string(""),
            .bool(true),
            .string("unknown"),
        ]
        for namespace in invalidNamespaces {
            let result = try await adapter.handleServerRequestForTesting(
                method: "item/tool/call",
                params: params(namespace: namespace)
            )
            guard case let .object(fields) = result else {
                Issue.record("invalid namespace response was not an object")
                continue
            }
            #expect(fields["success"] == .bool(false))
            #expect(await executor.calls.count == 2)
            #expect(String(describing: result).contains("unknown") == false)
        }
        await adapter.shutdown()
    }

    @Test("resume cannot overlap a pending start and cleanup permits retry")
    func resumeRejectsPendingStartBeforeWriting() async throws {
        let fixture = try await startCodexMappedThreadFixture()
        let process = fixture.process
        let adapter = fixture.adapter
        let threadID = fixture.threadID
        let starting = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "pending")
        }
        await process.waitForWriteCount(4)

        let outcome = CodexOperationOutcomeProbe()
        let conflictingResume = Task {
            await outcome.record(captureCodexOperation {
                try await adapter.resumeThread(threadID)
            })
        }
        await waitUntil {
            if await outcome.value() != nil { return true }
            return await process.writtenData().count > 4
        }
        #expect(
            await outcome.value()
                == .adapterError(.turnAlreadyStarting)
        )
        #expect((await process.writtenData()).count == 4)
        conflictingResume.cancel()
        await conflictingResume.value

        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"pending-turn"}}}"#
        )))
        let turnID = try await starting.value
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(threadID: threadID, turnID: turnID)
        )

        let writesBeforeRetry = (await process.writtenData()).count
        let retry = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(writesBeforeRetry + 1)
        let retryID = try await lastRequestID(from: process)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":\#(retryID),"result":{"thread":{"id":"thread-1","turns":[]}}}"#
        )))
        try await retry.value
        #expect(await adapter.stateCountsForTesting.pendingTurnStarts == 0)
        #expect(await adapter.stateCountsForTesting.pendingResumes == 0)
        #expect(await adapter.stateCountsForTesting.activeTurns == 0)
        await adapter.shutdown()
    }

    @Test("start cannot overlap a pending resume and cleanup permits retry")
    func startRejectsPendingResumeBeforeWriting() async throws {
        let fixture = try await startCodexMappedThreadFixture()
        let process = fixture.process
        let adapter = fixture.adapter
        let threadID = fixture.threadID
        let resuming = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(4)

        let outcome = CodexOperationOutcomeProbe()
        let conflictingStart = Task {
            await outcome.record(captureCodexOperation {
                _ = try await adapter.startTurn(
                    threadID: threadID,
                    prompt: "blocked"
                )
            })
        }
        await waitUntil {
            if await outcome.value() != nil { return true }
            return await process.writtenData().count > 4
        }
        #expect(
            await outcome.value()
                == .adapterError(.resumeAlreadyInProgress)
        )
        #expect((await process.writtenData()).count == 4)
        conflictingStart.cancel()
        await conflictingStart.value

        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"thread":{"id":"thread-1","turns":[]}}}"#
        )))
        try await resuming.value

        let writesBeforeRetry = (await process.writtenData()).count
        let retry = Task {
            try await adapter.startTurn(threadID: threadID, prompt: "retry")
        }
        await process.waitForWriteCount(writesBeforeRetry + 1)
        let retryID = try await lastRequestID(from: process)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":\#(retryID),"result":{"turn":{"id":"retry-turn"}}}"#
        )))
        let turnID = try await retry.value
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(threadID: threadID, turnID: turnID)
        )
        #expect(await adapter.stateCountsForTesting.pendingTurnStarts == 0)
        #expect(await adapter.stateCountsForTesting.pendingResumes == 0)
        #expect(await adapter.stateCountsForTesting.activeTurns == 0)
        await adapter.shutdown()
    }

    @Test("start and resume pending windows remain independent across threads")
    func startAndResumeRemainIndependentAcrossThreads() async throws {
        let process = ScriptedAppServerProcess()
        let secondThreadID = AgentThreadID(rawValue: "thread-2")
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor(),
            mappingStore: .init(threadIDs: [secondThreadID])
        )
        let firstThreadID = try await startMappedThread(
            adapter: adapter,
            process: process
        )
        let starting = Task {
            try await adapter.startTurn(
                threadID: firstThreadID,
                prompt: "first"
            )
        }
        await process.waitForWriteCount(4)
        let resuming = Task { try await adapter.resumeThread(secondThreadID) }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"thread":{"id":"thread-2","turns":[]}}}"#
        )))
        try await resuming.value

        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"turn":{"id":"first-turn"}}}"#
        )))
        let turnID = try await starting.value
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: firstThreadID,
                turnID: turnID
            )
        )
        #expect((await process.writtenData()).count == 5)
        #expect(await adapter.stateCountsForTesting.pendingTurnStarts == 0)
        #expect(await adapter.stateCountsForTesting.pendingResumes == 0)
        await adapter.shutdown()
    }

    @Test("resume is single-flight per thread and buffers before an existing active turn")
    func resumeIsSingleFlightAndHistoryFirstForActiveThread() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "active-resume-turn"
        )
        let process = fixture.process
        let adapter = fixture.adapter
        let threadID = fixture.threadID
        let turnID = fixture.turnID
        let before = fixture.eventsBeforeResume
        let first = fixture.resuming
        await #expect(throws: CodexAppServerAdapterError.resumeAlreadyInProgress) {
            try await adapter.resumeThread(threadID)
        }
        await bufferDelta(
            "wrong",
            fixture: fixture,
            turnID: .init(rawValue: "wrong-resume-turn")
        )
        await bufferDelta("early", fixture: fixture)
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(threadID: threadID, turnID: turnID)
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == before)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"thread":{"id":"thread-1","turns":[{"id":"active-resume-turn","status":"inProgress","items":[{"type":"agentMessage","text":"history"}]}]}}}"#
        )))
        try await first.value

        #expect(await adapter.replayedEventsForTesting(threadID).suffix(3) == [
            .history([.init(role: .assistant, text: "history")]),
            .assistantMessageDelta("early"),
            .turnCompleted(turnID),
        ])
        #expect(await adapter.stateCountsForTesting.activeTurns == 0)
        await adapter.shutdown()
    }

    @Test("failed resume replays buffered events for its exact prior active turn")
    func failedResumePreservesPriorActiveTurnEvents() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "failure-owner"
        )
        await bufferDelta("preserved", fixture: fixture)
        await fixture.adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: fixture.threadID,
                turnID: fixture.turnID
            )
        )
        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"error":{"code":-32000,"message":"resume failed"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await fixture.resuming.value
        }

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeResume + [
            .assistantMessageDelta("preserved"),
            .turnCompleted(fixture.turnID),
        ])
        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID).contains {
                if case .history = $0 { true } else { false }
            } == false
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("wrong-turn resume floods do not consume the exact owner's buffer")
    func activeResumeIgnoresWrongTurnFloodBeforeCapacity() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "resume-owner"
        )
        let staleTurnID = AgentTurnID(rawValue: "stale-turn")
        for index in 0...128 {
            await bufferDelta(
                "stale-\(index)",
                fixture: fixture,
                turnID: staleTurnID
            )
        }
        await bufferDelta("owned", fixture: fixture)
        await fixture.adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: fixture.threadID,
                turnID: fixture.turnID
            )
        )
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 2
        )

        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"error":{"code":-32000,"message":"resume failed"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await fixture.resuming.value
        }

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeResume + [
                    .assistantMessageDelta("owned"),
                    .turnCompleted(fixture.turnID),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("cancelled resume restores buffered events for its exact prior active turn")
    func cancelledResumePreservesPriorActiveTurnEvents() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "cancelled-owner"
        )
        await bufferDelta("preserved", fixture: fixture)
        await fixture.adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: fixture.threadID,
                turnID: fixture.turnID
            )
        )

        fixture.resuming.cancel()
        await #expect(throws: CancellationError.self) {
            try await fixture.resuming.value
        }
        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeResume + [
                    .assistantMessageDelta("preserved"),
                    .turnCompleted(fixture.turnID),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("missing or mismatched resume never replaces its exact prior active turn")
    func mismatchedResumePreservesPriorOwnerAndRejectsReplacement() async throws {
        for responseTurnID: String? in [nil, "replacement"] {
            let fixture = try await startCodexActiveResumeFixture(
                turnID: "exact-owner"
            )
            await bufferDelta("owned", fixture: fixture)
            await fixture.adapter.handleNotificationForTesting(
                method: "turn/completed",
                params: completedTurnParams(
                    threadID: fixture.threadID,
                    turnID: fixture.turnID
                )
            )
            let turns = responseTurnID.map {
                #"[{"id":"\#($0)","status":"inProgress","items":[{"type":"agentMessage","text":"must not publish"}]}]"#
            } ?? "[]"
            await fixture.process.emit(.standardOutput(jsonLine(
                #"{"id":4,"result":{"thread":{"id":"thread-1","turns":\#(turns)}}}"#
            )))
            await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
                try await fixture.resuming.value
            }
            if let responseTurnID {
                await bufferDelta(
                    "foreign",
                    fixture: fixture,
                    turnID: .init(rawValue: responseTurnID)
                )
            }

            #expect(
                await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                    == fixture.eventsBeforeResume + [
                        .assistantMessageDelta("owned"),
                        .turnCompleted(fixture.turnID),
                    ]
            )
            #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
            #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
            await fixture.adapter.shutdown()
        }
    }

    @Test("resume notification overflow fails without installing history or a turn")
    func resumeBufferOverflowFailsClosed() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let resuming = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(4)
        for index in 0...128 {
            await adapter.handleNotificationForTesting(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string("resume-overflow-turn"),
                    "delta": .string("\(index)"),
                ])
            )
        }
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"thread":{"id":"thread-1","turns":[{"id":"resume-overflow-turn","status":"inProgress","items":[]}]}}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await resuming.value
        }
        #expect(await adapter.replayedEventsForTesting(threadID) == [])
        #expect(await adapter.stateCountsForTesting.pendingResumes == 0)
        #expect(await adapter.stateCountsForTesting.activeTurns == 0)
        await adapter.shutdown()
    }

    @Test("prior active resume overflow fails its exact owner once without partial replay")
    func activeResumeBufferOverflowFailsExactOwnerOnce() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "overflow-owner"
        )
        for index in 0...128 {
            await bufferDelta("partial-\(index)", fixture: fixture)
        }
        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"thread":{"id":"thread-1","turns":[{"id":"overflow-owner","status":"inProgress","items":[]}]}}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await fixture.resuming.value
        }

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeResume + [
                    .turnFailed(fixture.turnID, .protocolFailure),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("failed delete replays exact active-turn notifications in order")
    func failedDeleteReplaysExactActiveTurnEvents() async throws {
        let fixture = try await startCodexActiveTurnFixture(
            turnID: "delete-failure-owner"
        )
        let deleting = Task {
            try await fixture.adapter.deleteThread(fixture.threadID)
        }
        await fixture.process.waitForWriteCount(5)
        await bufferDelta("preserved", fixture: fixture)
        await fixture.adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: fixture.threadID,
                turnID: fixture.turnID
            )
        )
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 2
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 1)

        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"error":{"code":-32000,"message":"delete failed"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await deleting.value
        }

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeDelete + [
                    .assistantMessageDelta("preserved"),
                    .turnCompleted(fixture.turnID),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 0
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("failed delete overflow fails the exact owner once without partial replay")
    func failedDeleteOverflowFailsExactOwnerOnce() async throws {
        let fixture = try await startCodexActiveTurnFixture(
            turnID: "delete-overflow-owner"
        )
        let deleting = Task {
            try await fixture.adapter.deleteThread(fixture.threadID)
        }
        await fixture.process.waitForWriteCount(5)
        for index in 0...128 {
            await bufferDelta("partial-\(index)", fixture: fixture)
        }
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 128
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 1)

        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"error":{"code":-32000,"message":"delete failed"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await deleting.value
        }

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeDelete + [
                    .turnFailed(fixture.turnID, .protocolFailure),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 0
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("wrong-turn delete floods do not consume the exact owner's buffer")
    func failedDeleteIgnoresWrongTurnFloodBeforeCapacity() async throws {
        let fixture = try await startCodexActiveTurnFixture(
            turnID: "delete-owner"
        )
        let deleting = Task {
            try await fixture.adapter.deleteThread(fixture.threadID)
        }
        await fixture.process.waitForWriteCount(5)
        let staleTurnID = AgentTurnID(rawValue: "stale-delete-turn")
        for index in 0...128 {
            await bufferDelta(
                "stale-\(index)",
                fixture: fixture,
                turnID: staleTurnID
            )
        }
        await bufferDelta("owned", fixture: fixture)
        await fixture.adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: fixture.threadID,
                turnID: fixture.turnID
            )
        )
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 2
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 1)

        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"error":{"code":-32000,"message":"delete failed"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await deleting.value
        }

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeDelete + [
                    .assistantMessageDelta("owned"),
                    .turnCompleted(fixture.turnID),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("successful delete discards exact active-turn notifications")
    func successfulDeleteDiscardsBufferedActiveTurnEvents() async throws {
        let fixture = try await startCodexActiveTurnFixture(
            turnID: "successful-delete-owner"
        )
        let deleting = Task {
            try await fixture.adapter.deleteThread(fixture.threadID)
        }
        await fixture.process.waitForWriteCount(5)
        await bufferDelta("discarded", fixture: fixture)
        await fixture.adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: completedTurnParams(
                threadID: fixture.threadID,
                turnID: fixture.turnID
            )
        )
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 2
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 1)

        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{}}"#
        )))
        try await deleting.value

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == []
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.knownThreads == 0)
        #expect(
            await fixture.adapter.stateCountsForTesting.bufferedNotifications
                == 0
        )
        #expect(await fixture.adapter.stateCountsForTesting.pendingDeletes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("shutdown and crash discard pending-delete buffers without reviving owners")
    func terminalProcessEndsPendingDeleteWithoutReplay() async throws {
        for crashes in [false, true] {
            let fixture = try await startCodexActiveTurnFixture(
                turnID: crashes ? "crash-delete-owner" : "shutdown-delete-owner"
            )
            let deleting = Task {
                try await fixture.adapter.deleteThread(fixture.threadID)
            }
            await fixture.process.waitForWriteCount(5)
            await bufferDelta("must be dropped", fixture: fixture)
            #expect(
                await fixture.adapter.stateCountsForTesting.bufferedNotifications
                    == 1
            )
            #expect(
                await fixture.adapter.stateCountsForTesting.pendingDeletes == 1
            )

            if crashes {
                await fixture.adapter.consumerFailedForTesting()
                await fixture.process.emit(.standardOutput(jsonLine(
                    #"{"id":4,"error":{"code":-32000,"message":"late delete failure"}}"#
                )))
                #expect(
                    await captureCodexOperation { try await deleting.value }
                        == .adapterError(.invalidResponse)
                )
                #expect(
                    await fixture.adapter.replayedEventsForTesting(
                        fixture.threadID
                    ) == fixture.eventsBeforeDelete + [
                        .turnFailed(fixture.turnID, .crashed),
                    ]
                )
            } else {
                await fixture.adapter.shutdown()
                #expect(
                    await captureCodexOperation { try await deleting.value }
                        != .success
                )
                #expect(
                    await fixture.adapter.replayedEventsForTesting(
                        fixture.threadID
                    ) == []
                )
            }
            #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
            #expect(
                await fixture.adapter.stateCountsForTesting.bufferedNotifications
                    == 0
            )
            #expect(
                await fixture.adapter.stateCountsForTesting.pendingDeletes == 0
            )
            await fixture.adapter.shutdown()
        }
    }

    @Test("delete cancels a pending resume before awaiting its RPC")
    func deleteWinsResumeRace() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let resuming = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(4)
        let deleting = Task { try await adapter.deleteThread(threadID) }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(#"{"id":4,"result":{}}"#)))
        try await deleting.value
        await #expect(throws: CancellationError.self) { try await resuming.value }

        await adapter.handleNotificationForTesting(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("late"),
                "delta": .string("ignored"),
            ])
        )
        #expect(await adapter.replayedEventsForTesting(threadID) == [])
        #expect(await adapter.stateCountsForTesting.pendingResumes == 0)
        await adapter.shutdown()
    }

    @Test("delete wins an active resume race without replaying or reviving its owner")
    func deleteDoesNotReviveActiveResumeOwner() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "delete-owner"
        )
        await bufferDelta("must be dropped", fixture: fixture)

        let deleting = Task {
            try await fixture.adapter.deleteThread(fixture.threadID)
        }
        await fixture.process.waitForWriteCount(6)
        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":5,"result":{}}"#
        )))
        try await deleting.value
        await #expect(throws: CancellationError.self) {
            try await fixture.resuming.value
        }
        await fixture.process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"thread":{"id":"thread-1","turns":[{"id":"delete-owner","status":"inProgress","items":[]}]}}}"#
        )))
        await bufferDelta("late", fixture: fixture)

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == []
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("shutdown wins an active resume race without replaying or reviving its owner")
    func shutdownDoesNotReviveActiveResumeOwner() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "shutdown-owner"
        )
        await bufferDelta("must be dropped", fixture: fixture)

        await fixture.adapter.shutdown()
        let resumeOutcome = await captureCodexOperation {
            try await fixture.resuming.value
        }
        #expect(resumeOutcome != .success)
        await bufferDelta("late", fixture: fixture)

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == []
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
    }

    @Test("crash wins an active resume race with one crash failure and no replay")
    func crashDoesNotReviveActiveResumeOwner() async throws {
        let fixture = try await startCodexActiveResumeFixture(
            turnID: "crash-owner"
        )
        await bufferDelta("must be dropped", fixture: fixture)

        await fixture.adapter.consumerFailedForTesting()
        await #expect(throws: CancellationError.self) {
            try await fixture.resuming.value
        }
        await bufferDelta("late", fixture: fixture)

        #expect(
            await fixture.adapter.replayedEventsForTesting(fixture.threadID)
                == fixture.eventsBeforeResume + [
                    .turnFailed(fixture.turnID, .crashed),
                ]
        )
        #expect(await fixture.adapter.stateCountsForTesting.activeTurns == 0)
        #expect(await fixture.adapter.stateCountsForTesting.pendingResumes == 0)
        await fixture.adapter.shutdown()
    }

    @Test("steer requires the exact active turn both before and after its request")
    func steerRevalidatesExactActiveTurn() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let turnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "steer-race-turn",
            requestID: 3,
            writeCount: 4
        )
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await adapter.steerTurn(
                threadID: threadID,
                turnID: .init(rawValue: "wrong"),
                prompt: "never sent"
            )
        }
        #expect((await process.writtenData()).count == 4)

        let steering = Task {
            try await adapter.steerTurn(
                threadID: threadID,
                turnID: turnID,
                prompt: "racing"
            )
        }
        await process.waitForWriteCount(5)
        await adapter.handleNotificationForTesting(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turn": .object([
                    "id": .string(turnID.rawValue),
                    "status": .string("completed"),
                ]),
            ])
        )
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"result":{"turnId":"steer-race-turn"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await steering.value
        }
        #expect(
            await adapter.replayedEventsForTesting(threadID)
                .contains(.userMessage("racing")) == false
        )
        await adapter.shutdown()
    }

    @Test("failed delete does not revive its cancelled resume and permits an explicit retry")
    func failedDeleteLeavesNoResumeContinuation() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let firstResume = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(4)
        let deleting = Task { try await adapter.deleteThread(threadID) }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":4,"error":{"code":-32000,"message":"delete failed"}}"#
        )))
        await #expect(throws: CodexAppServerAdapterError.invalidResponse) {
            try await deleting.value
        }
        await #expect(throws: CancellationError.self) {
            try await firstResume.value
        }
        await process.emit(.standardOutput(jsonLine(
            #"{"id":3,"result":{"thread":{"id":"thread-1","turns":[{"id":"ghost","status":"inProgress","items":[]}]}}}"#
        )))
        #expect(await adapter.replayedEventsForTesting(threadID) == [])

        let retry = Task { try await adapter.resumeThread(threadID) }
        await process.waitForWriteCount(6)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":5,"result":{"thread":{"id":"thread-1","turns":[]}}}"#
        )))
        try await retry.value
        #expect(await adapter.replayedEventsForTesting(threadID) == [.history([])])
        await adapter.shutdown()
    }

    @Test("call IDs are globally exactly-once and completed RPC tombstones saturate")
    func callIDsAndTombstonesFailClosed() async throws {
        let process = ScriptedAppServerProcess()
        let executor = GateCodexToolExecutor(blockedThreads: ["thread-1"])
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor,
            maximumInFlightToolRequests: 2,
            completedServerRequestTombstoneLimit: 2
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        let first = #"{"id":700,"method":"item/tool/call","params":{"arguments":{},"callId":"one-call","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        let alias = #"{"id":701,"method":"item/tool/call","params":{"arguments":{},"callId":"one-call","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        await process.emit(.standardOutput(jsonLine(first)))
        await executor.waitForCallCount(1)
        await process.emit(.standardOutput(jsonLine(alias)))
        await process.waitForWriteCount(4)
        #expect(await executor.calledThreads.count == 1)
        let rejection = try jsonObject(from: await process.writtenData()[3])
        #expect(rejection["id"] as? Int == 701)
        #expect(rejection["error"] != nil)

        await executor.release(threadID: "thread-1")
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(first)))
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 5)
        #expect(await executor.calledThreads.count == 1)

        await process.emit(.standardOutput(jsonLine(
            #"{"id":702,"method":"item/tool/call","params":{"arguments":{},"callId":"after-saturation","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        )))
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 5)
        #expect(await executor.calledThreads.count == 1)
        await adapter.shutdown()
    }

    @Test("shutdown has a hard deadline for an executor that ignores cancellation")
    func shutdownDeadlineDropsLateToolCompletion() async throws {
        let process = ScriptedAppServerProcess()
        let executor = StubbornCodexToolExecutor()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor,
            toolRequestDrainTimeout: .milliseconds(20)
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":800,"method":"item/tool/call","params":{"arguments":{},"callId":"stubborn","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        )))
        await executor.waitUntilStarted()

        let clock = ContinuousClock()
        let start = clock.now
        await adapter.shutdown()
        #expect(clock.now - start < .seconds(1))
        #expect(await adapter.inFlightToolRequestCountForTesting == 0)
        await executor.release()
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 3)
    }

    @Test("duplicate request IDs are ignored while the physical response write is pending")
    func duplicateDuringResponseWriteIsIgnored() async throws {
        let process = ScriptedAppServerProcess(gateWriteAt: 4)
        let executor = RecordingCodexToolExecutor()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        let request = #"{"id":"responding","method":"item/tool/call","params":{"arguments":{},"callId":"responding-call","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        await process.emit(.standardOutput(jsonLine(request)))
        await process.waitForWriteStartCount(4)
        await process.emit(.standardOutput(jsonLine(request)))
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 3)
        #expect(await executor.calls.count == 1)

        await process.releaseWrites()
        await process.waitForWriteCount(4)
        await process.emit(.standardOutput(jsonLine(request)))
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 4)
        #expect(await executor.calls.count == 1)
        await adapter.shutdown()
    }

    @Test("process failure has a hard deadline for an executor that ignores cancellation")
    func crashDeadlineDropsLateToolCompletion() async throws {
        let process = ScriptedAppServerProcess()
        let executor = StubbornCodexToolExecutor()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"]
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: executor,
            toolRequestDrainTimeout: .milliseconds(20)
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        await process.emit(.standardOutput(jsonLine(
            #"{"id":801,"method":"item/tool/call","params":{"arguments":{},"callId":"stubborn-crash","threadId":"thread-1","tool":"observe_screen","turnId":"turn-1","namespace":"merlin_tmux"}}"#
        )))
        await executor.waitUntilStarted()

        let clock = ContinuousClock()
        let start = clock.now
        await adapter.consumerFailedForTesting()
        #expect(clock.now - start < .seconds(1))
        #expect(await adapter.inFlightToolRequestCountForTesting == 0)
        #expect(await adapter.availabilityForTesting == .crashed)
        await executor.release()
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 3)
        await adapter.shutdown()
    }

    @Test("unknown server RPC IDs are rejected exactly once by the adapter")
    func unknownServerRPCDuplicateIsIgnored() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(
                process: process,
                knownServerRequestMethods: ["item/tool/call"],
                forwardUnknownServerRequests: true
            ),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        _ = try await startMappedThread(adapter: adapter, process: process)
        let request = #"{"id":"unknown","method":"command/exec","params":{}}"#
        await process.emit(.standardOutput(jsonLine(request)))
        await process.emit(.standardOutput(jsonLine(request)))
        await process.waitForWriteCount(4)
        for _ in 0..<100 { await Task.yield() }
        #expect((await process.writtenData()).count == 4)
        let response = try jsonObject(from: await process.writtenData()[3])
        #expect(response["id"] as? String == "unknown")
        #expect((response["error"] as? [String: Any])?["message"] as? String ==
            "Method not found")
        await adapter.shutdown()
    }

    @Test("slow streams stay bounded and require resubscription after event loss")
    func streamsAreBoundedAndResynchronizable() async throws {
        let process = ScriptedAppServerProcess()
        let adapter = CodexAppServerAdapter(
            transport: JSONLAppServerTransport(process: process),
            launchConfiguration: testLaunchConfiguration(),
            toolExecutor: RecordingCodexToolExecutor()
        )
        let threadID = try await startMappedThread(adapter: adapter, process: process)
        let turnID = try await startMappedTurn(
            adapter: adapter,
            process: process,
            threadID: threadID,
            turnID: "stream-turn",
            requestID: 3,
            writeCount: 4
        )
        let slow = await adapter.events(for: threadID)
        _ = slow
        for index in 0..<600 {
            await adapter.handleNotificationForTesting(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string(turnID.rawValue),
                    "delta": .string("\(index)"),
                ])
            )
        }
        #expect(await adapter.stateCountsForTesting.eventSubscribers == 0)
        #expect(await adapter.stateCountsForTesting.replayEvents == 512)

        let replacement = await adapter.events(for: threadID)
        var iterator = replacement.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(await adapter.stateCountsForTesting.eventSubscribers == 1)

        let availability = await adapter.availability()
        await adapter.consumerFailedForTesting()
        var availabilityIterator = availability.makeAsyncIterator()
        #expect(await availabilityIterator.next() == .crashed)
        await adapter.shutdown()
    }
}

private enum CodexOperationOutcome: Equatable, Sendable {
    case success
    case adapterError(CodexAppServerAdapterError)
    case cancellationError
    case otherError
}

private actor CodexOperationOutcomeProbe {
    private var outcome: CodexOperationOutcome?

    func record(_ outcome: CodexOperationOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
    }

    func value() -> CodexOperationOutcome? { outcome }
}

private func captureCodexOperation(
    _ operation: @Sendable () async throws -> Void
) async -> CodexOperationOutcome {
    do {
        try await operation()
        return .success
    } catch let error as CodexAppServerAdapterError {
        return .adapterError(error)
    } catch is CancellationError {
        return .cancellationError
    } catch {
        return .otherError
    }
}

private func completedTurnParams(
    threadID: AgentThreadID,
    turnID: AgentTurnID
) -> JSONValue {
    .object([
        "threadId": .string(threadID.rawValue),
        "turn": .object([
            "id": .string(turnID.rawValue),
            "status": .string("completed"),
        ]),
    ])
}

private struct CodexMappedThreadFixture {
    let process: ScriptedAppServerProcess
    let adapter: CodexAppServerAdapter
    let threadID: AgentThreadID
}

private func startCodexMappedThreadFixture() async throws
    -> CodexMappedThreadFixture
{
    let process = ScriptedAppServerProcess()
    let adapter = CodexAppServerAdapter(
        transport: JSONLAppServerTransport(process: process),
        launchConfiguration: testLaunchConfiguration(),
        toolExecutor: RecordingCodexToolExecutor()
    )
    let threadID = try await startMappedThread(
        adapter: adapter,
        process: process
    )
    return .init(process: process, adapter: adapter, threadID: threadID)
}

private struct CodexActiveResumeFixture {
    let process: ScriptedAppServerProcess
    let adapter: CodexAppServerAdapter
    let threadID: AgentThreadID
    let turnID: AgentTurnID
    let eventsBeforeResume: [AgentEvent]
    let resuming: Task<Void, Error>
}

private struct CodexActiveTurnFixture {
    let process: ScriptedAppServerProcess
    let adapter: CodexAppServerAdapter
    let threadID: AgentThreadID
    let turnID: AgentTurnID
    let eventsBeforeDelete: [AgentEvent]
}

private func startCodexActiveTurnFixture(
    turnID rawTurnID: String
) async throws -> CodexActiveTurnFixture {
    let mapped = try await startCodexMappedThreadFixture()
    let turnID = try await startMappedTurn(
        adapter: mapped.adapter,
        process: mapped.process,
        threadID: mapped.threadID,
        turnID: rawTurnID,
        requestID: 3,
        writeCount: 4
    )
    let eventsBeforeDelete = await mapped.adapter.replayedEventsForTesting(
        mapped.threadID
    )
    return .init(
        process: mapped.process,
        adapter: mapped.adapter,
        threadID: mapped.threadID,
        turnID: turnID,
        eventsBeforeDelete: eventsBeforeDelete
    )
}

private func startCodexActiveResumeFixture(
    turnID rawTurnID: String
) async throws -> CodexActiveResumeFixture {
    let mapped = try await startCodexMappedThreadFixture()
    let turnID = try await startMappedTurn(
        adapter: mapped.adapter,
        process: mapped.process,
        threadID: mapped.threadID,
        turnID: rawTurnID,
        requestID: 3,
        writeCount: 4
    )
    let eventsBeforeResume = await mapped.adapter.replayedEventsForTesting(
        mapped.threadID
    )
    let resuming = Task { try await mapped.adapter.resumeThread(mapped.threadID) }
    await mapped.process.waitForWriteCount(5)
    return .init(
        process: mapped.process,
        adapter: mapped.adapter,
        threadID: mapped.threadID,
        turnID: turnID,
        eventsBeforeResume: eventsBeforeResume,
        resuming: resuming
    )
}

private func bufferDelta(
    _ delta: String,
    fixture: CodexActiveResumeFixture,
    turnID: AgentTurnID? = nil
) async {
    await fixture.adapter.handleNotificationForTesting(
        method: "item/agentMessage/delta",
        params: .object([
            "threadId": .string(fixture.threadID.rawValue),
            "turnId": .string((turnID ?? fixture.turnID).rawValue),
            "delta": .string(delta),
        ])
    )
}

private func bufferDelta(
    _ delta: String,
    fixture: CodexActiveTurnFixture,
    turnID: AgentTurnID? = nil
) async {
    await fixture.adapter.handleNotificationForTesting(
        method: "item/agentMessage/delta",
        params: .object([
            "threadId": .string(fixture.threadID.rawValue),
            "turnId": .string((turnID ?? fixture.turnID).rawValue),
            "delta": .string(delta),
        ])
    )
}

private func lastRequestID(
    from process: ScriptedAppServerProcess
) async throws -> Int {
    guard let data = await process.writtenData().last,
        let id = try jsonObject(from: data)["id"] as? Int
    else { throw FixtureReadError.unavailable }
    return id
}

private actor RecordingCodexToolExecutor: CodexDynamicToolExecuting {
    private(set) var calls: [TerminalToolCall] = []

    func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        calls.append(call)
        return .inputAccepted(.init(acceptedRevision: 1, byteCount: 0))
    }
}

private actor GateCodexToolExecutor: CodexDynamicToolExecuting {
    private let blockedThreads: Set<String>
    private(set) var calledThreads: [String] = []
    private var cancellations = 0
    private var gates: [String: CheckedContinuation<Void, Error>] = [:]

    init(blockedThreads: Set<String>) {
        self.blockedThreads = blockedThreads
    }

    func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        calledThreads.append(threadID.rawValue)
        if blockedThreads.contains(threadID.rawValue) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gates[threadID.rawValue] = continuation
                }
            } onCancel: {
                Task { await self.cancel(threadID: threadID.rawValue) }
            }
        }
        return .inputAccepted(.init(acceptedRevision: 1, byteCount: 0))
    }

    func release(threadID: String) {
        gates.removeValue(forKey: threadID)?.resume()
    }

    func waitForCallCount(_ count: Int) async {
        while calledThreads.count < count { await Task.yield() }
    }

    func waitForCancellationCount(_ count: Int) async {
        while cancellations < count { await Task.yield() }
    }

    private func cancel(threadID: String) {
        guard let continuation = gates.removeValue(forKey: threadID) else {
            return
        }
        cancellations += 1
        continuation.resume(throwing: CancellationError())
    }
}

private actor StubbornCodexToolExecutor: CodexDynamicToolExecuting {
    private var started = false
    private var released = false

    func execute(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        call: TerminalToolCall
    ) async throws -> TerminalToolResult {
        started = true
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return .inputAccepted(.init(acceptedRevision: 1, byteCount: 0))
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() { released = true }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
}

private func testLaunchConfiguration() -> CodexLaunchConfiguration {
    CodexLaunchConfiguration(
        executable: testURL("/codex"),
        runtimeDirectory: testURL("/runtime"),
        environment: [:]
    )
}

private func startMappedThread(
    adapter: CodexAppServerAdapter,
    process: ScriptedAppServerProcess
) async throws -> AgentThreadID {
    let starting = Task { try await adapter.startThread() }
    await process.waitForWriteCount(1)
    await process.emit(.standardOutput(jsonLine(
        #"{"id":1,"result":{"codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-cli/0.144.2"}}"#
    )))
    await process.waitForWriteCount(3)
    await process.emit(.standardOutput(jsonLine(
        #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
    )))
    return try await starting.value
}

private func startMappedTurn(
    adapter: CodexAppServerAdapter,
    process: ScriptedAppServerProcess,
    threadID: AgentThreadID,
    turnID: String,
    requestID: Int,
    writeCount: Int
) async throws -> AgentTurnID {
    let starting = Task {
        try await adapter.startTurn(threadID: threadID, prompt: "prompt")
    }
    await process.waitForWriteCount(writeCount)
    await process.emit(.standardOutput(jsonLine(
        #"{"id":\#(requestID),"result":{"turn":{"id":"\#(turnID)"}}}"#
    )))
    return try await starting.value
}

private enum FixtureReadError: Error { case unavailable }

private func fixtureText(_ name: String) throws -> String {
    var sourcePath = #filePath
    if sourcePath.first != "/" {
        var workingDirectory = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.getcwd(&workingDirectory, workingDirectory.count) != nil
        else { throw FixtureReadError.unavailable }
        let bytes = workingDirectory.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        sourcePath = String(decoding: bytes, as: UTF8.self) + "/" + sourcePath
    }
    let testsDirectory = "/" + sourcePath.split(separator: "/").dropLast()
        .joined(separator: "/")
    let path = testsDirectory + "/Fixtures/CodexAppServer/\(name).jsonl"
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY) }
    guard descriptor >= 0 else { throw FixtureReadError.unavailable }
    defer { _ = Darwin.close(descriptor) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0 else { throw FixtureReadError.unavailable }
        if count == 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: bytes, as: UTF8.self)
}
