import MerlinLizdCore

@MainActor
final class MerlinRemoteRuntime {
    let sshMasterPool: SSHMasterPool
    let tmuxDiscovery: TmuxSessionDiscovery
    let tmuxController: TmuxSessionController
    let metricsStreamer: WorkerMetricsStreamer
    let warmupCoordinator: TargetWarmupCoordinator

    init() {
        let pool = SSHMasterPool(maxConcurrentPreparations: 4)
        sshMasterPool = pool
        tmuxDiscovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            maxConcurrentProcesses: 2
        )
        tmuxController = TmuxSessionController(sshMasterPool: pool)
        metricsStreamer = WorkerMetricsStreamer(sshMasterPool: pool)
        warmupCoordinator = TargetWarmupCoordinator(
            sshMasterPool: pool,
            discovery: tmuxDiscovery,
            maxConcurrentWorkerWarmups: 2
        )
    }

    func shutdown() async {
        await warmupCoordinator.shutdown()
        await WorkerMetricsStreamer.shutdownAll()
        await sshMasterPool.shutdown()
    }
}
