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

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarSelection = .overview
    @Published private(set) var hosts: [SSHHost] = []

    private let defaults: UserDefaults
    private let catalog: SSHConfigCatalog
    private let customHostsKey = "custom-ssh-hosts-v1"
    private var customDestinations: Set<String>

    init(
        defaults: UserDefaults = .standard,
        catalog: SSHConfigCatalog = SSHConfigCatalog()
    ) {
        self.defaults = defaults
        self.catalog = catalog
        customDestinations = Set(
            defaults.stringArray(forKey: customHostsKey) ?? []
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

    private func persistCustomHosts() {
        defaults.set(customDestinations.sorted(), forKey: customHostsKey)
    }
}
