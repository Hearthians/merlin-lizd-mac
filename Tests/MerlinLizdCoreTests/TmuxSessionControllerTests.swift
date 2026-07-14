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

    @Test("same-route selections serialize mutation through verification")
    func sameRouteSelectionsDoNotInterleave() async throws {
        let gate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(gate, then: successfulOutput()),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%36")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let first = Task {
            try await controller.select(
                .paneRight,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await gate.waitUntilEntered()
        let secondStarted = AsyncCompletionProbe()
        let second = Task {
            await secondStarted.complete()
            return try await controller.select(
                .paneLeft,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await waitUntilStarted(secondStarted)
        await settleSubmittedOperation()

        #expect(await runner.commands().map(\.arguments) == [[
            "select-pane", "-t", "%34", "-R",
        ]])

        await gate.open()
        #expect(try await first.value == surface(paneID: "%35"))
        #expect(try await second.value == surface(paneID: "%36"))
        #expect(await runner.commands().map(\.arguments) == [
            ["select-pane", "-t", "%34", "-R"],
            currentSurfaceArguments(sessionName: "mlz-shell"),
            ["select-pane", "-t", "%34", "-L"],
            currentSurfaceArguments(sessionName: "mlz-shell"),
        ])
    }

    @Test("same-route creates serialize and retain each split pane ownership")
    func sameRouteCreatesRegisterTheirOwnPanes() async throws {
        let gate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(gate, then: splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(splitOutput(paneID: "%36")),
            .output(surfaceOutput(paneID: "%36")),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
            .output(surfaceOutput(paneID: "%36")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        let first = Task {
            try await controller.createTemporaryPane(
                from: origin, route: localRoute()
            )
        }
        await gate.waitUntilEntered()
        let secondStarted = AsyncCompletionProbe()
        let second = Task {
            await secondStarted.complete()
            return try await controller.createTemporaryPane(
                from: origin, route: localRoute()
            )
        }
        await waitUntilStarted(secondStarted)
        await settleSubmittedOperation()

        #expect(await runner.commands().map(\.arguments) == [[
            "split-window", "-t", "%34", "-P",
            "-F#{window_id},#{pane_id}",
        ]])

        await gate.open()
        #expect(try await first.value == surface(paneID: "%35"))
        #expect(try await second.value == surface(paneID: "%36"))
        try await controller.closeTemporaryPane(
            "%35", restoring: origin, route: localRoute()
        )
        try await controller.closeTemporaryPane(
            "%36", restoring: origin, route: localRoute()
        )

        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.map(\.arguments) == [
            ["kill-pane", "-t", "%35"],
            ["kill-pane", "-t", "%36"],
        ])
    }

    @Test("Devbox relabel and tmux rename preserve one serialized route")
    func devboxRelabelAndRenamePreserveSerialization() async throws {
        try await expectStableRouteSerialization(
            firstRoute: devboxRoute(
                name: "old-devbox",
                alias: "old_alias",
                sessionName: "mlz-old"
            ),
            secondRoute: devboxRoute(
                name: "renamed-devbox",
                alias: "new_alias",
                sessionName: "training-main"
            ),
            firstAlias: "old_alias",
            secondAlias: "new_alias"
        )
    }

    @Test("Worker relabel and tmux rename preserve one serialized route")
    func workerRelabelAndRenamePreserveSerialization() async throws {
        try await expectStableRouteSerialization(
            firstRoute: workerRoute(
                devboxName: "old-devbox",
                alias: "old_alias",
                sessionName: "mlz-old"
            ),
            secondRoute: workerRoute(
                devboxName: "renamed-devbox",
                alias: "new_alias",
                sessionName: "training-main"
            ),
            firstAlias: "old_alias",
            secondAlias: "new_alias"
        )
    }

    @Test("concurrent closes on one lease issue one kill and one ownership failure")
    func concurrentClosesKillOwnedPaneOnce() async throws {
        let gate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .wait(gate, then: surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin, route: localRoute()
        )
        let first = Task {
            await closeOutcome(
                controller: controller,
                paneID: "%35",
                origin: origin,
                route: localRoute()
            )
        }
        await gate.waitUntilEntered()
        let secondStarted = AsyncCompletionProbe()
        let second = Task {
            await secondStarted.complete()
            return await closeOutcome(
                controller: controller,
                paneID: "%35",
                origin: origin,
                route: localRoute()
            )
        }
        await waitUntilStarted(secondStarted)
        await settleSubmittedOperation()

        #expect(await runner.commands().count == 3)

        await gate.open()
        #expect(await first.value == .success)
        #expect(await second.value == .surfaceFailure(
            .paneNotOwned(paneID: "%35")
        ))
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.map(\.arguments) == [["kill-pane", "-t", "%35"]])
    }

    @Test("a failed same-route operation releases the next FIFO waiter")
    func failedOperationReleasesRouteGate() async throws {
        let gate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(gate, then: InventoryProcessOutput(
                stdout: "", stderr: "selection failed", exitCode: 1
            )),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%36")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let first = Task {
            try await controller.select(
                .paneRight,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await gate.waitUntilEntered()
        let secondStarted = AsyncCompletionProbe()
        let second = Task {
            await secondStarted.complete()
            return try await controller.select(
                .paneLeft,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await waitUntilStarted(secondStarted)
        await settleSubmittedOperation()

        #expect(await runner.commands().count == 1)
        await gate.open()
        await #expect(throws: TmuxSurfaceControlError.commandFailed(
            exitCode: 1
        )) {
            try await first.value
        }
        #expect(try await second.value == surface(paneID: "%36"))
    }

    @Test("cancelling a same-route FIFO waiter does not block its successor")
    func cancelledWaiterDoesNotBlockRoute() async throws {
        let gate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(gate, then: successfulOutput()),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%37")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let first = Task {
            try await controller.select(
                .paneRight,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await gate.waitUntilEntered()
        let cancelledStarted = AsyncCompletionProbe()
        let cancelled = Task {
            await cancelledStarted.complete()
            return try await controller.select(
                .paneLeft,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await waitUntilStarted(cancelledStarted)
        await settleSubmittedOperation()
        cancelled.cancel()
        let third = Task {
            try await controller.select(
                .paneDown,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await settleSubmittedOperation()

        #expect(await runner.commands().count == 1)
        await gate.open()
        #expect(try await first.value == surface(paneID: "%35"))
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(try await third.value == surface(paneID: "%37"))
        #expect(await runner.commands().filter {
            $0.arguments.first == "select-pane"
        }.map(\.arguments) == [
            ["select-pane", "-t", "%34", "-R"],
            ["select-pane", "-t", "%34", "-D"],
        ])
    }

    @Test("different stable routes continue while one route is suspended")
    func differentRoutesProceedConcurrently() async throws {
        let gate = AsyncStartGate()
        let otherIdentity = TmuxSessionIdentity(
            serverSessionID: "$4", createdAtEpoch: 101
        )
        let otherRoute = TmuxRoute(
            target: .local,
            sessionName: "mlz-other",
            expectedIdentity: otherIdentity
        )
        let runner = GatedSurfaceRunner(actions: [
            .wait(gate, then: successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(
                identity: otherIdentity,
                paneID: "%44"
            )),
            .output(surfaceOutput(paneID: "%35")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let first = Task {
            try await controller.select(
                .nextWindow,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await gate.waitUntilEntered()

        let other = try await controller.select(
            .previousWindow,
            from: surface(
                identity: otherIdentity,
                paneID: "%43"
            ),
            route: otherRoute
        )

        #expect(other == surface(
            identity: otherIdentity,
            paneID: "%44"
        ))
        #expect(await runner.commands().map(\.arguments) == [
            ["next-window", "-t", "mlz-shell"],
            ["previous-window", "-t", "mlz-other"],
            currentSurfaceArguments(sessionName: "mlz-other"),
        ])
        await gate.open()
        #expect(try await first.value == surface(paneID: "%35"))
    }

    @Test("different stable targets continue while one target is suspended")
    func differentStableTargetsProceedConcurrently() async throws {
        let gate = AsyncStartGate()
        let firstRoute = devboxRoute(
            sid: "dbx_135679",
            name: "first-devbox",
            alias: "first_alias",
            sessionName: "mlz-shell"
        )
        let secondRoute = devboxRoute(
            sid: "dbx_246810",
            name: "second-devbox",
            alias: "second_alias",
            sessionName: "mlz-shell"
        )
        let runner = GatedSurfaceRunner(actions: [
            .wait(gate, then: successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%44")),
            .output(surfaceOutput(paneID: "%35")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let first = Task {
            try await controller.select(
                .nextWindow,
                from: surface(paneID: "%34"),
                route: firstRoute
            )
        }
        await gate.waitUntilEntered()

        let second = try await controller.select(
            .previousWindow,
            from: surface(paneID: "%43"),
            route: secondRoute
        )

        #expect(second == surface(paneID: "%44"))
        let commands = await runner.commands()
        #expect(commands.count == 3)
        #expect(commands[0].arguments.contains("first_alias"))
        #expect(commands[1].arguments.contains("second_alias"))
        #expect(commands[2].arguments.contains("second_alias"))
        await gate.open()
        #expect(try await first.value == surface(paneID: "%35"))
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

    @Test("an existing lease rejects another tmux identity without probing")
    func existingLeaseRejectsDifferentTmuxIdentity() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            splitOutput(paneID: "%35"),
            surfaceOutput(paneID: "%35"),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        _ = try await controller.createTemporaryPane(
            from: surface(paneID: "%34"),
            route: localRoute()
        )
        let otherIdentity = TmuxSessionIdentity(
            serverSessionID: "$4", createdAtEpoch: 101
        )
        let otherRoute = TmuxRoute(
            target: .local,
            sessionName: "mlz-other",
            expectedIdentity: otherIdentity
        )
        let commandCount = await runner.commands().count

        await #expect(throws: TmuxSurfaceControlError.paneNotOwned(
            paneID: "%35"
        )) {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: surface(
                    identity: otherIdentity,
                    paneID: "%44"
                ),
                route: otherRoute
            )
        }
        #expect(await runner.commands().count == commandCount)
    }

    @Test("a lease survives Worker relabel and tmux rename")
    func leaseSurvivesWorkerRelabelAndRename() async throws {
        let runner = SurfaceRecordingRunner(outputs: successfulLeaseLifecycle())
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: workerRoute(
                devboxName: "old-devbox",
                alias: "old_alias",
                sessionName: "mlz-old"
            )
        )

        try await controller.closeTemporaryPane(
            "%35",
            restoring: origin,
            route: workerRoute(
                devboxName: "renamed-devbox",
                alias: "new_alias",
                sessionName: "training-main"
            )
        )

        let commands = await runner.commands()
        #expect(commands.count == 7)
        #expect(commands.prefix(2).allSatisfy {
            $0.arguments.contains("old_alias")
        })
        #expect(commands.suffix(5).allSatisfy {
            $0.arguments.contains("new_alias")
        })
        #expect(commands.last?.arguments.last?.contains(
            "tmux display-message -p -t training-main "
        ) == true)
    }

    @Test("a relabeled lease still rejects a forged origin without probing")
    func relabeledLeaseRejectsMismatchedOrigin() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            splitOutput(paneID: "%35"),
            surfaceOutput(paneID: "%35"),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        _ = try await controller.createTemporaryPane(
            from: surface(paneID: "%34"),
            route: workerRoute(
                devboxName: "old-devbox",
                alias: "old_alias",
                sessionName: "mlz-old"
            )
        )
        let commandCount = await runner.commands().count

        await #expect(throws: TmuxSurfaceControlError.paneNotOwned(
            paneID: "%35"
        )) {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: surface(paneID: "%33"),
                route: workerRoute(
                    devboxName: "renamed-devbox",
                    alias: "new_alias",
                    sessionName: "training-main"
                )
            )
        }
        #expect(await runner.commands().count == commandCount)
    }

    @Test("a lease rejects another stable target without probing")
    func leaseRejectsDifferentStableTarget() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            splitOutput(paneID: "%35"),
            surfaceOutput(paneID: "%35"),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: workerRoute(workerID: "3960209")
        )
        let commandCount = await runner.commands().count

        await #expect(throws: TmuxSurfaceControlError.paneNotOwned(
            paneID: "%35"
        )) {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: workerRoute(workerID: "3966762")
            )
        }
        #expect(await runner.commands().count == commandCount)
    }

    @Test("an existing lease rejects a mismatched origin without probing")
    func existingLeaseRejectsMismatchedOrigin() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            splitOutput(paneID: "%35"),
            surfaceOutput(paneID: "%35"),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        _ = try await controller.createTemporaryPane(
            from: surface(paneID: "%34"),
            route: localRoute()
        )
        let commandCount = await runner.commands().count

        await #expect(throws: TmuxSurfaceControlError.paneNotOwned(
            paneID: "%35"
        )) {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: surface(paneID: "%33"),
                route: localRoute()
            )
        }
        #expect(await runner.commands().count == commandCount)
    }

    @Test("a post-split user switch retains created-pane ownership and context")
    func postSplitSwitchRetainsCreatedPane() async throws {
        let runner = SurfaceRecordingRunner(outputs: [
            splitOutput(paneID: "%35"),
            surfaceOutput(paneID: "%99", command: "vim"),
            surfaceOutput(paneID: "%35"),
            successfulOutput(),
            successfulOutput(),
            successfulOutput(),
            surfaceOutput(paneID: "%34"),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        let switched = surface(paneID: "%99", command: "vim")

        await #expect(throws: TmuxSurfaceControlError.createdPaneNotCurrent(
            createdWindowID: "@12",
            createdPaneID: "%35",
            actual: switched
        )) {
            try await controller.createTemporaryPane(
                from: origin, route: localRoute()
            )
        }

        try await controller.closeTemporaryPane(
            "%35", restoring: origin, route: localRoute()
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.map(\.arguments) == [["kill-pane", "-t", "%35"]])
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

private func devboxRoute(
    sid: String = "dbx_135679",
    name: String,
    alias: String,
    sessionName: String,
    identity: TmuxSessionIdentity = tmuxIdentity()
) -> TmuxRoute {
    TmuxRoute(
        target: .devbox(sid: sid, name: name, alias: alias),
        sessionName: sessionName,
        expectedIdentity: identity
    )
}

private func workerRoute(
    devboxSID: String = "dbx_135679",
    devboxName: String = "worker-devbox",
    alias: String = "worker_alias",
    workerID: String = "3960209",
    sessionName: String = "mlz-shell",
    identity: TmuxSessionIdentity = tmuxIdentity()
) -> TmuxRoute {
    TmuxRoute(
        target: .worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: alias,
            workerID: workerID
        ),
        sessionName: sessionName,
        expectedIdentity: identity
    )
}

private func expectStableRouteSerialization(
    firstRoute: TmuxRoute,
    secondRoute: TmuxRoute,
    firstAlias: String,
    secondAlias: String
) async throws {
    let gate = AsyncStartGate()
    let runner = GatedSurfaceRunner(actions: [
        .wait(gate, then: successfulOutput()),
        .output(surfaceOutput(paneID: "%35")),
        .output(successfulOutput()),
        .output(surfaceOutput(paneID: "%36")),
    ])
    let controller = TmuxSessionController(processRunner: runner)
    let first = Task {
        try await controller.select(
            .nextWindow,
            from: surface(paneID: "%34"),
            route: firstRoute
        )
    }
    await gate.waitUntilEntered()
    let secondStarted = AsyncCompletionProbe()
    let second = Task {
        await secondStarted.complete()
        return try await controller.select(
            .previousWindow,
            from: surface(paneID: "%34"),
            route: secondRoute
        )
    }
    await waitUntilStarted(secondStarted)
    await settleSubmittedOperation()

    #expect(await runner.commands().count == 1)

    await gate.open()
    #expect(try await first.value == surface(paneID: "%35"))
    #expect(try await second.value == surface(paneID: "%36"))
    let commands = await runner.commands()
    #expect(commands.count == 4)
    #expect(commands.prefix(2).allSatisfy {
        $0.arguments.contains(firstAlias)
    })
    #expect(commands.suffix(2).allSatisfy {
        $0.arguments.contains(secondAlias)
    })
    #expect(commands[1].arguments.last?.contains(
        "-t \(firstRoute.sessionName) "
    ) == true)
    #expect(commands[3].arguments.last?.contains(
        "-t \(secondRoute.sessionName) "
    ) == true)
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

private func splitOutput(
    windowID: String = "@12",
    paneID: String
) -> InventoryProcessOutput {
    InventoryProcessOutput(
        stdout: "\(windowID),\(paneID)\n",
        stderr: "",
        exitCode: 0
    )
}

private func currentSurfaceArguments(sessionName: String) -> [String] {
    [
        "display-message", "-p", "-t", sessionName,
        "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
    ]
}

private func waitUntilStarted(_ probe: AsyncCompletionProbe) async {
    while await probe.count() == 0 {
        await Task.yield()
    }
}

private func settleSubmittedOperation() async {
    for _ in 0 ..< 1_000 {
        await Task.yield()
    }
}

private enum CloseOutcome: Equatable, Sendable {
    case success
    case surfaceFailure(TmuxSurfaceControlError)
    case unexpectedFailure
}

private func closeOutcome(
    controller: TmuxSessionController,
    paneID: String,
    origin: TmuxSurface,
    route: TmuxRoute
) async -> CloseOutcome {
    do {
        try await controller.closeTemporaryPane(
            paneID, restoring: origin, route: route
        )
        return .success
    } catch let error as TmuxSurfaceControlError {
        return .surfaceFailure(error)
    } catch {
        return .unexpectedFailure
    }
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

private actor GatedSurfaceRunner: InventoryProcessRunning {
    enum Action: Sendable {
        case output(InventoryProcessOutput)
        case wait(AsyncStartGate, then: InventoryProcessOutput)
    }

    private var actions: [Action]
    private var recordedCommands: [CommandSpec] = []

    init(actions: [Action]) {
        self.actions = actions
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recordedCommands.append(command)
        guard !actions.isEmpty else { return successfulOutput() }
        let action = actions.removeFirst()
        switch action {
        case let .output(output):
            return output
        case let .wait(gate, output):
            await gate.wait()
            return output
        }
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
