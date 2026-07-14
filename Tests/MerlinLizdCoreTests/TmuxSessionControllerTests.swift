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

    @Test("cancelled current-surface read does not expose ignored output")
    func cancelledCurrentSurfaceDoesNotExposeOutput() async throws {
        let readGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(readGate, then: surfaceOutput(paneID: "%34")),
            .output(surfaceOutput(paneID: "%35")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let first = Task {
            try await controller.currentSurface(route: localRoute())
        }
        await readGate.waitUntilEntered()

        first.cancel()
        await readGate.open()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(try await controller.currentSurface(
            route: localRoute()
        ) == surface(paneID: "%35"))
        #expect(await runner.commands().count == 2)
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
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
            .output(surfaceOutput(paneID: "%36")),
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
        _ = try await controller.closeTemporaryPane(
            "%35", restoring: origin, route: localRoute()
        )
        _ = try await controller.closeTemporaryPane(
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
            .output(surfaceOutput(paneID: "%35")),
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
        #expect(await first.value == .outcome(
            .closed(restoration: .restored)
        ))
        #expect(await second.value == .outcome(
            .notCommitted(reason: .paneNotOwned)
        ))
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.map(\.arguments) == [["kill-pane", "-t", "%35"]])
    }

    @Test("cancelled active close holds its lane until the probe returns")
    func cancelledActiveCloseHoldsLane() async throws {
        let probeGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .wait(probeGate, then: surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )
        let first = Task {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            )
        }
        await probeGate.waitUntilEntered()
        first.cancel()
        let second = Task {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            )
        }
        await settleSubmittedOperation()

        #expect(await runner.commands().count == 3)
        await probeGate.open()
        #expect(
            try await first.value == .notCommitted(reason: .cancelled)
        )
        #expect(
            try await second.value == .closed(restoration: .restored)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.map(\.arguments) == [["kill-pane", "-t", "%35"]])
        #expect(try await controller.currentSurface(
            route: localRoute()
        ) == surface(paneID: "%34"))
        #expect(await runner.commands().count == 10)
    }

    @Test("cancellation after kill reports committed close and consumes ownership")
    func cancellationAfterKillConsumesOwnership() async throws {
        let killGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .wait(killGate, then: successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )
        let close = Task {
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            )
        }
        await killGate.waitUntilEntered()

        close.cancel()
        await killGate.open()
        #expect(
            try await close.value
                == .closed(restoration: .failed(.cancelled))
        )
        #expect(await runner.commands().count == 5)
        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            )
                == .notCommitted(reason: .paneNotOwned)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.map(\.arguments) == [["kill-pane", "-t", "%35"]])
        #expect(try await controller.currentSurface(
            route: localRoute()
        ) == surface(paneID: "%34"))
        #expect(await runner.commands().count == 6)
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

    @Test("cancelled active selection holds its lane through verification")
    func cancelledActiveSelectionHoldsLane() async throws {
        let verificationGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .output(successfulOutput()),
            .wait(
                verificationGate,
                then: surfaceOutput(paneID: "%35")
            ),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%36")),
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
        await verificationGate.waitUntilEntered()
        first.cancel()
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

        #expect(await runner.commands().count == 2)
        await verificationGate.open()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(try await second.value == surface(paneID: "%36"))
        #expect(try await controller.currentSurface(
            route: localRoute()
        ) == surface(paneID: "%36"))
        #expect(await runner.commands().filter {
            $0.arguments.first == "select-pane"
        }.map(\.arguments) == [
            ["select-pane", "-t", "%34", "-R"],
            ["select-pane", "-t", "%34", "-L"],
        ])
    }

    @Test("cancelled selection mutation unwinds before verification")
    func cancelledSelectionMutationSkipsVerification() async throws {
        let mutationGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(mutationGate, then: successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%36")),
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
        await mutationGate.waitUntilEntered()
        first.cancel()
        let second = Task {
            try await controller.select(
                .paneLeft,
                from: surface(paneID: "%34"),
                route: localRoute()
            )
        }
        await settleSubmittedOperation()

        #expect(await runner.commands().count == 1)
        await mutationGate.open()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(try await second.value == surface(paneID: "%36"))
        #expect(try await controller.currentSurface(
            route: localRoute()
        ) == surface(paneID: "%36"))
        #expect(await runner.commands().filter {
            $0.arguments.first == "display-message"
        }.count == 2)
    }

    @Test("cancelled active create holds its lane through verification")
    func cancelledActiveCreateHoldsLane() async throws {
        let verificationGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .wait(
                verificationGate,
                then: surfaceOutput(paneID: "%35")
            ),
            .output(splitOutput(paneID: "%36")),
            .output(surfaceOutput(paneID: "%36")),
            .output(surfaceOutput(paneID: "%36")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        let first = Task {
            try await controller.createTemporaryPane(
                from: origin,
                route: localRoute()
            )
        }
        await verificationGate.waitUntilEntered()
        first.cancel()
        let second = Task {
            try await controller.createTemporaryPane(
                from: origin,
                route: localRoute()
            )
        }
        await settleSubmittedOperation()

        #expect(await runner.commands().count == 2)
        await verificationGate.open()
        #expect(await surfaceError(from: first) == .temporaryPaneRetained(
            pane: RetainedTemporaryPane(windowID: "@12", paneID: "%35"),
            reason: .cancelled
        ))
        #expect(try await second.value == surface(paneID: "%36"))
        #expect(try await controller.currentSurface(
            route: localRoute()
        ) == surface(paneID: "%36"))
        #expect(await runner.commands().filter {
            $0.arguments.first == "split-window"
        }.map(\.arguments) == [
            [
                "split-window", "-t", "%34", "-P",
                "-F#{window_id},#{pane_id}",
            ],
            [
                "split-window", "-t", "%34", "-P",
                "-F#{window_id},#{pane_id}",
            ],
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

    @Test("a post-split command failure exposes and retains the exact pane")
    func postSplitCommandFailureRetainsPane() async throws {
        try await expectRetainedPaneAfterVerificationFailure(
            .output(InventoryProcessOutput(
                stdout: "", stderr: "tmux failed", exitCode: 7
            )),
            reason: .commandFailed(exitCode: 7)
        )
    }

    @Test("post-split Worker readiness exposes and retains the exact pane")
    func postSplitWorkerNotReadyRetainsPane() async throws {
        try await expectRetainedPaneAfterVerificationFailure(
            .output(InventoryProcessOutput(
                stdout: "",
                stderr: "worker has not been ready yet",
                exitCode: 1
            )),
            reason: .workerNotReady
        )
    }

    @Test("post-split malformed metadata exposes and retains the exact pane")
    func postSplitMalformedSurfaceRetainsPane() async throws {
        try await expectRetainedPaneAfterVerificationFailure(
            .output(InventoryProcessOutput(
                stdout: "malformed\n", stderr: "", exitCode: 0
            )),
            reason: .invalidSurfaceOutput
        )
    }

    @Test("post-split identity mismatch exposes and retains the exact pane")
    func postSplitIdentityMismatchRetainsPane() async throws {
        let replacement = TmuxSessionIdentity(
            serverSessionID: "$9", createdAtEpoch: 200
        )
        try await expectRetainedPaneAfterVerificationFailure(
            .output(surfaceOutput(
                identity: replacement,
                paneID: "%35"
            )),
            reason: .sessionIdentityMismatch(
                expected: tmuxIdentity(),
                actual: replacement
            )
        )
    }

    @Test("a post-split user switch exposes and retains the exact pane")
    func postSplitSwitchExposesRetainedPane() async throws {
        let sensitiveCommand =
            "/private/key worker_alias tmux capture-pane SECRET"
        let switched = surface(paneID: "%99", command: sensitiveCommand)
        let location = RetainedSurfaceLocation(
            sessionIdentity: switched.sessionIdentity,
            windowID: switched.windowID,
            paneID: switched.paneID
        )
        try await expectRetainedPaneAfterVerificationFailure(
            .output(surfaceOutput(
                paneID: "%99",
                command: sensitiveCommand
            )),
            reason: .createdPaneNotCurrent(actual: location),
            requiredEncodedTexts: ["$3", "100", "@12", "%99"],
            forbiddenEncodedTexts: [
                sensitiveCommand,
                "/private/key",
                "worker_alias",
                "capture-pane",
                "SECRET",
                "currentCommand",
            ],
            roundTripEncodedReason: true
        )
    }

    @Test("a post-split timeout exposes and retains the exact pane")
    func postSplitTimeoutRetainsPane() async throws {
        try await expectRetainedPaneAfterVerificationFailure(
            .timeout,
            reason: .timedOut
        )
    }

    @Test("unavailable post-split transport retains the exact pane")
    func postSplitUnavailableTransportRetainsPane() async throws {
        try await expectRetainedPaneAfterVerificationFailure(
            .transportUnavailable,
            reason: .transportUnavailable
        )
    }

    @Test("unknown post-split errors encode without sensitive diagnostics")
    func postSplitUnknownFailureIsSanitized() async throws {
        let secret = "/private/key worker_alias tmux capture-pane SECRET"
        try await expectRetainedPaneAfterVerificationFailure(
            .sensitiveFailure(secret),
            reason: .unavailable,
            expectedEncodedReason: #"{"unavailable":{}}"#,
            forbiddenEncodedTexts: [secret]
        )
    }

    @Test("ignored cancellation after valid verification retains the pane")
    func ignoredCancellationAfterValidVerificationRetainsPane() async throws {
        let verificationGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: retainedPaneActions(
            verification: .wait(
                verificationGate,
                then: surfaceOutput(paneID: "%35")
            )
        ))
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        let creation = Task {
            try await controller.createTemporaryPane(
                from: origin,
                route: localRoute()
            )
        }
        await verificationGate.waitUntilEntered()

        creation.cancel()
        await verificationGate.open()
        let error = await surfaceError(from: creation)

        try await expectRetainedPaneRecovery(
            error: error,
            reason: .cancelled,
            controller: controller,
            runner: runner,
            origin: origin
        )
    }

    @Test("cancellation wins over failing post-split verification output")
    func cancellationWinsOverVerificationFailure() async throws {
        let verificationGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: retainedPaneActions(
            verification: .wait(
                verificationGate,
                then: InventoryProcessOutput(
                    stdout: "",
                    stderr: "sensitive command diagnostic",
                    exitCode: 9
                )
            )
        ))
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        let creation = Task {
            try await controller.createTemporaryPane(
                from: origin,
                route: localRoute()
            )
        }
        await verificationGate.waitUntilEntered()

        creation.cancel()
        await verificationGate.open()
        let error = await surfaceError(from: creation)

        try await expectRetainedPaneRecovery(
            error: error,
            reason: .cancelled,
            controller: controller,
            runner: runner,
            origin: origin
        )
    }

    @Test("cancellation delivered with split output retains before verification")
    func cancellationAtSplitBoundaryRetainsPane() async throws {
        let splitGate = AsyncStartGate()
        let runner = GatedSurfaceRunner(actions: [
            .wait(splitGate, then: splitOutput(paneID: "%35")),
        ] + closeLifecycleActions())
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        let creation = Task {
            try await controller.createTemporaryPane(
                from: origin,
                route: localRoute()
            )
        }
        await splitGate.waitUntilEntered()

        creation.cancel()
        await splitGate.open()
        let error = await surfaceError(from: creation)

        try await expectRetainedPaneRecovery(
            error: error,
            reason: .cancelled,
            controller: controller,
            runner: runner,
            origin: origin,
            creationCommandCount: 1
        )
    }

    @Test("rejects close for a pane the controller did not lease")
    func rejectsUnownedTemporaryPane() async throws {
        let runner = SurfaceRecordingRunner(outputs: [])
        let controller = TmuxSessionController(processRunner: runner)

        #expect(
            try await controller.closeTemporaryPane(
                "%99",
                restoring: surface(paneID: "%34"),
                route: localRoute()
            )
                == .notCommitted(reason: .paneNotOwned)
        )
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

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: surface(
                    identity: otherIdentity,
                    paneID: "%44"
                ),
                route: otherRoute
            )
                == .notCommitted(reason: .paneNotOwned)
        )
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

        _ = try await controller.closeTemporaryPane(
            "%35",
            restoring: origin,
            route: workerRoute(
                devboxName: "renamed-devbox",
                alias: "new_alias",
                sessionName: "training-main"
            )
        )

        let commands = await runner.commands()
        #expect(commands.count == 8)
        #expect(commands.prefix(2).allSatisfy {
            $0.arguments.contains("old_alias")
        })
        #expect(commands.suffix(6).allSatisfy {
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

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: surface(paneID: "%33"),
                route: workerRoute(
                    devboxName: "renamed-devbox",
                    alias: "new_alias",
                    sessionName: "training-main"
                )
            )
                == .notCommitted(reason: .paneNotOwned)
        )
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

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: workerRoute(workerID: "3966762")
            )
                == .notCommitted(reason: .paneNotOwned)
        )
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

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: surface(paneID: "%33"),
                route: localRoute()
            )
                == .notCommitted(reason: .paneNotOwned)
        )
        #expect(await runner.commands().count == commandCount)
    }

    @Test("closes only the owned pane then structurally restores and verifies the origin")
    func closesOwnedPaneAndRestoresOrigin() async throws {
        let runner = SurfaceRecordingRunner(outputs: successfulLeaseLifecycle())
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin, route: localRoute()
        )

        let close = try await controller.closeTemporaryPane(
            "%35", restoring: origin, route: localRoute()
        )

        #expect(close == .closed(restoration: .restored))

        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.suffix(6) == [
            [
                "display-message", "-p", "-t", "%35",
                "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            ],
            currentSurfaceArguments(sessionName: "mlz-shell"),
            ["kill-pane", "-t", "%35"],
            ["select-window", "-t", "@12"],
            ["select-pane", "-t", "%34"],
            [
                "display-message", "-p", "-t", "mlz-shell",
                "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
            ],
        ].suffix(6))
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

        #expect(
            try await controller.closeTemporaryPane(
                "%35", restoring: origin, route: localRoute()
            )
                == .notCommitted(reason: .leasePaneMissing)
        )

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

        #expect(
            try await controller.closeTemporaryPane(
                "%35", restoring: origin, route: localRoute()
            )
                == .closed(restoration: .failed(.commandFailed))
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35", restoring: origin, route: localRoute()
            ) == .notCommitted(reason: .paneNotOwned)
        )

        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.filter { $0.first == "kill-pane" } == [
            ["kill-pane", "-t", "%35"],
        ])
        #expect(arguments.last == ["select-window", "-t", "@12"])
        #expect(!arguments.contains { $0 == ["select-pane", "-t", "%34"] })
    }

    @Test("failed kill reconciles an existing exact pane as not committed")
    func failedKillWithExistingPaneIsNotCommitted() async throws {
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .transportUnavailable,
            .output(surfaceOutput(paneID: "%35")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .notCommitted(reason: .transportUnavailable)
        )
        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.filter { $0.first == "kill-pane" } == [[
            "kill-pane", "-t", "%35",
        ]])
        #expect(arguments.filter { $0.first == "display-message" }.count == 4)
    }

    @Test("failed kill reconciles an absent exact pane as committed")
    func failedKillWithAbsentPaneIsClosed() async throws {
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .transportUnavailable,
            .output(InventoryProcessOutput(
                stdout: "",
                stderr: "can't find pane: %35",
                exitCode: 1
            )),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .closed(restoration: .restored)
        )
        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .notCommitted(reason: .paneNotOwned)
        )
        let arguments = await runner.commands().map(\.arguments)
        #expect(arguments.filter { $0.first == "kill-pane" }.count == 1)
    }

    @Test("unavailable reconciliation quarantines exact ownership before retry")
    func unavailableReconciliationQuarantinesOwnership() async throws {
        let reason = TmuxTemporaryPaneCloseIndeterminateReason(
            mutationFailure: .transportUnavailable,
            reconciliationFailure: .unavailable
        )
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .transportUnavailable,
            .sensitiveFailure("first reconciliation secret"),
            .sensitiveFailure("second reconciliation secret"),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .indeterminate(reason: reason)
        )
        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .indeterminate(reason: reason)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.count == 1)

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .closed(restoration: .restored)
        )
        let commands = await runner.commands()
        #expect(commands.filter { $0.arguments.first == "kill-pane" }.count == 2)
        #expect(!commands.flatMap(\.arguments).contains {
            $0.contains("secret")
        })
    }

    @Test("a same-window user switch before kill preserves ownership")
    func visiblePaneSwitchBeforeKillDoesNotClose() async throws {
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%36")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .notCommitted(reason: .visibleSurfaceChanged)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.isEmpty)

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .closed(restoration: .restored)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.count == 1)
    }

    @Test("a leased pane moved to another window is not authorized for kill")
    func movedLeasePaneBeforeKillDoesNotClose() async throws {
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(windowID: "@13", paneID: "%35")),
            .output(surfaceOutput(windowID: "@13", paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .notCommitted(reason: .visibleSurfaceChanged)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.isEmpty)

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .closed(restoration: .restored)
        )
    }

    @Test("quarantine retry stays indeterminate while the leased pane is hidden")
    func quarantineRetryRequiresCurrentVisibleLease() async throws {
        let unavailable = TmuxTemporaryPaneCloseIndeterminateReason(
            mutationFailure: .transportUnavailable,
            reconciliationFailure: .unavailable
        )
        let hidden = TmuxTemporaryPaneCloseIndeterminateReason(
            mutationFailure: .transportUnavailable,
            reconciliationFailure: .visibleSurfaceChanged
        )
        let runner = GatedSurfaceRunner(actions: [
            .output(splitOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .transportUnavailable,
            .sensitiveFailure("reconciliation unavailable"),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%36")),
            .output(surfaceOutput(paneID: "%35")),
            .output(surfaceOutput(paneID: "%35")),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(successfulOutput()),
            .output(surfaceOutput(paneID: "%34")),
        ])
        let controller = TmuxSessionController(processRunner: runner)
        let origin = surface(paneID: "%34")
        _ = try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .indeterminate(reason: unavailable)
        )
        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .indeterminate(reason: hidden)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.count == 1)

        #expect(
            try await controller.closeTemporaryPane(
                "%35",
                restoring: origin,
                route: localRoute()
            ) == .closed(restoration: .restored)
        )
        #expect(await runner.commands().filter {
            $0.arguments.first == "kill-pane"
        }.count == 2)
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

private func expectRetainedPaneAfterVerificationFailure(
    _ verification: GatedSurfaceRunner.Action,
    reason: RetainedTemporaryPaneReason,
    expectedEncodedReason: String? = nil,
    requiredEncodedTexts: [String] = [],
    forbiddenEncodedTexts: [String] = [],
    roundTripEncodedReason: Bool = false
) async throws {
    let runner = GatedSurfaceRunner(actions: retainedPaneActions(
        verification: verification
    ))
    let controller = TmuxSessionController(processRunner: runner)
    let origin = surface(paneID: "%34")
    let creation = Task {
        try await controller.createTemporaryPane(
            from: origin,
            route: localRoute()
        )
    }

    let error = await surfaceError(from: creation)

    try await expectRetainedPaneRecovery(
        error: error,
        reason: reason,
        controller: controller,
        runner: runner,
        origin: origin,
        expectedEncodedReason: expectedEncodedReason,
        requiredEncodedTexts: requiredEncodedTexts,
        forbiddenEncodedTexts: forbiddenEncodedTexts,
        roundTripEncodedReason: roundTripEncodedReason
    )
}

private func retainedPaneActions(
    verification: GatedSurfaceRunner.Action
) -> [GatedSurfaceRunner.Action] {
    [
        .output(splitOutput(paneID: "%35")),
        verification,
    ] + closeLifecycleActions()
}

private func closeLifecycleActions() -> [GatedSurfaceRunner.Action] {
    [
        .output(surfaceOutput(paneID: "%35")),
        .output(surfaceOutput(paneID: "%35")),
        .output(successfulOutput()),
        .output(successfulOutput()),
        .output(successfulOutput()),
        .output(surfaceOutput(paneID: "%34")),
    ]
}

private func surfaceError(
    from task: Task<TmuxSurface, Error>
) async -> TmuxSurfaceControlError? {
    do {
        _ = try await task.value
        Issue.record("Expected temporary-pane verification to fail")
        return nil
    } catch let error as TmuxSurfaceControlError {
        return error
    } catch {
        Issue.record("Expected a surface error, got \(error)")
        return nil
    }
}

private func expectRetainedPaneRecovery(
    error: TmuxSurfaceControlError?,
    reason: RetainedTemporaryPaneReason,
    controller: TmuxSessionController,
    runner: GatedSurfaceRunner,
    origin: TmuxSurface,
    creationCommandCount: Int = 2,
    expectedEncodedReason: String? = nil,
    requiredEncodedTexts: [String] = [],
    forbiddenEncodedTexts: [String] = [],
    roundTripEncodedReason: Bool = false
) async throws {
    guard let error else {
        Issue.record("Expected a retained temporary-pane error")
        return
    }
    guard case let .temporaryPaneRetained(retained, actualReason) = error else {
        Issue.record("Expected retained-pane provenance, got \(error)")
        return
    }
    let expectedPane = RetainedTemporaryPane(
        windowID: "@12",
        paneID: "%35"
    )
    #expect(retained == expectedPane)
    #expect(actualReason == reason)
    if expectedEncodedReason != nil
        || !requiredEncodedTexts.isEmpty
        || !forbiddenEncodedTexts.isEmpty
        || roundTripEncodedReason
    {
        let encoded = try encodeRetainedTemporaryPaneReason(actualReason)
        if let expectedEncodedReason {
            #expect(encoded == expectedEncodedReason)
        }
        for requiredEncodedText in requiredEncodedTexts {
            #expect(encoded.contains(requiredEncodedText))
        }
        for forbiddenEncodedText in forbiddenEncodedTexts {
            #expect(!encoded.contains(forbiddenEncodedText))
        }
        if roundTripEncodedReason {
            #expect(try decodeRetainedTemporaryPaneReason(encoded)
                == actualReason)
        }
    }
    #expect(await runner.commands().count == creationCommandCount)

    _ = try await controller.closeTemporaryPane(
        retained.paneID,
        restoring: origin,
        route: localRoute()
    )

    let commands = await runner.commands().map(\.arguments)
    #expect(commands.count == creationCommandCount + 6)
    #expect(Array(commands.suffix(6)) == [
        [
            "display-message", "-p", "-t", "%35",
            "-F#{session_id},#{session_created},#{window_id},#{pane_id},#{pane_current_command}",
        ],
        currentSurfaceArguments(sessionName: "mlz-shell"),
        ["kill-pane", "-t", "%35"],
        ["select-window", "-t", "@12"],
        ["select-pane", "-t", "%34"],
        currentSurfaceArguments(sessionName: "mlz-shell"),
    ])
    #expect(commands.filter { $0.first == "kill-pane" } == [[
        "kill-pane", "-t", "%35",
    ]])

    #expect(
        try await controller.closeTemporaryPane(
            retained.paneID,
            restoring: origin,
            route: localRoute()
        )
            == .notCommitted(reason: .paneNotOwned)
    )
    #expect(await runner.commands().count == creationCommandCount + 6)
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
    case outcome(TmuxTemporaryPaneCloseOutcome)
    case unexpectedFailure
}

private func closeOutcome(
    controller: TmuxSessionController,
    paneID: String,
    origin: TmuxSurface,
    route: TmuxRoute
) async -> CloseOutcome {
    do {
        let outcome = try await controller.closeTemporaryPane(
            paneID, restoring: origin, route: route
        )
        return .outcome(outcome)
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
        case timeout
        case transportUnavailable
        case sensitiveFailure(String)
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
        case .timeout:
            throw InventoryProcessTimeoutError.timedOut
        case .transportUnavailable:
            throw SSHMasterPoolError.shuttingDown
        case let .sensitiveFailure(secret):
            throw SensitiveSurfaceRunnerFailure(secret: secret)
        }
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

private struct SensitiveSurfaceRunnerFailure: Error, Sendable {
    let secret: String
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
