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
    case duplicateRequest
    case denied
    case expired
    case cancelled
}

public actor TerminalApprovalBroker {
    private struct PendingApproval {
        let request: TerminalApprovalRequest
        let turnID: String
        let continuation: CheckedContinuation<TerminalApprovalGrant, any Error>
    }

    private struct UnconsumedGrant {
        let requestID: UUID
        let scope: TerminalApprovalScope
        let turnID: String
    }

    private var pending: [UUID: PendingApproval] = [:]
    private var grants: [UUID: UnconsumedGrant] = [:]

    public init() {}

    public func awaitApproval(
        for request: TerminalApprovalRequest,
        turnID: String
    ) async throws -> TerminalApprovalGrant {
        guard pending[request.id] == nil,
            !grants.values.contains(where: { $0.requestID == request.id })
        else {
            throw TerminalApprovalError.duplicateRequest
        }
        if Task.isCancelled {
            throw TerminalApprovalError.cancelled
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: TerminalApprovalError.cancelled)
                    return
                }
                pending[request.id] = PendingApproval(
                    request: request,
                    turnID: turnID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelRequest(request.id) }
        }
    }

    @discardableResult
    public func approveOnce(_ requestID: UUID) -> Bool {
        guard let approval = pending.removeValue(forKey: requestID) else {
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

    private func cancelRequest(_ requestID: UUID) {
        guard let approval = pending.removeValue(forKey: requestID) else {
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
}
