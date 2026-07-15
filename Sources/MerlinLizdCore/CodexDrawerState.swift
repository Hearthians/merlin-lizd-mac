import Foundation

public enum CodexDrawerTerminalContext: Equatable, Hashable, Sendable {
    case noSelection
    case plainLocalShell
    case unresolvedTmux
    case notStarted(TerminalConversationKey)
    case endpointRegistering(TerminalConversationKey)
    case registrationFailed(TerminalConversationKey)
    case detached(TerminalConversationKey)
    case exited(TerminalConversationKey)
    case closed(TerminalConversationKey)
    case reconnecting(TerminalConversationKey)
    case disconnected(TerminalConversationKey)
    case connected(TerminalConversationKey)

    public var conversationKey: TerminalConversationKey? {
        switch self {
        case let .notStarted(key), let .endpointRegistering(key),
            let .registrationFailed(key), let .detached(key),
            let .exited(key), let .closed(key), let .reconnecting(key),
            let .connected(key), let .disconnected(key):
            key
        case .noSelection, .plainLocalShell, .unresolvedTmux: nil
        }
    }

    public static func project(
        key: TerminalConversationKey,
        session: CodexDrawerTerminalSessionReadiness,
        endpoint: CodexDrawerEndpointReadiness,
        isReconnecting: Bool
    ) -> Self {
        if isReconnecting { return .reconnecting(key) }
        switch session {
        case .exited: return .exited(key)
        case .closed: return .closed(key)
        case .missing, .idle, .running: break
        }
        switch endpoint {
        case .registered:
            guard session != .missing else { return .notStarted(key) }
            return .connected(key)
        case .registering: return .endpointRegistering(key)
        case .registrationFailed: return .registrationFailed(key)
        case .detached: return .detached(key)
        case .notStarted: return .notStarted(key)
        }
    }
}

public enum CodexDrawerTerminalSessionReadiness: Equatable, Sendable {
    case missing
    case idle
    case running
    case exited
    case closed
}

public enum CodexDrawerEndpointReadiness: Equatable, Sendable {
    case notStarted
    case registering
    case registered
    case registrationFailed
    case detached
}

public struct CodexDrawerEndpointRouteDescriptor:
    Equatable, Hashable, Sendable
{
    public let target: TerminalTarget
    public let sessionName: String
    public let tmuxIdentity: TmuxSessionIdentity

    public init(
        target: TerminalTarget,
        sessionName: String,
        tmuxIdentity: TmuxSessionIdentity
    ) {
        self.target = target
        self.sessionName = sessionName
        self.tmuxIdentity = tmuxIdentity
    }

    public init?(tab: TerminalTabRecord) {
        guard let sessionName = tab.sessionName,
            let tmuxIdentity = tab.tmuxIdentity
        else { return nil }
        self.init(
            target: tab.target,
            sessionName: sessionName,
            tmuxIdentity: tmuxIdentity
        )
    }
}

public enum CodexDrawerEndpointRouteChange {
    public static func changedTabIDs(
        from previous: [TerminalTabRecord],
        to current: [TerminalTabRecord]
    ) -> Set<String> {
        let tabIDs = Set(previous.map(\.id)).union(current.map(\.id))
        return Set(tabIDs.filter { tabID in
            let old = previous.first(where: { $0.id == tabID })
                .flatMap(CodexDrawerEndpointRouteDescriptor.init(tab:))
            let new = current.first(where: { $0.id == tabID })
                .flatMap(CodexDrawerEndpointRouteDescriptor.init(tab:))
            return old != new
        })
    }
}

public struct CodexDrawerEndpointRegistration: Equatable, Sendable {
    public private(set) var readiness: CodexDrawerEndpointReadiness
    public private(set) var generationID: UUID?
    public private(set) var route: CodexDrawerEndpointRouteDescriptor?

    public init(
        readiness: CodexDrawerEndpointReadiness = .notStarted
    ) {
        self.readiness = readiness
        generationID = nil
        route = nil
    }

    public mutating func begin(
        generationID: UUID,
        route: CodexDrawerEndpointRouteDescriptor
    ) {
        self.generationID = generationID
        self.route = route
        readiness = .registering
    }

    @discardableResult
    public mutating func succeed(
        generationID: UUID,
        route: CodexDrawerEndpointRouteDescriptor
    ) -> Bool {
        guard readiness == .registering,
            self.generationID == generationID,
            self.route == route
        else { return false }
        readiness = .registered
        return true
    }

    @discardableResult
    public mutating func fail(
        generationID: UUID,
        route: CodexDrawerEndpointRouteDescriptor
    ) -> Bool {
        guard readiness == .registering,
            self.generationID == generationID,
            self.route == route
        else { return false }
        readiness = .registrationFailed
        return true
    }

    public mutating func failPreparation() {
        generationID = nil
        route = nil
        readiness = .registrationFailed
    }

    public mutating func detach() {
        generationID = nil
        route = nil
        readiness = .detached
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
    case takeoverPending(UUID)
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
    case requestTakeover(UUID)
    case takeoverCompleted(TerminalConversationKey, UUID)
    case allowOnce(UUID)
    case deny(UUID)
    case retryAvailability
}

public enum CodexDrawerCommand: Equatable, Sendable {
    case submit(prompt: String, key: TerminalConversationKey)
    case steer(prompt: String, key: TerminalConversationKey)
    case stopAndTakeOver(TerminalConversationKey, UUID)
    case allowOnce(UUID)
    case deny(UUID)
    case retryAvailability
}

public enum CodexDrawerCommandSequencer {
    public static func stopAndTakeOver(
        _ key: TerminalConversationKey,
        operationID: UUID,
        stop: @escaping @Sendable () async -> Void
    ) async -> CodexDrawerAction {
        await stop()
        return .takeoverCompleted(key, operationID)
    }
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

    public var canTakeOver: Bool {
        guard selectedConversationKey != nil, isActive else { return false }
        if case .takeoverPending = keyboardOwnership { return false }
        return true
    }

    public var canSend: Bool {
        guard case .connected = terminalContext else { return false }
        if case .takeoverPending = keyboardOwnership { return false }
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
        case .notStarted:
            "Preparing this tmux terminal for Codex."
        case .endpointRegistering:
            "Registering the visible tmux terminal with Codex."
        case .registrationFailed:
            "Codex could not attach to this tmux terminal. Reconnect to retry."
        case .detached:
            "The Codex terminal route is detached. Reconnect this tab."
        case .exited:
            "This terminal exited. Reconnect it before starting new Codex work."
        case .closed:
            "This terminal is closed."
        case .reconnecting:
            "Reconnecting this tmux terminal to Codex…"
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
        case let .requestTakeover(operationID):
            guard let key = selectedConversationKey, canTakeOver
            else { break }
            ownership[key] = .takeoverPending(operationID)
            return [.stopAndTakeOver(key, operationID)]
        case let .takeoverCompleted(key, operationID):
            guard ownership[key] == .takeoverPending(operationID) else {
                break
            }
            ownership[key] = .user
        case let .allowOnce(requestID):
            guard case .connected = terminalContext,
                let request = selectedSession?.pendingApprovals.first(where: {
                    $0.id == requestID
                }),
                request.scope.context != nil
            else { break }
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
            if case .takeoverPending = ownership[key] { continue }
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
