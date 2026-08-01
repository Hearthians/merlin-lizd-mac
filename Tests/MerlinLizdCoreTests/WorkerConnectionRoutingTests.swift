import Testing
@testable import MerlinLizdCore

@Suite("Worker connection routing")
struct WorkerConnectionRoutingTests {
    @Test("direct Workers remain warmup targets when the parent Devbox is stopped")
    func projectsDirectWorkerIndependently() throws {
        let machine = makeMachine(
            status: .stopped,
            workerDestination: directWorkerDestination
        )
        let snapshot = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )

        let inventory = TargetWarmupInventory(snapshot: snapshot)

        #expect(inventory.runningDevboxAliases.isEmpty)
        #expect(inventory.workerTargets == [try #require(
            machine.workerTerminalTarget(for: machine.workers[0])
        )])
    }

    @Test("relay Workers require a running parent Devbox")
    func gatesRelayWorkerOnParentLifecycle() {
        let running = makeMachine(status: .running)
        let stopped = makeMachine(status: .stopped)

        #expect(running.workerTerminalTarget(for: running.workers[0]) == .worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: devboxAlias,
            workerID: workerID
        ))
        #expect(stopped.workerTerminalTarget(for: stopped.workers[0]) == nil)
    }

    @Test("accepts direct readiness updates independently of the parent lifecycle")
    func appliesDirectWarmupUpdate() throws {
        let machine = makeMachine(
            status: .stopped,
            workerDestination: directWorkerDestination
        )
        let current = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )
        let target = try #require(
            machine.workerTerminalTarget(for: machine.workers[0])
        )
        let update = TargetWarmupUpdate(
            target: target,
            snapshot: warmupSnapshot(target: target, readiness: .ready)
        )

        let updated = try #require(current.applyingWarmupUpdate(update))

        #expect(updated.devboxes[0].workers[0].readiness == .ready)
        #expect(updated.refreshedAt == current.refreshedAt)
    }

    @Test("rejects a stale relay update after a Worker gains a direct route")
    func rejectsStaleWarmupRoute() {
        let machine = makeMachine(
            status: .running,
            workerDestination: directWorkerDestination
        )
        let current = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )
        let staleTarget = TerminalTarget.worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: devboxAlias,
            workerID: workerID
        )
        let update = TargetWarmupUpdate(
            target: staleTarget,
            snapshot: warmupSnapshot(target: staleTarget, readiness: .ready)
        )

        #expect(current.applyingWarmupUpdate(update) == nil)
    }

    @Test("stopping a relay-only parent invalidates Worker readiness")
    func resetsReadinessWhenRelayStops() {
        let previous = makeMachine(
            status: .running,
            readiness: .ready
        )
        let incoming = makeMachine(status: .stopped)

        let reconciled = incoming.workersPreservingReadiness(from: previous)

        #expect(reconciled.map(\.readiness) == [.listed])
    }

    @Test("switching a Worker from relay to direct invalidates old readiness")
    func resetsReadinessWhenRouteChanges() {
        let previous = makeMachine(
            status: .running,
            readiness: .ready
        )
        let incoming = makeMachine(
            status: .running,
            workerDestination: directWorkerDestination
        )

        let reconciled = incoming.workersPreservingReadiness(from: previous)

        #expect(reconciled.map(\.readiness) == [.listed])
    }

    @Test("refreshing an unchanged direct route preserves Worker readiness")
    func preservesReadinessForSameDirectRoute() {
        let previous = makeMachine(
            status: .running,
            workerDestination: directWorkerDestination,
            readiness: .ready
        )
        let incoming = makeMachine(
            status: .stopped,
            workerDestination: directWorkerDestination
        )

        let reconciled = incoming.workersPreservingReadiness(from: previous)

        #expect(reconciled.map(\.readiness) == [.ready])
    }

    @Test("restarting a relay parent requires a fresh Worker probe")
    func resetsReadinessWhenRelayRestarts() {
        let previous = makeMachine(
            status: .stopped,
            readiness: .unreachable
        )
        let incoming = makeMachine(status: .running)

        let reconciled = incoming.workersPreservingReadiness(from: previous)

        #expect(reconciled.map(\.readiness) == [.listed])
    }

    @Test("switching a Worker from direct to relay requires a fresh probe")
    func resetsReadinessWhenDirectFallsBackToRelay() {
        let previous = makeMachine(
            status: .running,
            workerDestination: directWorkerDestination,
            readiness: .ready
        )
        let incoming = makeMachine(status: .running)

        let reconciled = incoming.workersPreservingReadiness(from: previous)

        #expect(reconciled.map(\.readiness) == [.listed])
    }

    @Test("rotating a direct Worker endpoint requires a fresh probe")
    func resetsReadinessWhenDirectEndpointRotates() {
        let previous = makeMachine(
            status: .running,
            workerDestination: directWorkerDestination,
            readiness: .ready
        )
        let incoming = makeMachine(
            status: .running,
            workerDestination: rotatedWorkerDestination
        )

        let reconciled = incoming.workersPreservingReadiness(from: previous)

        #expect(reconciled.map(\.readiness) == [.listed])
    }

    @Test("Devbox endpoint rotation keeps cached Worker rows and resets relay readiness")
    func projectsCachedWorkersAcrossDevboxEndpointRotation() throws {
        let previous = makeMachine(
            status: .running,
            devboxDestination: originalDevboxDestination,
            readiness: .ready
        )
        let incoming = withoutWorkers(makeMachine(
            status: .running,
            devboxDestination: rotatedDevboxDestination
        ))

        let projected = incoming.carryingWorkerInventory(from: previous)
        let worker = try #require(projected.workers.first)

        #expect(projected.workers.count == 1)
        #expect(worker.readiness == .listed)
        #expect(projected.workerTerminalTarget(for: worker) == .worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: rotatedDevboxDestination,
            workerID: workerID
        ))
    }

    @Test("Devbox endpoint rotation preserves an unchanged direct Worker route")
    func preservesDirectWorkerAcrossDevboxEndpointRotation() throws {
        let previous = makeMachine(
            status: .running,
            devboxDestination: originalDevboxDestination,
            workerDestination: directWorkerDestination,
            readiness: .ready
        )
        let incoming = withoutWorkers(makeMachine(
            status: .running,
            devboxDestination: rotatedDevboxDestination
        ))

        let projected = incoming.carryingWorkerInventory(from: previous)
        let worker = try #require(projected.workers.first)

        #expect(projected.workers.count == 1)
        #expect(worker.readiness == .ready)
        #expect(projected.workerTerminalTarget(for: worker)?.workerAlias ==
            directWorkerDestination)
    }

    @Test("restored Worker tabs migrate to the current direct route")
    func retargetsRestoredWorkerTab() throws {
        let machine = makeMachine(
            status: .stopped,
            workerDestination: directWorkerDestination
        )
        let snapshot = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )
        let original = TerminalState(
            selectedTabID: "worker-tab",
            tabs: [TerminalTabRecord(
                id: "worker-tab",
                title: "L20 training",
                target: .worker(
                    devboxSID: devboxSID,
                    devboxName: devboxName,
                    alias: devboxAlias,
                    workerID: workerID
                ),
                sessionName: "training-main",
                workingDirectory: "/mnt/training"
            )]
        )

        let migrated = original.retargetingConnections(using: snapshot)
        let tab = try #require(migrated.tabs.first)

        #expect(migrated.selectedTabID == original.selectedTabID)
        #expect(tab.id == "worker-tab")
        #expect(tab.title == "L20 training")
        #expect(tab.sessionName == "training-main")
        #expect(tab.workingDirectory == "/mnt/training")
        #expect(tab.target == .worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: directWorkerDestination,
            workerID: workerID
        ))
        #expect(migrated.retargetingConnections(using: snapshot) == migrated)
    }

    @Test("restored Devbox tabs migrate to the current platform route and name")
    func retargetsRestoredDevboxTab() throws {
        let destination = "135679.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
        let machine = makeMachine(
            status: .running,
            devboxDestination: destination
        )
        let snapshot = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )
        let original = TerminalState(
            selectedTabID: "devbox-tab",
            tabs: [TerminalTabRecord(
                id: "devbox-tab",
                title: "Development",
                target: .devbox(
                    sid: devboxSID,
                    name: "old-name",
                    alias: devboxAlias
                ),
                sessionName: "development"
            )]
        )

        let migrated = original.retargetingConnections(using: snapshot)
        let tab = try #require(migrated.tabs.first)

        #expect(tab.target == .devbox(
            sid: devboxSID,
            name: devboxName,
            alias: destination
        ))
        #expect(tab.title == "Development")
        #expect(tab.sessionName == "development")
    }

    @Test("restored relay Worker tabs migrate to the current Devbox route")
    func retargetsRestoredRelayWorkerTab() throws {
        let destination = "135679.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
        let machine = makeMachine(
            status: .running,
            devboxDestination: destination
        )
        let snapshot = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )
        let original = TerminalState(
            selectedTabID: "worker-tab",
            tabs: [TerminalTabRecord(
                id: "worker-tab",
                title: "Worker",
                target: .worker(
                    devboxSID: devboxSID,
                    devboxName: "old-name",
                    alias: devboxAlias,
                    workerID: workerID
                ),
                sessionName: "training-main"
            )]
        )

        let migrated = original.retargetingConnections(using: snapshot)
        let tab = try #require(migrated.tabs.first)

        #expect(tab.target == .worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: destination,
            workerID: workerID
        ))
    }

    @Test("restored direct Worker tabs migrate back to a valid relay route")
    func retargetsDirectWorkerTabToRelay() throws {
        let machine = makeMachine(status: .running)
        let snapshot = InventorySnapshot(
            devboxes: [machine],
            refreshedAt: .distantPast
        )
        let originalTarget = TerminalTarget.worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: directWorkerDestination,
            workerID: workerID
        )

        let migrated = try #require(originalTarget.retargeted(using: snapshot))

        #expect(migrated == .worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: devboxAlias,
            workerID: workerID
        ))
    }

    @Test("route changes preserve stable platform identity")
    func matchesTargetsAcrossRouteChanges() {
        let relay = TerminalTarget.worker(
            devboxSID: devboxSID,
            devboxName: devboxName,
            alias: devboxAlias,
            workerID: workerID
        )
        let direct = TerminalTarget.worker(
            devboxSID: devboxSID,
            devboxName: "renamed",
            alias: directWorkerDestination,
            workerID: workerID
        )
        let oldDevbox = TerminalTarget.devbox(
            sid: devboxSID,
            name: devboxName,
            alias: devboxAlias
        )
        let newDevbox = TerminalTarget.devbox(
            sid: devboxSID,
            name: "renamed",
            alias: rotatedDevboxDestination
        )

        #expect(relay.identity == direct.identity)
        #expect(oldDevbox.identity == newDevbox.identity)
        #expect(relay.identity != oldDevbox.identity)
        #expect(relay.identity != .worker(
            devboxSID: devboxSID,
            workerID: "4103855"
        ))
    }

    @Test("restored tabs never migrate from untrusted or unrelated inventory")
    func rejectsUnsafeTabMigration() {
        let unsafe = makeMachine(
            status: .running,
            workerDestination: "4099222.lizhuodong.worker@attacker.example"
        )
        let snapshot = InventorySnapshot(
            devboxes: [unsafe],
            refreshedAt: .distantPast
        )
        let original = TerminalState(
            selectedTabID: "worker-tab",
            tabs: [
                TerminalTabRecord(
                    id: "worker-tab",
                    title: "Worker",
                    target: .worker(
                        devboxSID: devboxSID,
                        devboxName: devboxName,
                        alias: devboxAlias,
                        workerID: workerID
                    ),
                    sessionName: "training-main"
                ),
                TerminalTabRecord(
                    id: "other-tab",
                    title: "Other",
                    target: .worker(
                        devboxSID: "dbx_other",
                        devboxName: "other",
                        alias: "other_alias",
                        workerID: workerID
                    ),
                    sessionName: "other-session"
                ),
            ]
        )

        #expect(original.retargetingConnections(using: snapshot) == original)
    }

    @Test("loads platform Workers even when the parent Devbox is stopped")
    func loadsStoppedDevboxWorkersFromControlPlane() async throws {
        let runner = StoppedDevboxWorkerRunner(
            workerID: workerID,
            destination: directWorkerDestination
        )
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )
        let machine = makeMachine(status: .stopped)

        let loaded = await inventory.loadWorkers(
            for: machine.devbox,
            sshAlias: devboxAlias
        )

        #expect(loaded.workerStatus == .loaded)
        #expect(loaded.workers.first?.id == workerID)
        #expect(loaded.workers.first?.sshProxyDestination ==
            directWorkerDestination)
        let commands = await runner.recordedCommands()
        #expect(commands.count == 1)
        #expect(commands.first?.executable ==
            "/Users/test/.merlin-cli/bin/merlin-cli")
    }

    private var devboxSID: String { "dbx_135679" }
    private var devboxName: String { "wt_hl" }
    private var devboxAlias: String { "hl_gpu_2" }
    private var workerID: String { "4099222" }
    private var directWorkerDestination: String {
        "4099222.lizhuodong.worker@merlin-ssh-proxy-cn.byted.org"
    }
    private var rotatedWorkerDestination: String {
        "4099222.rotated.worker@merlin-ssh-proxy-cn.byted.org"
    }
    private var originalDevboxDestination: String {
        "135679.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
    }
    private var rotatedDevboxDestination: String {
        "135679.rotated.ws@merlin-ssh-proxy-cn.byted.org"
    }

    private func makeMachine(
        status: DevboxLifecycle,
        devboxDestination: String? = nil,
        workerDestination: String? = nil,
        readiness: WorkerReadiness = .listed
    ) -> DevboxInventory {
        let devbox = Devbox(
            sid: devboxSID,
            name: devboxName,
            status: status,
            cpuCores: nil,
            memoryBytes: nil,
            diskBytes: nil,
            workerCount: 1,
            rootfsType: nil,
            region: nil,
            accessRole: nil,
            sshProxyDestination: devboxDestination,
            createdAt: nil,
            updatedAt: nil
        )
        let worker = Worker(
            id: workerID,
            cpuCores: 16,
            memoryGiB: 64,
            gpuCount: 1,
            gpuType: "L20",
            platformStatus: "running",
            sshProxyDestination: workerDestination,
            podIP: nil,
            port: 0,
            createdAt: "now",
            webshellURL: nil,
            readiness: readiness
        )
        return DevboxInventory(
            devbox: devbox,
            sshAlias: devboxAlias,
            workers: [WorkerInventoryRecord(worker: worker)],
            workerStatus: .loaded
        )
    }

    private func warmupSnapshot(
        target: TerminalTarget,
        readiness: TmuxReadinessEvidence
    ) -> TmuxSessionSnapshot {
        TmuxSessionSnapshot(
            target: target,
            sessions: [],
            readiness: readiness,
            fetchedAt: .distantPast,
            verification: .idle,
            lastError: nil
        )
    }

    private func withoutWorkers(
        _ machine: DevboxInventory
    ) -> DevboxInventory {
        DevboxInventory(
            devbox: machine.devbox,
            sshAlias: machine.sshAlias
        )
    }
}

private extension TerminalTarget {
    var workerAlias: String? {
        guard case let .worker(_, _, alias, _) = self else { return nil }
        return alias
    }
}

private actor StoppedDevboxWorkerRunner: InventoryProcessRunning {
    private let workerID: String
    private let destination: String
    private var commands: [CommandSpec] = []

    init(workerID: String, destination: String) {
        self.workerID = workerID
        self.destination = destination
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        commands.append(command)
        return InventoryProcessOutput(
            stdout: """
            {
              "ResponseBase": {"code": 0, "message": "success"},
              "data": [{
                "sid": "wkr_\(workerID)",
                "status": "running",
                "cpu_cores": 16,
                "memory_bytes": 68719476736,
                "gpu_count": 1,
                "ssh_proxy_cmd": "\(destination)",
                "created_at": "now"
              }],
              "pagination": {"page_size": 100}
            }
            """,
            stderr: "",
            exitCode: 0
        )
    }

    func recordedCommands() -> [CommandSpec] {
        commands
    }
}
