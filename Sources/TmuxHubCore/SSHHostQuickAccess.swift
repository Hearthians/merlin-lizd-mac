import Foundation

public enum SSHHostQuickAccessBucket: Int, CaseIterable, Identifiable, Sendable {
    case pinned
    case recent

    public var id: Int { rawValue }
}

public struct SSHHostQuickAccessSection: Identifiable, Sendable {
    public var id: SSHHostQuickAccessBucket { bucket }
    public let bucket: SSHHostQuickAccessBucket
    public let hosts: [SSHHost]

    public init(bucket: SSHHostQuickAccessBucket, hosts: [SSHHost]) {
        self.bucket = bucket
        self.hosts = hosts
    }
}

/// Builds the deliberately small host set used by navigation and new-terminal
/// menus. The complete SSH config remains available as a searchable catalog.
public enum SSHHostQuickAccessOrganizer {
    public static func initialPins(
        customDestinations: Set<String>
    ) -> Set<String> {
        Set(customDestinations.filter {
            !IdentifierValidator.isIPAddressDestination($0)
        })
    }

    public static func sections(
        hosts: [SSHHost],
        pinnedDestinations: Set<String>,
        lastUsedAt: [String: Date],
        now: Date = Date(),
        recentLimit: Int = 6,
        recentWindow: TimeInterval = 7 * 24 * 60 * 60
    ) -> [SSHHostQuickAccessSection] {
        let ordered = hosts.sorted {
            switch (lastUsedAt[$0.destination], lastUsedAt[$1.destination]) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return $0.destination.localizedStandardCompare($1.destination)
                    == .orderedAscending
            }
        }

        let pinned = ordered.filter {
            pinnedDestinations.contains($0.destination)
        }
        let recent = ordered.filter { host in
            guard !pinnedDestinations.contains(host.destination),
                let usedAt = lastUsedAt[host.destination]
            else { return false }
            let age = max(0, now.timeIntervalSince(usedAt))
            return age < recentWindow
        }.prefix(max(0, recentLimit))

        var sections: [SSHHostQuickAccessSection] = []
        if !pinned.isEmpty {
            sections.append(.init(bucket: .pinned, hosts: pinned))
        }
        if !recent.isEmpty {
            sections.append(.init(bucket: .recent, hosts: Array(recent)))
        }
        return sections
    }
}
