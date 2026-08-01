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
        workingDirectory: String? = nil
    ) throws -> CommandSpec {
        try managedRemoteCommand(
            target: target,
            sessionName: sessionName,
            workingDirectory: workingDirectory
        )
    }

    public func externalTerminalCommand(
        target: TerminalTarget,
        sessionName: String,
        workingDirectory: String? = nil
    ) throws -> CommandSpec {
        try managedRemoteCommand(
            target: target,
            sessionName: sessionName,
            workingDirectory: workingDirectory
        )
    }

    private func managedRemoteCommand(
        target: TerminalTarget,
        sessionName: String,
        workingDirectory: String?
    ) throws -> CommandSpec {
        let command: CommandSpec
        let alias: String
        switch target {
        case .local:
            throw ManagedTerminalCommandError.remoteTargetRequired
        case let .devbox(sid, _, targetAlias):
            alias = targetAlias
            command = try MerlinCommands.devboxTerminal(
                alias: targetAlias,
                devboxSID: sid,
                sessionName: sessionName,
                workingDirectory: workingDirectory
            )
        case let .worker(devboxSID, _, targetAlias, workerID):
            alias = targetAlias
            command = try MerlinCommands.workerTerminal(
                alias: targetAlias,
                devboxSID: devboxSID,
                workerID: workerID,
                sessionName: sessionName,
                workingDirectory: workingDirectory
            )
        }
        return try sshMasterPool.managedCommand(command, alias: alias)
    }
}
