import Foundation

public struct TmuxSessionRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public enum TmuxSessionParser {
    public static func parse(_ output: String) -> [TmuxSessionRecord] {
        var seen: Set<String> = []
        return output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { rawLine -> TmuxSessionRecord? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = sessionName(from: line)
                guard
                    let name,
                    seen.insert(name).inserted
                else {
                    return nil
                }
                return TmuxSessionRecord(name: name)
            }
    }

    public static func isAttachable(_ value: String) -> Bool {
        MerlinIdentifierValidator.isTmuxSessionName(value)
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
