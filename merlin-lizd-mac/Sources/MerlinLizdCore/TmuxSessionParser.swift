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
                let name = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    isAttachable(name),
                    seen.insert(name).inserted
                else {
                    return nil
                }
                return TmuxSessionRecord(name: name)
            }
    }

    public static func isAttachable(_ value: String) -> Bool {
        guard let match = value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) else {
            return false
        }
        return match == value.startIndex..<value.endIndex
    }
}
