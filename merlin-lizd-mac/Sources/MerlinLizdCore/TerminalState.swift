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
}

public struct TerminalTabRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public let target: TerminalTarget
    public let sessionName: String?

    public init(
        id: String,
        title: String,
        target: TerminalTarget,
        sessionName: String?
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.sessionName = sessionName
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
