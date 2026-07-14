import Foundation

public struct TerminalEndpointID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum TerminalKeyboardOwner: Codable, Equatable, Sendable {
    case user
    case codex
}

public struct TerminalInputReceipt: Codable, Equatable, Sendable {
    public let acceptedRevision: UInt64
    public let byteCount: Int

    public init(acceptedRevision: UInt64, byteCount: Int) {
        self.acceptedRevision = acceptedRevision
        self.byteCount = byteCount
    }
}

public enum TerminalScreenWaitCondition: Codable, Equatable, Sendable {
    case changed(after: UInt64)
    case stable(after: UInt64, for: Duration)
}

public struct TerminalScreenWaitRequest: Codable, Equatable, Sendable {
    public let condition: TerminalScreenWaitCondition
    public let timeout: Duration

    public init(
        condition: TerminalScreenWaitCondition,
        timeout: Duration
    ) {
        self.condition = condition
        self.timeout = timeout
    }
}

public struct TerminalScreenWaitResult: Codable, Equatable, Sendable {
    public let snapshot: TerminalScreenSnapshot
    public let timedOut: Bool

    public init(snapshot: TerminalScreenSnapshot, timedOut: Bool) {
        self.snapshot = snapshot
        self.timedOut = timedOut
    }
}

public protocol TerminalSessionPort: Sendable {
    func observeScreen() async throws -> TerminalScreenSnapshot
    func sendInput(_ batch: TerminalInputBatch) async throws -> TerminalInputReceipt
    func waitForScreen(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult
    func setKeyboardOwner(_ owner: TerminalKeyboardOwner) async
}

public actor TerminalScreenChannel<ChannelClock: Clock>
where ChannelClock.Duration == Duration {
    private struct Waiter {
        let condition: TerminalScreenWaitCondition
        let continuation: CheckedContinuation<
            TerminalScreenWaitResult,
            any Error
        >
        var timeoutTask: Task<Void, Never>?
        var stableTask: Task<Void, Never>?
        var stableGeneration: UInt64 = 0
    }

    private var snapshot: TerminalScreenSnapshot
    private let clock: ChannelClock
    private let timerTaskStarter: @Sendable (
        @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>
    private var waiters: [UUID: Waiter] = [:]

    public init(initial: TerminalScreenSnapshot, clock: ChannelClock) {
        snapshot = initial
        self.clock = clock
        timerTaskStarter = { operation in
            Task { await operation() }
        }
    }

    init(
        initial: TerminalScreenSnapshot,
        clock: ChannelClock,
        timerTaskStarter: @escaping @Sendable (
            @escaping @Sendable () async -> Void
        ) -> Task<Void, Never>
    ) {
        snapshot = initial
        self.clock = clock
        self.timerTaskStarter = timerTaskStarter
    }

    public func publish(_ newSnapshot: TerminalScreenSnapshot) {
        guard newSnapshot.revision >= snapshot.revision else { return }
        snapshot = newSnapshot

        for id in Array(waiters.keys) {
            guard let waiter = waiters[id] else { continue }
            switch waiter.condition {
            case let .changed(after: revision):
                if snapshot.revision > revision {
                    complete(id: id, timedOut: false)
                }
            case let .stable(after: revision, for: duration):
                if snapshot.revision > revision {
                    startStableTimer(id: id, duration: duration)
                }
            }
        }
    }

    public func latest() -> TerminalScreenSnapshot {
        snapshot
    }

    public func wait(
        _ request: TerminalScreenWaitRequest
    ) async throws -> TerminalScreenWaitResult {
        try Task.checkCancellation()
        if isImmediatelySatisfied(request.condition) {
            return TerminalScreenWaitResult(snapshot: snapshot, timedOut: false)
        }
        if request.timeout <= .zero {
            return TerminalScreenWaitResult(snapshot: snapshot, timedOut: true)
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = Waiter(
                    condition: request.condition,
                    continuation: continuation
                )
                startTimeoutTimer(id: id, duration: request.timeout)
                if case let .stable(after: revision, for: duration)
                    = request.condition,
                    snapshot.revision > revision
                {
                    startStableTimer(id: id, duration: duration)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func isImmediatelySatisfied(
        _ condition: TerminalScreenWaitCondition
    ) -> Bool {
        switch condition {
        case let .changed(after: revision):
            snapshot.revision > revision
        case let .stable(after: revision, for: duration):
            snapshot.revision > revision && duration <= .zero
        }
    }

    private func startTimeoutTimer(id: UUID, duration: Duration) {
        let clock = clock
        let deadline = clock.now.advanced(by: duration)
        let task = timerTaskStarter {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.timeout(id: id)
        }
        waiters[id]?.timeoutTask = task
    }

    private func startStableTimer(id: UUID, duration: Duration) {
        guard duration > .zero else {
            complete(id: id, timedOut: false)
            return
        }
        guard var waiter = waiters[id] else { return }
        waiter.stableTask?.cancel()
        waiter.stableGeneration += 1
        let generation = waiter.stableGeneration
        let clock = clock
        let deadline = clock.now.advanced(by: duration)
        waiter.stableTask = timerTaskStarter {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.stableTimerFired(id: id, generation: generation)
        }
        waiters[id] = waiter
    }

    private func timeout(id: UUID) {
        complete(id: id, timedOut: true)
    }

    private func stableTimerFired(id: UUID, generation: UInt64) {
        guard waiters[id]?.stableGeneration == generation else { return }
        complete(id: id, timedOut: false)
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask?.cancel()
        waiter.stableTask?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func complete(id: UUID, timedOut: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask?.cancel()
        waiter.stableTask?.cancel()
        waiter.continuation.resume(
            returning: TerminalScreenWaitResult(
                snapshot: snapshot,
                timedOut: timedOut
            )
        )
    }
}
