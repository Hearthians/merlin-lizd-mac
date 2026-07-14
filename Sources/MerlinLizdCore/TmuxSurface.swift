import Foundation

public struct TmuxSurface: Codable, Equatable, Sendable {
    public let sessionIdentity: TmuxSessionIdentity
    public let windowID: String
    public let paneID: String
    public let currentCommand: String

    public init(
        sessionIdentity: TmuxSessionIdentity,
        windowID: String,
        paneID: String,
        currentCommand: String
    ) {
        self.sessionIdentity = sessionIdentity
        self.windowID = windowID
        self.paneID = paneID
        self.currentCommand = currentCommand
    }
}

public enum TmuxVisibleSelection: Codable, Equatable, Sendable {
    case nextWindow
    case previousWindow
    case windowIndex(Int)
    case paneLeft
    case paneRight
    case paneUp
    case paneDown
    case nextPane
    case previousPane
}

public struct TemporaryPaneLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let conversationKey: TerminalConversationKey
    public let origin: TmuxSurface
    public let temporary: TmuxSurface

    public init(
        id: UUID,
        conversationKey: TerminalConversationKey,
        origin: TmuxSurface,
        temporary: TmuxSurface
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.origin = origin
        self.temporary = temporary
    }
}

public struct TmuxRoute: Codable, Equatable, Sendable {
    public let target: TerminalTarget
    public let sessionName: String
    public let expectedIdentity: TmuxSessionIdentity

    public init(
        target: TerminalTarget,
        sessionName: String,
        expectedIdentity: TmuxSessionIdentity
    ) {
        self.target = target
        self.sessionName = sessionName
        self.expectedIdentity = expectedIdentity
    }
}

public enum TmuxTemporaryPaneCloseFailureReason: String, Codable, Equatable,
    Sendable {
    case cancelled
    case paneNotOwned
    case leasePaneMissing
    case workerNotReady
    case timedOut
    case transportUnavailable
    case commandFailed
    case invalidSurfaceOutput
    case sessionIdentityMismatch
    case unavailable
}

public enum TmuxOriginRestoreFailureReason: String, Codable, Equatable,
    Sendable {
    case cancelled
    case workerNotReady
    case timedOut
    case transportUnavailable
    case commandFailed
    case invalidSurfaceOutput
    case sessionIdentityMismatch
    case originNotRestored
    case unavailable
}

public enum TmuxOriginRestoreOutcome: Codable, Equatable, Sendable {
    case restored
    case failed(TmuxOriginRestoreFailureReason)
}

public enum TmuxTemporaryPaneCloseOutcome: Codable, Equatable, Sendable {
    case notCommitted(reason: TmuxTemporaryPaneCloseFailureReason)
    case closed(restoration: TmuxOriginRestoreOutcome)
}

public protocol TmuxSurfaceControlling: Sendable {
    func currentSurface(route: TmuxRoute) async throws -> TmuxSurface
    func select(
        _ selection: TmuxVisibleSelection,
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface
    func createTemporaryPane(
        from: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxSurface
    func closeTemporaryPane(
        _ paneID: String,
        restoring origin: TmuxSurface,
        route: TmuxRoute
    ) async throws -> TmuxTemporaryPaneCloseOutcome
}

/// Provenance for a pane that tmux created successfully but whose current
/// surface could not be verified. The controller keeps this exact pane owned;
/// callers should retain these IDs and later pass `paneID`, the known origin,
/// and the current stable route to `closeTemporaryPane` for cleanup.
public struct RetainedTemporaryPane: Codable, Equatable, Sendable {
    public let windowID: String
    public let paneID: String

    public init(windowID: String, paneID: String) {
        self.windowID = windowID
        self.paneID = paneID
    }
}

/// Bounded tmux location metadata retained after a verified surface is found
/// somewhere other than the pane just created. Display labels, commands, and
/// diagnostics are intentionally excluded from this persisted payload.
public struct RetainedSurfaceLocation: Codable, Equatable, Sendable {
    public let sessionIdentity: TmuxSessionIdentity
    public let windowID: String
    public let paneID: String

    public init(
        sessionIdentity: TmuxSessionIdentity,
        windowID: String,
        paneID: String
    ) {
        self.sessionIdentity = sessionIdentity
        self.windowID = windowID
        self.paneID = paneID
    }
}

/// The typed cause that prevented a successfully created and retained pane
/// from being returned as a verified current surface.
public enum RetainedTemporaryPaneReason: Codable, Equatable, Sendable {
    case cancelled
    case workerNotReady
    case timedOut
    case transportUnavailable
    case commandFailed(exitCode: Int32)
    case invalidSurfaceOutput
    case sessionIdentityMismatch(
        expected: TmuxSessionIdentity,
        actual: TmuxSessionIdentity
    )
    case createdPaneNotCurrent(actual: RetainedSurfaceLocation)
    case unavailable
}

public enum TmuxSurfaceControlError: Error, Equatable, Sendable {
    case localTmuxNotFound
    case workerNotReady
    case commandFailed(exitCode: Int32)
    case invalidSurfaceOutput
    case sessionIdentityMismatch(
        expected: TmuxSessionIdentity,
        actual: TmuxSessionIdentity
    )
    case temporaryPaneRetained(
        pane: RetainedTemporaryPane,
        reason: RetainedTemporaryPaneReason
    )
    case paneNotOwned(paneID: String)
    case leasePaneMissing(paneID: String)
    case restoreFailed
}

struct TmuxPaneLocation: Equatable, Sendable {
    let windowID: String
    let paneID: String
}

enum TmuxSurfaceParser {
    static func parse(_ output: String) -> TmuxSurface? {
        guard let line = singleLine(output) else { return nil }
        let fields = line.split(
            separator: ",",
            maxSplits: 4,
            omittingEmptySubsequences: false
        )
        guard fields.count == 5 else { return nil }

        let sessionID = String(fields[0])
        let createdAt = String(fields[1])
        let windowID = String(fields[2])
        let paneID = String(fields[3])
        guard
            MerlinIdentifierValidator.isTmuxSessionID(sessionID),
            !createdAt.isEmpty,
            createdAt.allSatisfy({ $0.isASCII && $0.isNumber }),
            let createdAtEpoch = Int64(createdAt),
            MerlinIdentifierValidator.isTmuxWindowID(windowID),
            MerlinIdentifierValidator.isTmuxPaneID(paneID)
        else {
            return nil
        }

        return TmuxSurface(
            sessionIdentity: TmuxSessionIdentity(
                serverSessionID: sessionID,
                createdAtEpoch: createdAtEpoch
            ),
            windowID: windowID,
            paneID: paneID,
            currentCommand: String(fields[4])
        )
    }

    static func parsePaneLocation(_ output: String) -> TmuxPaneLocation? {
        guard let line = singleLine(output) else { return nil }
        let fields = line.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard fields.count == 2 else { return nil }

        let windowID = String(fields[0])
        let paneID = String(fields[1])
        guard
            MerlinIdentifierValidator.isTmuxWindowID(windowID),
            MerlinIdentifierValidator.isTmuxPaneID(paneID)
        else {
            return nil
        }
        return TmuxPaneLocation(windowID: windowID, paneID: paneID)
    }

    private static func singleLine(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !value.isEmpty,
            !value.contains(where: { $0.isNewline })
        else {
            return nil
        }
        return value
    }
}
