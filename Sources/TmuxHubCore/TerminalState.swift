import Foundation

public enum TerminalTarget: Codable, Equatable, Hashable, Sendable {
    case local
    case ssh(destination: String)

    public var sshDestination: String? {
        guard case let .ssh(destination) = self else { return nil }
        return destination
    }
}

public struct TerminalTabRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public let target: TerminalTarget
    public var sessionName: String?
    public var tmuxIdentity: TmuxSessionIdentity?

    public init(
        id: String,
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        tmuxIdentity: TmuxSessionIdentity? = nil
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.sessionName = sessionName
        self.tmuxIdentity = tmuxIdentity
    }
}

public struct TerminalState: Codable, Equatable, Sendable {
    public static let empty = TerminalState(selectedTabID: nil, tabs: [])

    public var selectedTabID: String?
    public var tabs: [TerminalTabRecord]

    public init(selectedTabID: String?, tabs: [TerminalTabRecord]) {
        self.selectedTabID = selectedTabID
        self.tabs = tabs
    }
}

public enum TerminalTabSelection {
    public static func previous(
        in tabIDs: [String],
        from selectedTabID: String?
    ) -> String? {
        selection(in: tabIDs, from: selectedTabID, offset: -1)
    }

    public static func next(
        in tabIDs: [String],
        from selectedTabID: String?
    ) -> String? {
        selection(in: tabIDs, from: selectedTabID, offset: 1)
    }

    private static func selection(
        in tabIDs: [String],
        from selectedTabID: String?,
        offset: Int
    ) -> String? {
        guard !tabIDs.isEmpty else { return nil }
        guard
            let selectedTabID,
            let selectedIndex = tabIDs.firstIndex(of: selectedTabID)
        else {
            return offset < 0 ? tabIDs.last : tabIDs.first
        }

        let nextIndex = (selectedIndex + offset + tabIDs.count) % tabIDs.count
        return tabIDs[nextIndex]
    }
}

public enum TerminalStateCodecError: Error, Equatable, Sendable {
    case invalidEncoding
}

public enum TerminalStateCodec {
    public static func encode(_ state: TerminalState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard let value = String(data: data, encoding: .utf8) else {
            throw TerminalStateCodecError.invalidEncoding
        }
        return value
    }

    public static func decode(_ value: String) throws -> TerminalState {
        guard let data = value.data(using: .utf8) else {
            throw TerminalStateCodecError.invalidEncoding
        }
        return try JSONDecoder().decode(TerminalState.self, from: data)
    }
}
