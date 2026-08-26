import Foundation

public enum SSHHostSource: String, Codable, Sendable {
    case configuration
    case custom
}

public struct SSHHost: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { destination }
    public let destination: String
    public let source: SSHHostSource

    public init(destination: String, source: SSHHostSource) {
        self.destination = destination
        self.source = source
    }
}

/// Reads concrete `Host` declarations from OpenSSH config files. Wildcard
/// patterns are intentionally omitted because they are connection rules, not
/// destinations a user can select. `Include` files are followed recursively.
public struct SSHConfigCatalog {
    private static let maximumFiles = 256
    private static let maximumFileBytes = 1_048_576

    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    public func load() -> [SSHHost] {
        let root = homeDirectory
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        var state = LoadState()
        load(root, state: &state)
        return state.destinations.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map {
            SSHHost(destination: $0, source: .configuration)
        }
    }

    public static func parseHostDeclarations(_ contents: String) -> [String] {
        var result: [String] = []
        for rawLine in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ) {
            let line = contentBeforeComment(String(rawLine))
            let fields = splitFields(line)
            guard fields.first?.lowercased() == "host" else { continue }
            for value in fields.dropFirst() where isConcreteHost(value) {
                result.append(value)
            }
        }
        return result
    }

    private func load(_ url: URL, state: inout LoadState) {
        guard state.visited.count < Self.maximumFiles else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard state.visited.insert(canonical.path).inserted else { return }
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: canonical.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue <= Self.maximumFileBytes,
            let contents = try? String(contentsOf: canonical, encoding: .utf8)
        else {
            return
        }

        state.destinations.formUnion(Self.parseHostDeclarations(contents))
        for include in Self.includePatterns(contents) {
            for includedURL in expandInclude(include, relativeTo: rootSSHDirectory) {
                load(includedURL, state: &state)
            }
        }
    }

    private var rootSSHDirectory: URL {
        homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
    }

    private func expandInclude(
        _ value: String,
        relativeTo baseDirectory: URL
    ) -> [URL] {
        let expanded: String
        if value == "~" {
            expanded = homeDirectory.path
        } else if value.hasPrefix("~/") {
            expanded = homeDirectory
                .appendingPathComponent(String(value.dropFirst(2)))
                .path
        } else if value.hasPrefix("/") {
            expanded = value
        } else {
            expanded = baseDirectory.appendingPathComponent(value).path
        }

        guard expanded.contains(where: { "*?[]".contains($0) }) else {
            return [URL(fileURLWithPath: expanded, isDirectory: false)]
        }

        let wildcardOffset = expanded.firstIndex {
            "*?[]".contains($0)
        } ?? expanded.endIndex
        let prefix = String(expanded[..<wildcardOffset])
        let scanPath = prefix.hasSuffix("/")
            ? String(prefix.dropLast())
            : URL(fileURLWithPath: prefix).deletingLastPathComponent().path
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: scanPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        let expression = Self.regularExpression(forGlob: expanded)
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            let path = candidate.standardizedFileURL.path
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            guard expression.firstMatch(in: path, range: range) != nil else {
                continue
            }
            matches.append(candidate)
            if matches.count >= Self.maximumFiles { break }
        }
        return matches.sorted { $0.path < $1.path }
    }

    private static func includePatterns(_ contents: String) -> [String] {
        var result: [String] = []
        for rawLine in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ) {
            let fields = splitFields(contentBeforeComment(String(rawLine)))
            guard fields.first?.lowercased() == "include" else { continue }
            result.append(contentsOf: fields.dropFirst())
        }
        return result
    }

    private static func contentBeforeComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "#", !quoted {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        func finish() {
            guard !current.isEmpty else { return }
            fields.append(current)
            current = ""
        }

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                finish()
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        finish()
        return fields
    }

    private static func isConcreteHost(_ value: String) -> Bool {
        !value.hasPrefix("!")
            && !value.contains(where: { "*?!".contains($0) })
            && IdentifierValidator.isSSHDestination(value)
    }

    private static func regularExpression(forGlob glob: String) -> NSRegularExpression {
        var pattern = "^"
        var inCharacterClass = false
        for character in glob {
            switch character {
            case "*" where !inCharacterClass:
                pattern += "[^/]*"
            case "?" where !inCharacterClass:
                pattern += "[^/]"
            case "[":
                inCharacterClass = true
                pattern += "["
            case "]" where inCharacterClass:
                inCharacterClass = false
                pattern += "]"
            default:
                if !inCharacterClass, "\\.^$|(){}+".contains(character) {
                    pattern += "\\"
                }
                pattern.append(character)
            }
        }
        pattern += "$"
        return try! NSRegularExpression(pattern: pattern)
    }

    private struct LoadState {
        var visited: Set<String> = []
        var destinations: Set<String> = []
    }
}
