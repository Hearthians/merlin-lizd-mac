import Foundation

/// A stable Slurm control-plane entry point. Compute-node names are deliberately
/// absent: they are transient scheduler output, not SSH destinations.
public struct SlurmPlatformProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let loginDestination: String
    public let owner: String

    public init(id: String, name: String, loginDestination: String, owner: String) {
        self.id = id
        self.name = name
        self.loginDestination = loginDestination
        self.owner = owner
    }
}

public struct SlurmGPURequest: Codable, Hashable, Sendable {
    public let type: String?
    public let count: Int

    public init(type: String? = nil, count: Int) {
        self.type = type
        self.count = count
    }
}

/// A wall-clock limit represented without locale-dependent parsing.
public struct SlurmWallTime: Codable, Hashable, Sendable {
    public let seconds: Int

    public init(seconds: Int) {
        self.seconds = seconds
    }

    public var schedulerValue: String {
        let days = seconds / 86_400
        let remainder = seconds % 86_400
        let hours = remainder / 3_600
        let minutes = (remainder % 3_600) / 60
        let seconds = remainder % 60
        if days > 0 {
            return String(format: "%d-%02d:%02d:%02d", days, hours, minutes, seconds)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

/// Reusable desired resources. `initializationScript` is an explicit user
/// script run inside the allocation before the interactive login shell.
public struct SlurmInteractivePreset: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let partition: String
    public let tasks: Int
    public let cpusPerTask: Int
    public let memoryMiB: Int
    public let wallTime: SlurmWallTime
    public let gpu: SlurmGPURequest?
    public let workingDirectory: String?
    public let initializationScript: String?

    public init(
        id: String,
        name: String,
        partition: String,
        tasks: Int = 1,
        cpusPerTask: Int,
        memoryMiB: Int,
        wallTime: SlurmWallTime,
        gpu: SlurmGPURequest? = nil,
        workingDirectory: String? = nil,
        initializationScript: String? = nil
    ) {
        self.id = id
        self.name = name
        self.partition = partition
        self.tasks = tasks
        self.cpusPerTask = cpusPerTask
        self.memoryMiB = memoryMiB
        self.wallTime = wallTime
        self.gpu = gpu
        self.workingDirectory = workingDirectory
        self.initializationScript = initializationScript
    }
}

public struct SlurmJobID: Codable, Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard SlurmValidation.isJobID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum SlurmJobState: Codable, Hashable, Sendable {
    case pending
    case running
    case completing
    case completed
    case cancelled
    case failed
    case timeout
    case nodeFailure
    case outOfMemory
    case preempted
    case suspended
    case unknown(String)

    public init(schedulerValue: String) {
        let value = schedulerValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch value {
        case "PENDING", "PD": self = .pending
        case "RUNNING", "R": self = .running
        case "COMPLETING", "CG": self = .completing
        case "COMPLETED", "CD": self = .completed
        case "CANCELLED", "CA": self = .cancelled
        case "FAILED", "F": self = .failed
        case "TIMEOUT", "TO": self = .timeout
        case "NODE_FAIL", "NF": self = .nodeFailure
        case "OUT_OF_MEMORY", "OOM": self = .outOfMemory
        case "PREEMPTED", "PR": self = .preempted
        case "SUSPENDED", "S": self = .suspended
        default: self = .unknown(value)
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed, .timeout, .nodeFailure, .outOfMemory, .preempted:
            true
        default:
            false
        }
    }
}

public struct SlurmJobSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: SlurmJobID { jobID }
    public let jobID: SlurmJobID
    public let name: String
    public let owner: String
    public let state: SlurmJobState
    public let reasonOrNodeList: String
    public let partition: String
    public let nodeCount: Int
    public let elapsed: String
    public let timeLimit: String
    public let startTime: String?
    public let submitTime: String?
    public let nodeList: String?
    public let comment: String

    public init(
        jobID: SlurmJobID,
        name: String,
        owner: String,
        state: SlurmJobState,
        reasonOrNodeList: String,
        partition: String,
        nodeCount: Int,
        elapsed: String,
        timeLimit: String,
        startTime: String?,
        submitTime: String?,
        nodeList: String?,
        comment: String
    ) {
        self.jobID = jobID
        self.name = name
        self.owner = owner
        self.state = state
        self.reasonOrNodeList = reasonOrNodeList
        self.partition = partition
        self.nodeCount = nodeCount
        self.elapsed = elapsed
        self.timeLimit = timeLimit
        self.startTime = startTime
        self.submitTime = submitTime
        self.nodeList = nodeList
        self.comment = comment
    }
}

/// Durable identity created before the remote mutation. It is sufficient to
/// reconcile an uncertain SSH outcome without submitting a duplicate job.
public struct SlurmLaunchReceipt: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { requestID }
    public let requestID: UUID
    public let platformID: String
    public let loginDestination: String
    public let owner: String
    public let jobName: String
    public let comment: String
    public let tmuxSessionName: String
    public let requestedAt: Date

    public init(
        requestID: UUID,
        platformID: String,
        loginDestination: String,
        owner: String,
        jobName: String,
        comment: String,
        tmuxSessionName: String,
        requestedAt: Date
    ) {
        self.requestID = requestID
        self.platformID = platformID
        self.loginDestination = loginDestination
        self.owner = owner
        self.jobName = jobName
        self.comment = comment
        self.tmuxSessionName = tmuxSessionName
        self.requestedAt = requestedAt
    }
}

public struct SlurmManagedJob: Codable, Hashable, Identifiable, Sendable {
    public var id: SlurmJobID { snapshot.jobID }
    public let receipt: SlurmLaunchReceipt
    public let snapshot: SlurmJobSnapshot

    public init(receipt: SlurmLaunchReceipt, snapshot: SlurmJobSnapshot) {
        self.receipt = receipt
        self.snapshot = snapshot
    }
}

public enum SlurmReconciliation: Equatable, Sendable {
    case waiting(SlurmLaunchReceipt)
    case found(SlurmManagedJob)
}

enum SlurmValidation {
    static func isSafeIdentifier(_ value: String, maximumBytes: Int = 128) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._:@+-".unicodeScalars.contains($0)
        }
    }

    static func isJobID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64,
            value.first?.isNumber == true
        else { return false }
        return value.allSatisfy { $0.isNumber || "_+.".contains($0) }
    }

    static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 16_384
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func isScript(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 * 1_024
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
