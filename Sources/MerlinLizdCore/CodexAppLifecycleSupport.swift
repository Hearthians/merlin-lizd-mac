import Foundation

public actor TerminalEndpointFocusArbiter {
    public typealias FocusEffect = @Sendable (TerminalEndpointID) async -> Void

    private let apply: FocusEffect
    private var requestedEndpointID: TerminalEndpointID?
    private var isApplying = false

    public init(apply: @escaping FocusEffect) {
        self.apply = apply
    }

    public func requestFocus(_ endpointID: TerminalEndpointID) async {
        requestedEndpointID = endpointID
        guard !isApplying else { return }
        isApplying = true
        while let requested = requestedEndpointID {
            requestedEndpointID = nil
            await apply(requested)
        }
        isApplying = false
    }
}

public struct CodexApprovalNotificationCandidate: Equatable, Sendable {
    public let identifier: String
    public let conversationKey: TerminalConversationKey

    public init(
        identifier: String,
        conversationKey: TerminalConversationKey
    ) {
        self.identifier = identifier
        self.conversationKey = conversationKey
    }
}

public struct CodexApprovalNotificationTracker: Sendable {
    private let limit: Int
    private var notificationKeys: [String: TerminalConversationKey] = [:]
    private var trackedIdentifiers: [String] = []

    public init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    public func conversation(
        for identifier: String
    ) -> TerminalConversationKey? {
        notificationKeys[identifier]
    }

    public mutating func consume(
        _ event: CodexSessionActivityEvent,
        foreground: TerminalConversationKey?
    ) -> [CodexApprovalNotificationCandidate] {
        switch event {
        case let .approvalRequested(key, request, _):
            return candidateIfBackground(
                key: key,
                requestID: request.id,
                foreground: foreground
            ).map { [$0] } ?? []
        case let .approvalResolved(_, requestID, _):
            forget(identifier: requestID.uuidString)
            return []
        case let .reconciliationRequired(snapshot),
            let .transitionHistoryGap(snapshot):
            let authoritative = Set(snapshot.states.values.flatMap { state in
                state.pendingApprovals.map { $0.id.uuidString }
            })
            for identifier in trackedIdentifiers
            where !authoritative.contains(identifier) {
                forget(identifier: identifier)
            }
            var candidates: [CodexApprovalNotificationCandidate] = []
            for state in snapshot.states.values {
                for request in state.pendingApprovals {
                    if let candidate = candidateIfBackground(
                        key: state.key,
                        requestID: request.id,
                        foreground: foreground
                    ) {
                        candidates.append(candidate)
                    }
                }
            }
            return candidates
        }
    }

    public mutating func removeAll() {
        notificationKeys.removeAll()
        trackedIdentifiers.removeAll()
    }

    private mutating func candidateIfBackground(
        key: TerminalConversationKey,
        requestID: UUID,
        foreground: TerminalConversationKey?
    ) -> CodexApprovalNotificationCandidate? {
        guard foreground != key else { return nil }
        let identifier = requestID.uuidString
        guard notificationKeys[identifier] == nil else { return nil }
        notificationKeys[identifier] = key
        trackedIdentifiers.append(identifier)
        while trackedIdentifiers.count > limit {
            forget(identifier: trackedIdentifiers[0])
        }
        return CodexApprovalNotificationCandidate(
            identifier: identifier,
            conversationKey: key
        )
    }

    private mutating func forget(identifier: String) {
        notificationKeys.removeValue(forKey: identifier)
        trackedIdentifiers.removeAll { $0 == identifier }
    }
}
