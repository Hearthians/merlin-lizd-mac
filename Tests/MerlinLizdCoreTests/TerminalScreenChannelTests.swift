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
        await clock.waitForPendingSleeps(1)

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
        await clock.waitForPendingSleeps(1)

        await channel.publish(snapshot(revision: 2, text: "two"))
        await clock.waitForPendingSleeps(2)
        clock.advance(by: .seconds(4))
        await channel.publish(snapshot(revision: 3, text: "three"))
        await clock.waitForPendingSleeps(2)
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
        await clock.waitForPendingSleeps(1)
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
        await clock.waitForPendingSleeps(1)

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        await clock.waitForPendingSleeps(0)

        let active = Task {
            try await channel.wait(
                .init(
                    condition: .changed(after: 1),
                    timeout: .seconds(30)
                )
            )
        }
        await clock.waitForPendingSleeps(1)
        await channel.publish(snapshot(revision: 2, text: "two"))
        let result = try? await active.value

        #expect(result?.snapshot.revision == 2)
        #expect(result?.timedOut == false)
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

private func settleTasks() async {
    for _ in 0..<20 {
        await Task.yield()
    }
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

    func waitForPendingSleeps(_ expected: Int) async {
        while state.withLock({ $0.sleeps.count }) != expected {
            await Task.yield()
        }
    }
}
