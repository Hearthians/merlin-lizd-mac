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
        #expect(first.utf8.count < 104)
    }

    @Test("builds prepare check and graceful stop commands")
    func lifecycleCommands() throws {
        let commands = SSHMasterCommands(
            directory: .init(fileURLWithPath: "/tmp/mlz-tests")
        )
        let prepare = try commands.prepare(alias: "hl_gpu_2")
        #expect(prepare.executable == "/usr/bin/ssh")
        #expect(prepare.arguments.contains("ControlMaster=yes"))
        #expect(prepare.arguments.contains("ControlPersist=600"))
        #expect(prepare.arguments.suffix(1) == ["hl_gpu_2"])
        #expect(try commands.check(alias: "hl_gpu_2").arguments.contains("check"))
        #expect(try commands.stop(alias: "hl_gpu_2").arguments.contains("stop"))
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
        let aliasIndex = try #require(managed.arguments.firstIndex(of: "hl_gpu_2"))
        #expect(managed.arguments[..<aliasIndex].contains("ControlMaster=auto"))
        #expect(managed.arguments[..<aliasIndex].contains("ControlPersist=600"))
        #expect(managed.arguments.last == "tmux list-sessions")
    }
}
