import CryptoKit
import Foundation

enum SSHMasterCommandError: Error, Equatable, Sendable {
    case invalidAlias
    case invalidSSHCommand
    case socketPathTooLong
}

struct SSHMasterCommands: Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func socketPath(alias: String) throws -> String {
        guard MerlinIdentifierValidator.isSSHAlias(alias) else {
            throw SSHMasterCommandError.invalidAlias
        }

        let digest = SHA256.hash(data: Data(alias.utf8))
        let hash = digest.prefix(12).map { byte in
            String(format: "%02x", byte)
        }.joined()
        let path = directory
            .appendingPathComponent("m-\(hash)", isDirectory: false)
            .path

        guard path.utf8.count < 104 else {
            throw SSHMasterCommandError.socketPathTooLong
        }
        return path
    }

    func prepare(alias: String) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-MNf", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ControlMaster=yes", "-o", "ControlPath=\(path)",
                "-o", "ControlPersist=600", alias,
            ]
        )
    }

    func check(alias: String) throws -> CommandSpec {
        try operation("check", alias: alias)
    }

    func stop(alias: String) throws -> CommandSpec {
        try operation("stop", alias: alias)
    }

    func managed(_ command: CommandSpec, alias: String) throws -> CommandSpec {
        guard MerlinIdentifierValidator.isSSHAlias(alias) else {
            throw SSHMasterCommandError.invalidAlias
        }
        guard
            command.executable == "/usr/bin/ssh",
            let destinationIndex = command.arguments.firstIndex(of: alias)
        else {
            throw SSHMasterCommandError.invalidSSHCommand
        }

        let path = try socketPath(alias: alias)
        var arguments = command.arguments
        arguments.insert(contentsOf: [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=600",
        ], at: destinationIndex)
        return CommandSpec(executable: command.executable, arguments: arguments)
    }

    private func operation(_ operation: String, alias: String) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-O", operation, "-o", "BatchMode=yes",
                "-o", "ControlPath=\(path)", alias,
            ]
        )
    }
}
