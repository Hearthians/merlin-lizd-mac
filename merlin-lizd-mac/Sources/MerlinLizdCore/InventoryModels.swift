import Foundation

public struct InventorySnapshot: Equatable, Sendable {
    public let devboxes: [DevboxInventory]
    public let refreshedAt: Date

    public init(devboxes: [DevboxInventory], refreshedAt: Date) {
        self.devboxes = devboxes
        self.refreshedAt = refreshedAt
    }
}

public struct DevboxInventory: Identifiable, Equatable, Sendable {
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

/// A persistence-safe projection of `Worker`. Network addresses and signed URLs
/// deliberately never cross the inventory interface.
public struct WorkerInventoryRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let cpuCores: Int
    public let memoryGiB: Int
    public let gpuCount: Int
    public let gpuType: String?
    public let createdAt: String
    public let readiness: WorkerReadiness

    public init(worker: Worker) {
        self.id = worker.id
        self.cpuCores = worker.cpuCores
        self.memoryGiB = worker.memoryGiB
        self.gpuCount = worker.gpuCount
        self.gpuType = worker.gpuType
        self.createdAt = worker.createdAt
        self.readiness = worker.readiness
    }
}

public enum WorkerInventoryStatus: Equatable, Sendable {
    case notQueried
    case loaded
    case failed(InventoryFailure)
}

public enum InventoryFailure: Equatable, Sendable {
    case transport
    case commandFailed(exitCode: Int32)
    case malformedOutput
}
