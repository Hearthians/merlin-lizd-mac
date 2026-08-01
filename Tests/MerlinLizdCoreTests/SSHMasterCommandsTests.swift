import Testing
@testable import MerlinLizdCore

@Suite("SSH master commands")
struct SSHMasterCommandsTests {
    @Test("uses a stable hashed socket path without exposing the alias")
    func hashesAlias() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests", isDirectory: true)
        )
        let first = try commands.socketPath(alias: "hl_gpu_2")
        #expect(first == (try commands.socketPath(alias: "hl_gpu_2")))
        #expect(first.hasPrefix("/tmp/mlz-tests/m-"))
        #expect(!first.contains("hl_gpu_2"))
        #expect(first.utf8.count < 72)
    }

    @Test("reserves room for OpenSSH's temporary listener suffix")
    func reservesListenerSuffixHeadroom() {
        let commands = SSHMasterCommands(directory: excessivelyLongSSHDirectory())

        #expect(throws: SSHMasterCommandError.socketPathTooLong) {
            try commands.socketPath(alias: "hl_gpu_2")
        }
    }

    @Test("uses a short default directory for SSH control sockets")
    func usesShortDefaultSocketDirectory() throws {
        let directory = SSHMasterPool.defaultSocketDirectory()
        let path = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")

        #expect(directory.path.hasPrefix("/tmp/mlz-ssh-"))
        #expect(path.utf8.count < 72)
    }

    @Test("builds prepare check and graceful stop commands")
    func lifecycleCommands() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let socketPath = "/tmp/mlz-tests/m-cac93519225495d659065a87"

        #expect(try commands.prepare(alias: "hl_gpu_2") == CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-MNf", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ControlMaster=yes", "-o", "ControlPath=\(socketPath)",
                "-o", "ControlPersist=600", "hl_gpu_2",
            ]
        ))
        #expect(try commands.check(alias: "hl_gpu_2") == CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-O", "check", "-o", "BatchMode=yes",
                "-o", "ControlPath=\(socketPath)", "hl_gpu_2",
            ]
        ))
        #expect(try commands.stop(alias: "hl_gpu_2") == CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-O", "stop", "-o", "BatchMode=yes",
                "-o", "ControlPath=\(socketPath)", "hl_gpu_2",
            ]
        ))
    }

    @Test("inserts multiplexing options before the validated destination")
    func decoratesChild() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "hl_gpu_2", "tmux list-sessions"]
        )
        let managed = try commands.managed(child, alias: "hl_gpu_2")
        #expect(managed == CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-nT",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=/tmp/mlz-tests/m-cac93519225495d659065a87",
                "-o", "ControlPersist=600",
                "hl_gpu_2", "tmux list-sessions",
            ]
        ))
    }

    @Test("multiplexes a validated direct Worker destination")
    func decoratesDirectWorkerChild() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let destination = "3960209.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org"
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", destination, "true"]
        )

        let managed = try commands.managed(child, alias: destination)

        #expect(managed.arguments.contains(destination))
        #expect(managed.arguments.contains("ControlMaster=auto"))
        #expect(managed.arguments.contains { $0.hasPrefix("ControlPath=") })
    }

    @Test("uses the Merlin proxy port for a direct destination lifecycle")
    func directDestinationLifecycleUsesProxyPort() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let destination =
            "140542.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"

        for command in [
            try commands.prepare(alias: destination),
            try commands.check(alias: destination),
            try commands.stop(alias: destination),
        ] {
            let destinationIndex = try #require(
                command.arguments.firstIndex(of: destination)
            )
            #expect(command.arguments[..<destinationIndex].contains("-p"))
            #expect(command.arguments[..<destinationIndex].contains("22222"))
        }
    }

    @Test("finds the destination after options and an option terminator")
    func parsesDestination() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-v", "-p", "22", "--", "hl_gpu_2", "true"]
        )

        let managed = try commands.managed(child, alias: "hl_gpu_2")

        #expect(managed.arguments == [
            "-v", "-p", "22",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/mlz-tests/m-cac93519225495d659065a87",
            "-o", "ControlPersist=600",
            "--", "hl_gpu_2", "true",
        ])
    }

    @Test("rejects an invalid alias")
    func rejectsInvalidAlias() {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["hl_gpu_2;id"]
        )

        #expect(throws: SSHMasterCommandError.invalidAlias) {
            try commands.managed(child, alias: "hl_gpu_2;id")
        }
    }

    @Test("rejects a non-SSH executable")
    func rejectsNonSSHExecutable() {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/env",
            arguments: ["hl_gpu_2"]
        )

        #expect(throws: SSHMasterCommandError.invalidSSHCommand) {
            try commands.managed(child, alias: "hl_gpu_2")
        }
    }

    @Test("rejects an SSH command without a destination")
    func rejectsMissingDestination() {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "-o", "BatchMode=yes"]
        )

        #expect(throws: SSHMasterCommandError.invalidSSHCommand) {
            try commands.managed(child, alias: "hl_gpu_2")
        }
    }

    @Test("rejects the alias when it appears only in the remote command")
    func rejectsAliasInRemoteCommand() {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["other-host", "echo", "hl_gpu_2"]
        )

        #expect(throws: SSHMasterCommandError.invalidSSHCommand) {
            try commands.managed(child, alias: "hl_gpu_2")
        }
    }

    @Test("rejects the alias when it appears only as an option value")
    func rejectsAliasAsOptionValue() {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let child = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "hl_gpu_2", "other-host"]
        )

        #expect(throws: SSHMasterCommandError.invalidSSHCommand) {
            try commands.managed(child, alias: "hl_gpu_2")
        }
    }
}
