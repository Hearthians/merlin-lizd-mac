import Darwin
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

    /// Returns whether an SSH destination names a literal IPv4 or IPv6
    /// address, with an optional `user@` prefix. This lets presentation code
    /// keep implementation addresses out of the primary host list without
    /// changing what OpenSSH is allowed to connect to.
    public static func isIPAddressDestination(_ value: String) -> Bool {
        guard isSSHDestination(value) else { return false }

        var host = value[...]
        if let separator = host.lastIndex(of: "@") {
            host = host[host.index(after: separator)...]
        }
        if host.first == "[", host.last == "]" {
            host = host.dropFirst().dropLast()
        }

        // `inet_pton` does not accept an IPv6 scope identifier such as
        // `%en0`, while OpenSSH does. Remove only that final scope suffix.
        let address = String(host.split(separator: "%", maxSplits: 1)[0])
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }

    public static func isTmuxSessionName(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#)
    }

    /// Returns the name tmux actually stores. Validate before normalization so
    /// unsupported input cannot become a valid command argument by replacement.
    public static func normalizedTmuxSessionName(_ value: String) -> String? {
        guard isTmuxSessionName(value) else { return nil }
        return value.replacingOccurrences(of: ".", with: "_")
    }

    /// Produces one deterministic tmux session name for a destination. Quick
    /// connect can therefore resume the same workspace instead of creating a
    /// new UUID-named session on every click.
    public static func stableTmuxSessionName(for destination: String) -> String? {
        guard isSSHDestination(destination) else { return nil }
        let normalized = destination.lowercased().map { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || ".-_".contains(character))
                ? character : "-"
        }
        let compact = String(normalized.prefix(46))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in destination.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hexadecimal = String(hash, radix: 16)
        let suffix = String(hexadecimal.suffix(8))
        let candidate = "tmuxhub-\(compact.isEmpty ? "shell" : compact)-\(suffix)"
        return normalizedTmuxSessionName(candidate)
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
