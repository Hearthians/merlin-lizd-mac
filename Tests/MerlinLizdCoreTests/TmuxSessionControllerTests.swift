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
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux rename-session -t mlz-old training-main")
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
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux kill-session -t mlz-finished-run")
    }

    @Test("returns only a current surface with the expected stable session identity")
    func returnsVerifiedCurrentSurface() async throws {
        let runner = SurfaceRecordingRunner(outputs: [surfaceOutput(
            paneID: "%34", command: "zsh"
        )])
        let controller = TmuxSessionController(processRunner: runner)

        let current = try await controller.currentSurface(route: localRoute())

        #expect(current == surface(paneID: "%34", command: "zsh"))
        #expect(await runner.commands().map(\.arguments) == [[
            "display-message", "-p", "-t", "mlz-shell",
            "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
        ]])
    }

    @Test("rejects a recreated same-name session before exposing its surface")
    func rejectsRecreatedSessionSurface() async {
        let replacement = TmuxSessionIdentity(
            serverSessionID: "$9", createdAtEpoch: 200
        )
        let runner = SurfaceRecordingRunner(outputs: [surfaceOutput(
            identity: replacement, paneID: "%34"
        )])
        let controller = TmuxSessionController(processRunner: runner)

        await #expect(throws: TmuxSurfaceControlError.sessionIdentityMismatch(
            expected: tmuxIdentity(),
            actual: replacement
        )) {
            try await controller.currentSurface(route: localRoute())
        }
    }

    @Test("switches the visible pane before reading and returning the new current surface")
    func selectionMutatesThenVerifiesCurrentSurface() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            successfulOutput(),
            surfaceOutput(paneID: "%35", command: "vim"),
        ])
        let controller = TmuxSessionController(processRunner: runner)

        let selected = try await controller.select(
            .paneRight,
            from: surface(paneID: "%34"),
            route: localRoute()
        )

        #expect(selected == surface(paneID: "%35", command: "vim"))
        let commands = await runner.commands()
        #expect(commands.map(\.arguments) == [
            ["select-pane", "-t", "%34", "-R"],
            [
                "display-message", "-p", "-t", "mlz-shell",
                "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            ],
        ])
    }

    @Test("selection verifies the session identity again after the visible switch")
    func selectionRejectsPostSwitchRecreation() async {
        let replacement = TmuxSessionIdentity(
            serverSessionID: "$9", createdAtEpoch: 200
        )
        let runner = SurfaceRecordingRunner(outputs: [
            successfulOutput(),
            surfaceOutput(identity: replacement, paneID: "%35"),
        ])
        let controller = TmuxSessionController(processRunner: runner)

        await #expect(throws: TmuxSurfaceControlError.sessionIdentityMismatch(
            expected: tmuxIdentity(), actual: replacement
        )) {
            try await controller.select(
                .nextWindow,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        #expect(await runner.commands().count == 2)
    }

    @Test("remote metadata reads replay once through the shared SSH master")
    func metadataReadUsesSharedControlPathWithReadOnlyReplay() async throws {
        let direct = SurfaceRecordingRunner(outputs: [])
        let poolRunner = SurfacePoolRunner(childOutputs: [
            InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255),
            surfaceOutput(paneID: "%34"),
        ])
        let directory = temporarySSHDirectory()
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let controller = TmuxSessionController(
            sshMasterPool: pool, processRunner: direct
        )
        let route = TmuxRoute(
            target: .worker(
                devboxSID: "dbx_135679", devboxName: "wt_hl",
                alias: "hl_gpu_2", workerID: "3960209"
            ),
            sessionName: "mlz-shell",
            expectedIdentity: tmuxIdentity()
        )

        let current = try await controller.currentSurface(route: route)

        #expect(current == surface(paneID: "%34"))
        #expect(await poolRunner.childCommandCount() == 2)
        #expect(await direct.commands().isEmpty)
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(await poolRunner.childCommands().allSatisfy {
            $0.arguments.contains("ControlPath=\(expectedPath)")
        })
        #expect(await poolRunner.childCommands().allSatisfy {
            $0.arguments.last ==
                "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- tmux display-message -p -t mlz-shell -F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}"
        })
    }

    @Test("remote visible selection is never replayed")
    func selectionUsesSharedControlPathWithoutReplay() async {
        let poolRunner = SurfacePoolRunner(childOutputs: [
            InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255),
        ])
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(), runner: poolRunner
        )
        let controller = TmuxSessionController(
            sshMasterPool: pool,
            processRunner: SurfaceRecordingRunner(outputs: [])
        )
        let route = TmuxRoute(
            target: .devbox(
                sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
            ),
            sessionName: "mlz-shell",
            expectedIdentity: tmuxIdentity()
        )

        await #expect(throws: TmuxSurfaceControlError.commandFailed(
            exitCode: 255
        )) {
            try await controller.select(
                .previousWindow,
                from: surface(paneID: "%34"),
                route: route
            )
        }
        #expect(await poolRunner.childCommandCount() == 1)
    }

    @Test("creates a visible temporary pane and verifies it is now current")
    func createsVisibleTemporaryPane() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            InventoryProcessOutput(
                stdout: "@12,%35\n", stderr: "", exitCode: 0
            ),
            surfaceOutput(paneID: "%35", command: "zsh"),
        ])
        let controller = TmuxSessionController(processRunner: runner)

        let temporary = try await controller.createTemporaryPane(
            from: surface(paneID: "%34"),
            route: localRoute()
        )

        #expect(temporary == surface(paneID: "%35", command: "zsh"))
        #expect(await runner.commands().map(\.arguments) == [
            [
                "split-window", "-t", "%34", "-P",
                "-F#{window_id},#{pane_id}",
            ],
            [
                "display-message", "-p", "-t", "mlz-shell",
                "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            ],
        ])
    }

    @Test("rejects close for a pane the controller did not lease")
    func rejectsUnownedTemporaryPane() async {
        let runner = SurfaceRecordingRunner(outputs: [])
        let controller = TmuxSessionController(processRunner: runner)

        await #expect(throws: TmuxSurfaceControlError.paneNotOwned(
            paneID: "%99"
        )) {
            try await controller.closeTemporaryPane(
                "%99",
                restoring: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        #expect(await runner.commands().isEmpty)
    }

    @Test("closes only the owned pane then structurally restores and verifies the origin")
    func closesOwnedPaneAndRestoresOrigin() async throws {
        let runner = SurfaceRecordingRunner(outputs: successfulLeaseLifecycle())
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin, route: localRoute()
        )

        try await controller.closeTemporaryPane(
            "%35", restoring: origin, route: localRoute()
        )

        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.suffix(5) == [
            [
                "display-message", "-p", "-t", "%35",
                "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            ],
            ["kill-pane", "-t", "%35"],
            ["select-window", "-t", "@12"],
            ["select-pane", "-t", "%34"],
            [
                "display-message", "-p", "-t", "mlz-shell",
                "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            ],
        ].suffix(5))
        let killCommands = arguments.filter { $0.first == "kill-pane" }
        #expect(killCommands == [["kill-pane", "-t", "%35"]])
        #expect(!arguments.flatMap { $0 }.contains("-a"))
    }

    @Test("a missing leased pane is retained as lost without targeting a replacement")
    func missingLeasePaneDoesNotKillOrRestore() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            InventoryProcessOutput(
                stdout: "@12,%35\n", stderr: "", exitCode: 0
            ),
            surfaceOutput(paneID: "%35"),
            InventoryProcessOutput(
                stdout: "", stderr: "can't find pane: %35", exitCode: 1
            ),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin, route: localRoute()
        )

        await #expect(throws: TmuxSurfaceControlError.leasePaneMissing(
            paneID: "%35"
        )) {
            try await controller.closeTemporaryPane(
                "%35", restoring: origin, route: localRoute()
            )
        }

        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.count == 3)
        #expect(arguments.last?.starts(with: [
            "display-message", "-p", "-t", "%35",
        ]) == true)
        #expect(!arguments.contains { $0.first == "kill-pane" })
        #expect(!arguments.contains { $0.first == "select-window" })
    }

    @Test("reports origin restore failure after killing no pane except the lease")
    func restoreFailureDoesNotKillCollateralPanes() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            InventoryProcessOutput(
                stdout: "@12,%35\n", stderr: "", exitCode: 0
            ),
            surfaceOutput(paneID: "%35"),
            surfaceOutput(paneID: "%35"),
            successfulOutput(),
            InventoryProcessOutput(
                stdout: "", stderr: "can't find window: @12", exitCode: 1
            ),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin, route: localRoute()
        )

        await #expect(throws: TmuxSurfaceControlError.restoreFailed) {
            try await controller.closeTemporaryPane(
                "%35", restoring: origin, route: localRoute()
            )
        }

        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.filter { $0.first == "kill-pane" } == [
            ["kill-pane", "-t", "%35"],
        ])
        #expect(arguments.last == ["select-window", "-t", "@12"])
        #expect(!arguments.contains { $0 == ["select-pane", "-t", "%34"] })
    }
}

private func tmuxIdentity() -> TmuxSessionIdentity {
    TmuxSessionIdentity(serverSessionID: "$3", createdAtEpoch: 100)
}

private func localRoute() -> TmuxRoute {
    TmuxRoute(
        target: .local,
        sessionName: "mlz-shell",
        expectedIdentity: tmuxIdentity()
    )
}

private func surface(
    identity: TmuxSessionIdentity = tmuxIdentity(),
    windowID: String = "@12",
    paneID: String,
    command: String = "zsh"
) -> TmuxSurface {
    TmuxSurface(
        sessionIdentity: identity,
        windowID: windowID,
        paneID: paneID,
        currentCommand: command
    )
}

private func successfulOutput() -> InventoryProcessOutput {
    InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
}

private func surfaceOutput(
    identity: TmuxSessionIdentity = tmuxIdentity(),
    windowID: String = "@12",
    paneID: String,
    command: String = "zsh"
) -> InventoryProcessOutput {
    InventoryProcessOutput(
        stdout: "\(identity.serverSessionID),\(identity.createdAtEpoch),\(windowID),\(paneID),\(command)\n",
        stderr: "",
        exitCode: 0
    )
}

private func successfulLeaseLifecycle() -> [InventoryProcessOutput] {
    [
        InventoryProcessOutput(
            stdout: "@12,%35\n", stderr: "", exitCode: 0
        ),
        surfaceOutput(paneID: "%35"),
        surfaceOutput(paneID: "%35"),
        successfulOutput(),
        successfulOutput(),
        successfulOutput(),
        surfaceOutput(paneID: "%34"),
    ]
}

private actor SurfaceRecordingRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var recordedCommands: [CommandSpec] = []

    init(outputs: [InventoryProcessOutput]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recordedCommands.append(command)
        guard !outputs.isEmpty else {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
        return outputs.removeFirst()
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

private actor SurfacePoolRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var recordedChildren: [CommandSpec] = []

    init(childOutputs: [InventoryProcessOutput]) {
        outputs = childOutputs
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.starts(with: ["-O", "check"]) {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf" {
            return successfulOutput()
        }
        recordedChildren.append(command)
        guard !outputs.isEmpty else { return successfulOutput() }
        return outputs.removeFirst()
    }

    func childCommandCount() -> Int {
        recordedChildren.count
    }

    func childCommands() -> [CommandSpec] {
        recordedChildren
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
