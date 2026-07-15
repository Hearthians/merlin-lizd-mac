import Darwin
import Testing
@testable import MerlinLizdCodexAdapter

@Suite("app-server transport", .serialized)
struct JSONLAppServerTransportTests {
    @Test("concurrent starts join one successful process start")
    func concurrentStartsJoinSuccess() async throws {
        let process = ScriptedAppServerProcess(gateStart: true)
        let transport = JSONLAppServerTransport(process: process)
        let first = Task { try await transport.start() }
        await process.waitForStartCount(1)
        let second = Task { try await transport.start() }
        await Task.yield()
        #expect(await process.startCallCount() == 1)
        await process.releaseStart()

        try await first.value
        try await second.value
        #expect(await transport.isRunningForTesting)
        await transport.shutdown()
    }

    @Test("concurrent starts join one process failure")
    func concurrentStartsJoinFailure() async {
        let process = ScriptedAppServerProcess(
            failStart: true,
            gateStart: true
        )
        let transport = JSONLAppServerTransport(process: process)
        let first = Task { try await transport.start() }
        await process.waitForStartCount(1)
        let second = Task { try await transport.start() }
        await process.releaseStart()

        await #expect(throws: JSONLAppServerTransportError.launchFailed) {
            try await first.value
        }
        await #expect(throws: JSONLAppServerTransportError.launchFailed) {
            try await second.value
        }
        #expect(await process.startCallCount() == 1)
        await transport.shutdown()
    }

    @Test("shutdown during start wins over every late start completion")
    func shutdownWinsStartingRace() async {
        let process = ScriptedAppServerProcess(gateStart: true)
        let transport = JSONLAppServerTransport(process: process)
        let starting = Task { try await transport.start() }
        await process.waitForStartCount(1)

        await transport.shutdown()
        await process.releaseStart()

        await #expect(throws: JSONLAppServerTransportError.stopped) {
            try await starting.value
        }
        #expect(await transport.isRunningForTesting == false)
        let counts = await process.lifecycleCounts()
        #expect(counts.terminate == 1)
        #expect(counts.wait == 1)
    }

    @Test("cancelled start caller cannot poison the shared start")
    func cancelledStartCallerDoesNotPoisonSharedStart() async throws {
        let process = ScriptedAppServerProcess(gateStart: true)
        let transport = JSONLAppServerTransport(process: process)
        let cancelled = Task { try await transport.start() }
        await process.waitForStartCount(1)
        let joined = Task { try await transport.start() }
        cancelled.cancel()
        await process.releaseStart()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        try await joined.value
        #expect(await transport.isRunningForTesting)
        await transport.shutdown()
    }

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

    @Test("dropping a running transport terminates and reaps its process")
    func runningTransportOwnerLossCleansUp() async throws {
        let result = try await exerciseRunningTransportOwnerLoss()
        #expect(result.transportReleased)
        #expect(result.terminateCalls == 1)
        #expect(result.waitCalls == 1)
        #expect(result.eventConsumerExited)
    }

    @Test("dropping a cancelled start still cleans up its process")
    func cancelledStartOwnerLossCleansUp() async throws {
        let result = try await exerciseCancelledStartOwnerLoss()
        #expect(result.transportReleased)
        #expect(result.terminateCalls == 1)
        #expect(result.waitCalls == 1)
    }

    @Test("dropping a concrete process kills and reaps its leader")
    func concreteProcessOwnerLossCleansUp() async throws {
        let result = try await exerciseConcreteProcessOwnerLoss()
        #expect(result.processReleased)
        #expect(result.leaderExited)
    }

    @Test("process events permanently lease one buffered consumer")
    func bufferedProcessEventConsumerIsExclusive() async {
        #expect(await exerciseBufferedEventConsumerExclusivity())
    }

    @Test("process events reject a second waiting consumer explicitly")
    func waitingProcessEventConsumerIsExclusive() async {
        #expect(await exerciseWaitingEventConsumerExclusivity())
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

    @Test("unconsumed output fails explicitly without blocking process reap")
    func concreteProcessOutputBackpressureIsBounded() async throws {
        let result = try await exerciseUnconsumedOutputProcess()
        #expect(result.completedBeforeConsumption)
        #expect(result.sawOverflow)
    }

    @Test("a blocked stdin write cannot delay termination")
    func concreteProcessBlockedWriteDoesNotBlockTermination() async throws {
        let result = try await exerciseBlockedStdinTermination()
        #expect(result.terminationWasPrompt)
        #expect(result.writeFailed)
    }

    @Test("blocked stdin bounds retained requests and bytes")
    func blockedStdinQueueIsBounded() async throws {
        let result = try await exerciseBoundedStdinQueue()
        #expect(result.overflowWasTyped)
        #expect(result.maximumRetainedRequests == 2)
        #expect(result.maximumRetainedBytes == 256 * 1_024)
    }

    @Test("cancelling a queued stdin write releases capacity and preserves FIFO")
    func queuedStdinCancellationReleasesCapacity() async throws {
        let result = try await exerciseQueuedStdinCancellation()
        #expect(result.cancelledPromptly)
        #expect(result.replacementWasAccepted)
        #expect(result.outputPreservedFIFO)
    }

    @Test("cancelling the active stdin write retains its physical lane")
    func activeStdinCancellationRetainsLane() async throws {
        let result = try await exerciseActiveStdinCancellation()
        #expect(result.cancelledPromptly)
        #expect(result.retainedActiveRequest)
        #expect(result.overflowWhileActive)
        #expect(result.outputIncludedCancelledActiveWrite)
    }

    @Test("termination fails active and queued stdin callers exactly once")
    func stdinTerminationRaceIsBounded() async throws {
        let result = try await exerciseStdinTerminationRace()
        #expect(result.activeFailed)
        #expect(result.queuedFailed)
        #expect(result.retainedRequestsAfterClose == 0)
        #expect(result.physicalStarts == 1)
        #expect(result.newWriteWasRejected)
    }

    @Test("descendants retaining pipes cannot delay leader reap")
    func concreteProcessDescendantPipeLifetimeIsBounded() async throws {
        #expect(try await exerciseDescendantPipeLifetimeIsBounded())
    }

    @Test("continuous descendant output obeys an absolute post-leader deadline")
    func continuousDescendantOutputHasAbsoluteDeadline() async throws {
        let result = try await exerciseContinuousDescendantDrainDeadline()
        #expect(result.sawTypedDrainLimit)
        #expect(result.elapsed < .milliseconds(500))
        #expect(result.descendantExited)
        #expect(result.descriptorDelta <= 2)
    }

    @Test("process test cleanup has an independent hard deadline")
    func processTestCleanupHardDeadlineIsBounded() async throws {
        let result = try await exerciseHardDeadlineTestCleanup()
        #expect(result.preservedOperationTimeout)
        #expect(result.elapsed < .milliseconds(250))
        #expect(result.emergencyCleanupCalls == 1)
        #expect(result.cleanupTaskExited)
        #expect(result.operationTaskExited)
    }

    @Test("continuous descendant fixture cleans up after a forced failure")
    func continuousDescendantForcedFailureCleansUp() async throws {
        let result = try await exerciseContinuousDescendantForcedFailure()
        #expect(result.descendantExited)
        #expect(result.directoryRemoved)
    }

    @Test("fixture cleanup signals only the exact captured process identity")
    func fixtureCleanupSignalsMatchingIdentity() {
        let result = exerciseMatchingFixtureProcessIdentitySignal()
        #expect(result.signalWasSent)
        #expect(result.signalledProcessID == result.expectedProcessID)
        #expect(result.signal == SIGKILL)
    }

    @Test("fixture cleanup rejects reused PIDs and changed executables")
    func fixtureCleanupRejectsChangedIdentity() {
        let result = exerciseChangedFixtureProcessIdentitySignals()
        #expect(result.changedStartTimeWasRejected)
        #expect(result.changedExecutableWasRejected)
        #expect(result.signalCount == 0)
    }

    @Test("fixture cleanup never signals an absent process")
    func fixtureCleanupDoesNotSignalAbsentProcess() {
        let result = exerciseAbsentFixtureProcessIdentitySignal()
        #expect(result.wasTreatedAsGone)
        #expect(result.signalCount == 0)
    }

    @Test("fixture deinit cleanup cannot bypass process identity checks")
    func fixtureDeinitCleanupChecksIdentity() throws {
        let result = try exerciseFixtureCleanupDeinitIdentityChecks()
        #expect(result.exactPIDSignalCount == 0)
        #expect(result.descendantSignalCount == 0)
        #expect(result.descendantDirectoryRemoved)
    }

    @Test("concurrent stdin writes are acknowledged in FIFO order")
    func concreteProcessWritesAreFIFO() async throws {
        let result = try await exerciseFIFOProcessWrites()
        #expect(result.outputByteCount == result.expectedByteCount)
        #expect(result.matches)
    }

    @Test("launch failure and termination close every owned descriptor")
    func concreteProcessClosesDescriptors() async throws {
        let deltas = try await exerciseProcessDescriptorCleanup()
        #expect(deltas.afterLaunchFailures <= 2)
        #expect(deltas.afterTermination <= 2)
    }

    @Test("correlates concurrent integer responses")
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
            "{\"id\":\(secondID),\"result\":{\"value\":2},\"extra\":true}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"id\":\(firstID),\"result\":{\"value\":1}}"
        )))

        #expect(try await first.value == .object(["value": .number(1)]))
        #expect(try await second.value == .object(["value": .number(2)]))
        await transport.shutdown()
    }

    @Test("0.144.2 requests and responses omit JSON-RPC version headers")
    func appServerWireOmitsJSONRPCHeader() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()

        let request = Task {
            try await transport.request(
                method: "initialize",
                params: .object(["capabilities": .object([:])])
            )
        }
        await process.waitForWriteCount(1)
        let outbound = try jsonObject(from: await process.writtenData()[0])
        #expect(outbound["jsonrpc"] == nil)
        #expect(outbound["id"] as? Int == 1)
        #expect(outbound["method"] as? String == "initialize")

        await process.emit(.standardOutput(jsonLine(
            #"{"id":1,"result":{"ready":true}}"#
        )))
        #expect(try await request.value == .object(["ready": .bool(true)]))

        try await transport.respond(to: .string("tool-1"), result: .object([:]))
        try await transport.respondError(
            to: .string("tool-2"),
            code: -32601,
            message: "Method not found"
        )
        let responses = await process.writtenData()
        #expect(try jsonObject(from: responses[1])["jsonrpc"] == nil)
        #expect(try jsonObject(from: responses[2])["jsonrpc"] == nil)
        await transport.shutdown()
    }

    @Test("notifications omit ids params and JSON-RPC headers when absent")
    func sendsHeaderlessNotification() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()

        try await transport.sendNotification(method: "initialized")

        let object = try jsonObject(from: await process.writtenData()[0])
        #expect(Set(object.keys) == ["method"])
        #expect(object["method"] as? String == "initialized")
        await transport.shutdown()
    }

    @Test("legacy JSON-RPC header is optional but must be 2.0")
    func validatesOptionalLegacyJSONRPCHeader() async throws {
        let compatibleProcess = ScriptedAppServerProcess()
        let compatible = JSONLAppServerTransport(process: compatibleProcess)
        try await compatible.start()
        let compatibleRequest = Task {
            try await compatible.request(method: "legacy-compatible")
        }
        await compatibleProcess.waitForWriteCount(1)
        await compatibleProcess.emit(.standardOutput(jsonLine(
            #"{"jsonrpc":"2.0","id":1,"result":true}"#
        )))
        #expect(try await compatibleRequest.value == .bool(true))
        await compatible.shutdown()

        for invalidHeader in [#""1.0""#, "null"] {
            let process = ScriptedAppServerProcess()
            let transport = JSONLAppServerTransport(process: process)
            try await transport.start()
            let request = Task { try await transport.request(method: "legacy") }
            await process.waitForWriteCount(1)
            await process.emit(.standardOutput(jsonLine(
                "{\"jsonrpc\":\(invalidHeader),\"id\":1,\"result\":true}"
            )))

            await #expect(throws: JSONLAppServerTransportError.invalidMessage) {
                try await request.value
            }
        }
    }

    @Test("string response ID never correlates an integer request ID")
    func responseIDTypesAreExact() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "exact") }
        await process.waitForWriteCount(1)

        await process.emit(.standardOutput(jsonLine(
            "{\"id\":\"1\",\"result\":\"wrong\"}"
        )))
        while await transport.processedLineCountForTesting == 0 {
            await Task.yield()
        }
        #expect(await transport.pendingRequestCountForTesting == 1)
        await process.emit(.standardOutput(jsonLine(
            "{\"id\":1,\"result\":\"right\"}"
        )))
        #expect(try await request.value == .string("right"))
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
            "{\"id\":1,\"res"
        )))
        await process.emit(.standardOutput(testData(
            "ult\":1}\r\n{\"id\":2,\"result\":2}\n{\"id\":3,\"result\":3}"
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
            "{\"method\":\"turn/completed\",\"params\":{\"turn\":\"t\"},\"future\":7}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"id\":\"server-1\",\"method\":\"item/tool/call\",\"params\":{\"callId\":\"c\"},\"future\":7}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"method\":\"turn/null\",\"params\":null,\"future\":7}"
        )))

        let first = try await transport.nextServerMessage()
        let second = try await transport.nextServerMessage()
        let third = try await transport.nextServerMessage()
        #expect(first == .notification(
            method: "turn/completed",
            params: .object(["turn": .string("t")])
        ))
        #expect(second == .request(
            id: .string("server-1"),
            method: "item/tool/call",
            params: .object(["callId": .string("c")])
        ))
        #expect(third == .notification(method: "turn/null", params: .null))
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
            "{\"id\":9007199254740993,\"method\":\"item/tool/call\"}"
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
            "{\"method\":\"turn/started\"}"
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
            "{\"method\":\"future/event\",\"params\":{\"x\":1}}"
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
            "{\"id\":\"future-9\",\"method\":\"future/request\",\"params\":{}}"
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

    @Test("terminal failure discards every queued server message")
    func failureDiscardsQueuedServerMessages() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            knownServerRequestMethods: ["item/tool/call"]
        )
        try await transport.start()
        await process.emit(.standardOutput(jsonLine(
            "{\"id\":\"queued\",\"method\":\"item/tool/call\"}"
        )))
        await process.emit(.standardOutput(testData("malformed\n")))
        while await transport.processedLineCountForTesting < 2 {
            await Task.yield()
        }

        await #expect(throws: JSONLAppServerTransportError.invalidMessage) {
            try await transport.nextServerMessage()
        }
        #expect(await transport.queuedMessageCountForTesting == 0)
    }

    @Test("shutdown discards queued server messages")
    func shutdownDiscardsQueuedServerMessages() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        await process.emit(.standardOutput(jsonLine(
            "{\"method\":\"queued\"}"
        )))
        while await transport.processedLineCountForTesting == 0 {
            await Task.yield()
        }
        await transport.shutdown()

        await #expect(throws: JSONLAppServerTransportError.stopped) {
            try await transport.nextServerMessage()
        }
        #expect(await transport.queuedMessageCountForTesting == 0)
    }

    @Test("a second message stream can never replace the first consumer")
    func messageConsumerLeaseIsPermanent() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let first = transport.messages()
        var firstIterator = first.makeAsyncIterator()
        await process.emit(.standardOutput(jsonLine(
            "{\"method\":\"first\"}"
        )))
        _ = try await firstIterator.next()

        let second = transport.messages()
        var secondIterator = second.makeAsyncIterator()
        await #expect(
            throws: JSONLAppServerTransportError.messageConsumerAlreadyWaiting
        ) {
            try await secondIterator.next()
        }
        await transport.shutdown()
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
        #expect(
            await transport.maximumBufferedStandardOutputBytesForTesting
                <= JSONLAppServerTransport.maximumLineBytes
        )
    }

    @Test("inbound line limit accepts the exact boundary")
    func acceptsExactInboundLineBoundary() async throws {
        let response = testData(
            "{\"id\":1,\"result\":true}"
        )
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(
            process: process,
            maximumLineBytes: response.count
        )
        try await transport.start()
        let request = Task { try await transport.request(method: "m") }
        await process.waitForWriteCount(1)
        await process.emit(.standardOutput(response + testBytes([0x0A])))

        #expect(try await request.value == .bool(true))
        await transport.shutdown()
    }

    @Test("outbound line limit includes newline and is exact")
    func boundsOutboundLinesExactly() async throws {
        let exactProcess = ScriptedAppServerProcess()
        let exact = JSONLAppServerTransport(
            process: exactProcess,
            maximumLineBytes: 64
        )
        try await exact.start()
        let accepted = Task {
            try await exact.request(
                method: "m",
                params: .string(String(repeating: "x", count: 30))
            )
        }
        await exactProcess.waitForWriteCount(1)
        #expect((await exactProcess.writtenData()[0]).count == 64)
        accepted.cancel()
        _ = try? await accepted.value
        await exact.shutdown()

        let rejectedProcess = ScriptedAppServerProcess()
        let rejected = JSONLAppServerTransport(
            process: rejectedProcess,
            maximumLineBytes: 64
        )
        try await rejected.start()
        await #expect(
            throws: JSONLAppServerTransportError.outboundLineTooLarge(
                maximumBytes: 64
            )
        ) {
            try await rejected.request(
                method: "m",
                params: .string(String(repeating: "x", count: 31))
            )
        }
        #expect((await rejectedProcess.writtenData()).isEmpty)
        await rejected.shutdown()
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
            "{\"method\":\"ok\"}"
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

    @Test("process output overflow fails every pending request explicitly")
    func processOutputOverflowFailsPending() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "pending") }
        await process.waitForWriteCount(1)
        await process.emit(.outputOverflow(maximumBufferedEvents: 32))

        await #expect(
            throws: JSONLAppServerTransportError.processOutputOverflow(
                maximumBufferedEvents: 32
            )
        ) {
            try await request.value
        }
    }

    @Test("post-leader output drain limit fails pending requests explicitly")
    func processOutputDrainLimitFailsPending() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "pending") }
        await process.waitForWriteCount(1)
        await process.emit(.outputDrainLimitExceeded(
            maximumBytes: 4 * 1_024 * 1_024
        ))

        await #expect(
            throws: JSONLAppServerTransportError
                .processOutputDrainLimitExceeded(
                    maximumBytes: 4 * 1_024 * 1_024
                )
        ) {
            try await request.value
        }
    }

    @Test("stdin queue overflow fails pending requests with its exact bounds")
    func processWriteQueueOverflowFailsPending() async throws {
        let process = ScriptedAppServerProcess(writeError: .writeQueueOverflow(
            maximumRequests: 2,
            maximumBytes: 256 * 1_024
        ))
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()

        await #expect(
            throws: JSONLAppServerTransportError.processWriteQueueOverflow(
                maximumRequests: 2,
                maximumBytes: 256 * 1_024
            )
        ) {
            try await transport.request(method: "overflow")
        }
    }

    @Test("losing the process event lease fails pending requests explicitly")
    func processEventConsumerLossFailsPending() async throws {
        let process = ScriptedAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "pending") }
        await process.waitForWriteCount(1)
        await process.emit(.eventConsumerUnavailable)

        await #expect(
            throws: JSONLAppServerTransportError
                .processEventConsumerUnavailable
        ) {
            try await request.value
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
            "{\"id\":1,\"result\":{}}"
        )))
        #expect(await transport.isRunningForTesting)
        await transport.shutdown()
    }

    @Test("request cancellation propagates to its exact process write")
    func requestCancellationCancelsExactWrite() async throws {
        let process = CancellationRecordingAppServerProcess()
        let transport = JSONLAppServerTransport(process: process)
        try await transport.start()
        let request = Task { try await transport.request(method: "blocked") }
        await process.waitForWriteCount(1)

        request.cancel()
        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        await process.waitForWriteCancellationCount(1)
        #expect(await process.writeCancellationCount() == 1)
        #expect(await transport.pendingRequestCountForTesting == 0)
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
            "{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"raw secret omitted\",\"data\":{\"token\":\"x\"}}}"
        )))
        await process.emit(.standardOutput(jsonLine(
            "{\"id\":2,\"result\":true}"
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
