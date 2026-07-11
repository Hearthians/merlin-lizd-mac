import Foundation

public struct CommandSpec: Equatable, Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum CommandValidationError: Error, Equatable, Sendable {
    case invalidAlias
    case invalidWorkerID
    case invalidSessionName
    case invalidExecutablePath
    case invalidSID
}

public enum MerlinCommands {
    public static func listTmuxSessions(
        target: TerminalTarget,
        localTmuxPath: String = "/opt/homebrew/bin/tmux"
    ) throws -> CommandSpec {
        let tmuxArguments = ["list-sessions", "-F", "#{session_name}"]
        switch target {
        case .local:
            guard localTmuxPath.hasPrefix("/") else {
                throw CommandValidationError.invalidExecutablePath
            }
            return CommandSpec(executable: localTmuxPath, arguments: tmuxArguments)
        case let .devbox(_, _, alias):
            try validateAlias(alias)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "tmux list-sessions -F '#{session_name}'"
                )
            )
        case let .worker(_, _, alias, workerID):
            try validateAlias(alias)
            try validateWorkerID(workerID)
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: nonInteractiveSSHArguments(
                    alias: alias,
                    remoteCommand: "NO_COLOR=1 TERM=dumb mlx worker login \(workerID) -- tmux list-sessions -F '#{session_name}'"
                )
            )
        }
    }

    public static func startDevbox(
        merlinCLIPath: String,
        sid: String
    ) throws -> CommandSpec {
        guard
            merlinCLIPath.hasPrefix("/"),
            !merlinCLIPath.contains(where: { $0.isNewline || $0 == "\0" })
        else {
            throw CommandValidationError.invalidExecutablePath
        }
        guard matches(sid, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#) else {
            throw CommandValidationError.invalidSID
        }

        let payloadData = try JSONEncoder().encode(StartPayload(sid: sid))
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw CommandValidationError.invalidSID
        }
        return CommandSpec(
            executable: merlinCLIPath,
            arguments: [
                "cpu-devbox", "instances", "start",
                "--control-plane", "cn",
                "--json", payload,
            ]
        )
    }

    public static func devboxTerminal(
        alias: String,
        sessionName: String
    ) throws -> CommandSpec {
        try validateAlias(alias)
        try validateSessionName(sessionName)

        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: interactiveSSHArguments(
                alias: alias,
                remoteCommand: "exec tmux new-session -A -s \(sessionName)"
            )
        )
    }

    public static func workerTerminal(
        alias: String,
        workerID: String,
        sessionName: String
    ) throws -> CommandSpec {
        try validateAlias(alias)
        try validateWorkerID(workerID)
        try validateSessionName(sessionName)

        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: interactiveSSHArguments(
                alias: alias,
                remoteCommand: "exec mlx worker login \(workerID) -- tmux new-session -A -s \(sessionName)"
            )
        )
    }

    private static func interactiveSSHArguments(
        alias: String,
        remoteCommand: String
    ) -> [String] {
        [
            "-tt",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            alias,
            remoteCommand,
        ]
    }

    private static func nonInteractiveSSHArguments(
        alias: String,
        remoteCommand: String
    ) -> [String] {
        [
            "-nT",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            alias,
            remoteCommand,
        ]
    }

    private static func validateAlias(_ value: String) throws {
        guard matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#) else {
            throw CommandValidationError.invalidAlias
        }
    }

    private static func validateWorkerID(_ value: String) throws {
        guard matches(value, pattern: #"^[0-9]+$"#) else {
            throw CommandValidationError.invalidWorkerID
        }
    }

    private static func validateSessionName(_ value: String) throws {
        guard matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#) else {
            throw CommandValidationError.invalidSessionName
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return false
        }
        return range == value.startIndex..<value.endIndex
    }

    private struct StartPayload: Encodable {
        let sid: String
    }
}
