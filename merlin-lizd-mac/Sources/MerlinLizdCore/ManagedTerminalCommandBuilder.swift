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
        sessionName: String
    ) throws -> CommandSpec {
        try managedRemoteCommand(target: target, sessionName: sessionName)
    }

    public func externalTerminalCommand(
        target: TerminalTarget,
        sessionName: String
    ) throws -> CommandSpec {
        try managedRemoteCommand(target: target, sessionName: sessionName)
    }

    private func managedRemoteCommand(
        target: TerminalTarget,
        sessionName: String
    ) throws -> CommandSpec {
        let command: CommandSpec
        let alias: String
        switch target {
        case .local:
            throw ManagedTerminalCommandError.remoteTargetRequired
        case let .devbox(_, _, targetAlias):
            alias = targetAlias
            command = try MerlinCommands.devboxTerminal(
                alias: targetAlias,
                sessionName: sessionName
            )
        case let .worker(_, _, targetAlias, workerID):
            alias = targetAlias
            command = try MerlinCommands.workerTerminal(
                alias: targetAlias,
                workerID: workerID,
                sessionName: sessionName
            )
        }
        return try sshMasterPool.managedCommand(command, alias: alias)
    }
}
