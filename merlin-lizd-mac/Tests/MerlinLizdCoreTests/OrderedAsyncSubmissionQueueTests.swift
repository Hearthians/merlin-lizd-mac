import Testing
@testable import MerlinLizdCore

@Suite("ordered async submissions")
struct OrderedAsyncSubmissionQueueTests {
    @Test("a gated old submission cannot overtake a newer submission")
    func preservesOldThenNewOrder() async {
        let queue = OrderedAsyncSubmissionQueue()
        let gate = AsyncStartGate()
        let recorder = SubmissionRecorder()

        queue.submit {
            await gate.wait()
            await recorder.record("old")
        }
        queue.submit {
            await recorder.record("new")
        }

        await gate.waitUntilEntered()
        #expect(await recorder.values().isEmpty)
        await gate.open()
        await queue.finish()

        #expect(await recorder.values() == ["old", "new"])
        #expect(await recorder.latest() == "new")
    }

    @Test("rapid priorities are delivered in selection order")
    func preservesRapidPriorityOrder() async {
        let queue = OrderedAsyncSubmissionQueue()
        let recorder = SubmissionRecorder()

        queue.submit { await recorder.record("recent") }
        queue.submit { await recorder.record("open") }
        queue.submit { await recorder.record("selected") }
        await queue.finish()

        #expect(await recorder.values() == ["recent", "open", "selected"])
        #expect(await recorder.latest() == "selected")
    }

    @Test("shutdown drains active work and rejects pending or late submissions")
    func shutdownRejectsPendingAndLateWork() async {
        let queue = OrderedAsyncSubmissionQueue()
        let gate = AsyncStartGate()
        let recorder = SubmissionRecorder()

        queue.submit {
            await gate.wait()
            await recorder.record("active")
        }
        queue.submit { await recorder.record("pending") }
        await gate.waitUntilEntered()

        let shutdown = Task {
            await queue.cancelPendingAndFinish()
        }
        while queue.acceptingSubmissionsForTesting() {
            await Task.yield()
        }
        await gate.open()
        await shutdown.value
        queue.submit { await recorder.record("late") }
        await queue.finish()

        #expect(await recorder.values() == ["active"])
    }
}

private actor SubmissionRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }

    func latest() -> String? {
        recorded.last
    }
}
