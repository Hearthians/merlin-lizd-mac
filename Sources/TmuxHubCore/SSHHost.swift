import Darwin
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
        (try? load(requiresCompleteRead: false)) ?? []
    }

    /// Editing must not silently overlook aliases from unreadable includes.
    func loadForConfigurationEdit() throws -> [SSHHost] {
        try load(requiresCompleteRead: true)
    }

    private func load(requiresCompleteRead: Bool) throws -> [SSHHost] {
        let root = homeDirectory
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        var state = LoadState()
        try load(root, state: &state, requiresCompleteRead: requiresCompleteRead)
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
            let fields = directiveFields(line)
            guard fields.first?.lowercased() == "host" else { continue }
            for value in fields.dropFirst() where isConcreteHost(value) {
                result.append(value)
            }
        }
        return result
    }

    private func load(_ url: URL, state: inout LoadState, requiresCompleteRead: Bool) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !state.visited.contains(canonical.path) else { return }
        guard state.visited.count < Self.maximumFiles else {
            if requiresCompleteRead { throw SSHHostConfigurationError.unreadableConfiguration }
            return
        }
        state.visited.insert(canonical.path)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: canonical.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // An unmatched Include is valid OpenSSH configuration.
            return
        } catch {
            if requiresCompleteRead { throw SSHHostConfigurationError.unreadableConfiguration }
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber,
            size.intValue <= Self.maximumFileBytes,
            let contents = try? boundedContents(of: canonical)
        else {
            if requiresCompleteRead { throw SSHHostConfigurationError.unreadableConfiguration }
            return
        }

        state.destinations.formUnion(Self.parseHostDeclarations(contents))
        for include in Self.includePatterns(contents) {
            for includedURL in try expandInclude(
                include, relativeTo: rootSSHDirectory, requiresCompleteRead: requiresCompleteRead
            ) {
                try load(includedURL, state: &state, requiresCompleteRead: requiresCompleteRead)
            }
        }
    }

    private var rootSSHDirectory: URL {
        homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
    }

    private func boundedContents(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes,
            let contents = String(data: data, encoding: .utf8)
        else { throw SSHHostConfigurationError.unreadableConfiguration }
        return contents
    }

    private func expandInclude(
        _ value: String,
        relativeTo baseDirectory: URL,
        requiresCompleteRead: Bool
    ) throws -> [URL] {
        if requiresCompleteRead,
            value.contains("${") || value.contains("%")
                || (value.hasPrefix("~") && value != "~" && !value.hasPrefix("~/"))
        {
            throw SSHHostConfigurationError.unsupportedIncludePath
        }
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

        // Use the same glob syntax as OpenSSH instead of recursively scanning
        // directories or translating character classes to regular expressions.
        var matches = glob_t()
        defer { globfree(&matches) }
        let result = expanded.withCString { Darwin.glob($0, GLOB_ERR, nil, &matches) }
        if result == GLOB_NOMATCH { return [] }
        guard result == 0, let paths = matches.gl_pathv else {
            if requiresCompleteRead { throw SSHHostConfigurationError.unreadableConfiguration }
            return []
        }
        if matches.gl_pathc > Self.maximumFiles, requiresCompleteRead {
            throw SSHHostConfigurationError.unreadableConfiguration
        }
        return (0..<min(matches.gl_pathc, Self.maximumFiles)).compactMap { index in
            paths[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    private static func includePatterns(_ contents: String) -> [String] {
        var result: [String] = []
        for rawLine in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ) {
            let fields = directiveFields(contentBeforeComment(String(rawLine)))
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

    private static func directiveFields(_ line: String) -> [String] {
        var remainder = line.drop(while: \.isWhitespace)
        let keyword = remainder.prefix { !$0.isWhitespace && $0 != "=" }
        guard !keyword.isEmpty else { return [] }
        remainder = remainder.dropFirst(keyword.count).drop(while: \.isWhitespace)
        if remainder.first == "=" { remainder = remainder.dropFirst() }
        return [String(keyword)] + splitFields(String(remainder))
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

    private struct LoadState {
        var visited: Set<String> = []
        var destinations: Set<String> = []
    }
}
