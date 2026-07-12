import Testing
@testable import MerlinLizdCore

@Suite("ordered async submissions")
struct OrderedAsyncSubmissionQueueTests {
    @Test("a gated old submission cannot overtake a newer submission")
    func preservesOldThenNewOrder() async {
        let queue = OrderedAsyncSubmissionQueue()
        let gate = AsyncStartGate()
        let recorder = SubmissionRecorder()

        queue.submit {
            await gate.wait()
            await recorder.record("old")
        }
        queue.submit {
            await recorder.record("new")
        }

        await gate.waitUntilEntered()
        #expect(await recorder.values().isEmpty)
        await gate.open()
        await queue.finish()

        #expect(await recorder.values() == ["old", "new"])
        #expect(await recorder.latest() == "new")
    }

    @Test("rapid priorities are delivered in selection order")
    func preservesRapidPriorityOrder() async {
        let queue = OrderedAsyncSubmissionQueue()
        let recorder = SubmissionRecorder()

        queue.submit { await recorder.record("recent") }
        queue.submit { await recorder.record("open") }
        queue.submit { await recorder.record("selected") }
        await queue.finish()

        #expect(await recorder.values() == ["recent", "open", "selected"])
        #expect(await recorder.latest() == "selected")
    }

    @Test("shutdown drains active work and rejects pending or late submissions")
    func shutdownRejectsPendingAndLateWork() async {
        let queue = OrderedAsyncSubmissionQueue()
        let gate = AsyncStartGate()
        let recorder = SubmissionRecorder()

        queue.submit {
            await gate.wait()
            await recorder.record("active")
        }
        queue.submit { await recorder.record("pending") }
        await gate.waitUntilEntered()

        let shutdown = Task {
            await queue.cancelPendingAndFinish()
        }
        while queue.acceptingSubmissionsForTesting() {
            await Task.yield()
        }
        await gate.open()
        await shutdown.value
        queue.submit { await recorder.record("late") }
        await queue.finish()

        #expect(await recorder.values() == ["active"])
    }

    @Test("restored priorities are applied before startup reconciliation")
    func restoredPrioritiesLeadFirstWarmupBatch() async {
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: StartupSubmissionPoolRunner()
        )
        let discoveryRunner = StartupSubmissionDiscoveryRunner()
        let coordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: TmuxSessionDiscovery(processRunner: discoveryRunner),
            maxConcurrentWorkerWarmups: 2
        )
        let queue = OrderedAsyncSubmissionQueue()
        let background = startupWorker("9100001")
        let restoredOpen = startupWorker("9100002")
        let restoredSelected = startupWorker("9100003")

        queue.submit { await coordinator.prioritize(restoredOpen) }
        queue.submit { await coordinator.prioritize(restoredSelected) }
        queue.submit {
            await coordinator.reconcile(
                .init(
                    runningDevboxAliases: [],
                    workerTargets: [background, restoredOpen, restoredSelected]
                ),
                reason: .appLaunch,
                onUpdate: { _ in }
            )
        }
        await queue.finish()
        await discoveryRunner.waitForStarts(2)

        #expect(
            Set(await discoveryRunner.startedWorkerIDs())
                == ["9100002", "9100003"]
        )
        await discoveryRunner.releaseAll()
        await coordinator.shutdown()
        await pool.shutdown()
    }
}

private actor SubmissionRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }

    func latest() -> String? {
        recorded.last
    }
}

private func startupWorker(_ workerID: String) -> TerminalTarget {
    .worker(
        devboxSID: "dbx_startup",
        devboxName: "startup",
        alias: "startup_alias",
        workerID: workerID
    )
}

private actor StartupSubmissionPoolRunner: InventoryProcessRunning {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        .init(stdout: "", stderr: "", exitCode: 0)
    }
}

private actor StartupSubmissionDiscoveryRunner: InventoryProcessRunning {
    private var isGated = true
    private var started: [String] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

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
        if isGated {
            await withCheckedContinuation { gates.append($0) }
        }
        return .init(stdout: "__MLZ_READY__\n", stderr: "", exitCode: 0)
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func startedWorkerIDs() -> [String] {
        started
    }

    func releaseAll() {
        isGated = false
        let pending = gates
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}
