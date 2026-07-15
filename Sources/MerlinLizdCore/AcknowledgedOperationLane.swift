import Foundation

public enum AcknowledgedOperationLaneError: Error, Equatable, Sendable {
    case disconnected
}

/// Runs one acknowledged asynchronous operation at a time. Cancelling a
/// caller resolves that caller immediately, but an operation that has already
/// started continues to hold the lane until its acknowledgement arrives.
public final class AcknowledgedOperationLane: @unchecked Sendable {
    private struct Entry: Sendable {
        let id: UUID
        let isResolved: @Sendable () -> Bool
        let run: @Sendable () async -> Void
        let reject: @Sendable (AcknowledgedOperationLaneError) -> Void
    }

    private struct State {
        var active: Entry?
        var activeHasStarted = false
        var queued: [Entry] = []
        var isDisconnected = false
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    public func submit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let completion = AcknowledgedOperationCompletion<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                admit(
                    Entry(
                        id: id,
                        isResolved: { completion.isResolved },
                        run: {
                            do {
                                completion.finish(.success(try await operation()))
                            } catch {
                                completion.finish(.failure(error))
                            }
                        },
                        reject: { error in
                            completion.finish(.failure(error))
                        }
                    )
                )
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            self.cancel(id: id)
        }
    }

    public func disconnect() {
        let rejected: [Entry]
        let drainWaiters: [CheckedContinuation<Void, Never>]

        lock.lock()
        guard !state.isDisconnected else {
            lock.unlock()
            return
        }
        state.isDisconnected = true
        rejected = [state.active].compactMap { $0 } + state.queued
        state.queued.removeAll()
        if !state.activeHasStarted {
            state.active = nil
        }
        if state.active == nil {
            drainWaiters = state.drainWaiters
            state.drainWaiters.removeAll()
        } else {
            drainWaiters = []
        }
        lock.unlock()

        rejected.forEach { $0.reject(.disconnected) }
        drainWaiters.forEach { $0.resume() }
    }

    public func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard state.active != nil || !state.queued.isEmpty else {
                lock.unlock()
                continuation.resume()
                return
            }
            state.drainWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func admit(_ entry: Entry) {
        var shouldStart = false
        var rejection: AcknowledgedOperationLaneError?

        lock.lock()
        if entry.isResolved() {
            lock.unlock()
            return
        }
        if state.isDisconnected {
            rejection = .disconnected
        } else if state.active == nil {
            state.active = entry
            state.activeHasStarted = false
            shouldStart = true
        } else {
            state.queued.append(entry)
        }
        lock.unlock()

        if let rejection {
            entry.reject(rejection)
        } else if shouldStart {
            launch(entry)
        }
    }

    private func launch(_ entry: Entry) {
        Task.detached { [self] in
            guard begin(entry) else { return }
            await entry.run()
            finish(entry)
        }
    }

    private func begin(_ entry: Entry) -> Bool {
        var next: Entry?
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        guard state.active?.id == entry.id else {
            lock.unlock()
            return false
        }
        guard !state.isDisconnected, !entry.isResolved() else {
            state.active = nil
            state.activeHasStarted = false
            drainWaiters = promoteNextLocked()
            next = state.active
            lock.unlock()
            drainWaiters.forEach { $0.resume() }
            if let next { launch(next) }
            return false
        }
        state.activeHasStarted = true
        lock.unlock()
        return true
    }

    private func finish(_ entry: Entry) {
        var next: Entry?
        var drainWaiters: [CheckedContinuation<Void, Never>] = []

        lock.lock()
        guard state.active?.id == entry.id else {
            lock.unlock()
            return
        }
        state.active = nil
        state.activeHasStarted = false
        drainWaiters = promoteNextLocked()
        next = state.active
        lock.unlock()

        drainWaiters.forEach { $0.resume() }
        if let next {
            launch(next)
        }
    }

    private func cancel(id: UUID) {
        var next: Entry?
        var drainWaiters: [CheckedContinuation<Void, Never>] = []

        lock.lock()
        if state.active?.id == id {
            if !state.activeHasStarted {
                state.active = nil
                drainWaiters = promoteNextLocked()
                next = state.active
            }
            lock.unlock()
            drainWaiters.forEach { $0.resume() }
            if let next { launch(next) }
            return
        }
        if let index = state.queued.firstIndex(where: { $0.id == id }) {
            state.queued.remove(at: index)
        }
        lock.unlock()
    }

    /// Promotes the next unresolved entry and returns waiters only when the
    /// lane has become completely idle. The caller must hold `lock`.
    private func promoteNextLocked() -> [CheckedContinuation<Void, Never>] {
        guard !state.isDisconnected else {
            guard state.active == nil else { return [] }
            let waiters = state.drainWaiters
            state.drainWaiters.removeAll()
            return waiters
        }

        while !state.queued.isEmpty {
            let next = state.queued.removeFirst()
            guard !next.isResolved() else { continue }
            state.active = next
            state.activeHasStarted = false
            return []
        }

        let waiters = state.drainWaiters
        state.drainWaiters.removeAll()
        return waiters
    }
}

private final class AcknowledgedOperationCompletion<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var resolved = false

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if resolved {
            let result = pendingResult
            pendingResult = nil
            lock.unlock()
            continuation.resume(
                with: result ?? .failure(CancellationError())
            )
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}
