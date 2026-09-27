import Foundation

public struct CommandSpec: Equatable, Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public enum CommandValidationError: Error, Equatable, Sendable {
    case invalidSSHDestination
    case invalidSessionName
    case invalidTmuxSessionID
    case invalidExecutablePath
}

/// Builds argv-only OpenSSH and tmux commands for local machines and arbitrary
/// destinations understood by the user's existing OpenSSH configuration.
public enum TmuxCommands {
    public static func sshDestination(for target: TerminalTarget) -> String? {
        target.sshDestination
    }

    public static func terminateTmuxSession(
        target: TerminalTarget,
        sessionName: String,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        let sessionName = try normalizedSessionName(sessionName)
        return try tmuxCommand(
            target: target,
            arguments: ["kill-session", "-t", sessionName],
            localTmuxPath: localTmuxPath
        )
    }

    public static func renameTmuxSession(
        target: TerminalTarget,
        from currentName: String,
        to newName: String,
        identity: TmuxSessionIdentity? = nil,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        let currentName = try normalizedSessionName(currentName)
        let newName = try normalizedSessionName(newName)
        let selector: String
        if let identity {
            guard identity.createdAtEpoch >= 0,
                IdentifierValidator.isTmuxSessionID(identity.serverSessionID)
            else {
                throw CommandValidationError.invalidTmuxSessionID
            }
            selector = identity.serverSessionID
        } else {
            selector = currentName
        }
        return try tmuxCommand(
            target: target,
            arguments: ["rename-session", "-t", selector, newName],
            localTmuxPath: localTmuxPath
        )
    }

    public static func listTmuxSessions(
        target: TerminalTarget,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        try tmuxCommand(
            target: target,
            arguments: [
                "list-sessions",
                "-F#{session_name},#{session_id},#{session_created}",
            ],
            localTmuxPath: localTmuxPath
        )
    }

    public static func remoteTerminal(
        destination: String,
        sessionName: String,
        launchMode: TmuxSessionLaunchMode = .createOrAttach
    ) throws -> CommandSpec {
        try validateDestination(destination)
        let sessionName = try normalizedSessionName(sessionName)
        let remoteCommand = switch launchMode {
        case .createOrAttach:
            "exec tmux new-session -A -s \(sessionName)"
        case .attachOnly:
            "exec tmux attach-session -t =\(sessionName)"
        }
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-tt",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=3",
                destination,
                remoteCommand,
            ]
        )
    }

    private static func tmuxCommand(
        target: TerminalTarget,
        arguments: [String],
        localTmuxPath: String
    ) throws -> CommandSpec {
        switch target {
        case .local:
            try validateExecutablePath(localTmuxPath)
            return CommandSpec(executable: localTmuxPath, arguments: arguments)
        case let .ssh(destination):
            try validateDestination(destination)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-nT",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    destination,
                    "tmux \(remoteArguments(arguments))",
                ]
            )
        }
    }

    private static func remoteArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            argument.hasPrefix("$") ? "'\(argument)'" : argument
        }.joined(separator: " ")
    }

    private static func validateDestination(_ value: String) throws {
        guard IdentifierValidator.isSSHDestination(value) else {
            throw CommandValidationError.invalidSSHDestination
        }
    }

    private static func normalizedSessionName(_ value: String) throws -> String {
        guard let normalized = IdentifierValidator.normalizedTmuxSessionName(value) else {
            throw CommandValidationError.invalidSessionName
        }
        return normalized
    }

    private static func validateExecutablePath(_ value: String) throws {
        guard value.hasPrefix("/"),
            !value.contains(where: { $0.isNewline || $0 == "\0" })
        else {
            throw CommandValidationError.invalidExecutablePath
        }
    }
}
