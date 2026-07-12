import Testing
@testable import MerlinLizdCore

@Suite("target warmup scheduler")
struct TargetWarmupCoordinatorTests {
    @Test("warmup prepares every cached running Devbox alias")
    func preparesCachedAliases() async {
        let poolRunner = WarmupPoolRunner()
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: poolRunner
        )
        let discovery = TmuxSessionDiscovery(
            processRunner: WarmupDiscoveryRunner()
        )
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: discovery
        )

        await coordinator.reconcile(
            TargetWarmupInventory(
                runningDevboxAliases: ["cached_one", "cached_two"],
                workerTargets: []
            ),
            reason: .appLaunch,
            onUpdate: { _ in }
        )
        await poolRunner.waitForPreparedAliases(2)

        #expect(await poolRunner.preparedAliases() == ["cached_one", "cached_two"])
        await coordinator.shutdown()
    }

    @Test("warmup runs selected then recent targets before background work")
    func prioritizesSelectedAndRecentTargets() async {
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: WarmupPoolRunner()
        )
        let runner = WarmupDiscoveryRunner(gated: true)
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: TmuxSessionDiscovery(processRunner: runner),
            maxConcurrentWorkerWarmups: 1
        )
        let background = warmupWorker("1000001")
        let recent = warmupWorker("1000002")
        let open = warmupWorker("1000003")
        let selected = warmupWorker("1000004")

        await coordinator.prioritize(recent)
        await coordinator.prioritize(open)
        await coordinator.prioritize(selected)
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [background, recent, open, selected]
            ),
            reason: .appLaunch,
            onUpdate: { _ in }
        )
        await runner.waitForStarts(1)
        #expect(await runner.startedWorkerIDs() == ["1000004"])
        await runner.releaseNext()
        await runner.waitForStarts(2)
        #expect(await runner.startedWorkerIDs() == ["1000004", "1000003"])
        await runner.releaseAll()
        await coordinator.shutdown()
    }

    @Test("warmup runs no more than two Worker refreshes concurrently")
    func boundsWorkerConcurrency() async {
        let runner = WarmupDiscoveryRunner(gated: true)
        let coordinator = makeWarmupCoordinator(runner: runner)
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [
                    warmupWorker("2000001"),
                    warmupWorker("2000002"),
                    warmupWorker("2000003"),
                ]
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )

        await runner.waitForStarts(2)
        #expect(await runner.startedWorkerIDs().count == 2)
        #expect(await runner.maximumConcurrency() == 2)
        await runner.releaseAll()
        await runner.waitForStarts(3)
        #expect(await runner.maximumConcurrency() == 2)
        await coordinator.shutdown()
    }

    @Test("repeated reconciliation keeps each target single-flight")
    func repeatedReconciliationIsSingleFlight() async {
        let runner = WarmupDiscoveryRunner(gated: true)
        let coordinator = makeWarmupCoordinator(runner: runner)
        let inventory = TargetWarmupInventory(
            runningDevboxAliases: [],
            workerTargets: [warmupWorker("3000001"), warmupWorker("3000002")]
        )
        await coordinator.reconcile(
            inventory, reason: .inventoryChange, onUpdate: { _ in }
        )
        await runner.waitForStarts(2)
        await coordinator.reconcile(
            inventory, reason: .inventoryChange, onUpdate: { _ in }
        )
        await Task.yield()

        #expect(await runner.startedWorkerIDs().count == 2)
        await runner.releaseAll()
        await coordinator.shutdown()
    }

    @Test("replacing a Worker ID removes obsolete queued warmup")
    func workerReplacementCancelsQueuedWarmup() async {
        let runner = WarmupDiscoveryRunner(gated: true)
        let coordinator = makeWarmupCoordinator(
            runner: runner,
            maxConcurrentWorkerWarmups: 1
        )
        let active = warmupWorker("4000001")
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [active, warmupWorker("4000002")]
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )
        await runner.waitForStarts(1)
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [active, warmupWorker("4000003")]
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )
        await runner.releaseAll()
        await runner.waitForStarts(2)

        #expect(await runner.startedWorkerIDs() == ["4000001", "4000003"])
        await coordinator.shutdown()
    }

    @Test("five-minute cache expiry re-enqueues current targets")
    func periodicRefreshReenqueuesCurrentTargets() async {
        let runner = WarmupDiscoveryRunner()
        let sleeper = WarmupTestSleeper()
        let coordinator = makeWarmupCoordinator(
            runner: runner,
            sleeper: { duration in try await sleeper.sleep(duration) }
        )
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [warmupWorker("5000001")]
            ),
            reason: .appLaunch,
            onUpdate: { _ in }
        )
        await runner.waitForStarts(1)
        await sleeper.waitUntilSleeping()
        await sleeper.advance()
        await runner.waitForStarts(2)

        #expect(await runner.startedWorkerIDs() == ["5000001", "5000001"])
        await sleeper.cancelAll()
        await coordinator.shutdown()
    }

    @Test("shutdown cancels active and queued read-only warmups")
    func shutdownCancelsWarmupsWithoutMutation() async {
        let runner = CancellingWarmupRunner()
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: WarmupPoolRunner()
        )
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: TmuxSessionDiscovery(processRunner: runner),
            maxConcurrentWorkerWarmups: 1
        )
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [warmupWorker("6000001"), warmupWorker("6000002")]
            ),
            reason: .appLaunch,
            onUpdate: { _ in }
        )
        await runner.waitUntilStarted()
        await coordinator.shutdown()

        let commands = await runner.commands()
        #expect(commands.count == 1)
        #expect(await runner.wasCancelled())
        #expect(!commands[0].arguments.joined(separator: " ").contains("new-session"))
        #expect(!commands[0].arguments.joined(separator: " ").contains("kill"))
        #expect(!commands[0].arguments.joined(separator: " ").contains("attach"))
    }
}

private func makeWarmupCoordinator(
    runner: WarmupDiscoveryRunner,
    maxConcurrentWorkerWarmups: Int = 2,
    sleeper: TargetWarmupCoordinator.Sleeper? = nil
) -> TargetWarmupCoordinator {
    let pool = SSHMasterPool(
        testDirectory: temporarySSHDirectory(),
        runner: WarmupPoolRunner()
    )
    let discovery = TmuxSessionDiscovery(processRunner: runner)
    if let sleeper {
        return TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: discovery,
            maxConcurrentWorkerWarmups: maxConcurrentWorkerWarmups,
            sleeper: sleeper
        )
    }
    return TargetWarmupCoordinator(
        sshMasterPool: pool,
        discovery: discovery,
        maxConcurrentWorkerWarmups: maxConcurrentWorkerWarmups
    )
}

private func warmupWorker(_ workerID: String) -> TerminalTarget {
    .worker(
        devboxSID: "dbx_135679",
        devboxName: "wt_hl",
        alias: "hl_gpu_2",
        workerID: workerID
    )
}

private actor WarmupPoolRunner: InventoryProcessRunning {
    private var prepared: [String] = []

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.starts(with: ["-O", "check"]) {
            return .init(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf", let alias = command.arguments.last {
            prepared.append(alias)
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func waitForPreparedAliases(_ count: Int) async {
        while prepared.count < count { await Task.yield() }
    }

    func preparedAliases() -> [String] { prepared }
}

private actor WarmupDiscoveryRunner: InventoryProcessRunning {
    private var gated: Bool
    private var started: [String] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var active = 0
    private var maximumActive = 0

    init(gated: Bool = false) {
        self.gated = gated
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if let remote = command.arguments.last,
            let suffix = remote.components(separatedBy: "mlx worker login ").last,
            let workerID = suffix.split(separator: " ").first
        {
            started.append(String(workerID))
            let ready = startWaiters.filter { started.count >= $0.0 }
            startWaiters.removeAll { started.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
        active += 1
        maximumActive = max(maximumActive, active)
        if gated {
            await withCheckedContinuation { gates.append($0) }
        }
        active -= 1
        return .init(stdout: "__MLZ_READY__\n", stderr: "", exitCode: 0)
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func startedWorkerIDs() -> [String] { started }
    func maximumConcurrency() -> Int { maximumActive }

    func releaseNext() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }

    func releaseAll() {
        gated = false
        let pending = gates
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}

private actor WarmupTestSleeper {
    private var continuation: CheckedContinuation<Void, any Error>?

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilSleeping() async {
        while continuation == nil { await Task.yield() }
    }

    func advance() {
        continuation?.resume()
        continuation = nil
    }

    func cancelAll() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor CancellingWarmupRunner: InventoryProcessRunning {
    private var recorded: [CommandSpec] = []
    private var cancelled = false

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recorded.append(command)
        do {
            try await Task.sleep(for: .seconds(60))
            return .init(stdout: "__MLZ_READY__\n", stderr: "", exitCode: 0)
        } catch {
            cancelled = true
            throw error
        }
    }

    func waitUntilStarted() async {
        while recorded.isEmpty { await Task.yield() }
    }

    func commands() -> [CommandSpec] { recorded }
    func wasCancelled() -> Bool { cancelled }
}
