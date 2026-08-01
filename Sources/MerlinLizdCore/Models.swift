import Foundation

public struct DevboxLifecycle: RawRepresentable, Codable, Hashable, Sendable {
    public static let running = DevboxLifecycle(rawValue: "running")
    public static let stopped = DevboxLifecycle(rawValue: "stopped")
    public static let starting = DevboxLifecycle(rawValue: "starting")
    public static let stopping = DevboxLifecycle(rawValue: "stopping")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public var isRunning: Bool { self == .running }
    public var isStopped: Bool { self == .stopped }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Devbox: Identifiable, Codable, Hashable, Sendable {
    public var id: String { sid }

    public let sid: String
    public let name: String
    public let status: DevboxLifecycle
    public let cpuCores: Int?
    public let memoryBytes: Int64?
    public let diskBytes: Int64?
    public let workerCount: Int?
    public let rootfsType: String?
    public let region: String?
    public let accessRole: String?
    public let sshProxyDestination: String?
    public let createdAt: String?
    public let updatedAt: String?

    init(
        sid: String,
        name: String,
        status: DevboxLifecycle,
        cpuCores: Int?,
        memoryBytes: Int64?,
        diskBytes: Int64?,
        workerCount: Int?,
        rootfsType: String?,
        region: String?,
        accessRole: String?,
        sshProxyDestination: String?,
        createdAt: String?,
        updatedAt: String?
    ) {
        self.sid = sid
        self.name = name
        self.status = status
        self.cpuCores = cpuCores
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.workerCount = workerCount
        self.rootfsType = rootfsType
        self.region = region
        self.accessRole = accessRole
        self.sshProxyDestination = sshProxyDestination
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sid
        case name
        case status
        case cpuCores = "cpu_cores"
        case memoryBytes = "memory_bytes"
        case diskBytes = "disk_bytes"
        case workerCount = "worker_num"
        case rootfsType = "rootfs_type"
        case region
        case accessRole = "access_role"
        case sshProxyDestination = "ssh_proxy_cmd"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct DevboxPage: Hashable, Sendable {
    public let devboxes: [Devbox]
    public let nextPageToken: String?
}

public enum WorkerReadiness: String, Codable, Hashable, Sendable {
    case listed
    case probing
    case ready
    case notReady
    case unreachable
}

public struct Worker: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let cpuCores: Int
    public let memoryGiB: Int
    public let gpuCount: Int
    public let gpuType: String?
    /// Merlin's control-plane lifecycle value. This is deliberately separate
    /// from `readiness`: a platform `running` Worker can still be unavailable
    /// to an SSH/`mlx worker login` probe.
    public let platformStatus: String?
    public let sshProxyDestination: String?
    public let podIP: String?
    public let port: Int
    public let createdAt: String
    public let webshellURL: URL?
    public var readiness: WorkerReadiness

    public init(
        id: String,
        cpuCores: Int,
        memoryGiB: Int,
        gpuCount: Int,
        gpuType: String?,
        platformStatus: String? = nil,
        sshProxyDestination: String? = nil,
        podIP: String?,
        port: Int,
        createdAt: String,
        webshellURL: URL?,
        readiness: WorkerReadiness = .listed
    ) {
        self.id = id
        self.cpuCores = cpuCores
        self.memoryGiB = memoryGiB
        self.gpuCount = gpuCount
        self.gpuType = gpuType
        self.platformStatus = platformStatus
        self.sshProxyDestination = sshProxyDestination
        self.podIP = podIP
        self.port = port
        self.createdAt = createdAt
        self.webshellURL = webshellURL
        self.readiness = readiness
    }
}
