import Foundation

public enum CodexDrawerTerminalContext: Equatable, Hashable, Sendable {
    case noSelection
    case plainLocalShell
    case unresolvedTmux
    case disconnected(TerminalConversationKey)
    case connected(TerminalConversationKey)

    public var conversationKey: TerminalConversationKey? {
        switch self {
        case let .connected(key), let .disconnected(key): key
        case .noSelection, .plainLocalShell, .unresolvedTmux: nil
        }
    }
}

public enum CodexDrawerPresentation: Equatable, Sendable {
    case collapsed
    case compact
    case expanded(fraction: Double)
}

public enum CodexDrawerComposerMode: Equatable, Sendable {
    case prompt
    case steer
}

public enum CodexDrawerKeyboardOwnership: Equatable, Sendable {
    case user
    case codex
    case takeoverPending
}

public enum CodexDrawerBadgePhase: Equatable, Sendable {
    case running
    case awaitingApproval
    case waitingForUser
    case failed
    case interrupted
}

public struct CodexDrawerBadge: Equatable, Sendable {
    public let phase: CodexDrawerBadgePhase
    public let approvalCount: Int

    public init(phase: CodexDrawerBadgePhase, approvalCount: Int) {
        self.phase = phase
        self.approvalCount = approvalCount
    }
}

public struct CodexDrawerBackgroundActivity: Equatable, Sendable {
    public let runningConversationCount: Int
    public let approvalConversationCount: Int
    public let pendingApprovalCount: Int

    public init(
        runningConversationCount: Int,
        approvalConversationCount: Int,
        pendingApprovalCount: Int
    ) {
        self.runningConversationCount = runningConversationCount
        self.approvalConversationCount = approvalConversationCount
        self.pendingApprovalCount = pendingApprovalCount
    }
}

public struct CodexDrawerAvailabilityNotice: Equatable, Sendable {
    public let message: String
    public let isRetryable: Bool

    public init(message: String, isRetryable: Bool) {
        self.message = message
        self.isRetryable = isRetryable
    }
}

public enum CodexDrawerAction: Equatable, Sendable {
    case selectTerminal(CodexDrawerTerminalContext)
    case receiveSessions([TerminalConversationKey: CodexSessionState])
    case receiveAvailability(AgentAvailability)
    case editComposer(String)
    case sendComposer
    case setExpanded(Bool)
    case resizeExpanded(fraction: Double)
    case requestTakeover
    case takeoverCompleted(TerminalConversationKey)
    case allowOnce(UUID)
    case deny(UUID)
    case retryAvailability
}

public enum CodexDrawerCommand: Equatable, Sendable {
    case submit(prompt: String, key: TerminalConversationKey)
    case steer(prompt: String, key: TerminalConversationKey)
    case stopAndTakeOver(TerminalConversationKey)
    case allowOnce(UUID)
    case deny(UUID)
    case retryAvailability
}

public struct CodexDrawerState: Equatable, Sendable {
    public static let collapsedHeight = 42.0
    public static let compactHeight = 92.0
    public static let minimumExpandedFraction = 0.2
    public static let maximumExpandedFraction = 0.5

    public private(set) var terminalContext: CodexDrawerTerminalContext
    public private(set) var sessions: [
        TerminalConversationKey: CodexSessionState
    ]
    public private(set) var availability: AgentAvailability
    public private(set) var isExpanded: Bool
    public private(set) var expandedFraction: Double

    private var composers: [TerminalConversationKey: String]
    private var ownership: [
        TerminalConversationKey: CodexDrawerKeyboardOwnership
    ]

    public init(
        terminalContext: CodexDrawerTerminalContext = .noSelection,
        sessions: [TerminalConversationKey: CodexSessionState] = [:],
        availability: AgentAvailability = .stopped,
        isExpanded: Bool = false,
        expandedFraction: Double = 0.32
    ) {
        self.terminalContext = terminalContext
        self.sessions = sessions
        self.availability = availability
        self.isExpanded = isExpanded
        self.expandedFraction = Self.clamp(expandedFraction)
        composers = [:]
        ownership = [:]
        reconcileOwnership()
    }

    public var selectedConversationKey: TerminalConversationKey? {
        terminalContext.conversationKey
    }

    public var selectedSession: CodexSessionState? {
        guard let selectedConversationKey else { return nil }
        return sessions[selectedConversationKey]
    }

    public var isActive: Bool {
        selectedSession.map(Self.isActive) ?? false
    }

    public var presentation: CodexDrawerPresentation {
        if isExpanded { return .expanded(fraction: expandedFraction) }
        return isActive ? .compact : .collapsed
    }

    public var composerMode: CodexDrawerComposerMode {
        isActive ? .steer : .prompt
    }

    public var keyboardOwnership: CodexDrawerKeyboardOwnership {
        guard let selectedConversationKey else { return .user }
        return ownership[selectedConversationKey] ?? .user
    }

    public var canSend: Bool {
        guard case .connected = terminalContext else { return false }
        guard !composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else { return false }
        switch availability {
        case .ready, .stopped: return true
        case .starting, .unsupportedVersion, .authenticationRequired,
            .capabilityUnavailable, .overloaded, .crashed:
            return false
        }
    }

    public var composerText: String {
        guard let selectedConversationKey else { return "" }
        return composers[selectedConversationKey, default: ""]
    }

    public var currentAction: String? {
        guard let phase = selectedSession?.phase else { return nil }
        switch phase {
        case .idle: return nil
        case .thinking: return "Thinking"
        case .controlling: return "Operating the visible terminal"
        case .awaitingApproval: return "Waiting for approval"
        case .waitingForUser: return "Waiting for your input"
        case .completed: return "Completed"
        case .failed: return "Stopped with an error"
        case .interrupted: return "Interrupted"
        }
    }

    public var availabilityNotice: CodexDrawerAvailabilityNotice? {
        switch availability {
        case .ready, .stopped: nil
        case .starting:
            CodexDrawerAvailabilityNotice(
                message: "Starting the local Codex service…",
                isRetryable: false
            )
        case .unsupportedVersion:
            CodexDrawerAvailabilityNotice(
                message: "This Codex version is not supported by Merlin Lizd.",
                isRetryable: false
            )
        case .authenticationRequired:
            CodexDrawerAvailabilityNotice(
                message: "Sign in with the local Codex CLI, then retry.",
                isRetryable: true
            )
        case .capabilityUnavailable:
            CodexDrawerAvailabilityNotice(
                message: "The required local Codex capability is unavailable.",
                isRetryable: true
            )
        case .overloaded:
            CodexDrawerAvailabilityNotice(
                message: "The local Codex service is busy. Try again shortly.",
                isRetryable: true
            )
        case .crashed:
            CodexDrawerAvailabilityNotice(
                message: "The local Codex service stopped unexpectedly.",
                isRetryable: true
            )
        }
    }

    public var terminalNotice: String? {
        switch terminalContext {
        case .noSelection: "Select a terminal to use Codex."
        case .plainLocalShell: "Codex is available only for tmux-backed tabs."
        case .unresolvedTmux:
            "Waiting for a stable tmux session identity."
        case .disconnected:
            "Reconnect this terminal before asking Codex to operate it."
        case .connected: nil
        }
    }

    public func composer(for key: TerminalConversationKey) -> String {
        composers[key, default: ""]
    }

    public func height(in containerHeight: Double) -> Double {
        switch presentation {
        case .collapsed: Self.collapsedHeight
        case .compact: Self.compactHeight
        case let .expanded(fraction): max(0, containerHeight) * fraction
        }
    }

    public func badge(for key: TerminalConversationKey) -> CodexDrawerBadge? {
        guard let session = sessions[key] else { return nil }
        let phase: CodexDrawerBadgePhase
        switch session.phase {
        case .thinking, .controlling:
            phase = .running
        case .awaitingApproval:
            phase = .awaitingApproval
        case .waitingForUser:
            phase = .waitingForUser
        case .failed:
            phase = .failed
        case .interrupted:
            phase = .interrupted
        case .idle, .completed:
            return nil
        }
        return CodexDrawerBadge(
            phase: phase,
            approvalCount: session.pendingApprovals.count
        )
    }

    public func badges(
        for tabs: [TerminalTabRecord]
    ) -> [String: CodexDrawerBadge] {
        var result: [String: CodexDrawerBadge] = [:]
        for tab in tabs {
            guard tab.sessionName != nil, let tmux = tab.tmuxIdentity else {
                continue
            }
            let key = TerminalConversationKey(
                terminalTarget: tab.target,
                tmux: tmux
            )
            if let badge = badge(for: key) { result[tab.id] = badge }
        }
        return result
    }

    public func backgroundActivity(
        excluding foregroundKey: TerminalConversationKey?
    ) -> CodexDrawerBackgroundActivity {
        var runningConversationCount = 0
        var approvalConversationCount = 0
        var pendingApprovalCount = 0
        for (key, session) in sessions where key != foregroundKey {
            if !session.pendingApprovals.isEmpty {
                approvalConversationCount += 1
                pendingApprovalCount += session.pendingApprovals.count
            } else if Self.isActive(session) {
                runningConversationCount += 1
            }
        }
        return CodexDrawerBackgroundActivity(
            runningConversationCount: runningConversationCount,
            approvalConversationCount: approvalConversationCount,
            pendingApprovalCount: pendingApprovalCount
        )
    }

    @discardableResult
    public mutating func reduce(
        _ action: CodexDrawerAction
    ) -> [CodexDrawerCommand] {
        switch action {
        case let .selectTerminal(context):
            terminalContext = context
        case let .receiveSessions(sessions):
            self.sessions = sessions
            reconcileOwnership()
        case let .receiveAvailability(availability):
            self.availability = availability
        case let .editComposer(text):
            guard let selectedConversationKey else { break }
            composers[selectedConversationKey] = text
        case .sendComposer:
            guard canSend, let key = selectedConversationKey else { break }
            let prompt = composerText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            composers[key] = ""
            ownership[key] = .codex
            return isActive
                ? [.steer(prompt: prompt, key: key)]
                : [.submit(prompt: prompt, key: key)]
        case let .setExpanded(expanded):
            isExpanded = expanded
        case let .resizeExpanded(fraction):
            isExpanded = true
            expandedFraction = Self.clamp(fraction)
        case .requestTakeover:
            guard case .connected = terminalContext,
                let key = selectedConversationKey,
                isActive,
                ownership[key] != .takeoverPending
            else { break }
            ownership[key] = .takeoverPending
            return [.stopAndTakeOver(key)]
        case let .takeoverCompleted(key):
            ownership[key] = .user
        case let .allowOnce(requestID):
            guard case .connected = terminalContext,
                selectedSession?.pendingApprovals.contains(where: {
                $0.id == requestID
            }) == true else { break }
            return [.allowOnce(requestID)]
        case let .deny(requestID):
            guard selectedSession?.pendingApprovals.contains(where: {
                $0.id == requestID
            }) == true else { break }
            return [.deny(requestID)]
        case .retryAvailability:
            guard availabilityNotice?.isRetryable == true else { break }
            return [.retryAvailability]
        }
        return []
    }

    private mutating func reconcileOwnership() {
        let knownKeys = Set(sessions.keys).union(ownership.keys)
        for key in knownKeys {
            if ownership[key] == .takeoverPending { continue }
            ownership[key] = sessions[key].map(Self.isActive) == true
                ? .codex
                : .user
        }
    }

    private static func clamp(_ fraction: Double) -> Double {
        min(
            Self.maximumExpandedFraction,
            max(Self.minimumExpandedFraction, fraction)
        )
    }

    private static func isActive(_ session: CodexSessionState) -> Bool {
        if session.activeTurnID != nil { return true }
        switch session.phase {
        case .thinking, .controlling, .awaitingApproval, .waitingForUser:
            return true
        case .idle, .completed, .failed, .interrupted:
            return false
        }
    }
}
