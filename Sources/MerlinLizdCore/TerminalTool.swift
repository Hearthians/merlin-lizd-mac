import Foundation

public struct AgentThreadID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AgentTurnID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AgentTurnHandle: Hashable, Sendable {
    public let threadID: AgentThreadID
    let generationID: UUID

    init(threadID: AgentThreadID, generationID: UUID = UUID()) {
        self.threadID = threadID
        self.generationID = generationID
    }
}

public enum TerminalToolCall: Codable, Equatable, Sendable {
    case observeScreen
    case sendInput(TerminalInputBatch)
    case waitForScreen(TerminalScreenWaitRequest)
    case selectVisibleSurface(
        TmuxVisibleSelection,
        expectedRevision: UInt64
    )
    case createTemporaryPane(expectedRevision: UInt64)
    case finishTemporaryPane(leaseID: UUID, expectedRevision: UInt64)
}

public enum TemporaryPaneRetentionReason: Codable, Equatable, Sendable {
    case foregroundProcess(String)
    case backgroundJobs([String])
    case unsupportedShell(String)
    case markerAmbiguity
    case probeTimedOut
    case disconnected
    case revisionDrift(expected: UInt64, actual: UInt64)
    case userSurfaceSwitch(expectedPaneID: String, actualPaneID: String)
    case terminalWidthUncertain(required: Int, available: Int)
    case routeUnavailable
    case auditUnavailable
    case interrupted
    case crashed
    case turnEnded
    case pinLost
    case controllerRetained(RetainedTemporaryPaneReason)
    case closeNotCommitted(TmuxTemporaryPaneCloseFailureReason)
}

public struct RetainedTemporaryPaneLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let conversationKey: TerminalConversationKey
    public let origin: TmuxSurface
    public let route: TmuxRoute
    public let pane: RetainedTemporaryPane

    public init(
        id: UUID,
        conversationKey: TerminalConversationKey,
        origin: TmuxSurface,
        route: TmuxRoute,
        pane: RetainedTemporaryPane
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.origin = origin
        self.route = route
        self.pane = pane
    }
}

public struct TerminalTurnRetainedPaneAudit: Codable, Equatable, Sendable {
    public let provenance: RetainedTemporaryPaneLease
    public let reason: TemporaryPaneRetentionReason

    public init(
        provenance: RetainedTemporaryPaneLease,
        reason: TemporaryPaneRetentionReason
    ) {
        self.provenance = provenance
        self.reason = reason
    }
}

public struct TerminalTurnIndeterminatePaneAudit: Codable, Equatable,
    Sendable {
    public let provenance: RetainedTemporaryPaneLease
    public let reason: TmuxTemporaryPaneCloseIndeterminateReason

    public init(
        provenance: RetainedTemporaryPaneLease,
        reason: TmuxTemporaryPaneCloseIndeterminateReason
    ) {
        self.provenance = provenance
        self.reason = reason
    }
}

public enum TerminalTurnTerminationError: Error, Equatable, Sendable {
    case auditUnavailable([TerminalTurnRetainedPaneAudit])
    case indeterminateAuditUnavailable(
        [TerminalTurnIndeterminatePaneAudit]
    )
}

public enum TemporaryPaneFinishOutcome: Codable, Equatable, Sendable {
    case closed(TemporaryPaneLease)
    case closedWithRestoreFailure(
        TemporaryPaneLease,
        reason: TmuxOriginRestoreFailureReason
    )
    case retained(
        TemporaryPaneLease,
        reason: TemporaryPaneRetentionReason
    )
    case indeterminate(
        TemporaryPaneLease,
        reason: TmuxTemporaryPaneCloseIndeterminateReason
    )
}

public enum TerminalToolResult: Codable, Equatable, Sendable {
    case screen(TerminalScreenSnapshot)
    case inputAccepted(TerminalInputReceipt)
    case screenWait(TerminalScreenWaitResult)
    case surfaceSelected(TmuxSurface, screen: TerminalScreenSnapshot)
    case temporaryPaneCreated(
        TemporaryPaneLease,
        screen: TerminalScreenSnapshot
    )
    case temporaryPaneRetained(
        TemporaryPaneLease,
        reason: TemporaryPaneRetentionReason
    )
    case temporaryPaneFinished(TemporaryPaneFinishOutcome)
}

public enum TerminalToolRouterError: Error, Equatable, Sendable {
    case endpointUnavailable
    case pinLost
    case turnUnavailable
    case staleRevision(expected: UInt64, actual: UInt64)
    case denied(reason: String)
    case approvalDenied
    case approvalExpired
    case interrupted
    case auditUnavailable
    case terminalFailure
    case surfaceFailure
    case liveLeaseExists
    case leaseNotFound
    case temporaryPaneRetained(
        RetainedTemporaryPaneLease,
        reason: TemporaryPaneRetentionReason
    )
    case temporaryPaneAuditUnavailable(
        RetainedTemporaryPaneLease,
        reason: TemporaryPaneRetentionReason
    )
    case temporaryPaneCloseAuditUnavailable(
        TemporaryPaneLease,
        restoration: TmuxOriginRestoreOutcome
    )
    case temporaryPaneCloseIndeterminateAuditUnavailable(
        TemporaryPaneLease,
        reason: TmuxTemporaryPaneCloseIndeterminateReason
    )
}
