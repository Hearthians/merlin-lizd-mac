public enum TerminalTargetIdentity: Codable, Hashable, Sendable {
    case local
    case devbox(sid: String)
    case worker(devboxSID: String, workerID: String)

    public init(_ target: TerminalTarget) {
        switch target {
        case .local:
            self = .local
        case let .devbox(sid, _, _):
            self = .devbox(sid: sid)
        case let .worker(devboxSID, _, _, workerID):
            self = .worker(devboxSID: devboxSID, workerID: workerID)
        }
    }
}

public struct TerminalConversationKey: Codable, Hashable, Sendable {
    public let target: TerminalTargetIdentity
    public let tmux: TmuxSessionIdentity

    public init(target: TerminalTargetIdentity, tmux: TmuxSessionIdentity) {
        self.target = target
        self.tmux = tmux
    }

    public init(terminalTarget: TerminalTarget, tmux: TmuxSessionIdentity) {
        self.init(target: TerminalTargetIdentity(terminalTarget), tmux: tmux)
    }
}
