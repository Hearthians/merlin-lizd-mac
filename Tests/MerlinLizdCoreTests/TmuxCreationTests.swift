import Testing
@testable import MerlinLizdCore

@Suite("tmux creation")
struct TmuxCreationTests {
    private let draft = TmuxCreationDraft(
        title: "hl_gpu_2",
        target: .devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            alias: "hl_gpu_2"
        ),
        suggestedSessionName: "mlz-hl_gpu_2-12345678"
    )

    @Test("request preserves the generated name until creation")
    func requestsAndCreates() throws {
        var coordinator = TmuxCreationCoordinator()

        coordinator.request(draft)
        #expect(
            coordinator.pending?.suggestedSessionName
                == "mlz-hl_gpu_2-12345678"
        )

        let result = try coordinator.create(
            sessionName: " training-main ",
            workingDirectory: "/mnt/training "
        )

        #expect(result.draft == draft)
        #expect(result.configuration.sessionName == "training-main")
        #expect(result.configuration.workingDirectory == "/mnt/training ")
        #expect(coordinator.pending == nil)
    }

    @Test("invalid creation leaves the draft pending")
    func retainsInvalidCreation() {
        var coordinator = TmuxCreationCoordinator()
        coordinator.request(draft)

        #expect(throws: TmuxCreationError.invalidSessionName) {
            try coordinator.create(
                sessionName: "unsafe name",
                workingDirectory: "/mnt/training"
            )
        }
        #expect(coordinator.pending == draft)
    }

    @Test("cancelling discards the pending creation")
    func cancelsCreation() {
        var coordinator = TmuxCreationCoordinator()
        coordinator.request(draft)

        coordinator.cancel()

        #expect(coordinator.pending == nil)
    }

    @Test("pending creation follows the current inventory route")
    func retargetsPendingCreation() throws {
        let destination = "135679.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
        let devbox = Devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            status: .running,
            cpuCores: nil,
            memoryBytes: nil,
            diskBytes: nil,
            workerCount: nil,
            rootfsType: nil,
            region: nil,
            accessRole: nil,
            sshProxyDestination: destination,
            createdAt: nil,
            updatedAt: nil
        )
        let snapshot = InventorySnapshot(
            devboxes: [DevboxInventory(devbox: devbox, sshAlias: "hl_gpu_2")],
            refreshedAt: .distantPast
        )
        var coordinator = TmuxCreationCoordinator()
        coordinator.request(draft)

        let didRetarget = coordinator.retarget(using: snapshot)
        #expect(didRetarget)
        let pending = try #require(coordinator.pending)

        #expect(pending.title == draft.title)
        #expect(pending.suggestedSessionName == draft.suggestedSessionName)
        #expect(pending.target == .devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            alias: destination
        ))
    }

    @Test("local tmux uses a separate working-directory argument")
    func buildsLocalCommand() throws {
        let command = try MerlinCommands.localTerminal(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "training-main",
            workingDirectory: "/mnt/training runs"
        )

        #expect(command == CommandSpec(
            executable: "/opt/homebrew/bin/tmux",
            arguments: [
                "new-session", "-A", "-s", "training-main",
                "-c", "/mnt/training runs",
            ]
        ))
    }
}
