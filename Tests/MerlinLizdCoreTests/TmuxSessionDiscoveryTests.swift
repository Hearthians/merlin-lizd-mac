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
        #expect(await discovery.cached(target: tmuxTestTarget) == first.sessions)
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

    @Test(
        "empty tmux diagnostics replace inventory with authoritative evidence",
        arguments: [
            "no server running on /tmp/tmux/default",
            "no sessions"
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
        #expect(await discovery.snapshot(target: target)?.sessions == sessions)
        #expect(await discovery.cached(target: target) == sessions)
        let command = await runner.recordedCommand()
        #expect(command?.executable == "/usr/bin/ssh")
    }

    @Test("Worker tmux warmup parses readiness before session names")
    func workerWarmupParsesReadinessMarker() async throws {
        let runner = TmuxScriptedRunner(output: InventoryProcessOutput(
            stdout: "connecting to Worker\n__MLZ_READY__\none\ntwo\n",
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

        let sessions = try await discovery.list(target: target)

        #expect(sessions.map(\.name) == ["one", "two"])
        let remote = await runner.recordedCommand()?.arguments.last
        #expect(remote?.components(separatedBy: "mlx worker login").count == 2)
        #expect(remote?.contains("printf \\\"__MLZ_READY__\\n\\\"") == true)
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
                stdout: "__MLZ_READY__\n",
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

        #expect(try await discovery.list(target: target).isEmpty)
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

        _ = try await discovery.list(target: target)
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
