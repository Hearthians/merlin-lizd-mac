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
    case interrupted
    case crashed
    case turnEnded
    case pinLost
    case controllerRetained(RetainedTemporaryPaneReason)
}

public enum TemporaryPaneFinishOutcome: Codable, Equatable, Sendable {
    case closed(TemporaryPaneLease)
    case retained(
        TemporaryPaneLease,
        reason: TemporaryPaneRetentionReason
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
        paneID: String,
        reason: RetainedTemporaryPaneReason
    )
}
