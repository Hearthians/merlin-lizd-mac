public enum TerminalTerminfo {
    public static func term(for target: TerminalTarget) -> String {
        switch target {
        case .local:
            "xterm-256color"
        case .devbox, .worker:
            "xterm"
        }
    }
}
