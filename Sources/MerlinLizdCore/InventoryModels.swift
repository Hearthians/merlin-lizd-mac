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

    /// Keeps direct connectivity evidence when newer platform inventory
    /// refreshes the same Worker records.
    public static func preservingReadiness(
        of incoming: [WorkerInventoryRecord],
        from previous: [WorkerInventoryRecord]
    ) -> [WorkerInventoryRecord] {
        var readinessByWorkerID: [String: WorkerReadiness] = [:]
        for worker in previous {
            readinessByWorkerID[worker.id] = worker.readiness
        }
        return incoming.map { worker in
            guard let readiness = readinessByWorkerID[worker.id] else {
                return worker
            }
            return worker.withReadiness(readiness)
        }
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
            MerlinIdentifierValidator.isSSHAlias(fallback)
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
