import Testing
@testable import MerlinLizdCodexAdapter

@Suite("app-server transport", .serialized)
struct JSONLAppServerTransportTests {
    @Test("start failures and duplicate starts use bounded lifecycle errors")
    func startErrorsAreTyped() async throws {
        let failed = JSONLAppServerTransport(
            process: ScriptedAppServerProcess(failStart: true)
        )
        await #expect(throws: JSONLAppServerTransportError.launchFailed) {
            try await failed.start()
        }
        await failed.shutdown()

        let running = JSONLAppServerTransport(
            process: ScriptedAppServerProcess()
        )
        try await running.start()
        await #expect(throws: JSONLAppServerTransportError.alreadyStarted) {
            try await running.start()
        }
        await running.shutdown()
    }

    @Test("concrete process drains both pipes and reaps one exit")
    func concreteProcessOwnsPipesAndReap() async throws {
        let result = try await exerciseConcreteAppServerProcess()
        #expect(result.standardOutput == "before:hello\n")
        #expect(result.standardError == "diagnostic")
        #expect(result.firstExitCode == 0)
        #expect(result.secondExitCode == 0)
    }

    @Test("concrete process termination is idempotent and force bounded")
    func concreteProcessTerminationIsBounded() async throws {
        let result = try await exerciseTermResistantAppServerProcess()
        #expect(result.exitCode != 0)
        #expect(result.elapsed < .seconds(2))
    }

    @Test("correlates concurrent responses with integer and numeric string IDs")
    func correlatesConcurrentResponses() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()

        let first = Task {
            try await transport.request(
                method: "first",
                params: .object(["nested": .array([.bool(true), .null])])
            )
        }
        let second = Task {
            try await transport.request(method: "second", params: .object([:]))
        }
        await process.waitForWriteCount(2)
        let writes = await process.writtenData()
        let methodsByID = try jsonRequestMethodsByIntegerID(writes)
        let firstID = try #require(methodsByID.first(where: { $0.value == "first" })?.key)
        let secondID = try #require(methodsByID.first(where: { $0.value == "second" })?.key)

        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":\"\(secondID)\",\"result\":{\"value\":2},\"extra\":true}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":\(firstID),\"result\":{\"value\":1}}"
        )))

        #expect(try await first.value == .object(["value": .number(1)]))
        #expect(try await second.value == .object(["value": .number(2)]))
        await transport.shutdown()
    }

    @Test("decodes chunked CRLF and multiple lines including an EOF tail")
    func decodesChunkBoundariesAndEOFTail() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let one = Task { try await transport.request(method: "one") }
        await process.waitForWriteCount(1)
        let two = Task { try await transport.request(method: "two") }
        await process.waitForWriteCount(2)
        let three = Task { try await transport.request(method: "three") }
        await process.waitForWriteCount(3)

        await process.emit(.standardOutput(testData(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"res"
        )))
        await process.emit(.standardOutput(testData(
            "ult\":1}\r\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":2}\n{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":3}"
        )))
        await process.emit(.terminated(exitCode: 0))

        #expect(try await one.value == .number(1))
        #expect(try await two.value == .number(2))
        #expect(try await three.value == .number(3))
    }

    @Test("delivers notifications and known server requests with additive fields")
    func decodesServerMessages() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            knownServerRequestMethods: ["item/tool/call"]
        )
        try await transport.start()

        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turn\":\"t\"},\"future\":7}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":\"server-1\",\"method\":\"item/tool/call\",\"params\":{\"callId\":\"c\"},\"future\":7}"
        )))

        let first = try await transport.nextServerMessage()
        let second = try await transport.nextServerMessage()
        #expect(first == .notification(
            method: "turn/completed",
            params: .object(["turn": .string("t")])
        ))
        #expect(second == .request(
            id: .string("server-1"),
            method: "item/tool/call",
            params: .object(["callId": .string("c")])
        ))
        await transport.shutdown()
    }

    @Test("preserves integer server IDs beyond floating-point precision")
    func preservesLargeIntegerServerID() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            knownServerRequestMethods: ["item/tool/call"]
        )
        try await transport.start()
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":9007199254740993,\"method\":\"item/tool/call\"}"
        )))

        #expect(try await transport.nextServerMessage() == .request(
            id: .integer(9_007_199_254_740_993),
            method: "item/tool/call",
            params: nil
        ))
        await transport.shutdown()
    }

    @Test("message stream is pull-driven without retaining observation history")
    func exposesPullDrivenMessageStream() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let stream = transport.messages()
        var iterator = stream.makeAsyncIterator()
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"method\":\"turn/started\"}"
        )))

        #expect(try await iterator.next() == .notification(
            method: "turn/started",
            params: nil
        ))
        await transport.shutdown()
    }

    @Test("tolerates unknown notifications without failing the transport")
    func toleratesUnknownNotification() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"method\":\"future/event\",\"params\":{\"x\":1}}"
        )))

        #expect(try await transport.nextServerMessage() == .notification(
            method: "future/event",
            params: .object(["x": .number(1)])
        ))
        #expect(await transport.isRunningForTesting)
        await transport.shutdown()
    }

    @Test("answers unknown server requests with method-not-found and does not deliver them")
    func rejectsUnknownServerRequest() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            knownServerRequestMethods: ["item/tool/call"]
        )
        try await transport.start()
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":\"future-9\",\"method\":\"future/request\",\"params\":{}}"
        )))
        await process.waitForWriteCount(1)

        let response = await process.writtenData()[0]
        #expect(try jsonRPCStringID(response) == "future-9")
        #expect(try jsonRPCErrorCode(response) == -32601)
        #expect(await transport.deliveredMessageCountForTesting == 0)
        await transport.shutdown()
    }

    @Test("malformed JSON fails the transport and every pending request once")
    func malformedJSONFailsPending() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let first = Task { try await transport.request(method: "first") }
        let second = Task { try await transport.request(method: "second") }
        await process.waitForWriteCount(2)

        await process.emit(.standardOutput(testData("not-json\n")))

        await #expect(throws: JSONLAppServerTransportError.self) {
            try await first.value
        }
        await #expect(throws: JSONLAppServerTransportError.self) {
            try await second.value
        }
        #expect(await transport.pendingRequestCountForTesting == 0)
    }

    @Test("invalid UTF-8 and empty protocol lines fail closed")
    func invalidLinesFailClosed() async throws {
        for bytes in [testBytes([0xFF, 0x0A]), testBytes([0x0A])] {
            let process = ScriptedAppServerProcess()
            let transport = JSONLAppServerTransport(process: process)
            try await transport.start()
            let request = Task { try await transport.request(method: "pending") }
            await process.waitForWriteCount(1)
            await process.emit(.standardOutput(bytes))
            await #expect(throws: JSONLAppServerTransportError.self) {
                try await request.value
            }
        }
    }

    @Test("line limit is exact and fails all pending without retaining input")
    func enforcesLineLimit() async throws {
        #expect(JSONLAppServerTransport.maximumLineBytes == 4 * 1_024 * 1_024)
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "pending") }
        await process.waitForWriteCount(1)
        await process.emit(.standardOutput(testRepeatedData(
            0x61,
            count: JSONLAppServerTransport.maximumLineBytes + 1
        )))

        await #expect(throws: JSONLAppServerTransportError.self) {
            try await request.value
        }
        #expect(await transport.bufferedStandardOutputBytesForTesting == 0)
    }

    @Test("stderr retains only the deterministic final 64 KiB")
    func boundsStderrTail() async throws {
        #expect(JSONLAppServerTransport.maximumStderrTailBytes == 64 * 1_024)
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let stderr = testPatternedData(count: 70 * 1_024, modulus: 251)
        await process.emit(.standardError(testPrefix(stderr, count: 40 * 1_024)))
        await process.emit(.standardError(testDropFirst(stderr, count: 40 * 1_024)))
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"method\":\"ok\"}"
        )))
        _ = try await transport.nextServerMessage()

        #expect(
            await transport.stderrTailForTesting
                == testSuffix(stderr, count: 64 * 1_024)
        )
        await transport.shutdown()
    }

    @Test("EOF and nonzero crashes fail all pending requests with bounded errors")
    func processTerminationFailsPending() async throws {
        for exitCode: Int32 in [0, 9] {
            let process = ScriptedAppServerProcess()
            let transport = JSONLAppServerTransport(process: process)
            try await transport.start()
            let first = Task { try await transport.request(method: "first") }
            let second = Task { try await transport.request(method: "second") }
            await process.waitForWriteCount(2)
            await process.emit(.standardError(testData("secret-token")))
            await process.emit(.terminated(exitCode: exitCode))

            await #expect(throws: JSONLAppServerTransportError.self) {
                try await first.value
            }
            await #expect(throws: JSONLAppServerTransportError.self) {
                try await second.value
            }
            #expect(await transport.pendingRequestCountForTesting == 0)
            #expect(!String(describing: await transport.failureForTesting).contains("secret-token"))
        }
    }

    @Test("cancellation removes exactly its pending continuation")
    func cancellationRemovesPending() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "cancel") }
        await process.waitForWriteCount(1)

        request.cancel()
        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(await transport.pendingRequestCountForTesting == 0)
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        )))
        #expect(await transport.isRunningForTesting)
        await transport.shutdown()
    }

    @Test("JSON-RPC error responses fail only the correlated request")
    func decodesResponseErrors() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let failed = Task { try await transport.request(method: "failed") }
        await process.waitForWriteCount(1)
        let succeeded = Task { try await transport.request(method: "succeeded") }
        await process.waitForWriteCount(2)
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"raw secret omitted\",\"data\":{\"token\":\"x\"}}}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":true}"
        )))

        await #expect(throws: JSONLAppServerTransportError.self) {
            try await failed.value
        }
        #expect(try await succeeded.value == .bool(true))
        await transport.shutdown()
    }

    @Test("server message buffering fails explicitly instead of growing without bound")
    func boundsServerMessages() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let pending = Task { try await transport.request(method: "pending") }
        await process.waitForWriteCount(1)
        await process.emit(.standardOutput(notificationLines(count: 129)))

        await #expect(throws: JSONLAppServerTransportError.self) {
            try await pending.value
        }
        #expect(
            await transport.failureForTesting
                == .messageBufferOverflow(maximumMessages: 128)
        )
    }

    @Test("cancelling a server-message wait removes its continuation")
    func cancelsServerMessageWait() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let waiter = Task { try await transport.nextServerMessage() }
        await Task.yield()
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await transport.messageWaiterCountForTesting == 0)
        await transport.shutdown()
    }

    @Test("pending requests have an explicit bound")
    func boundsPendingRequests() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            maximumPendingRequests: 2
        )
        try await transport.start()
        let first = Task { try await transport.request(method: "first") }
        await process.waitForWriteCount(1)
        let second = Task { try await transport.request(method: "second") }
        await process.waitForWriteCount(2)

        await #expect(
            throws: JSONLAppServerTransportError.tooManyPendingRequests(
                maximumRequests: 2
            )
        ) {
            try await transport.request(method: "third")
        }
        first.cancel()
        second.cancel()
        _ = try? await first.value
        _ = try? await second.value
        await transport.shutdown()
    }

    @Test("only one pull consumer can wait for the next server message")
    func boundsMessageConsumers() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let first = Task { try await transport.nextServerMessage() }
        while await transport.messageWaiterCountForTesting == 0 {
            await Task.yield()
        }

        await #expect(
            throws: JSONLAppServerTransportError.messageConsumerAlreadyWaiting
        ) {
            try await transport.nextServerMessage()
        }
        first.cancel()
        _ = try? await first.value
        await transport.shutdown()
    }

    @Test("shutdown is idempotent, reaps once, and forbids later writes")
    func shutdownIsIdempotent() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()

        async let one: Void = transport.shutdown()
        async let two: Void = transport.shutdown()
        _ = await (one, two)
        await transport.shutdown()

        let counts = await process.lifecycleCounts()
        #expect(counts.terminate == 1)
        #expect(counts.wait == 1)
        await #expect(throws: JSONLAppServerTransportError.self) {
            try await transport.request(method: "after-shutdown")
        }
        #expect((await process.writtenData()).isEmpty)
    }
}
