import Foundation

public enum ShellCommandRenderingError: Error, Equatable, Sendable {
    case nullByte
}

/// Renders an executable and argv as one POSIX-shell command while preserving
/// every argument exactly. This is used only at the Terminal.app boundary,
/// whose AppleScript API accepts a command string rather than argv.
public enum ShellCommandRenderer {
    public static func render(_ command: CommandSpec) throws -> String {
        try ([command.executable] + command.arguments)
            .map(quote)
            .joined(separator: " ")
    }

    private static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else {
            throw ShellCommandRenderingError.nullByte
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum ExternalTerminalLauncherError: Error, Equatable, Sendable {
    case commandFailed(exitCode: Int32)
}

/// Opens a command in Terminal.app. The rendered command is passed to a static
/// AppleScript program as `run` argv; user-controlled data is never interpolated
/// into AppleScript source and no intermediary shell is spawned by this app.
public actor ExternalTerminalLauncher {
    private static let appleScript = """
        on run argv
            set commandText to item 1 of argv
            tell application "Terminal"
                activate
                do script commandText
            end tell
        end run
        """

    private let processRunner: any InventoryProcessRunning

    public init() {
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 1,
            underlying: FoundationInventoryProcessRunner()
        )
    }

    init(processRunner: any InventoryProcessRunning) {
        self.processRunner = processRunner
    }

    public nonisolated static func command(
        for terminalCommand: CommandSpec
    ) throws -> CommandSpec {
        CommandSpec(
            executable: "/usr/bin/osascript",
            arguments: [
                "-e", appleScript,
                "--", try ShellCommandRenderer.render(terminalCommand),
            ]
        )
    }

    public func open(_ terminalCommand: CommandSpec) async throws {
        let launchCommand = try Self.command(for: terminalCommand)
        let output = try await processRunner.run(launchCommand)
        guard output.exitCode == 0 else {
            throw ExternalTerminalLauncherError.commandFailed(exitCode: output.exitCode)
        }
    }
}
