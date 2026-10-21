import Foundation
import TmuxHubCore

enum SidebarSelection: Hashable {
    case overview
    case mesh
    case portForwarding
    case notifications
    case local
    case platform(String)
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

extension SSHHostQuickAccessBucket {
    var displayTitle: String {
        switch self {
        case .pinned: "已固定"
        case .recent: "最近使用"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarSelection = .overview
    @Published private(set) var hosts: [SSHHost] = []

    private let defaults: UserDefaults
    private let catalog: SSHConfigCatalog
    private let configWriter: SSHConfigWriter
    private let customHostsKey = "custom-ssh-hosts-v1"
    private let lastUsedHostsKey = "ssh-host-last-used-v1"
    private let pinnedHostsKey = "pinned-ssh-hosts-v1"
    private var customDestinations: Set<String>
    private var lastUsedAt: [String: Date]
    private var pinnedDestinations: Set<String>

    init(
        defaults: UserDefaults = .standard,
        catalog: SSHConfigCatalog = SSHConfigCatalog(),
        configWriter: SSHConfigWriter = SSHConfigWriter()
    ) {
        self.defaults = defaults
        self.catalog = catalog
        self.configWriter = configWriter
        customDestinations = Set(
            defaults.stringArray(forKey: customHostsKey) ?? []
        )
        lastUsedAt = Self.loadLastUsedHosts(
            defaults.dictionary(forKey: lastUsedHostsKey) ?? [:]
        )
        if let savedPins = defaults.stringArray(forKey: pinnedHostsKey) {
            pinnedDestinations = Set(savedPins)
        } else {
            // Existing manually added destinations were explicit choices, so
            // preserve named targets as favorites when upgrading. Literal IPs
            // stay available and recent, but do not become permanent clutter.
            pinnedDestinations = SSHHostQuickAccessOrganizer.initialPins(
                customDestinations: customDestinations
            )
            defaults.set(pinnedDestinations.sorted(), forKey: pinnedHostsKey)
        }
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
        let knownDestinations = Set(byDestination.keys)
        let retainedUsage = lastUsedAt.filter {
            knownDestinations.contains($0.key)
        }
        if retainedUsage.count != lastUsedAt.count {
            lastUsedAt = retainedUsage
            persistLastUsedHosts()
        }
        hosts = byDestination.values.sorted {
            $0.destination.localizedStandardCompare($1.destination)
                == .orderedAscending
        }
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
        pinnedDestinations.insert(destination)
        persistCustomHosts()
        persistPinnedHosts()
        refresh()
        selection = .host(destination)
        return hosts.first(where: { $0.destination == destination })
            ?? SSHHost(destination: destination, source: .custom)
    }

    @discardableResult
    func add(configuration: SSHHostConfiguration) async throws -> SSHHost {
        let writer = configWriter
        let host = try await Task.detached(priority: .userInitiated) {
            try writer.add(configuration)
        }.value
        if customDestinations.remove(host.destination) != nil {
            persistCustomHosts()
        }
        pinnedDestinations.insert(host.destination)
        persistPinnedHosts()
        refresh()
        selection = .host(host.destination)
        return host
    }

    @discardableResult
    func updateConnection(_ settings: SSHConnectionSettings) async throws -> SSHHost {
        let writer = configWriter
        let updatedHost = try await Task.detached(priority: .userInitiated) {
            try writer.update(settings)
        }.value
        let original = settings.destination
        let wasSelected = selection == .host(original)
        let wasPinned = pinnedDestinations.remove(original) != nil
        let previousUse = lastUsedAt.removeValue(forKey: original)
        customDestinations.remove(original)
        if updatedHost.source == .custom {
            customDestinations.insert(updatedHost.destination)
        }
        if wasPinned { pinnedDestinations.insert(updatedHost.destination) }
        if let previousUse {
            lastUsedAt[updatedHost.destination] = max(
                previousUse, lastUsedAt[updatedHost.destination] ?? .distantPast
            )
        }
        persistCustomHosts()
        persistPinnedHosts()
        persistLastUsedHosts()
        refresh()
        if wasSelected { selection = .host(updatedHost.destination) }
        return updatedHost
    }

    func removeCustomHost(_ destination: String) {
        guard customDestinations.remove(destination) != nil else { return }
        pinnedDestinations.remove(destination)
        lastUsedAt.removeValue(forKey: destination)
        persistCustomHosts()
        persistPinnedHosts()
        persistLastUsedHosts()
        refresh()
    }

    func isCustom(_ destination: String) -> Bool {
        customDestinations.contains(destination)
    }

    func host(destination: String) -> SSHHost? {
        hosts.first { $0.destination == destination }
    }

    func isPinned(_ destination: String) -> Bool {
        pinnedDestinations.contains(destination)
    }

    func setPinned(_ pinned: Bool, destination: String) {
        guard hosts.contains(where: { $0.destination == destination }) else {
            return
        }
        objectWillChange.send()
        if pinned {
            pinnedDestinations.insert(destination)
        } else {
            pinnedDestinations.remove(destination)
        }
        persistPinnedHosts()
    }

    func recordUse(of destination: String, at date: Date = Date()) {
        guard IdentifierValidator.isSSHDestination(destination) else { return }
        objectWillChange.send()
        lastUsedAt[destination] = date
        persistLastUsedHosts()
    }

    func quickAccessSections(
        now: Date = Date()
    ) -> [SSHHostQuickAccessSection] {
        SSHHostQuickAccessOrganizer.sections(
            hosts: hosts,
            pinnedDestinations: pinnedDestinations,
            lastUsedAt: lastUsedAt,
            now: now
        )
    }

    var quickAccessHosts: [SSHHost] {
        quickAccessSections().flatMap(\.hosts)
    }

    func searchHosts(matching searchText: String) -> [SSHHost] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return orderedByUse(hosts.filter {
            $0.destination.localizedCaseInsensitiveContains(query)
        })
    }

    func libraryHosts(
        matching searchText: String = "",
        includeRawAddresses: Bool = false,
        now: Date = Date()
    ) -> [SSHHost] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quickDestinations = Set(
            quickAccessSections(now: now).flatMap(\.hosts).map(\.destination)
        )
        return orderedByUse(hosts.filter { host in
            guard !quickDestinations.contains(host.destination) else {
                return false
            }
            guard includeRawAddresses
                || !IdentifierValidator.isIPAddressDestination(host.destination)
            else { return false }
            return query.isEmpty
                || host.destination.localizedCaseInsensitiveContains(query)
        })
    }

    var hiddenRawAddressCount: Int {
        let quickDestinations = Set(
            quickAccessSections().flatMap(\.hosts).map(\.destination)
        )
        return hosts.filter {
            !quickDestinations.contains($0.destination)
                && IdentifierValidator.isIPAddressDestination($0.destination)
        }.count
    }

    private func orderedByUse(_ values: [SSHHost]) -> [SSHHost] {
        values.sorted { lhs, rhs in
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

    private func persistPinnedHosts() {
        defaults.set(pinnedDestinations.sorted(), forKey: pinnedHostsKey)
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
