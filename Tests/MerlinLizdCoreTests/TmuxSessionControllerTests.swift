import Testing
@testable import MerlinLizdCore

@Suite("tmux session mutations")
struct TmuxSessionControllerTests {
    @Test("renames through the target-specific safe command")
    func renamesWorkerSession() async throws {
        let runner = MutationRecordingRunner(output: InventoryProcessOutput(
            stdout: "",
            stderr: "",
            exitCode: 0
        ))
        let controller = TmuxSessionController(processRunner: runner)

        try await controller.rename(
            target: .worker(
                devboxSID: "dbx_135679", devboxName: "wt_hl",
                alias: "hl_gpu_2", workerID: "3960209"
            ),
            from: "mlz-old", to: "training-main"
        )

        #expect(await runner.lastCommand()?.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- env -u TMUX TERM=dumb TMUX_TMPDIR=/dev/shm tmux rename-session -t mlz-old training-main")
    }

    @Test("routes a mutation through the shared path without replay")
    func mutationUsesSharedControlPathWithoutReplay() async throws {
        let directRunner = MutationRecordingRunner(output: InventoryProcessOutput(
            stdout: "", stderr: "", exitCode: 0
        ))
        let directory = temporarySSHDirectory()
        let poolRunner = SSHMasterScriptedRunner(actions: [
            .exit(255), .succeed, .exit(255),
        ])
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let controller = TmuxSessionController(
            sshMasterPool: pool, processRunner: directRunner
        )

        await #expect(throws: TmuxSessionMutationError.commandFailed(exitCode: 255)) {
            try await controller.rename(
                target: .devbox(
                    sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
                ),
                from: "mlz-old", to: "training-main"
            )
        }

        let commands = await poolRunner.commands()
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(commands.last?.arguments.contains("ControlPath=\(expectedPath)") == true)
        #expect(await poolRunner.childCommandCount(alias: "hl_gpu_2") == 1)
        #expect(await directRunner.lastCommand() == nil)
    }

    @Test("surfaces a Worker not-ready diagnostic")
    func surfacesWorkerNotReady() async {
        let runner = MutationRecordingRunner(output: InventoryProcessOutput(
            stdout: "",
            stderr: "worker has not been ready yet",
            exitCode: 1
        ))
        let controller = TmuxSessionController(processRunner: runner)

        await #expect(throws: TmuxSessionMutationError.workerNotReady) {
            try await controller.rename(
                target: .worker(
                    devboxSID: "dbx_135679",
                    devboxName: "wt_hl",
                    alias: "hl_gpu_2",
                    workerID: "3966762"
                ),
                from: "mlz-old",
                to: "training-main"
            )
        }
    }

    @Test("pooled mutation preserves Worker not-ready diagnostics")
    func pooledMutationSurfacesWorkerNotReady() async {
        let runner = MutationPoolRunner(childOutput: InventoryProcessOutput(
            stdout: "", stderr: "worker is not ready", exitCode: 1
        ))
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(), runner: runner
        )
        let controller = TmuxSessionController(
            sshMasterPool: pool,
            processRunner: MutationRecordingRunner(output: InventoryProcessOutput(
                stdout: "must-not-run", stderr: "", exitCode: 0
            ))
        )

        await #expect(throws: TmuxSessionMutationError.workerNotReady) {
            try await controller.terminate(
                target: .worker(
                    devboxSID: "dbx_135679", devboxName: "wt_hl",
                    alias: "hl_gpu_2", workerID: "3960209"
                ),
                sessionName: "mlz-finished-run"
            )
        }
        #expect(await runner.childCommands() == 1)
    }

    @Test("terminates through the target-specific safe command")
    func terminatesWorkerSession() async throws {
        let runner = MutationRecordingRunner(output: InventoryProcessOutput(
            stdout: "",
            stderr: "",
            exitCode: 0
        ))
        let controller = TmuxSessionController(processRunner: runner)

        try await controller.terminate(
            target: .worker(
                devboxSID: "dbx_135679",
                devboxName: "wt_hl",
                alias: "hl_gpu_2",
                workerID: "3960209"
            ),
            sessionName: "mlz-finished-run"
        )

        #expect(await runner.lastCommand()?.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- env -u TMUX TERM=dumb TMUX_TMPDIR=/dev/shm tmux kill-session -t mlz-finished-run")
    }
}

private actor MutationPoolRunner: InventoryProcessRunning {
    private let childOutput: InventoryProcessOutput
    private var childCount = 0

    init(childOutput: InventoryProcessOutput) {
        self.childOutput = childOutput
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.starts(with: ["-O", "check"]) {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf" {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
        childCount += 1
        return childOutput
    }

    func childCommands() -> Int { childCount }
}

private actor MutationRecordingRunner: InventoryProcessRunning {
    private let output: InventoryProcessOutput
    private var commands: [CommandSpec] = []

    init(output: InventoryProcessOutput) {
        self.output = output
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        commands.append(command)
        return output
    }

    func lastCommand() -> CommandSpec? {
        commands.last
    }
}
