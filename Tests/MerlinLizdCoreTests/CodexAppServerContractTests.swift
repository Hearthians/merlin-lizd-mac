import Darwin
import Testing
@testable import MerlinLizdCore
@testable import MerlinLizdCodexAdapter

@Suite("Codex app-server 0.144.2 contract", .serialized)
struct CodexAppServerContractTests {
    @Test("checked-in fixtures cover the complete frozen V1 method surface")
    func fixtureCoverage() throws {
        let thread = try fixtureText("thread-start-resume")
        let turn = try fixtureText("turn-stream")
        let dynamic = try fixtureText("dynamic-tools")
        let errors = try fixtureText("errors")
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
        #expect(errors.contains(#""code":"usageLimitExceeded""#))
        #expect(errors.contains(#""threadId":17"#))
        #expect(errors.contains(#""method":"account/authentication/required""#))
        #expect(errors.contains(#""fixture":"processCrash""#))
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
        await process.waitForWriteCount(3)
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
            #"{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1"}}}"#
        )))
        let turnID = try await turnStart.value

        let steer = Task {
            try await adapter.steerTurn(
                threadID: threadID,
                turnID: turnID,
                prompt: "more"
            )
        }
        await process.waitForWriteCount(4)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":4,"result":{}}"#
        )))
        try await steer.value

        let interrupt = Task {
            await adapter.interruptTurn(threadID: threadID, turnID: turnID)
        }
        await process.waitForWriteCount(5)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":5,"result":{}}"#
        )))
        await interrupt.value

        let archive = Task { try await adapter.archiveThread(threadID) }
        await process.waitForWriteCount(6)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":6,"result":{}}"#
        )))
        try await archive.value

        let unarchive = Task { try await adapter.unarchiveThread(threadID) }
        await process.waitForWriteCount(7)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":7,"result":{}}"#
        )))
        try await unarchive.value

        let delete = Task { try await adapter.deleteThread(threadID) }
        await process.waitForWriteCount(8)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":8,"result":{}}"#
        )))
        try await delete.value

        let writes = await process.writtenData()
        let requests = try writes.map(jsonObject)
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

    @Test("unknown and failure notifications map without raw diagnostics")
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
        #expect(await adapter.replayedEventsForTesting(threadID) == [
            .turnFailed(nil, .protocolFailure),
        ])

        await adapter.handleNotificationForTesting(
            method: "error",
            params: .object([
                "code": .string("usageLimitExceeded"),
                "message": .string("private diagnostic"),
            ])
        )
        #expect(await adapter.availabilityForTesting == .overloaded)

        await adapter.handleNotificationForTesting(
            method: "account/authentication/required",
            params: .object([:])
        )
        #expect(await adapter.availabilityForTesting == .authenticationRequired)

        await adapter.consumerFailedForTesting()
        #expect(await adapter.availabilityForTesting == .crashed)
        #expect(String(describing: await adapter.replayedEventsForTesting(threadID))
            .contains("private diagnostic") == false)
        await adapter.shutdown()
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
            #"{"jsonrpc":"2.0","id":1,"result":{"codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-cli/0.144.2"}}"#
        )))
        await process.waitForWriteCount(2)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread-1"}}}"#
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
        await process.waitForWriteCount(3)
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"live-turn","delta":"live"}}"#
        )))
        await process.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":3,"result":{"thread":{"id":"thread-1","turns":[{"id":"old-turn","items":[{"type":"userMessage","content":[{"type":"inputText","text":"old prompt"}]},{"type":"agentMessage","text":"old answer"}]}]}}}"#
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
        let resume = try jsonObject(from: writes[2])
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
        #"{"jsonrpc":"2.0","id":1,"result":{"codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-cli/0.144.2"}}"#
    )))
    await process.waitForWriteCount(2)
    await process.emit(.standardOutput(jsonLine(
        #"{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"thread-1"}}}"#
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
