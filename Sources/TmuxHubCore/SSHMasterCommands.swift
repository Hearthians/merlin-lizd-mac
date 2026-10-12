import CryptoKit
import Foundation

enum SSHMasterCommandError: Error, Equatable, Sendable {
    case invalidDestination
    case invalidSSHCommand
    case invalidForwardHost
    case invalidForwardPort
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
        guard IdentifierValidator.isSSHDestination(alias) else {
            throw SSHMasterCommandError.invalidDestination
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

    func prepare(
        alias: String,
        authentication: SSHPasswordAuthentication? = nil
    ) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        var arguments = ["-MNf"]
        arguments.append(contentsOf: authentication == nil
            ? ["-o", "BatchMode=yes"]
            : authenticationOptions(authentication))
        arguments.append(contentsOf: [
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=yes", "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=600", alias,
        ])
        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: authenticationEnvironment(authentication)
        )
    }

    func check(alias: String) throws -> CommandSpec {
        try operation("check", alias: alias)
    }

    func stop(alias: String) throws -> CommandSpec {
        try operation("stop", alias: alias)
    }

    func openLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) throws -> CommandSpec {
        try localForwardOperation(
            "forward",
            alias: alias,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
    }

    func cancelLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) throws -> CommandSpec {
        try localForwardOperation(
            "cancel",
            alias: alias,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
    }

    func sftp(batchFile: URL, alias: String) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        // Batch transfers must use the prepared master. If it disappears,
        // fail instead of opening an unprompted second authentication flow.
        return CommandSpec(executable: "/usr/bin/sftp", arguments: [
            "-q", "-b", batchFile.path,
            "-o", "BatchMode=yes", "-o", "ControlMaster=no",
            "-o", "ControlPath=\(path)",
            "-o", "ProxyCommand=/usr/bin/false",
            AttachmentPaths.sftpDestination(alias),
        ])
    }

    func managed(
        _ command: CommandSpec,
        alias: String,
        authentication: SSHPasswordAuthentication? = nil
    ) throws -> CommandSpec {
        guard IdentifierValidator.isSSHDestination(alias) else {
            throw SSHMasterCommandError.invalidDestination
        }
        guard command.executable == "/usr/bin/ssh" else {
            throw SSHMasterCommandError.invalidSSHCommand
        }

        let path = try socketPath(alias: alias)
        var arguments = removingBatchModeOption(
            from: command.arguments,
            when: authentication != nil
        )
        guard let parsed = sshDestination(in: arguments),
            arguments[parsed.destinationIndex] == alias
        else {
            throw SSHMasterCommandError.invalidSSHCommand
        }
        arguments.insert(contentsOf: [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=600",
        ] + authenticationOptions(authentication), at: parsed.insertionIndex)
        var environment = command.environment
        environment.merge(
            authenticationEnvironment(authentication),
            uniquingKeysWith: { _, override in override }
        )
        return CommandSpec(
            executable: command.executable,
            arguments: arguments,
            environment: environment
        )
    }

    private func authenticationOptions(
        _ authentication: SSHPasswordAuthentication?
    ) -> [String] {
        guard authentication != nil else { return [] }
        return [
            "-o", "BatchMode=no",
            "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
            "-o", "PasswordAuthentication=yes",
            "-o", "KbdInteractiveAuthentication=yes",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }

    private func authenticationEnvironment(
        _ authentication: SSHPasswordAuthentication?
    ) -> [String: String] {
        guard let authentication else { return [:] }
        return [
            "SSH_ASKPASS": authentication.askPassExecutable,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "tmuxhub:0",
            "TMUXHUB_SSH_PASSWORD": authentication.password,
        ]
    }

    private func removingBatchModeOption(
        from arguments: [String],
        when shouldRemove: Bool
    ) -> [String] {
        guard shouldRemove else { return arguments }
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let value = arguments[index]
            if value == "-o" {
                let optionIndex = arguments.index(after: index)
                if optionIndex < arguments.endIndex,
                    arguments[optionIndex].lowercased().hasPrefix("batchmode=")
                {
                    index = arguments.index(after: optionIndex)
                    continue
                }
            }
            if value.lowercased().hasPrefix("-obatchmode=") {
                index = arguments.index(after: index)
                continue
            }
            result.append(value)
            index = arguments.index(after: index)
        }
        return result
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
                "-F", "/dev/null", "-S", path,
                "-O", operation, "-o", "BatchMode=yes", alias,
            ]
        )
    }

    private func localForwardOperation(
        _ operation: String,
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) throws -> CommandSpec {
        let path = try socketPath(alias: alias)
        guard (1...65_535).contains(localPort),
            (1...65_535).contains(remotePort)
        else {
            throw SSHMasterCommandError.invalidForwardPort
        }

        let formattedRemoteHost: String
        switch remoteHost {
        case "localhost", "127.0.0.1":
            formattedRemoteHost = remoteHost
        case "::1":
            formattedRemoteHost = "[::1]"
        default:
            throw SSHMasterCommandError.invalidForwardHost
        }

        return CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-F", "/dev/null", "-S", path,
                "-O", operation,
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-L", "127.0.0.1:\(localPort):\(formattedRemoteHost):\(remotePort)",
                alias,
            ]
        )
    }
}
