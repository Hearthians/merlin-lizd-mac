import Foundation

public struct TmuxSessionIdentity: Codable, Hashable, Sendable {
    public let serverSessionID: String
    public let createdAtEpoch: Int64

    public var stableDisplayString: String {
        "\(serverSessionID)@\(createdAtEpoch)"
    }

    public init(serverSessionID: String, createdAtEpoch: Int64) {
        self.serverSessionID = serverSessionID
        self.createdAtEpoch = createdAtEpoch
    }
}

public struct TmuxSessionRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: String {
        identity.map { "\($0.serverSessionID)@\($0.createdAtEpoch)" } ?? name
    }
    public let name: String
    public let identity: TmuxSessionIdentity?

    public init(name: String, identity: TmuxSessionIdentity? = nil) {
        self.name = name
        self.identity = identity
    }
}

public enum TmuxSessionParser {
    public static func parse(_ output: String) -> [TmuxSessionRecord] {
        var seenIdentities: Set<TmuxSessionIdentity> = []
        var seenLegacyNames: Set<String> = []
        return output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { rawLine -> TmuxSessionRecord? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if let record = structuredRecord(from: line) {
                    guard
                        let identity = record.identity,
                        seenIdentities.insert(identity).inserted
                    else {
                        return nil
                    }
                    return record
                }
                let name = sessionName(from: line)
                guard
                    let name,
                    seenLegacyNames.insert(name).inserted
                else {
                    return nil
                }
                return TmuxSessionRecord(name: name)
            }
    }

    public static func isAttachable(_ value: String) -> Bool {
        MerlinIdentifierValidator.isTmuxSessionName(value)
    }

    private static func structuredRecord(
        from line: String
    ) -> TmuxSessionRecord? {
        let fields = line.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard fields.count == 3 else { return nil }

        let name = String(fields[0])
        let serverSessionID = String(fields[1])
        let createdAt = String(fields[2])
        guard
            isAttachable(name),
            serverSessionID.first == "$",
            serverSessionID.count > 1,
            serverSessionID.dropFirst().allSatisfy({
                $0.isASCII && $0.isNumber
            }),
            !createdAt.isEmpty,
            createdAt.allSatisfy({ $0.isASCII && $0.isNumber }),
            let createdAtEpoch = Int64(createdAt)
        else {
            return nil
        }

        return TmuxSessionRecord(
            name: name,
            identity: TmuxSessionIdentity(
                serverSessionID: serverSessionID,
                createdAtEpoch: createdAtEpoch
            )
        )
    }

    private static func sessionName(from line: String) -> String? {
        if isAttachable(line) {
            return line
        }

        // Older mlx Worker login paths can drop tmux's -F option and return
        // its default `name: N windows (...)` line. Recognize that exact shape
        // rather than silently reporting an empty server.
        guard
            let colon = line.firstIndex(of: ":"),
            line[line.index(after: colon)...].contains(" window")
        else {
            return nil
        }
        let candidate = String(line[..<colon])
        return isAttachable(candidate) ? candidate : nil
    }
}
