import Foundation

public enum CodexNotificationKind: String, Codable, Sendable {
    case turnCompleted
    case approvalRequested
    case turnStarted
}

/// Only routing metadata is retained. Prompts, tool arguments, transcripts and
/// assistant output are deliberately absent from this wire format.
public struct CodexNotificationEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceID: String
    public let kind: CodexNotificationKind
    public let sessionID: String
    public let turnID: String?
    /// Stable desktop chat identity, distinct from transient hook/engine session IDs.
    public let desktopThreadID: String?
    public let cwd: String
    public let hostname: String
    public let sequence: Int
    public let timestamp: Date
    public let tmuxSession: String?
    public let tmuxSessionID: String?
    public let tmuxSessionCreated: Int?
    public let tmuxServerPID: Int?
    public let tmuxWindow: String?
    public let tmuxPane: String?
    public let tmuxSocket: String?

    public init(
        id: String, sourceID: String, kind: CodexNotificationKind,
        sessionID: String, turnID: String? = nil, cwd: String, hostname: String,
        sequence: Int, timestamp: Date, tmuxSession: String? = nil,
        tmuxSessionID: String? = nil, tmuxSessionCreated: Int? = nil,
        tmuxServerPID: Int? = nil, tmuxWindow: String? = nil,
        tmuxPane: String? = nil, tmuxSocket: String? = nil,
        desktopThreadID: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.sessionID = sessionID
        self.turnID = turnID
        self.desktopThreadID = desktopThreadID
        self.cwd = cwd
        self.hostname = hostname
        self.sequence = sequence
        self.timestamp = timestamp
        self.tmuxSession = tmuxSession
        self.tmuxSessionID = tmuxSessionID
        self.tmuxSessionCreated = tmuxSessionCreated
        self.tmuxServerPID = tmuxServerPID
        self.tmuxWindow = tmuxWindow
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, kind, sessionID, turnID, desktopThreadID, cwd, hostname, sequence, timestamp
        case tmuxSession, tmuxSessionID, tmuxSessionCreated, tmuxServerPID
        case tmuxWindow, tmuxPane, tmuxSocket
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        kind = try values.decode(CodexNotificationKind.self, forKey: .kind)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
        desktopThreadID = try values.decodeIfPresent(String.self, forKey: .desktopThreadID)
        cwd = try values.decode(String.self, forKey: .cwd)
        hostname = try values.decode(String.self, forKey: .hostname)
        sequence = try values.decode(Int.self, forKey: .sequence)
        let rawTimestamp = try values.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: rawTimestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: rawTimestamp)
        }
        guard let date else {
            throw DecodingError.dataCorruptedError(forKey: .timestamp, in: values, debugDescription: "Invalid event timestamp")
        }
        timestamp = date
        tmuxSession = try values.decodeIfPresent(String.self, forKey: .tmuxSession)
        tmuxSessionID = try values.decodeIfPresent(String.self, forKey: .tmuxSessionID)
        tmuxSessionCreated = try values.decodeIfPresent(Int.self, forKey: .tmuxSessionCreated)
        tmuxServerPID = try values.decodeIfPresent(Int.self, forKey: .tmuxServerPID)
        tmuxWindow = try values.decodeIfPresent(String.self, forKey: .tmuxWindow)
        tmuxPane = try values.decodeIfPresent(String.self, forKey: .tmuxPane)
        tmuxSocket = try values.decodeIfPresent(String.self, forKey: .tmuxSocket)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sourceID, forKey: .sourceID)
        try values.encode(kind, forKey: .kind)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(turnID, forKey: .turnID)
        try values.encodeIfPresent(desktopThreadID, forKey: .desktopThreadID)
        try values.encode(cwd, forKey: .cwd)
        try values.encode(hostname, forKey: .hostname)
        try values.encode(sequence, forKey: .sequence)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try values.encode(formatter.string(from: timestamp), forKey: .timestamp)
        try values.encodeIfPresent(tmuxSession, forKey: .tmuxSession)
        try values.encodeIfPresent(tmuxSessionID, forKey: .tmuxSessionID)
        try values.encodeIfPresent(tmuxSessionCreated, forKey: .tmuxSessionCreated)
        try values.encodeIfPresent(tmuxServerPID, forKey: .tmuxServerPID)
        try values.encodeIfPresent(tmuxWindow, forKey: .tmuxWindow)
        try values.encodeIfPresent(tmuxPane, forKey: .tmuxPane)
        try values.encodeIfPresent(tmuxSocket, forKey: .tmuxSocket)
    }
}

public struct CodexNotificationFeed: Codable, Sendable, Equatable {
    public let sourceID: String
    public let events: [CodexNotificationEvent]
    /// Global high-water mark. While hasMore is true, commit only the last
    /// returned event's sequence so the next page cannot be skipped.
    public let latestSequence: Int
    public let hasMore: Bool
    /// Complete shared read-state snapshot for retained events, independent of
    /// this device's delivery cursor or the events included in this page.
    public let readEventIDs: [String]

    public init(sourceID: String, events: [CodexNotificationEvent], latestSequence: Int, hasMore: Bool, readEventIDs: [String] = []) {
        self.sourceID = sourceID
        self.events = events
        self.latestSequence = latestSequence
        self.hasMore = hasMore
        self.readEventIDs = readEventIDs
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, events, latestSequence, hasMore, readEventIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        events = try values.decode([CodexNotificationEvent].self, forKey: .events)
        latestSequence = try values.decode(Int.self, forKey: .latestSequence)
        hasMore = try values.decode(Bool.self, forKey: .hasMore)
        readEventIDs = try values.decodeIfPresent([String].self, forKey: .readEventIDs) ?? []
    }

    static func decode(_ output: String, after: Int, limit: Int) throws -> Self {
        guard output.utf8.count <= 2_097_152, let data = output.data(using: .utf8) else {
            throw CodexNotificationError.invalidResponse
        }
        let feed: Self
        do { feed = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw CodexNotificationError.invalidResponse }
        guard UUID(uuidString: feed.sourceID) != nil, feed.latestSequence >= 0,
            feed.events.count <= limit, !feed.hasMore || !feed.events.isEmpty,
            feed.readEventIDs.count <= 2_000, Set(feed.readEventIDs).count == feed.readEventIDs.count,
            feed.readEventIDs.allSatisfy({ UUID(uuidString: $0) != nil })
        else { throw CodexNotificationError.invalidResponse }
        var previous = after
        var identifiers = Set<String>()
        for event in feed.events {
            guard event.sourceID == feed.sourceID, UUID(uuidString: event.id) != nil,
                event.sequence > previous, event.sequence <= feed.latestSequence,
                identifiers.insert(event.id).inserted,
                validText(event.sessionID, limit: 256), !event.sessionID.isEmpty,
                validText(event.cwd, limit: 4_096), event.cwd.isEmpty || event.cwd.hasPrefix("/"),
                validHostname(event.hostname)
            else { throw CodexNotificationError.invalidResponse }
            if let turnID = event.turnID, !validText(turnID, limit: 256) {
                throw CodexNotificationError.invalidResponse
            }
            if let threadID = event.desktopThreadID, UUID(uuidString: threadID) == nil {
                throw CodexNotificationError.invalidResponse
            }
            let metadata: [String?] = [event.tmuxSession, event.tmuxSessionID, event.tmuxWindow, event.tmuxPane, event.tmuxSocket]
            for value in metadata.compactMap({ $0 }) where !validText(value, limit: 4_096) {
                throw CodexNotificationError.invalidResponse
            }
            if let socket = event.tmuxSocket, !socket.hasPrefix("/") { throw CodexNotificationError.invalidResponse }
            for (value, prefix) in [(event.tmuxSessionID, "$"), (event.tmuxWindow, "@"), (event.tmuxPane, "%")] {
                if let value, !validTmuxIdentifier(value, prefix: prefix) { throw CodexNotificationError.invalidResponse }
            }
            if let created = event.tmuxSessionCreated, created < 0 { throw CodexNotificationError.invalidResponse }
            if let pid = event.tmuxServerPID, pid <= 0 { throw CodexNotificationError.invalidResponse }
            previous = event.sequence
        }
        return feed
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validHostname(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, bytes.count <= 256, isASCIIAlphaNumeric(first) else { return false }
        return bytes.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func validTmuxIdentifier(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.utf8.count > 1 && value.utf8.dropFirst().allSatisfy { (48...57).contains($0) }
    }
}

public enum CodexNotificationError: Error, Equatable, LocalizedError, Sendable {
    case invalidDestination
    case invalidCursor
    case notInstalled
    case invalidResponse
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: "通知主机地址无效。"
        case .invalidCursor: "通知读取位置无效。"
        case .notInstalled: "此主机尚未安装 Codex 通知桥接，请先启用通知并在 Codex 的 /hooks 中确认。"
        case .invalidResponse: "通知数据不完整，读取位置未更新。"
        case let .commandFailed(message): "无法同步 Codex 通知：\(message)"
        }
    }
}
