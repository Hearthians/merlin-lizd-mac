import Foundation

public enum ManagedTerminalCommandError: Error, Equatable, Sendable {
    case remoteTargetRequired
}

/// Builds the complete interactive SSH command used by both embedded
/// SwiftTerm sessions and the external Terminal launcher.
public struct ManagedTerminalCommandBuilder: Sendable {
    private let sshMasterPool: SSHMasterPool

    public init(sshMasterPool: SSHMasterPool) {
        self.sshMasterPool = sshMasterPool
    }

    public func swiftTermCommand(
        target: TerminalTarget,
        sessionName: String,
        launchMode: TmuxSessionLaunchMode = .createOrAttach
    ) throws -> CommandSpec {
        try managedRemoteCommand(
            target: target,
            sessionName: sessionName,
            launchMode: launchMode
        )
    }

    public func externalTerminalCommand(
        target: TerminalTarget,
        sessionName: String,
        launchMode: TmuxSessionLaunchMode = .createOrAttach
    ) throws -> CommandSpec {
        try managedRemoteCommand(
            target: target,
            sessionName: sessionName,
            launchMode: launchMode
        )
    }

    private func managedRemoteCommand(
        target: TerminalTarget,
        sessionName: String,
        launchMode: TmuxSessionLaunchMode
    ) throws -> CommandSpec {
        let command: CommandSpec
        let alias: String
        switch target {
        case .local:
            throw ManagedTerminalCommandError.remoteTargetRequired
        case let .ssh(destination):
            alias = destination
            command = try TmuxCommands.remoteTerminal(
                destination: destination,
                sessionName: sessionName,
                launchMode: launchMode
            )
        }
        return try sshMasterPool.managedCommand(command, alias: alias)
    }
}
