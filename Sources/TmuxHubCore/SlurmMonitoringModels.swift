import Foundation

public struct SlurmNodeSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let partitions: [String]
    public let state: String
    public let totalGPU: Int?
    public let allocatedGPU: Int?
    public let totalCPU: Int?
    public let allocatedCPU: Int?
    public let totalMemoryMiB: Int64?
    public let allocatedMemoryMiB: Int64?
    public let isSchedulable: Bool

    public var totalNPU: Int? = nil
    public var allocatedNPU: Int? = nil

    public var unallocatedNPU: Int? {
        guard let totalNPU, let allocatedNPU else { return nil }
        return max(0, totalNPU - allocatedNPU)
    }

    public var unallocatedGPU: Int? {
        guard let totalGPU, let allocatedGPU else { return nil }
        return max(0, totalGPU - allocatedGPU)
    }
}

/// A partition is a view over nodes. Nodes may belong to several partitions;
/// partition totals must never be added together as cluster-wide capacity.
public struct SlurmQueueSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: String { partition }
    public let partition: String
    public let state: String
    public let totalGPU: Int?
    public let allocatedGPU: Int?
    public let unallocatedGPU: Int?
    public let totalCPU: Int?
    public let allocatedCPU: Int?
    public let totalMemoryMiB: Int64?
    public let allocatedMemoryMiB: Int64?
    public let nodeCount: Int
    public let unavailableNodeCount: Int
    public let schedulableFourGPUNodeCount: Int?
    public let schedulableEightGPUNodeCount: Int?
    public let runningJobCount: Int?
    public let pendingJobCount: Int?
    public let nodes: [SlurmNodeSnapshot]
    public let sampledAt: Date
    public var totalNPU: Int? = nil
    public var allocatedNPU: Int? = nil
    public var unallocatedNPU: Int? = nil
}

public struct SlurmJobAllocation: Codable, Hashable, Sendable {
    public let jobID: SlurmJobID
    public let owner: String
    public let state: SlurmJobState
    public let nodeList: String?
    public let allocatedGPU: Int?
    public let allocatedCPU: Int?
    public let allocatedMemoryMiB: Int64?
    public let elapsedSeconds: TimeInterval?
    /// Original TRES allocation, retained to distinguish full GPUs from MIG slices.
    public var allocatedResources: String? = nil
    public var allocatedNPU: Int? = nil
}

public struct SlurmGPUUtilization: Codable, Hashable, Identifiable, Sendable {
    public var id: String { nodeName.map { "\($0):\(uuid)" } ?? uuid }
    public let index: Int
    public let uuid: String
    public let name: String
    public let utilizationPercent: Double?
    public let memoryUsedMiB: Double?
    public let memoryTotalMiB: Double?
    public let nodeName: String?
    public let powerDrawWatts: Double?
    public let powerLimitWatts: Double?

    public init(
        index: Int, uuid: String, name: String, utilizationPercent: Double?,
        memoryUsedMiB: Double?, memoryTotalMiB: Double?, nodeName: String? = nil,
        powerDrawWatts: Double? = nil, powerLimitWatts: Double? = nil
    ) {
        self.index = index
        self.uuid = uuid
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
        self.nodeName = nodeName
        self.powerDrawWatts = powerDrawWatts
        self.powerLimitWatts = powerLimitWatts
    }
}

public struct SlurmJobStatistics: Codable, Hashable, Sendable {
    /// CPU time divided by elapsed time and allocated CPUs, as a percentage.
    /// This is an average since the job began, not an instantaneous sample.
    public let averageCPUPercent: Double?
    /// Largest sampled resident set of any task; Slurm does not provide a
    /// reliable instantaneous whole-job RSS in the sstat fields used here.
    public let peakTaskMemoryMiB: Double?
    public let cpuTimeSeconds: TimeInterval?
    public let source: String
}

public struct SlurmJobUtilizationSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: SlurmJobID { jobID }
    public let jobID: SlurmJobID
    public let allocation: SlurmJobAllocation?
    public let statistics: SlurmJobStatistics?
    /// nil means unavailable. An empty array means an observed CPU-only job.
    public let gpus: [SlurmGPUUtilization]?
    public let sampledAt: Date
    public let unavailableReason: String?

    public init(
        jobID: SlurmJobID,
        allocation: SlurmJobAllocation?,
        statistics: SlurmJobStatistics?,
        gpus: [SlurmGPUUtilization]?,
        sampledAt: Date,
        unavailableReason: String? = nil
    ) {
        self.jobID = jobID
        self.allocation = allocation
        self.statistics = statistics
        self.gpus = gpus
        self.sampledAt = sampledAt
        self.unavailableReason = unavailableReason
    }
}
