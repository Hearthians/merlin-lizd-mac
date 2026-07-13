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
        for _ in 0 ..< 1_000 {
            if await coordinator.preparationTaskCountForTesting() == 0 { break }
            await Task.yield()
        }

        #expect(Set(await poolRunner.preparedAliases()) == ["cached_one", "cached_two"])
        #expect(await coordinator.preparationTaskCountForTesting() == 0)
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

    @Test("warmup runs no more than sixteen Worker refreshes concurrently")
    func boundsWorkerConcurrency() async {
        let runner = WarmupDiscoveryRunner(gated: true)
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: WarmupPoolRunner()
        )
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: TmuxSessionDiscovery(processRunner: runner)
        )
        let workers = (1 ... 17).map {
            warmupWorker(String(2_000_000 + $0))
        }
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: workers
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )

        await runner.waitForStarts(2)
        for _ in 0 ..< 10_000 {
            if await runner.startedWorkerIDs().count >= 16 { break }
            await Task.yield()
        }
        let initialCount = await runner.startedWorkerIDs().count
        #expect(initialCount == 16)
        guard initialCount == 16 else {
            await runner.releaseAll()
            await coordinator.shutdown()
            return
        }
        #expect(await runner.maximumConcurrency() == 16)
        await runner.releaseNext()
        await runner.waitForStarts(17)
        #expect(await runner.maximumConcurrency() == 16)
        await runner.releaseAll()
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

    @Test("replacing both active Workers immediately admits new Workers")
    func workerReplacementCancelsActiveWarmups() async {
        let runner = CancellationAwareWarmupRunner()
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: SSHMasterPool(
                testDirectory: temporarySSHDirectory(),
                runner: WarmupPoolRunner()
            ),
            discovery: TmuxSessionDiscovery(processRunner: runner),
            maxConcurrentWorkerWarmups: 2
        )
        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [warmupWorker("4100001"), warmupWorker("4100002")]
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )
        await runner.waitForStarts(2)

        await coordinator.reconcile(
            .init(
                runningDevboxAliases: [],
                workerTargets: [warmupWorker("4100003"), warmupWorker("4100004")]
            ),
            reason: .inventoryChange,
            onUpdate: { _ in }
        )
        await runner.waitForStarts(4)
        await runner.waitForCancellations(2)

        #expect(Set(await runner.startedWorkerIDs().suffix(2)) == ["4100003", "4100004"])
        #expect(await runner.cancelledWorkerIDs() == ["4100001", "4100002"])
        await runner.releaseAll()
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

    @Test("new reconciliation supersedes an older cache-expiry follow-up")
    func newerGenerationSupersedesQueuedExpiry() async {
        let runner = WarmupDiscoveryRunner(gated: true)
        let sleeper = WarmupTestSleeper()
        let updates = WarmupUpdateRecorder()
        let coordinator = makeWarmupCoordinator(
            runner: runner,
            maxConcurrentWorkerWarmups: 1,
            sleeper: { duration in try await sleeper.sleep(duration) }
        )
        let target = warmupWorker("5500001")
        await coordinator.reconcile(
            .init(runningDevboxAliases: [], workerTargets: [target]),
            reason: .appLaunch,
            onUpdate: { _ in Task { await updates.record("launch") } }
        )
        await runner.waitForStarts(1)
        await sleeper.waitUntilSleeping()
        await sleeper.advance()
        await sleeper.waitUntilSleepCount(2)

        await coordinator.reconcile(
            .init(runningDevboxAliases: [], workerTargets: [target]),
            reason: .manualRefresh,
            onUpdate: { _ in Task { await updates.record("manual") } }
        )
        await runner.releaseAll()
        await updates.waitForCount(1)

        #expect(await runner.startedWorkerIDs() == ["5500001"])
        #expect(await updates.values() == ["manual"])
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
        let argv = commands[0].arguments.joined(separator: " ")
        for forbidden in [
            "new-session", "attach", "tmux kill", "kill-session",
            "rename-session", "worker stop", "worker delete",
        ] {
            #expect(!argv.contains(forbidden))
        }
    }

    @Test("shutdown cancels and reaps the active local warmup child")
    func shutdownReapsActiveWarmupChild() async throws {
        let pidFile = TemporaryProcessIDFile()
        defer { pidFile.remove() }
        let runner = LocalWarmupChildRunner(pidFile: pidFile)
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
                workerTargets: [warmupWorker("6000003"), warmupWorker("6000004")]
            ),
            reason: .appLaunch,
            onUpdate: { _ in }
        )
        let processID = try await pidFile.waitForProcessID()

        await coordinator.shutdown()

        #expect(pidFile.processIsAbsent(processID))
        #expect(!pidFile.processHasExitedWithoutReaping(processID))
        #expect(await runner.runCount() == 1)
    }

    @Test("concurrent shutdown callers await the same cleanup")
    func concurrentShutdownIsSingleFlight() async {
        let poolRunner = GatedWarmupPoolRunner()
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: poolRunner
        )
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: TmuxSessionDiscovery(processRunner: WarmupDiscoveryRunner())
        )
        await coordinator.reconcile(
            .init(runningDevboxAliases: ["shutdown_gate"], workerTargets: []),
            reason: .appLaunch,
            onUpdate: { _ in }
        )
        await poolRunner.waitUntilPreparationStarted()
        let callers = WarmupUpdateRecorder()
        let completions = WarmupUpdateRecorder()

        let first = Task {
            await callers.record("first")
            await coordinator.shutdown()
            await completions.record("first")
        }
        let second = Task {
            await callers.record("second")
            await coordinator.shutdown()
            await completions.record("second")
        }
        await callers.waitForCount(2)
        for _ in 0 ..< 1_000 {
            if !(await completions.values()).isEmpty { break }
            await Task.yield()
        }

        #expect(await completions.values().isEmpty)
        await poolRunner.releasePreparation()
        await completions.waitForCount(2)
        _ = await (first.value, second.value)
        #expect(Set(await completions.values()) == ["first", "second"])
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

private actor GatedWarmupPoolRunner: InventoryProcessRunning {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.starts(with: ["-O", "check"]) {
            return .init(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf" {
            started = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { gate = $0 }
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func waitUntilPreparationStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releasePreparation() {
        gate?.resume()
        gate = nil
    }
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

private actor CancellationAwareWarmupRunner: InventoryProcessRunning {
    private var started: [String] = []
    private var cancelled: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let remote = command.arguments.last ?? ""
        let suffix = remote.components(separatedBy: "mlx worker login ").last ?? ""
        let workerID = String(suffix.split(separator: " ").first ?? "")
        started.append(workerID)
        do {
            try await withTaskCancellationHandler {
                await withCheckedContinuation { gates[workerID] = $0 }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancel(workerID) }
            }
        } catch {
            cancelled.insert(workerID)
            throw error
        }
        return .init(stdout: "__MLZ_READY__\n", stderr: "", exitCode: 0)
    }

    private func cancel(_ workerID: String) {
        gates.removeValue(forKey: workerID)?.resume()
    }

    func waitForStarts(_ count: Int) async {
        while started.count < count { await Task.yield() }
    }

    func startedWorkerIDs() -> [String] { started }
    func cancelledWorkerIDs() -> Set<String> { cancelled }

    func waitForCancellations(_ count: Int) async {
        while cancelled.count < count { await Task.yield() }
    }

    func releaseAll() {
        let pending = Array(gates.values)
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}

private actor WarmupTestSleeper {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var sleepCount = 0
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async throws {
        sleepCount += 1
        let ready = countWaiters.filter { sleepCount >= $0.0 }
        countWaiters.removeAll { sleepCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilSleeping() async {
        while continuation == nil { await Task.yield() }
    }

    func advance() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilSleepCount(_ count: Int) async {
        guard sleepCount < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func cancelAll() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor WarmupUpdateRecorder {
    private var recorded: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ value: String) {
        recorded.append(value)
        let ready = waiters.filter { recorded.count >= $0.0 }
        waiters.removeAll { recorded.count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }

    func waitForCount(_ count: Int) async {
        guard recorded.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func values() -> [String] { recorded }
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

private actor LocalWarmupChildRunner: InventoryProcessRunning {
    private let pidFile: TemporaryProcessIDFile
    private let runner = FoundationInventoryProcessRunner()
    private var count = 0

    init(pidFile: TemporaryProcessIDFile) {
        self.pidFile = pidFile
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        count += 1
        return try await runner.run(CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1\"; exec /bin/sleep 30",
                "merlin-lizd-warmup-shutdown-test",
                pidFile.path,
            ]
        ))
    }

    func runCount() -> Int { count }
}
