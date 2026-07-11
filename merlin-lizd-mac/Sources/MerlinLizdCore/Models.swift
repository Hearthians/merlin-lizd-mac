import Foundation

public struct Devbox: Identifiable, Codable, Hashable, Sendable {
    public var id: String { sid }

    public let sid: String
    public let name: String
    public let status: String
    public let cpuCores: Int?
    public let memoryBytes: Int64?
    public let diskBytes: Int64?
    public let workerCount: Int?
    public let rootfsType: String?
    public let region: String?
    public let accessRole: String?
    public let createdAt: String?
    public let updatedAt: String?

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
        self.podIP = podIP
        self.port = port
        self.createdAt = createdAt
        self.webshellURL = webshellURL
        self.readiness = readiness
    }
}
