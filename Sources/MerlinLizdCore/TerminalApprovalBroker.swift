import Foundation

public struct TerminalApprovalGrant: Hashable, Sendable {
    public let requestID: UUID
    public let scope: TerminalApprovalScope
    fileprivate let token: UUID

    fileprivate init(
        requestID: UUID,
        scope: TerminalApprovalScope,
        token: UUID
    ) {
        self.requestID = requestID
        self.scope = scope
        self.token = token
    }
}

public enum TerminalApprovalError: Error, Equatable, Sendable {
    case invalidRequest
    case duplicateRequest
    case denied
    case expired
    case cancelled
}

public actor TerminalApprovalBroker {
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private struct PendingApproval {
        let request: TerminalApprovalRequest
        let turnID: String
        let cancellationState: CancellationState
        let continuation: CheckedContinuation<TerminalApprovalGrant, any Error>
    }

    private struct UnconsumedGrant {
        let requestID: UUID
        let scope: TerminalApprovalScope
        let turnID: String
    }

    private struct PendingObserver {
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [UUID: PendingApproval] = [:]
    private var grants: [UUID: UnconsumedGrant] = [:]
    private var pendingObservers: [UUID: [UUID: PendingObserver]] = [:]

    public init() {}

    public func awaitApproval(
        for request: TerminalApprovalRequest,
        endpointID: TerminalEndpointID,
        screen: TerminalScreenSnapshot,
        surface: TmuxSurface,
        turnID: String
    ) async throws -> TerminalApprovalGrant {
        guard let canonicalScope = try? TerminalApprovalScope(
            batch: request.batch,
            endpointID: endpointID,
            screen: screen,
            surface: surface
        ), canonicalScope == request.scope,
            request.batch.expectedRevision == screen.revision
        else {
            throw TerminalApprovalError.invalidRequest
        }
        guard pending[request.id] == nil,
            !grants.values.contains(where: { $0.requestID == request.id })
        else {
            throw TerminalApprovalError.duplicateRequest
        }
        if Task.isCancelled {
            throw TerminalApprovalError.cancelled
        }

        let cancellationState = CancellationState()
        let grant: TerminalApprovalGrant = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancellationState.isCancelled() {
                    continuation.resume(throwing: TerminalApprovalError.cancelled)
                    return
                }
                pending[request.id] = PendingApproval(
                    request: request,
                    turnID: turnID,
                    cancellationState: cancellationState,
                    continuation: continuation
                )
                resolvePendingObservers(for: request.id, result: true)
            }
        } onCancel: {
            cancellationState.cancel()
            Task { await self.cancelRequest(request.id) }
        }
        if Task.isCancelled || cancellationState.isCancelled() {
            grants.removeValue(forKey: grant.token)
            throw TerminalApprovalError.cancelled
        }
        return grant
    }

    @discardableResult
    public func approveOnce(_ requestID: UUID) -> Bool {
        guard let approval = pending.removeValue(forKey: requestID) else {
            return false
        }
        if approval.cancellationState.isCancelled() {
            approval.continuation.resume(
                throwing: TerminalApprovalError.cancelled
            )
            return false
        }
        let token = UUID()
        let grant = TerminalApprovalGrant(
            requestID: requestID,
            scope: approval.request.scope,
            token: token
        )
        grants[token] = UnconsumedGrant(
            requestID: requestID,
            scope: approval.request.scope,
            turnID: approval.turnID
        )
        approval.continuation.resume(returning: grant)
        return true
    }

    @discardableResult
    public func deny(_ requestID: UUID) -> Bool {
        guard let approval = pending.removeValue(forKey: requestID) else {
            return false
        }
        approval.continuation.resume(throwing: TerminalApprovalError.denied)
        return true
    }

    public func consume(
        _ grant: TerminalApprovalGrant,
        matching scope: TerminalApprovalScope
    ) -> Bool {
        guard let stored = grants.removeValue(forKey: grant.token) else {
            return false
        }
        return stored.requestID == grant.requestID
            && stored.scope == grant.scope
            && stored.scope == scope
    }

    public func invalidateRoute(_ endpointID: TerminalEndpointID) {
        expirePending { $0.request.scope.endpointID == endpointID }
        grants = grants.filter { $0.value.scope.endpointID != endpointID }
    }

    public func invalidateScreen(
        endpointID: TerminalEndpointID,
        currentRevision: UInt64
    ) {
        expirePending {
            $0.request.scope.endpointID == endpointID
                && $0.request.scope.screenRevision != currentRevision
        }
        grants = grants.filter {
            $0.value.scope.endpointID != endpointID
                || $0.value.scope.screenRevision == currentRevision
        }
    }

    public func cancelTurn(_ turnID: String) {
        let requestIDs = pending.compactMap { key, value in
            value.turnID == turnID ? key : nil
        }
        for requestID in requestIDs {
            guard let approval = pending.removeValue(forKey: requestID) else {
                continue
            }
            approval.continuation.resume(
                throwing: TerminalApprovalError.cancelled
            )
        }
        grants = grants.filter { $0.value.turnID != turnID }
    }

    public func pendingRequests() -> [TerminalApprovalRequest] {
        pending.values.map(\.request).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }

    func waitUntilPending(
        _ requestID: UUID,
        timeout: Duration
    ) async -> Bool {
        if pending[requestID] != nil { return true }
        if Task.isCancelled { return false }
        let observerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pending[requestID] != nil {
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolvePendingObserver(
                        requestID: requestID,
                        observerID: observerID,
                        result: false
                    )
                }
                pendingObservers[requestID, default: [:]][observerID]
                    = PendingObserver(
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
            }
        } onCancel: {
            Task {
                await self.resolvePendingObserver(
                    requestID: requestID,
                    observerID: observerID,
                    result: false
                )
            }
        }
    }

    private func cancelRequest(_ requestID: UUID) {
        guard let approval = pending.removeValue(forKey: requestID) else {
            grants = grants.filter { $0.value.requestID != requestID }
            return
        }
        approval.continuation.resume(throwing: TerminalApprovalError.cancelled)
    }

    private func expirePending(
        where predicate: (PendingApproval) -> Bool
    ) {
        let requestIDs = pending.compactMap { key, value in
            predicate(value) ? key : nil
        }
        for requestID in requestIDs {
            guard let approval = pending.removeValue(forKey: requestID) else {
                continue
            }
            approval.continuation.resume(throwing: TerminalApprovalError.expired)
        }
    }

    private func resolvePendingObservers(
        for requestID: UUID,
        result: Bool
    ) {
        guard let observers = pendingObservers.removeValue(forKey: requestID)
        else { return }
        for observer in observers.values {
            observer.timeoutTask.cancel()
            observer.continuation.resume(returning: result)
        }
    }

    private func resolvePendingObserver(
        requestID: UUID,
        observerID: UUID,
        result: Bool
    ) {
        guard let observer = pendingObservers[requestID]?
            .removeValue(forKey: observerID)
        else { return }
        if pendingObservers[requestID]?.isEmpty == true {
            pendingObservers.removeValue(forKey: requestID)
        }
        observer.timeoutTask.cancel()
        observer.continuation.resume(returning: result)
    }
}
