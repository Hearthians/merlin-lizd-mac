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

    @Test("routes remote discovery through the shared SSH control path")
    func usesSharedControlPath() async throws {
        let directory = temporarySSHDirectory()
        let poolRunner = TmuxPoolRunner()
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let directRunner = TmuxScriptedRunner(output: InventoryProcessOutput(
            stdout: "must-not-run", stderr: "", exitCode: 0
        ))
        let discovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            processRunner: directRunner
        )

        let sessions = try await discovery.list(target: .devbox(
            sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
        ))

        #expect(sessions.map(\.name) == ["pool-session"])
        let commands = await poolRunner.commands()
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(commands.last?.arguments.contains("ControlPath=\(expectedPath)") == true)
        #expect(await directRunner.recordedCommand() == nil)
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

    @Test("pooled discovery caches authoritative no-server output")
    func pooledDiscoveryCachesNoServer() async throws {
        let runner = TmuxPoolRunner(childOutput: InventoryProcessOutput(
            stdout: "",
            stderr: "no server running on /tmp/tmux-1000/default",
            exitCode: 1
        ))
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(), runner: runner
        )
        let discovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            processRunner: TmuxScriptedRunner(output: InventoryProcessOutput(
                stdout: "must-not-run", stderr: "", exitCode: 0
            ))
        )
        let target = TerminalTarget.devbox(
            sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
        )

        #expect(try await discovery.list(target: target).isEmpty)
        #expect(await discovery.cached(target: target) == [])
    }

    @Test("pooled discovery preserves Worker not-ready diagnostics")
    func pooledDiscoverySurfacesWorkerNotReady() async {
        let runner = TmuxPoolRunner(childOutput: InventoryProcessOutput(
            stdout: "", stderr: "worker has not been ready yet", exitCode: 1
        ))
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(), runner: runner
        )
        let discovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            processRunner: TmuxScriptedRunner(output: InventoryProcessOutput(
                stdout: "must-not-run", stderr: "", exitCode: 0
            ))
        )

        await #expect(throws: TmuxSessionDiscoveryError.workerNotReady) {
            try await discovery.list(target: .worker(
                devboxSID: "dbx_135679", devboxName: "wt_hl",
                alias: "hl_gpu_2", workerID: "3966773"
            ))
        }
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

    @Test("removes terminated sessions without refreshing cache age")
    func recordsTermination() async throws {
        let runner = TmuxScriptedRunner(
            output: InventoryProcessOutput(
                stdout: "one\ntwo\nthree\n",
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
        await discovery.recordTermination(
            target: target,
            sessionNames: ["one", "three"]
        )

        #expect(
            await discovery.cached(target: target)?.map(\.name) == ["two"]
        )
    }
}

private actor TmuxPoolRunner: InventoryProcessRunning {
    private let childOutput: InventoryProcessOutput
    private var recorded: [CommandSpec] = []

    init(childOutput: InventoryProcessOutput = InventoryProcessOutput(
        stdout: "pool-session\n", stderr: "", exitCode: 0
    )) {
        self.childOutput = childOutput
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recorded.append(command)
        if command.arguments.starts(with: ["-O", "check"]) {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf" {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
        return childOutput
    }

    func commands() -> [CommandSpec] { recorded }
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
