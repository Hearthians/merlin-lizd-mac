import MerlinLizdCore

@MainActor
final class MerlinRemoteRuntime {
    let sshMasterPool: SSHMasterPool
    let tmuxDiscovery: TmuxSessionDiscovery
    let tmuxController: TmuxSessionController
    let metricsStreamer: WorkerMetricsStreamer
    let warmupCoordinator: TargetWarmupCoordinator
    let codexRuntime: CodexRuntime?
    private let submissions = OrderedAsyncSubmissionQueue()
    private var isShuttingDown = false

    init() {
        let pool = SSHMasterPool(maxConcurrentPreparations: 4)
        sshMasterPool = pool
        tmuxDiscovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            maxConcurrentBackgroundWorkerRefreshes: 16
        )
        tmuxController = TmuxSessionController(sshMasterPool: pool)
        metricsStreamer = WorkerMetricsStreamer(sshMasterPool: pool)
        warmupCoordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: tmuxDiscovery,
            maxConcurrentWorkerWarmups: 16
        )
        codexRuntime = try? CodexRuntime(tmuxController: tmuxController)
    }

    func reconcile(
        _ inventory: TargetWarmupInventory,
        reason: WarmupReason,
        onUpdate: @escaping @Sendable (TargetWarmupUpdate) -> Void
    ) {
        guard !isShuttingDown else { return }
        let coordinator = warmupCoordinator
        submissions.submit {
            await coordinator.reconcile(
                inventory,
                reason: reason,
                onUpdate: onUpdate
            )
        }
    }

    func prioritize(_ target: TerminalTarget) {
        guard !isShuttingDown else { return }
        let coordinator = warmupCoordinator
        submissions.submit {
            await coordinator.prioritize(target)
        }
    }

    func shutdown() async {
        isShuttingDown = true
        await codexRuntime?.shutdown()
        await submissions.cancelPendingAndFinish()
        await warmupCoordinator.shutdown()
        await WorkerMetricsStreamer.shutdownAll()
        await sshMasterPool.shutdown()
    }
}
