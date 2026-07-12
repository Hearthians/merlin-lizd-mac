import Foundation

/// Accepts operations synchronously and executes them in submission order.
/// Callers do not need to create fire-and-forget tasks before crossing an actor
/// boundary, so the order observed here is the order in which they submitted.
public final class OrderedAsyncSubmissionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let acceptance = SubmissionAcceptance()
    private var tail: Task<Void, Never>?
    private var isAccepting = true

    public init() {}

    public func submit(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        guard isAccepting else {
            lock.unlock()
            return
        }
        let previous = tail
        let acceptance = acceptance
        let task = Task {
            if let previous {
                await previous.value
            }
            guard !Task.isCancelled, acceptance.isOpen() else { return }
            await operation()
        }
        tail = task
        lock.unlock()
    }

    /// Waits for every operation accepted before this call.
    public func finish() async {
        let task = currentTail()
        await task?.value
    }

    /// Rejects future submissions and skips accepted work that has not begun.
    public func cancelPendingAndFinish() async {
        let task = closeAndCurrentTail()
        await task?.value
    }

    private func closeAndCurrentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        isAccepting = false
        let task = tail
        acceptance.close()
        task?.cancel()
        return task
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    func acceptingSubmissionsForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccepting
    }
}

private final class SubmissionAcceptance: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    func isOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}
