import Foundation

public enum SSHHostRecencyBucket: Int, CaseIterable, Identifiable, Sendable {
    case withinThreeDays
    case threeToSevenDays
    case olderThanSevenDays
    case neverUsed

    public var id: Int { rawValue }
}

public struct SSHHostRecencySection: Identifiable, Sendable {
    public var id: SSHHostRecencyBucket { bucket }
    public let bucket: SSHHostRecencyBucket
    public let hosts: [SSHHost]

    public init(bucket: SSHHostRecencyBucket, hosts: [SSHHost]) {
        self.bucket = bucket
        self.hosts = hosts
    }
}

public enum SSHHostRecencyOrganizer {
    private static let day: TimeInterval = 24 * 60 * 60

    public static func sections(
        hosts: [SSHHost],
        lastUsedAt: [String: Date],
        now: Date = Date()
    ) -> [SSHHostRecencySection] {
        let sorted = hosts.sorted { lhs, rhs in
            switch (lastUsedAt[lhs.destination], lastUsedAt[rhs.destination]) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.destination.localizedStandardCompare(rhs.destination)
                    == .orderedAscending
            }
        }

        var grouped: [SSHHostRecencyBucket: [SSHHost]] = [:]
        for host in sorted {
            let bucket = bucket(
                lastUsedAt: lastUsedAt[host.destination],
                now: now
            )
            grouped[bucket, default: []].append(host)
        }
        return SSHHostRecencyBucket.allCases.compactMap { bucket in
            guard let values = grouped[bucket], !values.isEmpty else {
                return nil
            }
            return SSHHostRecencySection(bucket: bucket, hosts: values)
        }
    }

    private static func bucket(
        lastUsedAt: Date?,
        now: Date
    ) -> SSHHostRecencyBucket {
        guard let lastUsedAt else { return .neverUsed }
        let age = max(0, now.timeIntervalSince(lastUsedAt))
        if age < 3 * day { return .withinThreeDays }
        if age < 7 * day { return .threeToSevenDays }
        return .olderThanSevenDays
    }
}
