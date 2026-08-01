import Foundation

public struct InventorySnapshot: Codable, Equatable, Sendable {
    public let devboxes: [DevboxInventory]
    public let refreshedAt: Date

    public init(devboxes: [DevboxInventory], refreshedAt: Date) {
        self.devboxes = devboxes
        self.refreshedAt = refreshedAt
    }
}

public struct DevboxInventory: Identifiable, Codable, Equatable, Sendable {
    public var id: String { devbox.sid }

    public let devbox: Devbox
    public let sshAlias: String?
    public let workers: [WorkerInventoryRecord]
    public let workerStatus: WorkerInventoryStatus

    public var displayName: String { devbox.name }

    /// Platform connectivity is authoritative. The local alias is retained
    /// only as a compatibility fallback for older Devboxes.
    public var sshConnectionTarget: String? {
        if
            let destination = devbox.sshProxyDestination,
            MerlinIdentifierValidator.isDevboxSSHProxyDestination(
                destination,
                devboxSID: devbox.sid
            )
        {
            return destination
        }
        guard
            let sshAlias,
            MerlinIdentifierValidator.isSSHAlias(sshAlias)
        else {
            return nil
        }
        return sshAlias
    }

    public func sshConnectionTarget(
        for worker: WorkerInventoryRecord
    ) -> String? {
        if let direct = worker.sshConnectionTarget(fallback: nil) {
            return direct
        }
        guard devbox.status.isRunning else { return nil }
        return worker.sshConnectionTarget(fallback: sshConnectionTarget)
    }

    public func workerTerminalTarget(
        for worker: WorkerInventoryRecord
    ) -> TerminalTarget? {
        guard
            MerlinIdentifierValidator.isDevboxSID(devbox.sid),
            MerlinIdentifierValidator.isWorkerID(worker.id),
            let destination = sshConnectionTarget(for: worker)
        else {
            return nil
        }
        return .worker(
            devboxSID: devbox.sid,
            devboxName: devbox.name,
            alias: destination,
            workerID: worker.id
        )
    }

    /// Carries readiness evidence forward only while the same Worker keeps the
    /// exact same usable route. A relay disappearing with its parent, or a
    /// relay/direct endpoint change, must be probed again.
    public func workersPreservingReadiness(
        from previous: DevboxInventory
    ) -> [WorkerInventoryRecord] {
        var previousByID: [String: WorkerInventoryRecord] = [:]
        for worker in previous.workers {
            previousByID[worker.id] = worker
        }
        return workers.map { worker in
            guard let previousWorker = previousByID[worker.id] else {
                return worker
            }
            guard
                let route = workerTerminalTarget(for: worker),
                let previousRoute = previous.workerTerminalTarget(
                    for: previousWorker
                ),
                route == previousRoute
            else {
                return worker.withReadiness(.listed)
            }
            return worker.withReadiness(previousWorker.readiness)
        }
    }

    /// Projects last-known Worker rows onto newer Devbox metadata. This keeps
    /// the machine tree stable while the control-plane Worker refresh runs,
    /// while route-specific readiness is reconciled against the new route.
    public func carryingWorkerInventory(
        from previous: DevboxInventory
    ) -> DevboxInventory {
        let candidate = DevboxInventory(
            devbox: devbox,
            sshAlias: sshAlias,
            workers: previous.workers,
            workerStatus: previous.workerStatus
        )
        return DevboxInventory(
            devbox: candidate.devbox,
            sshAlias: candidate.sshAlias,
            workers: candidate.workersPreservingReadiness(from: previous),
            workerStatus: candidate.workerStatus
        )
    }

    public init(
        devbox: Devbox,
        sshAlias: String? = nil,
        workers: [WorkerInventoryRecord] = [],
        workerStatus: WorkerInventoryStatus = .notQueried
    ) {
        self.devbox = devbox
        self.sshAlias = sshAlias
        self.workers = workers
        self.workerStatus = workerStatus
    }
}

/// A persistence-safe projection of `Worker`. Only the validated SSH proxy
/// destination crosses the inventory interface; raw addresses and signed URLs
/// remain excluded.
public struct WorkerInventoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let cpuCores: Int
    public let memoryGiB: Int
    public let gpuCount: Int
    public let gpuType: String?
    public let platformStatus: String?
    public let sshProxyDestination: String?
    public let createdAt: String
    public let readiness: WorkerReadiness

    public init(worker: Worker) {
        self.id = worker.id
        self.cpuCores = worker.cpuCores
        self.memoryGiB = worker.memoryGiB
        self.gpuCount = worker.gpuCount
        self.gpuType = worker.gpuType
        self.platformStatus = worker.platformStatus
        self.sshProxyDestination = worker.sshProxyDestination
        self.createdAt = worker.createdAt
        self.readiness = worker.readiness
    }

    public func withReadiness(_ readiness: WorkerReadiness) -> WorkerInventoryRecord {
        WorkerInventoryRecord(
            id: id,
            cpuCores: cpuCores,
            memoryGiB: memoryGiB,
            gpuCount: gpuCount,
            gpuType: gpuType,
            platformStatus: platformStatus,
            sshProxyDestination: sshProxyDestination,
            createdAt: createdAt,
            readiness: readiness
        )
    }

    /// The platform Worker API currently omits the GPU model. Callers can carry
    /// forward a previously observed safe display label without reintroducing
    /// network metadata from `mlx worker list`.
    public func withGPUType(_ gpuType: String?) -> WorkerInventoryRecord {
        WorkerInventoryRecord(
            id: id,
            cpuCores: cpuCores,
            memoryGiB: memoryGiB,
            gpuCount: gpuCount,
            gpuType: gpuType,
            platformStatus: platformStatus,
            sshProxyDestination: sshProxyDestination,
            createdAt: createdAt,
            readiness: readiness
        )
    }

    public func sshConnectionTarget(fallback: String?) -> String? {
        if
            let sshProxyDestination,
            MerlinIdentifierValidator.isWorkerSSHProxyDestination(
                sshProxyDestination,
                workerID: id
            )
        {
            return sshProxyDestination
        }
        guard
            let fallback,
            MerlinIdentifierValidator.isSSHConnectionTarget(fallback)
        else {
            return nil
        }
        return fallback
    }

    private init(
        id: String,
        cpuCores: Int,
        memoryGiB: Int,
        gpuCount: Int,
        gpuType: String?,
        platformStatus: String?,
        sshProxyDestination: String?,
        createdAt: String,
        readiness: WorkerReadiness
    ) {
        self.id = id
        self.cpuCores = cpuCores
        self.memoryGiB = memoryGiB
        self.gpuCount = gpuCount
        self.gpuType = gpuType
        self.platformStatus = platformStatus
        self.sshProxyDestination = sshProxyDestination
        self.createdAt = createdAt
        self.readiness = readiness
    }
}

public enum WorkerInventoryStatus: Codable, Equatable, Sendable {
    case notQueried
    case loaded
    case failed(InventoryFailure)
}

public enum InventoryFailure: Codable, Equatable, Sendable {
    case transport
    case commandFailed(exitCode: Int32)
    case malformedOutput
}
