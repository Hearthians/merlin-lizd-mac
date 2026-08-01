import Testing
import os
@testable import MerlinLizdCore

@Suite("tmux session inventory")
struct TmuxSessionDiscoveryTests {
    @Test("returns a 59-second snapshot without starting another process")
    func returnsFreshSnapshotWithoutRefresh() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "one\n", stderr: "", exitCode: 0))
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )
        let target = tmuxTestTarget

        let first = await discovery.refresh(target: target)
        clock.advance(by: 59)
        let cached = await discovery.snapshot(target: target)

        #expect(cached?.sessions == first.sessions)
        #expect(cached?.isFresh(at: clock.now) == true)
        #expect(await runner.runCount == 1)
    }

    @Test("returns stale evidence while sharing one background refresh")
    func staleSnapshotStartsSingleFlightRefresh() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "old\n", stderr: "", exitCode: 0)),
            .gated(.init(stdout: "new\n", stderr: "", exitCode: 0))
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        let first = await discovery.refresh(target: tmuxTestTarget)
        clock.advance(by: 61)
        let stale = await discovery.snapshot(target: tmuxTestTarget)
        let sameStale = await discovery.snapshot(target: tmuxTestTarget)
        await runner.waitUntilRunCount(2)

        #expect(stale?.sessions == first.sessions)
        #expect(stale?.verification == .verifying)
        #expect(stale?.isFresh(at: clock.now) == false)
        #expect(sameStale == stale)
        #expect(await runner.runCount == 2)

        await runner.releaseGate()
        let refreshed = await discovery.refresh(target: tmuxTestTarget)
        #expect(refreshed.sessions.map(\.name) == ["new"])
        #expect(await runner.runCount == 2)
    }

    @Test("browser-style stale load peeks cache then starts exactly one refresh")
    func peekThenRefreshStartsOneRequest() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "cached\n", stderr: "", exitCode: 0)),
            .gated(.init(stdout: "fresh\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        _ = await discovery.refresh(target: tmuxTestTarget)
        clock.advance(by: 61)
        let cached = await discovery.peekSnapshot(target: tmuxTestTarget)

        #expect(cached?.sessions.map(\.name) == ["cached"])
        #expect(cached?.isFresh(at: clock.now) == false)
        #expect(await runner.runCount == 1)

        let verification = Task {
            await discovery.refresh(target: tmuxTestTarget)
        }
        await runner.waitUntilRunCount(2)
        let verifying = await discovery.peekSnapshot(target: tmuxTestTarget)
        #expect(verifying?.sessions.map(\.name) == ["cached"])
        #expect(verifying?.verification == .verifying)
        #expect(await runner.runCount == 2)

        await runner.releaseGate()
        #expect(await verification.value.sessions.map(\.name) == ["fresh"])
        #expect(await runner.runCount == 2)
    }

    @Test("stale request rechecks freshness after an existing refresh finishes")
    func refreshIfStaleAvoidsCompletedRefreshDuplicate() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "cached\n", stderr: "", exitCode: 0)),
            .gated(.init(stdout: "fresh\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        _ = await discovery.refresh(target: tmuxTestTarget)
        clock.advance(by: 61)
        let existingRefresh = Task {
            await discovery.refresh(target: tmuxTestTarget)
        }
        await runner.waitUntilRunCount(2)
        let cached = await discovery.peekSnapshot(target: tmuxTestTarget)
        #expect(cached?.sessions.map(\.name) == ["cached"])
        #expect(cached?.verification == .verifying)

        await runner.releaseGate()
        #expect(await existingRefresh.value.sessions.map(\.name) == ["fresh"])

        let rechecked = await discovery.refreshIfStale(target: tmuxTestTarget)
        #expect(rechecked.sessions.map(\.name) == ["fresh"])
        #expect(rechecked.isFresh(at: clock.now))
        #expect(await runner.runCount == 2)
    }

    @Test("failed refresh retains authoritative sessions and timestamp")
    func failedRefreshRetainsEvidence() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "known\n", stderr: "", exitCode: 0)),
            .failure
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        let first = await discovery.refresh(target: tmuxTestTarget)
        clock.advance(by: 61)
        let failed = await discovery.refresh(target: tmuxTestTarget)

        #expect(failed.sessions == first.sessions)
        #expect(failed.fetchedAt == first.fetchedAt)
        #expect(failed.readiness == .ready)
        #expect(failed.verification == .idle)
        #expect(failed.lastError == .transport)
        #expect(await discovery.peekSnapshot(target: tmuxTestTarget)?.sessions == first.sessions)
    }

    @Test("in-flight transport failure preserves an authoritative rename")
    func failedRefreshPreservesConcurrentRename() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "old\nother\n", stderr: "", exitCode: 0)),
            .gatedFailure
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        let first = await discovery.refresh(target: tmuxTestTarget)
        let refresh = Task {
            await discovery.refresh(target: tmuxTestTarget)
        }
        await runner.waitUntilRunCount(2)
        await discovery.recordRename(
            target: tmuxTestTarget,
            from: "old",
            to: "renamed"
        )
        await runner.releaseGate()
        let failed = await refresh.value

        #expect(failed.sessions.map(\.name) == ["renamed", "other"])
        #expect(failed.fetchedAt == first.fetchedAt)
        #expect(failed.readiness == .ready)
        #expect(failed.lastError == .transport)
    }

    @Test("in-flight Worker-not-ready result preserves an authoritative termination")
    func workerNotReadyPreservesConcurrentTermination() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0)),
            .gated(.init(
                stdout: "",
                stderr: "worker is not ready",
                exitCode: 1
            ))
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        let first = await discovery.refresh(target: tmuxTestTarget)
        let refresh = Task {
            await discovery.refresh(target: tmuxTestTarget)
        }
        await runner.waitUntilRunCount(2)
        await discovery.recordTermination(
            target: tmuxTestTarget,
            sessionNames: ["one"]
        )
        await runner.releaseGate()
        let notReady = await refresh.value

        #expect(notReady.sessions.map(\.name) == ["two"])
        #expect(notReady.fetchedAt == first.fetchedAt)
        #expect(notReady.readiness == .workerNotReady)
        #expect(notReady.lastError == .workerNotReady)
    }

    @Test("successful in-flight refresh preserves a concurrent rename")
    func successfulRefreshPreservesConcurrentRename() async {
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "old\nother\n", stderr: "", exitCode: 0)),
            .gated(.init(stdout: "old\nother\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(processRunner: runner)

        _ = await discovery.refresh(target: tmuxTestTarget)
        let refresh = Task { await discovery.refresh(target: tmuxTestTarget) }
        await runner.waitUntilRunCount(2)
        await discovery.recordRename(
            target: tmuxTestTarget,
            from: "old",
            to: "renamed"
        )
        await runner.releaseGate()

        #expect(await refresh.value.sessions.map(\.name) == ["renamed", "other"])
    }

    @Test("successful in-flight refresh preserves a concurrent termination")
    func successfulRefreshPreservesConcurrentTermination() async {
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0)),
            .gated(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(processRunner: runner)

        _ = await discovery.refresh(target: tmuxTestTarget)
        let refresh = Task { await discovery.refresh(target: tmuxTestTarget) }
        await runner.waitUntilRunCount(2)
        await discovery.recordTermination(
            target: tmuxTestTarget,
            sessionNames: ["one"]
        )
        await runner.releaseGate()

        #expect(await refresh.value.sessions.map(\.name) == ["two"])
    }

    @Test("first successful refresh preserves a concurrent rename")
    func firstRefreshPreservesConcurrentRename() async {
        let runner = TmuxSnapshotRunner(steps: [
            .gated(.init(stdout: "old\nother\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(processRunner: runner)

        let refresh = Task { await discovery.refresh(target: tmuxTestTarget) }
        await runner.waitUntilRunCount(1)
        await discovery.recordRename(
            target: tmuxTestTarget,
            from: "old",
            to: "renamed"
        )
        await runner.releaseGate()

        #expect(await refresh.value.sessions.map(\.name) == ["renamed", "other"])
    }

    @Test("first successful refresh preserves a concurrent termination")
    func firstRefreshPreservesConcurrentTermination() async {
        let runner = TmuxSnapshotRunner(steps: [
            .gated(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(processRunner: runner)

        let refresh = Task { await discovery.refresh(target: tmuxTestTarget) }
        await runner.waitUntilRunCount(1)
        await discovery.recordTermination(
            target: tmuxTestTarget,
            sessionNames: ["one"]
        )
        await runner.releaseGate()

        #expect(await refresh.value.sessions.map(\.name) == ["two"])
    }

    @Test("mutations outside refresh advance revision without accumulating journal")
    func idleMutationsDoNotAccumulateJournal() async {
        let discovery = TmuxSessionDiscovery(processRunner: TmuxSnapshotRunner(
            steps: [.output(.init(
                stdout: "one\ntwo\n",
                stderr: "",
                exitCode: 0
            ))]
        ))
        _ = await discovery.refresh(target: tmuxTestTarget)

        await discovery.recordRename(
            target: tmuxTestTarget,
            from: "one",
            to: "renamed"
        )
        await discovery.recordTermination(
            target: tmuxTestTarget,
            sessionNames: ["two"]
        )

        let state = await discovery.mutationStateForTesting(
            target: tmuxTestTarget
        )
        #expect(state.revision == 2)
        #expect(state.journalCount == 0)
        #expect(
            await discovery.peekSnapshot(target: tmuxTestTarget)?
                .sessions.map(\.name) == ["renamed"]
        )
    }

    @Test(
        "empty tmux diagnostics replace inventory with authoritative evidence",
        arguments: [
            "no server running on /tmp/tmux/default",
            "no sessions",
            "error connecting to /dev/shm/tmux-1000/default (No such file or directory)",
        ]
    )
    func emptyTmuxIsAuthoritative(_ diagnostic: String) async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "old\n", stderr: "", exitCode: 0)),
            .output(.init(
                stdout: "",
                stderr: diagnostic,
                exitCode: 1
            ))
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        _ = await discovery.refresh(target: tmuxTestTarget)
        clock.advance(by: 10)
        let empty = await discovery.refresh(target: tmuxTestTarget)

        #expect(empty.sessions.isEmpty)
        #expect(empty.readiness == .ready)
        #expect(empty.fetchedAt == clock.now)
        #expect(empty.lastError == nil)
    }

    @Test("Worker-not-ready evidence does not replace authoritative sessions")
    func workerNotReadyRetainsSessions() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "known\n", stderr: "", exitCode: 0)),
            .output(.init(
                stdout: "",
                stderr: "worker has not been ready yet",
                exitCode: 1
            ))
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966773"
        )

        let first = await discovery.refresh(target: target)
        clock.advance(by: 10)
        let notReady = await discovery.refresh(target: target)

        #expect(notReady.sessions == first.sessions)
        #expect(notReady.fetchedAt == first.fetchedAt)
        #expect(notReady.readiness == .workerNotReady)
        #expect(notReady.lastError == .workerNotReady)
    }

    @Test("rename and termination preserve the authoritative timestamp")
    func mutationsPreserveTimestamp() async {
        let clock = TmuxTestClock()
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0))
        ])
        let discovery = TmuxSessionDiscovery(
            processRunner: runner,
            now: { clock.now }
        )

        let first = await discovery.refresh(target: tmuxTestTarget)
        clock.advance(by: 10)
        await discovery.recordRename(
            target: tmuxTestTarget,
            from: "one",
            to: "renamed"
        )
        let renamed = await discovery.snapshot(target: tmuxTestTarget)
        await discovery.recordTermination(
            target: tmuxTestTarget,
            sessionNames: ["two"]
        )
        let terminated = await discovery.snapshot(target: tmuxTestTarget)

        #expect(renamed?.sessions.map(\.name) == ["renamed", "two"])
        #expect(renamed?.fetchedAt == first.fetchedAt)
        #expect(terminated?.sessions.map(\.name) == ["renamed"])
        #expect(terminated?.fetchedAt == first.fetchedAt)
    }

    @Test("mutations update cached snapshots across routes for one platform target")
    func mutationsFollowStableTargetIdentity() async {
        let runner = TmuxSnapshotRunner(steps: [
            .output(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0)),
            .output(.init(stdout: "one\ntwo\n", stderr: "", exitCode: 0)),
        ])
        let discovery = TmuxSessionDiscovery(processRunner: runner)
        let relay = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966773"
        )
        let direct = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "3966773.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org",
            workerID: "3966773"
        )
        _ = await discovery.refresh(target: relay)
        _ = await discovery.refresh(target: direct)

        await discovery.recordRename(
            target: relay,
            from: "one",
            to: "renamed"
        )

        #expect(await discovery.peekSnapshot(target: relay)?
            .sessions.map(\.name) == ["renamed", "two"])
        #expect(await discovery.peekSnapshot(target: direct)?
            .sessions.map(\.name) == ["renamed", "two"])

        await discovery.recordTermination(
            target: relay,
            sessionNames: ["renamed"]
        )

        #expect(await discovery.peekSnapshot(target: relay)?
            .sessions.map(\.name) == ["two"])
        #expect(await discovery.peekSnapshot(target: direct)?
            .sessions.map(\.name) == ["two"])
    }

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
        let sessions = await discovery.refresh(target: target).sessions

        #expect(sessions.map(\.name) == ["mlz-shell", "external.train"])
        #expect(await discovery.snapshot(target: target)?.sessions == sessions)
        let command = await runner.recordedCommand()
        #expect(command?.executable == "/usr/bin/ssh")
    }

    @Test("Worker discovery clears inherited tmux state and uses the safe socket directory")
    func workerDiscoveryUsesDirectTmuxListing() async throws {
        let runner = TmuxScriptedRunner(output: InventoryProcessOutput(
            stdout: "connecting to Worker\none\ntwo\n",
            stderr: "",
            exitCode: 0
        ))
        let discovery = TmuxSessionDiscovery(processRunner: runner)
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )

        let sessions = await discovery.refresh(target: target).sessions

        #expect(sessions.map(\.name) == ["one", "two"])
        let remote = await runner.recordedCommand()?.arguments.last
        #expect(remote ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3966762 -- env -u TMUX TERM=dumb TMUX_TMPDIR=/dev/shm tmux list-sessions -F#{session_name}")
    }

    @Test("Worker discovery finds sessions in the socket directory used by terminals")
    func workerDiscoveryUsesTerminalSocketDirectory() async {
        let discovery = TmuxSessionDiscovery(
            processRunner: WorkerSocketAwareDiscoveryRunner()
        )
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "4065910"
        )

        let snapshot = await discovery.refresh(target: target)

        #expect(snapshot.sessions.map(\.name) == ["dora_metric_ana", "metric"])
        #expect(snapshot.lastError == nil)
    }

    @Test("successful Worker login discovers sessions without a synthetic readiness marker")
    func workerDiscoveryDoesNotRequireReadinessMarker() async {
        let runner = TmuxScriptedRunner(output: InventoryProcessOutput(
            stdout: """
            Logging into fdbd8fc6-01fe-4a95-b962-b814c31e6ac0
            2026-07-13 19:58:30 check if require setup...
            mlz-hl_gpu_2-4004694-6243a14a
            """,
            stderr: "",
            exitCode: 0
        ))
        let discovery = TmuxSessionDiscovery(processRunner: runner)
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "4004694"
        )

        let snapshot = await discovery.refresh(target: target)

        #expect(snapshot.sessions.map(\.name) == [
            "mlz-hl_gpu_2-4004694-6243a14a"
        ])
        #expect(snapshot.readiness == .ready)
        #expect(snapshot.lastError == nil)
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

        let sessions = await discovery.refresh(target: .devbox(
            sid: "dbx_135679", name: "wt_hl", alias: "hl_gpu_2"
        )).sessions

        #expect(sessions.map(\.name) == ["pool-session"])
        let commands = await poolRunner.commands()
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(commands.last?.arguments.contains("ControlPath=\(expectedPath)") == true)
        #expect(await directRunner.recordedCommand() == nil)
    }

    @Test("foreground discovery bypasses occupied background slots")
    func foregroundDiscoveryBypassesBackgroundSlots() async {
        let runner = GatedPooledDiscoveryRunner()
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: runner
        )
        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .foreground) == .ready)
        let discovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            processRunner: TmuxScriptedRunner(output: .init(
                stdout: "must-not-run", stderr: "", exitCode: 0
            )),
            foregroundExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: 2,
                timeout: .seconds(5)
            ),
            backgroundExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: 2,
                timeout: .seconds(5)
            )
        )
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: discovery,
            maxConcurrentWorkerWarmups: 2,
            maxConcurrentWorkerWarmupsPerAlias: 2
        )
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [
                    pooledWorker("7000001"), pooledWorker("7000002"),
                ]
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )
        await runner.waitForChildStarts(2)

        let browser = Task {
            await discovery.refresh(
                target: pooledWorker("7000003"),
                lane: .foreground
            )
        }
        await runner.waitForChildStarts(3)
        #expect(await runner.childStartCount() == 3)
        #expect(await runner.maximumChildConcurrency() == 3)

        await runner.releaseAll()
        _ = await browser.value
        await coordinator.shutdown()
        await pool.shutdown()
    }

    @Test("foreground joins an in-flight background refresh for the same Worker")
    func foregroundJoinsBackgroundRefreshForSameWorker() async {
        let runner = GatedPooledDiscoveryRunner()
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: runner
        )
        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .foreground) == .ready)
        let discovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            processRunner: TmuxScriptedRunner(output: .init(
                stdout: "must-not-run", stderr: "", exitCode: 0
            )),
            foregroundExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: 2,
                timeout: .seconds(5)
            ),
            backgroundExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: 2,
                timeout: .seconds(5)
            )
        )
        let target = pooledWorker("7000004")
        let background = Task {
            await discovery.refresh(target: target, lane: .background)
        }
        await runner.waitForChildStarts(1)
        let foreground = Task {
            await discovery.refresh(target: target, lane: .foreground)
        }
        for _ in 0 ..< 1_000 { await Task.yield() }
        #expect(await runner.childStartCount() == 1)

        await runner.releaseAll()
        _ = await (background.value, foreground.value)
        await pool.shutdown()
    }

    @Test("pooled discovery timeout reaps its child and releases shutdown lease")
    func pooledDiscoveryTimeoutReapsChild() async throws {
        let pidFile = TemporaryProcessIDFile()
        defer { pidFile.remove() }
        let runner = PooledDiscoveryChildRunner(pidFile: pidFile)
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: runner
        )
        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .foreground) == .ready)
        let discovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            processRunner: TmuxScriptedRunner(output: .init(
                stdout: "must-not-run", stderr: "", exitCode: 0
            )),
            foregroundExecutionPolicy: BoundedAsyncOperationRunner(
                maxConcurrentOperations: 2,
                timeout: .milliseconds(300)
            )
        )
        let refresh = Task { await discovery.refresh(target: pooledWorker("7000004")) }
        let processID = try await pidFile.waitForProcessID()

        let snapshot = await refresh.value
        #expect(snapshot.lastError == .transport)
        #expect(pidFile.processIsAbsent(processID))
        #expect(!pidFile.processHasExitedWithoutReaping(processID))

        await pool.shutdown()
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

        #expect(await discovery.refresh(target: target).sessions.isEmpty)
        #expect(await discovery.snapshot(target: target)?.sessions == [])
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

        #expect(await discovery.refresh(target: target).sessions.isEmpty)
        #expect(await discovery.snapshot(target: target)?.sessions == [])
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

        let snapshot = await discovery.refresh(target: .worker(
            devboxSID: "dbx_135679", devboxName: "wt_hl",
            alias: "hl_gpu_2", workerID: "3966773"
        ))
        #expect(snapshot.lastError == .workerNotReady)
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

        _ = await discovery.refresh(target: target)
        await discovery.recordRename(
            target: target,
            from: "old-name",
            to: "new-name"
        )

        #expect(
            await discovery.snapshot(target: target)?.sessions.map(\.name)
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

        _ = await discovery.refresh(target: target)
        await discovery.recordTermination(
            target: target,
            sessionNames: ["one", "three"]
        )

        #expect(
            await discovery.snapshot(target: target)?.sessions.map(\.name)
                == ["two"]
        )
    }
}

private let tmuxTestTarget = TerminalTarget.devbox(
    sid: "dbx_135679",
    name: "wt_hl",
    alias: "hl_gpu_2"
)

private func pooledWorker(_ workerID: String) -> TerminalTarget {
    .worker(
        devboxSID: "dbx_135679",
        devboxName: "wt_hl",
        alias: "hl_gpu_2",
        workerID: workerID
    )
}

private final class TmuxTestClock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(
        initialState: TmuxSnapshotDate(timeIntervalSince1970: 1_000)
    )

    var now: TmuxSnapshotDate { value.withLock { $0 } }

    func advance(by interval: Double) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private enum TmuxSnapshotRunnerError: Error {
    case failed
}

private actor TmuxSnapshotRunner: InventoryProcessRunning {
    enum Step: Sendable {
        case output(InventoryProcessOutput)
        case failure
        case gated(InventoryProcessOutput)
        case gatedFailure
    }

    private var steps: [Step]
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var runCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        runCount += 1
        let step = steps.removeFirst()
        switch step {
        case let .output(output):
            return output
        case .failure:
            throw TmuxSnapshotRunnerError.failed
        case let .gated(output):
            await withCheckedContinuation { gate = $0 }
            return output
        case .gatedFailure:
            await withCheckedContinuation { gate = $0 }
            throw TmuxSnapshotRunnerError.failed
        }
    }

    func waitUntilRunCount(_ expected: Int) async {
        while runCount < expected { await Task.yield() }
    }

    func releaseGate() {
        gate?.resume()
        gate = nil
    }
}

private actor GatedPooledDiscoveryRunner: InventoryProcessRunning {
    private var childStarts = 0
    private var activeChildren = 0
    private var maximumChildren = 0
    private var gates: [CheckedContinuation<Void, Never>] = []

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.starts(with: ["-O", "check"]) {
            return .init(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf"
            || command.arguments.starts(with: ["-O", "stop"])
        {
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        childStarts += 1
        activeChildren += 1
        maximumChildren = max(maximumChildren, activeChildren)
        await withCheckedContinuation { gates.append($0) }
        activeChildren -= 1
        let isWorker = command.arguments.last?.contains("mlx worker login") == true
        return .init(
            stdout: isWorker ? "__MLZ_READY__\n" : "browser\n",
            stderr: "",
            exitCode: 0
        )
    }

    func waitForChildStarts(_ count: Int) async {
        while childStarts < count { await Task.yield() }
    }

    func childStartCount() -> Int { childStarts }
    func maximumChildConcurrency() -> Int { maximumChildren }

    func releaseOne() {
        gates.removeFirst().resume()
    }

    func releaseAll() {
        let pending = gates
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}

private actor PooledDiscoveryChildRunner: InventoryProcessRunning {
    private let pidFile: TemporaryProcessIDFile
    private let runner = FoundationInventoryProcessRunner()

    init(pidFile: TemporaryProcessIDFile) {
        self.pidFile = pidFile
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.starts(with: ["-O", "check"]) {
            return .init(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf"
            || command.arguments.starts(with: ["-O", "stop"])
        {
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        return try await runner.run(.init(
            executable: "/bin/sh",
            arguments: [
                "-c", "echo $$ > \"$1\"; exec /bin/sleep 30",
                "pooled-discovery-timeout", pidFile.path,
            ]
        ))
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

private actor WorkerSocketAwareDiscoveryRunner: InventoryProcessRunning {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let remoteCommand = command.arguments.last ?? ""
        let usesTerminalSocket = [
            "env -u TMUX",
            "TMUX_TMPDIR=/dev/shm",
            "tmux list-sessions",
        ].allSatisfy(remoteCommand.contains)
        guard usesTerminalSocket else {
            return InventoryProcessOutput(
                stdout: "",
                stderr: "no server running on /tmp/tmux-1000/default",
                exitCode: 1
            )
        }
        return InventoryProcessOutput(
            stdout: "dora_metric_ana\nmetric\n",
            stderr: "",
            exitCode: 0
        )
    }
}
