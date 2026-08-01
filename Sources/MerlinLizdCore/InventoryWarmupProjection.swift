import Foundation

public extension TargetWarmupInventory {
    init(snapshot: InventorySnapshot) {
        var runningDevboxAliases: [String] = []
        var seenAliases: Set<String> = []
        var workerTargets: [TerminalTarget] = []
        var seenWorkerTargets: Set<TerminalTarget> = []

        for machine in snapshot.devboxes {
            if
                machine.devbox.status.isRunning,
                MerlinIdentifierValidator.isDevboxSID(machine.devbox.sid),
                let destination = machine.sshConnectionTarget,
                MerlinIdentifierValidator.isSSHConnectionTarget(destination),
                seenAliases.insert(destination).inserted
            {
                runningDevboxAliases.append(destination)
            }

            for worker in machine.workers {
                guard
                    let target = machine.workerTerminalTarget(for: worker),
                    seenWorkerTargets.insert(target).inserted
                else {
                    continue
                }
                workerTargets.append(target)
            }
        }

        self.init(
            runningDevboxAliases: runningDevboxAliases,
            workerTargets: workerTargets
        )
    }
}

public extension InventorySnapshot {
    /// Applies readiness only when the completed warmup still describes the
    /// route currently selected by inventory. A route change makes the update
    /// stale, including a relay being replaced by a direct Worker destination.
    func applyingWarmupUpdate(
        _ update: TargetWarmupUpdate
    ) -> InventorySnapshot? {
        guard
            update.snapshot.target == update.target,
            case let .worker(devboxSID, _, _, workerID) = update.target,
            let machine = devboxes.first(where: {
                $0.devbox.sid == devboxSID
            }),
            let worker = machine.workers.first(where: {
                $0.id == workerID
            }),
            machine.workerTerminalTarget(for: worker) == update.target
        else {
            return nil
        }

        let readiness = WorkerReadiness(warmupSnapshot: update.snapshot)
        let updatedDevboxes = devboxes.map { candidate in
            guard candidate.devbox.sid == devboxSID else { return candidate }
            return DevboxInventory(
                devbox: candidate.devbox,
                sshAlias: candidate.sshAlias,
                workers: candidate.workers.map { candidateWorker in
                    candidateWorker.id == workerID
                        ? candidateWorker.withReadiness(readiness)
                        : candidateWorker
                },
                workerStatus: candidate.workerStatus
            )
        }
        return InventorySnapshot(
            devboxes: updatedDevboxes,
            refreshedAt: refreshedAt
        )
    }
}

private extension WorkerReadiness {
    init(warmupSnapshot snapshot: TmuxSessionSnapshot) {
        if let error = snapshot.lastError {
            self = error == .workerNotReady ? .notReady : .unreachable
            return
        }
        self = switch snapshot.readiness {
        case .ready:
            .ready
        case .workerNotReady:
            .notReady
        case .unknown:
            .unreachable
        }
    }
}
