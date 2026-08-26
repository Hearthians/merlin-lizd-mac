import TmuxHubCore

@MainActor
final class HubRuntime {
    let sshMasterPool: SSHMasterPool
    let tmuxDiscovery: TmuxSessionDiscovery
    let tmuxController: TmuxSessionController
    private var isShuttingDown = false

    init() {
        let pool = SSHMasterPool(maxConcurrentPreparations: 4)
        sshMasterPool = pool
        tmuxDiscovery = TmuxSessionDiscovery(
            sshMasterPool: pool,
            maxConcurrentBackgroundRefreshes: 8
        )
        tmuxController = TmuxSessionController(
            sshMasterPool: pool,
            maxConcurrentProcesses: 4
        )
    }

    func prepare(_ target: TerminalTarget) {
        guard !isShuttingDown, let destination = target.sshDestination else {
            return
        }
        Task {
            _ = await sshMasterPool.prepare(
                alias: destination,
                priority: .foreground
            )
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        await sshMasterPool.shutdown()
    }
}
