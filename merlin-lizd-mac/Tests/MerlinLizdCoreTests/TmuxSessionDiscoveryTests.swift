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

        let target = TerminalTarget.devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            alias: "hl_gpu_2"
        )
        let sessions = try await discovery.list(target: target)

        #expect(sessions.map(\.name) == ["mlz-shell", "external.train"])
        #expect(await discovery.cached(target: target) == sessions)
        let command = await runner.recordedCommand()
        #expect(command?.executable == "/usr/bin/ssh")
    }

    @Test("caches an empty result when tmux has no server")
    func cachesNoServerResult() async throws {
        let runner = TmuxScriptedRunner(
            output: InventoryProcessOutput(
                stdout: "",
                stderr: "no server running on /tmp/tmux-1000/default",
                exitCode: 1
            )
        )
        let discovery = TmuxSessionDiscovery(processRunner: runner)
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966773"
        )

        #expect(try await discovery.list(target: target).isEmpty)
        #expect(await discovery.cached(target: target) == [])
    }

    @Test("updates cached inventory after an authoritative rename")
    func recordsRename() async throws {
        let runner = TmuxScriptedRunner(
            output: InventoryProcessOutput(
                stdout: "old-name\nother\n",
                stderr: "",
                exitCode: 0
            )
        )
        let discovery = TmuxSessionDiscovery(processRunner: runner)
        let target = TerminalTarget.devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            alias: "hl_gpu_2"
        )

        _ = try await discovery.list(target: target)
        await discovery.recordRename(
            target: target,
            from: "old-name",
            to: "new-name"
        )

        #expect(
            await discovery.cached(target: target)?.map(\.name)
                == ["new-name", "other"]
        )
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
