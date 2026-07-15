import Testing
@testable import MerlinLizdCore

@Suite("Acknowledged operation lane")
struct AcknowledgedOperationLaneTests {
    @Test("a second operation starts only after the first acknowledgement")
    func serializesThroughAcknowledgement() async throws {
        let lane = AcknowledgedOperationLane()
        let firstGate = AsyncStartGate()
        let recorder = AcknowledgedLaneRecorder()

        let first = Task {
            try await lane.submit {
                await recorder.started("first")
                await firstGate.wait()
                await recorder.finished("first")
                return "first receipt"
            }
        }
        await firstGate.waitUntilEntered()
        let second = Task {
            try await lane.submit {
                await recorder.started("second")
                await recorder.finished("second")
                return "second receipt"
            }
        }
        for _ in 0..<20 { await Task.yield() }

        #expect(await recorder.starts == ["first"])
        await firstGate.open()
        #expect(try await first.value == "first receipt")
        #expect(try await second.value == "second receipt")
        #expect(await recorder.starts == ["first", "second"])
        #expect(await recorder.finishes == ["first", "second"])
    }

    @Test("cancelling an active caller does not release its physical operation")
    func activeCancellationRetainsLaneUntilAcknowledgement() async throws {
        let lane = AcknowledgedOperationLane()
        let firstGate = AsyncStartGate()
        let recorder = AcknowledgedLaneRecorder()

        let first = Task {
            try await lane.submit {
                await recorder.started("first")
                await firstGate.wait()
                await recorder.finished("first")
                return "ignored"
            }
        }
        await firstGate.waitUntilEntered()
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }

        let second = Task {
            try await lane.submit {
                await recorder.started("second")
                return "second receipt"
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await recorder.starts == ["first"])

        await firstGate.open()
        #expect(try await second.value == "second receipt")
        #expect(await recorder.starts == ["first", "second"])
    }

    @Test("disconnect promptly rejects active queued and future callers")
    func disconnectRejectsEveryCallerWithoutOverlap() async {
        let lane = AcknowledgedOperationLane()
        let activeGate = AsyncStartGate()
        let recorder = AcknowledgedLaneRecorder()

        let active = Task {
            try await lane.submit {
                await recorder.started("active")
                await activeGate.wait()
                await recorder.finished("active")
                return "active receipt"
            }
        }
        await activeGate.waitUntilEntered()
        let queued = Task {
            try await lane.submit {
                await recorder.started("queued")
                return "queued receipt"
            }
        }
        for _ in 0..<20 { await Task.yield() }

        lane.disconnect()
        await #expect(throws: AcknowledgedOperationLaneError.disconnected) {
            try await active.value
        }
        await #expect(throws: AcknowledgedOperationLaneError.disconnected) {
            try await queued.value
        }
        await #expect(throws: AcknowledgedOperationLaneError.disconnected) {
            try await lane.submit { "late receipt" }
        }
        #expect(await recorder.starts == ["active"])

        await activeGate.open()
        await lane.waitUntilDrained()
        #expect(await recorder.starts == ["active"])
        #expect(await recorder.finishes == ["active"])
    }
}

private actor AcknowledgedLaneRecorder {
    private(set) var starts: [String] = []
    private(set) var finishes: [String] = []

    func started(_ label: String) {
        starts.append(label)
    }

    func finished(_ label: String) {
        finishes.append(label)
    }
}
