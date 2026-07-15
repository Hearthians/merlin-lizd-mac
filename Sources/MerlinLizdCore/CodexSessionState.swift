import Foundation

public enum CodexFailure: String, Codable, Equatable, Sendable {
    case authenticationRequired
    case overloaded
    case capabilityUnavailable
    case interrupted
    case crashed
    case protocolFailure
    case persistenceUnavailable
    case endpointUnavailable
    case unknown
}

public enum CodexSessionPhase: Codable, Equatable, Sendable {
    case idle
    case thinking
    case controlling
    case awaitingApproval
    case waitingForUser
    case completed
    case failed(CodexFailure)
    case interrupted
}

public struct CodexDeletionRetryState: Codable, Equatable, Sendable {
    public let stage: CodexDeletionStage
    public let failure: CodexDeletionFailure?
    public let updatedAt: Date

    public init(
        stage: CodexDeletionStage,
        failure: CodexDeletionFailure?,
        updatedAt: Date
    ) {
        self.stage = stage
        self.failure = failure
        self.updatedAt = updatedAt
    }
}

public struct CodexSessionState: Codable, Equatable, Sendable {
    public let key: TerminalConversationKey
    public let threadID: AgentThreadID?
    public let activeTurnID: AgentTurnID?
    public let phase: CodexSessionPhase
    public let messages: [AgentMessage]
    public let pendingApprovals: [TerminalApprovalRequest]
    public let archived: Bool
    public let deletionRetry: CodexDeletionRetryState?
    public let orphanedThreads: [CodexOrphanedThread]

    public init(
        key: TerminalConversationKey,
        threadID: AgentThreadID? = nil,
        activeTurnID: AgentTurnID? = nil,
        phase: CodexSessionPhase = .idle,
        messages: [AgentMessage] = [],
        pendingApprovals: [TerminalApprovalRequest] = [],
        archived: Bool = false,
        deletionRetry: CodexDeletionRetryState? = nil,
        orphanedThreads: [CodexOrphanedThread] = []
    ) {
        self.key = key
        self.threadID = threadID
        self.activeTurnID = activeTurnID
        self.phase = phase
        self.messages = messages
        self.pendingApprovals = pendingApprovals
        self.archived = archived
        self.deletionRetry = deletionRetry
        self.orphanedThreads = orphanedThreads
    }
}

public struct CodexSessionActivitySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let states: [TerminalConversationKey: CodexSessionState]

    public init(
        revision: UInt64,
        states: [TerminalConversationKey: CodexSessionState]
    ) {
        self.revision = revision
        self.states = states
    }
}

public enum CodexSessionActivityEvent: Equatable, Sendable {
    case approvalRequested(
        key: TerminalConversationKey,
        request: TerminalApprovalRequest,
        revision: UInt64
    )
    case approvalResolved(
        key: TerminalConversationKey,
        requestID: UUID,
        revision: UInt64
    )
    case reconciliationRequired(CodexSessionActivitySnapshot)

    public var revision: UInt64 {
        switch self {
        case let .approvalRequested(_, _, revision),
            let .approvalResolved(_, _, revision):
            revision
        case let .reconciliationRequired(snapshot):
            snapshot.revision
        }
    }
}
