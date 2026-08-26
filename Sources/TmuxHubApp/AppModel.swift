import Foundation
import TmuxHubCore

enum SidebarSelection: Hashable {
    case overview
    case local
    case host(String)
}

enum HostCatalogError: LocalizedError {
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "SSH 目标格式无效。可使用 config alias、hostname、IP 或 user@host。"
        }
    }
}

extension SSHHostRecencyBucket {
    var displayTitle: String {
        switch self {
        case .withinThreeDays: "3 天内"
        case .threeToSevenDays: "3–7 天前"
        case .olderThanSevenDays: "7 天以前"
        case .neverUsed: "从未使用"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarSelection = .overview
    @Published private(set) var hosts: [SSHHost] = []

    private let defaults: UserDefaults
    private let catalog: SSHConfigCatalog
    private let customHostsKey = "custom-ssh-hosts-v1"
    private let lastUsedHostsKey = "ssh-host-last-used-v1"
    private var customDestinations: Set<String>
    private var lastUsedAt: [String: Date]

    init(
        defaults: UserDefaults = .standard,
        catalog: SSHConfigCatalog = SSHConfigCatalog()
    ) {
        self.defaults = defaults
        self.catalog = catalog
        customDestinations = Set(
            defaults.stringArray(forKey: customHostsKey) ?? []
        )
        lastUsedAt = Self.loadLastUsedHosts(
            defaults.dictionary(forKey: lastUsedHostsKey) ?? [:]
        )
        refresh()
    }

    func refresh() {
        let configured = catalog.load()
        var byDestination = Dictionary(
            uniqueKeysWithValues: configured.map { ($0.destination, $0) }
        )
        for destination in customDestinations
        where IdentifierValidator.isSSHDestination(destination) {
            if byDestination[destination] == nil {
                byDestination[destination] = SSHHost(
                    destination: destination,
                    source: .custom
                )
            }
        }
        hosts = SSHHostRecencyOrganizer.sections(
            hosts: Array(byDestination.values),
            lastUsedAt: lastUsedAt
        ).flatMap(\.hosts)
        if case let .host(destination) = selection,
            !hosts.contains(where: { $0.destination == destination })
        {
            selection = .overview
        }
    }

    @discardableResult
    func add(destination proposedValue: String) throws -> SSHHost {
        let destination = proposedValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard IdentifierValidator.isSSHDestination(destination) else {
            throw HostCatalogError.invalidDestination
        }
        customDestinations.insert(destination)
        persistCustomHosts()
        refresh()
        selection = .host(destination)
        return hosts.first(where: { $0.destination == destination })
            ?? SSHHost(destination: destination, source: .custom)
    }

    func removeCustomHost(_ destination: String) {
        guard customDestinations.remove(destination) != nil else { return }
        persistCustomHosts()
        refresh()
    }

    func isCustom(_ destination: String) -> Bool {
        customDestinations.contains(destination)
    }

    func host(destination: String) -> SSHHost? {
        hosts.first { $0.destination == destination }
    }

    func recordUse(of destination: String, at date: Date = Date()) {
        guard IdentifierValidator.isSSHDestination(destination) else { return }
        lastUsedAt[destination] = date
        persistLastUsedHosts()
        hosts = SSHHostRecencyOrganizer.sections(
            hosts: hosts,
            lastUsedAt: lastUsedAt,
            now: date
        ).flatMap(\.hosts)
    }

    func hostSections(
        matching searchText: String = "",
        now: Date = Date()
    ) -> [SSHHostRecencySection] {
        let values = searchText.isEmpty ? hosts : hosts.filter {
            $0.destination.localizedCaseInsensitiveContains(searchText)
        }
        return SSHHostRecencyOrganizer.sections(
            hosts: values,
            lastUsedAt: lastUsedAt,
            now: now
        )
    }

    private func persistCustomHosts() {
        defaults.set(customDestinations.sorted(), forKey: customHostsKey)
    }

    private func persistLastUsedHosts() {
        defaults.set(
            lastUsedAt.mapValues(\.timeIntervalSince1970),
            forKey: lastUsedHostsKey
        )
    }

    private static func loadLastUsedHosts(
        _ values: [String: Any]
    ) -> [String: Date] {
        values.reduce(into: [:]) { result, entry in
            guard IdentifierValidator.isSSHDestination(entry.key),
                let timestamp = (entry.value as? NSNumber)?.doubleValue,
                timestamp.isFinite,
                timestamp > 0
            else { return }
            result[entry.key] = Date(timeIntervalSince1970: timestamp)
        }
    }
}
