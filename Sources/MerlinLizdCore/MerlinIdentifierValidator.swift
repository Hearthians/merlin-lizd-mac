import Foundation

/// One trust boundary for identifiers that may become local argv or part of a
/// deliberately constrained remote command. Callers still pass plain strings,
/// but every command-producing path shares these exact rules.
public enum MerlinIdentifierValidator {
    public static func isSSHAlias(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#)
    }

    public static func isDevboxSID(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#)
    }

    public static func isWorkerID(_ value: String) -> Bool {
        matches(value, pattern: #"^[0-9]+$"#)
    }

    public static func isTmuxSessionName(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#)
    }

    public static func isTmuxWorkingDirectory(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.unicodeScalars.count <= 1_024
            && !value.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0) || $0.value == 0
            })
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return false
        }
        return range == value.startIndex..<value.endIndex
    }
}
