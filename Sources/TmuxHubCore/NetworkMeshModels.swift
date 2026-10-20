import Foundation

public enum NetworkMeshNetworkKind: String, Codable, CaseIterable, Sendable {
    case campus, zeroTier, lan, publicInternet, other

    public var displayName: String {
        switch self {
        case .campus: "校园网"
        case .zeroTier: "ZeroTier"
        case .lan: "局域网"
        case .publicInternet: "公网"
        case .other: "其他"
        }
    }
}

public enum NetworkMeshPlatform: String, Codable, CaseIterable, Sendable {
    case posix, windows
    public var displayName: String { self == .posix ? "Linux / macOS / WSL" : "Windows" }
}

public struct NetworkMeshEndpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var address: String
    public var username: String
    public var port: Int
    public var sshDestination: String
    public var networkKind: NetworkMeshNetworkKind
    public var bandwidthPort: Int
    public var environmentID: String
    public var environmentName: String
    public var platform: NetworkMeshPlatform

    public init(
        id: UUID = UUID(), label: String, address: String, username: String = "",
        port: Int = 22, sshDestination: String = "", networkKind: NetworkMeshNetworkKind = .other,
        bandwidthPort: Int = 5201, environmentID: String = "main",
        environmentName: String = "Linux", platform: NetworkMeshPlatform = .posix
    ) {
        self.id = id
        self.label = label
        self.address = address
        self.username = username
        self.port = port
        self.sshDestination = sshDestination
        self.networkKind = networkKind
        self.bandwidthPort = bandwidthPort
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, address, username, port, sshDestination, networkKind, bandwidthPort
        case environmentID, environmentName, platform
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        address = try values.decode(String.self, forKey: .address)
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        sshDestination = try values.decodeIfPresent(String.self, forKey: .sshDestination) ?? ""
        networkKind = try values.decodeIfPresent(NetworkMeshNetworkKind.self, forKey: .networkKind) ?? .other
        bandwidthPort = try values.decodeIfPresent(Int.self, forKey: .bandwidthPort) ?? 5201
        environmentID = try values.decodeIfPresent(String.self, forKey: .environmentID) ?? "main"
        environmentName = try values.decodeIfPresent(String.self, forKey: .environmentName) ?? "Linux"
        platform = try values.decodeIfPresent(NetworkMeshPlatform.self, forKey: .platform) ?? .posix
    }
}

public struct NetworkMeshHost: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isLocal: Bool
    public var controlDestination: String?
    public var endpoints: [NetworkMeshEndpoint]
    public var isMember: Bool

    public init(
        id: UUID = UUID(), name: String, isLocal: Bool = false,
        controlDestination: String? = nil, endpoints: [NetworkMeshEndpoint] = [], isMember: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.controlDestination = controlDestination
        self.endpoints = endpoints
        self.isMember = isMember
    }

    private enum CodingKeys: String, CodingKey { case id, name, isLocal, controlDestination, endpoints, isMember }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        isLocal = try values.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        controlDestination = try values.decodeIfPresent(String.self, forKey: .controlDestination)
        endpoints = try values.decodeIfPresent([NetworkMeshEndpoint].self, forKey: .endpoints) ?? []
        isMember = try values.decodeIfPresent(Bool.self, forKey: .isMember) ?? false
    }
}

public struct NetworkMeshRoute: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var sourceHostID: UUID
    public var sourceEndpointID: UUID
    public var targetHostID: UUID
    public var targetEndpointID: UUID

    public var id: String {
        "\(sourceHostID.uuidString)/\(sourceEndpointID.uuidString)>\(targetHostID.uuidString)/\(targetEndpointID.uuidString)"
    }

    public init(sourceHostID: UUID, sourceEndpointID: UUID, targetHostID: UUID, targetEndpointID: UUID) {
        self.sourceHostID = sourceHostID
        self.sourceEndpointID = sourceEndpointID
        self.targetHostID = targetHostID
        self.targetEndpointID = targetEndpointID
    }
}

public enum NetworkMeshProbeMode: String, Codable, CaseIterable, Sendable {
    case connectivity, speed, bandwidth

    public var displayName: String {
        switch self {
        case .connectivity: "连接检查"
        case .speed: "SSH 吞吐"
        case .bandwidth: "网络带宽"
        }
    }
}

public enum NetworkMeshProbeStatus: String, Codable, CaseIterable, Sendable {
    case reachable, unreachable, authenticationRequired, hostKeyFailure, unsupported, cancelled

    public var displayName: String {
        switch self {
        case .reachable: "可达"
        case .unreachable: "不可达"
        case .authenticationRequired: "需要 SSH 认证"
        case .hostKeyFailure: "需要核对主机指纹"
        case .unsupported: "缺少探测能力"
        case .cancelled: "已取消"
        }
    }
}

public struct NetworkMeshProbeResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var route: NetworkMeshRoute
    public var mode: NetworkMeshProbeMode
    public var status: NetworkMeshProbeStatus
    public var message: String
    public var latencyMilliseconds: Double?
    public var throughputMbps: Double?
    public var measuredAt: Date

    public init(
        id: UUID = UUID(), route: NetworkMeshRoute, mode: NetworkMeshProbeMode,
        status: NetworkMeshProbeStatus, message: String, latencyMilliseconds: Double? = nil,
        throughputMbps: Double? = nil, measuredAt: Date = Date()
    ) {
        self.id = id
        self.route = route
        self.mode = mode
        self.status = status
        self.message = message
        self.latencyMilliseconds = latencyMilliseconds
        self.throughputMbps = throughputMbps
        self.measuredAt = measuredAt
    }
}

/// Bounds text returned by remote tools before displaying or saving diagnostics.
func networkMeshDiagnostic(_ value: String) -> String? {
    let scalars = value.unicodeScalars.filter {
        $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
    }
    let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return nil }
    return String(clean.prefix(4096))
}
