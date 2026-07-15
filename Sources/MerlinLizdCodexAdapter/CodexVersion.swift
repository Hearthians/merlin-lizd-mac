import Foundation

public enum CodexVersionParseError: Error, Equatable, Sendable {
    case malformed
}

public struct CodexVersion: Codable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        precondition(major >= 0 && minor >= 0 && patch >= 0)
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func parse(commandOutput: String) throws -> Self {
        let pattern = #"\Acodex-cli ([0-9]+)\.([0-9]+)\.([0-9]+)\r?\n?\z"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: commandOutput,
                range: NSRange(commandOutput.startIndex..., in: commandOutput)
            ),
            match.range == NSRange(commandOutput.startIndex..., in: commandOutput),
            match.numberOfRanges == 4,
            let majorRange = Range(match.range(at: 1), in: commandOutput),
            let minorRange = Range(match.range(at: 2), in: commandOutput),
            let patchRange = Range(match.range(at: 3), in: commandOutput),
            let major = Int(commandOutput[majorRange]),
            let minor = Int(commandOutput[minorRange]),
            let patch = Int(commandOutput[patchRange])
        else {
            throw CodexVersionParseError.malformed
        }
        return Self(major: major, minor: minor, patch: patch)
    }

    public var isSupported: Bool {
        self >= Self(major: 0, minor: 144, patch: 2)
            && self < Self(major: 0, minor: 145, patch: 0)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension CodexVersion: CustomStringConvertible {
    public var description: String { "\(major).\(minor).\(patch)" }
}
