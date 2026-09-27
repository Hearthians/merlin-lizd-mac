import Foundation

public enum TerminalTarget: Codable, Equatable, Hashable, Sendable {
    case local
    case ssh(destination: String)

    public var sshDestination: String? {
        guard case let .ssh(destination) = self else { return nil }
        return destination
    }
}

public enum TmuxSessionLaunchMode: String, Codable, Equatable, Hashable, Sendable {
    case createOrAttach
    case attachOnly
}

public struct TerminalTabRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public let target: TerminalTarget
    public var sessionName: String?
    public var tmuxIdentity: TmuxSessionIdentity?
    public var herdrReference: HerdrTerminalReference?
    public var tmuxLaunchMode: TmuxSessionLaunchMode

    public var allowsTmuxLifecycleMutation: Bool {
        tmuxLaunchMode == .createOrAttach
    }

    public init(
        id: String,
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        tmuxIdentity: TmuxSessionIdentity? = nil,
        herdrReference: HerdrTerminalReference? = nil,
        tmuxLaunchMode: TmuxSessionLaunchMode = .createOrAttach
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.sessionName = sessionName
        self.tmuxIdentity = tmuxIdentity
        self.herdrReference = herdrReference
        self.tmuxLaunchMode = tmuxLaunchMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case target
        case sessionName
        case tmuxIdentity
        case herdrReference
        case tmuxLaunchMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        target = try container.decode(TerminalTarget.self, forKey: .target)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        tmuxIdentity = try container.decodeIfPresent(
            TmuxSessionIdentity.self,
            forKey: .tmuxIdentity
        )
        herdrReference = try container.decodeIfPresent(
            HerdrTerminalReference.self,
            forKey: .herdrReference
        )
        tmuxLaunchMode = try container.decodeIfPresent(
            TmuxSessionLaunchMode.self,
            forKey: .tmuxLaunchMode
        ) ?? .createOrAttach
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(sessionName, forKey: .sessionName)
        try container.encodeIfPresent(tmuxIdentity, forKey: .tmuxIdentity)
        try container.encodeIfPresent(herdrReference, forKey: .herdrReference)
        try container.encode(tmuxLaunchMode, forKey: .tmuxLaunchMode)
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
