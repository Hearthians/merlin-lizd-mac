import CryptoKit
import Foundation

enum SSHMasterCommandError: Error, Equatable, Sendable {
    case invalidAlias
    case invalidSSHCommand
    case socketPathTooLong
}

struct SSHMasterCommands: Sendable {
    // macOS reserves 104 bytes for a Unix-domain socket pathname including its
    // NUL terminator. OpenSSH temporarily adds a randomized listener suffix
    // while establishing the master, so retain a generous 32-byte headroom.
    private static let maximumControlPathBytes = 71

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func socketPath(alias: String) throws -> String {
        guard MerlinIdentifierValidator.isSSHConnectionTarget(alias) else {
            throw SSHMasterCommandError.invalidAlias
        }

        let digest = SHA256.hash(data: Data(alias.utf8))
        let hash = digest.prefix(12).map { byte in
            String(format: "%02x", byte)
        }.joined()
        let path = directory
            .appendingPathComponent("m-\(hash)", isDirectory: false)
            .path

        guard path.utf8.count <= Self.maximumControlPathBytes else {
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
                "-o", "ControlPersist=600",
            ] + MerlinCommands.sshPortArguments(forConnectionTarget: alias) + [
                alias,
            ]
        )
    }

    func check(alias: String) throws -> CommandSpec {
        try operation("check", alias: alias)
    }

    /// Opens one no-op session through an existing control socket. `-O check`
    /// only proves that the master process answers control messages; a master
    /// can still be unable to open new session channels. The false proxy makes
    /// this probe fail closed: a healthy mux bypasses normal connection setup,
    /// while a missing or refusing mux cannot silently cold-connect and turn a
    /// broken health check into exit status zero.
    func probe(alias: String) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ConnectionAttempts=1",
                "-o", "ClearAllForwardings=yes",
                "-o", "ControlMaster=no", "-o", "ControlPath=\(path)",
                "-o", "ProxyCommand=/usr/bin/false",
            ] + MerlinCommands.sshPortArguments(forConnectionTarget: alias) + [
                alias, "true",
            ]
        )
    }

    func stop(alias: String) throws -> CommandSpec {
        try operation("stop", alias: alias)
    }

    func managed(_ command: CommandSpec, alias: String) throws -> CommandSpec {
        guard MerlinIdentifierValidator.isSSHConnectionTarget(alias) else {
            throw SSHMasterCommandError.invalidAlias
        }
        guard
            command.executable == "/usr/bin/ssh",
            let parsed = sshDestination(in: command.arguments),
            command.arguments[parsed.destinationIndex] == alias
        else {
            throw SSHMasterCommandError.invalidSSHCommand
        }

        let path = try socketPath(alias: alias)
        var arguments = command.arguments
        arguments.insert(contentsOf: [
            // The pool is the only owner allowed to create a master. Children
            // reuse its socket when available and cold-connect when it is not,
            // without attempting to bind the same ControlPath themselves.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=600",
        ], at: parsed.insertionIndex)
        return CommandSpec(executable: command.executable, arguments: arguments)
    }

    private func sshDestination(
        in arguments: [String]
    ) -> (destinationIndex: Int, insertionIndex: Int)? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                let destinationIndex = arguments.index(after: index)
                guard destinationIndex < arguments.endIndex else {
                    return nil
                }
                return (destinationIndex, index)
            }
            if argument == "-" || !argument.hasPrefix("-") {
                return (index, index)
            }

            index = arguments.index(after: index)
            if optionConsumesFollowingArgument(argument) {
                guard index < arguments.endIndex else {
                    return nil
                }
                index = arguments.index(after: index)
            }
        }
        return nil
    }

    private func optionConsumesFollowingArgument(_ argument: String) -> Bool {
        let valueOptions = Set("BbcDEeFIiJLlmOoPpQRSWw")
        let options = argument.dropFirst()
        for (offset, option) in options.enumerated() where valueOptions.contains(option) {
            return offset == options.count - 1
        }
        return false
    }

    private func operation(_ operation: String, alias: String) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-O", operation, "-o", "BatchMode=yes",
                "-o", "ControlPath=\(path)",
            ] + MerlinCommands.sshPortArguments(forConnectionTarget: alias) + [
                alias,
            ]
        )
    }
}
