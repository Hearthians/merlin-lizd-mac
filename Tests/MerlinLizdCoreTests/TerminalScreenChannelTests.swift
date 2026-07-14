import Testing
import os
@testable import MerlinLizdCore

@Suite("Terminal screen channel")
struct TerminalScreenChannelTests {
    @Test("changed wait returns the first newer revision")
    func changedWaitReturnsFirstNewerRevision() async throws {
        let clock = ManualTerminalClock()
        let channel = TerminalScreenChannel(
            initial: snapshot(revision: 1, text: "one"),
            clock: clock
        )
        let waiter = Task {
            try await channel.wait(
                .init(
                    condition: .changed(after: 1),
                    timeout: .seconds(10)
                )
            )
        }
        guard await requireEventually(
            "changed-wait timeout registration",
            { clock.pendingSleepCount == 1 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }

        await channel.publish(snapshot(revision: 2, text: "two"))
        let result = try await waiter.value

        #expect(!result.timedOut)
        #expect(result.snapshot.revision == 2)
        #expect(result.snapshot.text == "two")
        #expect(await channel.latest().revision == 2)
    }

    @Test("stable wait restarts its quiet period on every newer publication")
    func stableWaitRestartsQuietPeriod() async throws {
        let clock = ManualTerminalClock()
        let channel = TerminalScreenChannel(
            initial: snapshot(revision: 1, text: "one"),
            clock: clock
        )
        let completion = WaitCompletionProbe()
        let waiter = Task {
            let result = try await channel.wait(
                .init(
                    condition: .stable(after: 1, for: .seconds(5)),
                    timeout: .seconds(20)
                )
            )
            await completion.finish()
            return result
        }
        guard await requireEventually(
            "stable-wait timeout registration",
            { clock.pendingSleepCount == 1 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }

        await channel.publish(snapshot(revision: 2, text: "two"))
        guard await requireEventually(
            "first stability registration",
            { clock.pendingSleepCount == 2 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        clock.advance(by: .seconds(4))
        await channel.publish(snapshot(revision: 3, text: "three"))
        guard await requireEventually(
            "restarted stability registration",
            { clock.pendingSleepCount == 2 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        clock.advance(by: .seconds(1))
        await settleTasks()

        #expect(!(await completion.isFinished))

        clock.advance(by: .seconds(4))
        let result = try await waiter.value

        #expect(!result.timedOut)
        #expect(result.snapshot.revision == 3)
        #expect(result.snapshot.text == "three")
    }

    @Test("timeout is a successful result containing the newest snapshot")
    func timeoutReturnsNewestSnapshot() async throws {
        let clock = ManualTerminalClock()
        let channel = TerminalScreenChannel(
            initial: snapshot(revision: 1, text: "one"),
            clock: clock
        )
        let waiter = Task {
            try await channel.wait(
                .init(
                    condition: .changed(after: 5),
                    timeout: .seconds(3)
                )
            )
        }
        guard await requireEventually(
            "timeout registration",
            { clock.pendingSleepCount == 1 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        await channel.publish(snapshot(revision: 2, text: "latest"))

        clock.advance(by: .seconds(3))
        let result = try await waiter.value

        #expect(result.timedOut)
        #expect(result.snapshot.revision == 2)
        #expect(result.snapshot.text == "latest")
    }

    @Test("cancellation removes the waiter and its timers")
    func cancellationRemovesWaiter() async {
        let clock = ManualTerminalClock()
        let channel = TerminalScreenChannel(
            initial: snapshot(revision: 1, text: "one"),
            clock: clock
        )
        let cancelled = Task {
            try await channel.wait(
                .init(
                    condition: .changed(after: 1),
                    timeout: .seconds(30)
                )
            )
        }
        guard await requireEventually(
            "cancelled-wait timeout registration",
            { clock.pendingSleepCount == 1 }
        ) else {
            cancelled.cancel()
            _ = try? await cancelled.value
            return
        }

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        guard await requireEventually(
            "cancelled-wait timer cleanup",
            { clock.pendingSleepCount == 0 }
        ) else {
            return
        }

        let active = Task {
            try await channel.wait(
                .init(
                    condition: .changed(after: 1),
                    timeout: .seconds(30)
                )
            )
        }
        guard await requireEventually(
            "replacement-wait timeout registration",
            { clock.pendingSleepCount == 1 }
        ) else {
            active.cancel()
            _ = try? await active.value
            return
        }
        await channel.publish(snapshot(revision: 2, text: "two"))
        let result = try? await active.value

        #expect(result?.snapshot.revision == 2)
        #expect(result?.timedOut == false)
    }

    @Test("timeout deadline starts when the wait is registered")
    func timeoutDeadlineStartsAtRegistration() async throws {
        let clock = ManualTerminalClock()
        let gate = TimerTaskGate()
        let completion = WaitCompletionProbe()
        let channel = gatedChannel(clock: clock, gate: gate)
        let waiter = Task {
            let result = try await channel.wait(
                .init(
                    condition: .changed(after: 5),
                    timeout: .seconds(3)
                )
            )
            await completion.finish()
            return result
        }
        guard await requireEventually(
            "gated timeout task",
            { await gate.waitingCount == 1 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }

        clock.advance(by: .seconds(3))
        await gate.releaseAll()
        let completed = await eventually {
            await completion.isFinished
        }

        #expect(completed)
        guard completed else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        let result = try await waiter.value
        #expect(result.timedOut)
        #expect(result.snapshot.revision == 1)
    }

    @Test("stability deadline starts at the qualifying publication")
    func stabilityDeadlineStartsAtPublication() async throws {
        let clock = ManualTerminalClock()
        let gate = TimerTaskGate()
        let completion = WaitCompletionProbe()
        let channel = gatedChannel(clock: clock, gate: gate)
        let waiter = Task {
            let result = try await channel.wait(
                .init(
                    condition: .stable(after: 1, for: .seconds(5)),
                    timeout: .seconds(100)
                )
            )
            await completion.finish()
            return result
        }
        guard await requireEventually(
            "gated timeout task",
            { await gate.waitingCount == 1 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }

        await channel.publish(snapshot(revision: 2, text: "two"))
        guard await requireEventually(
            "gated stability task",
            { await gate.waitingCount == 2 }
        ) else {
            await gate.releaseAll()
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        clock.advance(by: .seconds(5))
        await gate.releaseAll()
        let completed = await eventually {
            await completion.isFinished
        }

        #expect(completed)
        guard completed else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        let result = try await waiter.value
        #expect(!result.timedOut)
        #expect(result.snapshot.revision == 2)
    }

    @Test("zero stability completes before an expired timeout task")
    func zeroStabilityBeatsExpiredTimeout() async throws {
        let clock = ManualTerminalClock()
        let gate = TimerTaskGate()
        let completion = WaitCompletionProbe()
        let channel = gatedChannel(clock: clock, gate: gate)
        let waiter = Task {
            let result = try await channel.wait(
                .init(
                    condition: .stable(after: 1, for: .zero),
                    timeout: .seconds(5)
                )
            )
            await completion.finish()
            return result
        }
        guard await requireEventually(
            "gated timeout task",
            { await gate.waitingCount == 1 }
        ) else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }

        clock.advance(by: .seconds(5))
        await channel.publish(snapshot(revision: 2, text: "two"))
        await gate.releaseNext()
        guard await requireEventually(
            "released timeout registration or completion",
            {
                await completion.isFinished || clock.pendingSleepCount > 0
            }
        ) else {
            await gate.releaseAll()
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        if !(await completion.isFinished) {
            clock.advance(by: .seconds(5))
        }
        let completed = await eventually {
            await completion.isFinished
        }

        #expect(completed)
        guard completed else {
            await gate.releaseAll()
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        let result = try await waiter.value
        #expect(!result.timedOut)
        #expect(result.snapshot.revision == 2)
        await gate.releaseAll()
    }
}

private func snapshot(
    revision: UInt64,
    text: String
) -> TerminalScreenSnapshot {
    TerminalScreenSnapshot(
        revision: revision,
        columns: 10,
        rows: 1,
        cursor: .init(row: 0, column: text.count, isVisible: true),
        mode: .normal,
        text: text,
        significantRuns: [],
        changedRows: [0]
    )
}

private actor WaitCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor TimerTaskGate {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var nextID = 0
    private var waiters: [Waiter] = []

    var waitingCount: Int { waiters.count }

    func wait() async {
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            if Task.isCancelled { return }
            await withCheckedContinuation { continuation in
                waiters.append(.init(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.continuation.resume()
        }
    }

    private func cancel(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume()
    }
}

private func gatedChannel(
    clock: ManualTerminalClock,
    gate: TimerTaskGate
) -> TerminalScreenChannel<ManualTerminalClock> {
    TerminalScreenChannel(
        initial: snapshot(revision: 1, text: "one"),
        clock: clock,
        timerTaskStarter: { operation in
            Task {
                await gate.wait()
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    )
}

private func settleTasks() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@discardableResult
private func eventually(
    attempts: Int = 1_000,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func requireEventually(
    _ description: String,
    attempts: Int = 1_000,
    _ condition: () async -> Bool
) async -> Bool {
    guard await eventually(attempts: attempts, condition) else {
        Issue.record("Timed out waiting for \(description)")
        return false
    }
    return true
}

private struct ManualTerminalInstant: InstantProtocol {
    typealias Duration = Swift.Duration

    let offset: Duration

    func advanced(by duration: Duration) -> Self {
        .init(offset: offset + duration)
    }

    func duration(to other: Self) -> Duration {
        other.offset - offset
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.offset < rhs.offset
    }
}

private final class ManualTerminalClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ManualTerminalInstant

    private struct Sleep {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleeps: [Int: Sleep] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    var pendingSleepCount: Int {
        state.withLock { $0.sleeps.count }
    }

    func sleep(
        until deadline: Instant,
        tolerance: Duration?
    ) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResume = state.withLock { state in
                    guard deadline > state.now else { return true }
                    state.sleeps[id] = Sleep(
                        id: id,
                        deadline: deadline,
                        continuation: continuation
                    )
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            let sleep = state.withLock { $0.sleeps.removeValue(forKey: id) }
            sleep?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let ready = state.sleeps.values.filter {
                $0.deadline <= state.now
            }
            for sleep in ready {
                state.sleeps.removeValue(forKey: sleep.id)
            }
            return ready
        }
        for sleep in ready {
            sleep.continuation.resume()
        }
    }

}
