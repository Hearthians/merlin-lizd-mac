import Foundation

/// Validates values that cross the local SSH/tmux command boundary.
public enum IdentifierValidator {
    /// Accepts OpenSSH aliases, host names, IPv4/IPv6 literals and
    /// `user@host` destinations while rejecting option injection, whitespace,
    /// control characters and shell syntax.
    public static func isSSHDestination(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, value.first != "-" else {
            return false
        }
        return matches(
            value,
            pattern: #"^[A-Za-z0-9\[][A-Za-z0-9@._:%+\-\[\]]{0,254}$"#
        )
    }

    public static func isTmuxSessionName(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#)
    }

    public static func isTmuxSessionID(_ value: String) -> Bool {
        matches(value, pattern: #"^\$[0-9]+$"#)
    }

    public static func isTmuxWindowID(_ value: String) -> Bool {
        matches(value, pattern: #"^@[0-9]+$"#)
    }

    public static func isTmuxPaneID(_ value: String) -> Bool {
        matches(value, pattern: #"^%[0-9]+$"#)
    }

    public static func isTmuxWindowIndex(_ value: Int) -> Bool {
        value >= 0
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return false
        }
        return range == value.startIndex..<value.endIndex
    }
}
