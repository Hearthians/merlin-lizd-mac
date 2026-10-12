import Foundation

/// A browser URL whose explicit port refers to a loopback service on a remote host.
///
/// Parsing is intentionally strict because terminal output is untrusted. This type
/// never resolves a host name: it accepts only the loopback spellings listed below
/// and retains the original URL text so a forwarded URL preserves existing
/// escapes, path, query and fragment while Foundation encodes raw Unicode.
public struct LoopbackURL: Equatable, Hashable, Sendable {
    private static let maximumUTF8Length = 16_384

    public let originalLink: String
    public let remoteHost: String
    public let remotePort: Int

    private let scheme: Substring
    private let localHost: String
    private let suffix: Substring

    public init?(_ link: String) {
        guard !link.isEmpty,
            link.utf8.count <= Self.maximumUTF8Length,
            !link.unicodeScalars.contains(where: { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || CharacterSet.whitespacesAndNewlines.contains(scalar)
            }),
            !link.contains("\\"),
            Self.hasValidPercentEscapes(link)
        else { return nil }

        guard let schemeSeparator = link.firstIndex(of: ":") else { return nil }
        let scheme = link[..<schemeSeparator]
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "http" || normalizedScheme == "https" else {
            return nil
        }

        let authorityStart = link.index(after: schemeSeparator)
        guard link[authorityStart...].hasPrefix("//") else { return nil }
        let hostStart = link.index(authorityStart, offsetBy: 2)
        let authorityEnd = link[hostStart...].firstIndex(where: { character in
            character == "/" || character == "?" || character == "#"
        }) ?? link.endIndex
        let authority = link[hostStart..<authorityEnd]
        guard !authority.isEmpty,
            !authority.contains("@"),
            !authority.contains("%")
        else { return nil }

        let host: Substring
        let portText: Substring
        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]"),
                closingBracket != authority.startIndex,
                authority[authority.index(after: closingBracket)...].hasPrefix(":")
            else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<closingBracket]
            let colon = authority.index(after: closingBracket)
            portText = authority[authority.index(after: colon)...]
            guard host == "::1" else { return nil }
        } else {
            guard let colon = authority.lastIndex(of: ":"),
                colon != authority.startIndex,
                !authority[..<colon].contains(":")
            else { return nil }
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        }

        guard let port = Self.parsePort(portText) else { return nil }
        let remoteHost: String
        let localHost: String
        switch host.lowercased() {
        case "localhost":
            remoteHost = "localhost"
            localHost = "localhost"
        case "127.0.0.1":
            remoteHost = "127.0.0.1"
            localHost = "127.0.0.1"
        case "0.0.0.0":
            remoteHost = "127.0.0.1"
            localHost = "127.0.0.1"
        case "::1":
            remoteHost = "::1"
            localHost = "127.0.0.1"
        default:
            return nil
        }

        // Foundation must agree on the parsed authority. It may percent-encode
        // non-ASCII path/query text when creating the URL handed to AppKit.
        guard let parsed = URL(string: link),
            parsed.scheme?.lowercased() == normalizedScheme,
            parsed.port == port,
            parsed.user == nil,
            parsed.password == nil
        else { return nil }

        self.originalLink = link
        self.remoteHost = remoteHost
        self.remotePort = port
        self.scheme = scheme
        self.localHost = localHost
        self.suffix = link[authorityEnd...]
    }

    /// Replaces only the authority with a local loopback endpoint.
    /// The original scheme, percent escapes, path, query and fragment are kept.
    public func rewrittenURL(localPort: Int) -> URL? {
        guard (1...65_535).contains(localPort) else { return nil }
        let rewritten = "\(scheme)://\(localHost):\(localPort)\(suffix)"
        return URL(string: rewritten)
    }

    private static func parsePort(_ text: Substring) -> Int? {
        guard !text.isEmpty else { return nil }
        var value = 0
        for byte in text.utf8 {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int(byte - 48)
            guard value <= 65_535 else { return nil }
        }
        return (1...65_535).contains(value) ? value : nil
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 { // "%"
                guard index + 2 < bytes.count,
                    isHexadecimal(bytes[index + 1]),
                    isHexadecimal(bytes[index + 2])
                else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHexadecimal(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
