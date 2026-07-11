import Testing
@testable import MerlinLizdCore

@Suite("tmux session inventory")
struct TmuxSessionDiscoveryTests {
    @Test("discovers sessions through the safe target command")
    func discoversSessions() async throws {
        let runner = TmuxScriptedRunner(
            output: InventoryProcessOutput(
                stdout: "mlz-shell\nexternal.train\n",
                stderr: "",
                exitCode: 0
            )
        )
        let discovery = TmuxSessionDiscovery(processRunner: runner)

        let sessions = try await discovery.list(
            target: .devbox(sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2")
        )

        #expect(sessions.map(\.name) == ["mlz-shell", "external.train"])
        let command = await runner.recordedCommand()
        #expect(command?.executable == "/usr/bin/ssh")
    }
}

private actor TmuxScriptedRunner: InventoryProcessRunning {
    let output: InventoryProcessOutput
    private var command: CommandSpec?

    init(output: InventoryProcessOutput) {
        self.output = output
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        self.command = command
        return output
    }

    func recordedCommand() -> CommandSpec? {
        command
    }
}
