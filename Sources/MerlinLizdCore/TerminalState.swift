import Foundation

public enum TerminalTarget: Codable, Equatable, Hashable, Sendable {
    case local
    case devbox(sid: String, name: String, alias: String)
    case worker(
        devboxSID: String,
        devboxName: String,
        alias: String,
        workerID: String
    )

    public var sessionAttachmentTitle: String {
        switch self {
        case .local:
            "本机"
        case let .devbox(_, _, alias):
            alias
        case let .worker(_, _, _, workerID):
            "Worker \(workerID)"
        }
    }
}

public struct TerminalTabRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public let target: TerminalTarget
    public var sessionName: String?
    public let workingDirectory: String?

    public init(
        id: String,
        title: String,
        target: TerminalTarget,
        sessionName: String?,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
    }

    public var sessionContextTitle: String? {
        guard let sessionName else { return title.isEmpty ? nil : title }
        let contextTitle = titleExcludingSessionName(sessionName)
        return contextTitle.isEmpty ? nil : contextTitle
    }

    @discardableResult
    public mutating func recordSessionRename(
        from currentName: String,
        to newName: String
    ) -> Bool {
        guard sessionName == currentName else { return false }
        title = titleExcludingSessionName(currentName)
        sessionName = newName
        return true
    }

    private func titleExcludingSessionName(_ sessionName: String) -> String {
        let legacyTitle = "\(target.sessionAttachmentTitle) · \(sessionName)"
        return title == legacyTitle ? target.sessionAttachmentTitle : title
    }
}

public enum TerminalTabCloseDisposition: Equatable, Sendable {
    case closeTab
    case confirmTmuxTermination

    public static func resolve(
        for tab: TerminalTabRecord,
        optionPressed: Bool
    ) -> TerminalTabCloseDisposition {
        optionPressed && tab.sessionName != nil
            ? .confirmTmuxTermination
            : .closeTab
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
