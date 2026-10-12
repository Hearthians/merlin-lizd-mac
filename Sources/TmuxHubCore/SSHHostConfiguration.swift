import Darwin
import Foundation

public enum SSHHostConfigurationError: LocalizedError, Equatable {
    case invalidAlias
    case invalidHostname
    case invalidUsername
    case invalidPort
    case invalidIdentityFile
    case duplicateAlias(String)
    case unreadableConfiguration
    case unsupportedIncludePath
    case configurationChanged
    case invalidDestination
    case invalidManagedConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidAlias:
            return "主机名称需以字母或数字开头，只能包含字母、数字、点、横线和下划线，最多 255 个字符。"
        case .invalidHostname:
            return "请输入有效的主机地址（域名、IPv4 或 IPv6），用户名和端口请分别填写。"
        case .invalidUsername:
            return "SSH 用户名格式无效，不能包含空白或控制字符。"
        case .invalidPort:
            return "SSH 端口必须是 1 到 65535 之间的整数。"
        case .invalidIdentityFile:
            return "私钥路径需为绝对路径或以 ~/ 开头，不能包含控制字符或环境变量表达式。"
        case let .duplicateAlias(alias):
            return "SSH 配置中已存在主机“\(alias)”，请换一个名称。"
        case .unreadableConfiguration:
            return "SSH 配置或 Include 文件无法安全读取，或保存后会超过 1 MB，未做任何修改。"
        case .unsupportedIncludePath:
            return "现有 SSH Include 使用了动态路径或其他用户的主目录，无法确认主机名称是否重复；请先改为固定路径。"
        case .configurationChanged:
            return "SSH 配置在保存期间发生了变化，请重新打开后保存。"
        case .invalidDestination:
            return "此 SSH 目标无法安全修改，请使用具体 alias、IP 或 user@host。"
        case .invalidManagedConfiguration:
            return "TmuxHub 管理的 SSH 属性区块不完整或重复，未做任何修改。请先检查 ~/.ssh/config。"
        }
    }
}

/// Editable common properties of an existing destination. The destination's
/// host component stays stable; an explicit `user@` prefix follows the edited
/// username because command-line users take precedence over config values.
public struct SSHConnectionSettings: Equatable, Sendable {
    public let destination: String
    public let hostname: String
    public let username: String
    public let port: Int

    fileprivate let hostPattern: String
    fileprivate let hasExplicitUsername: Bool

    public var updatedDestination: String {
        hasExplicitUsername ? "\(username)@\(hostPattern)" : destination
    }

    public init(destination: String, hostname: String, username: String, port: Int) throws {
        let cleanDestination = destination.trimmingCharacters(in: .whitespaces)
        guard IdentifierValidator.isSSHDestination(cleanDestination),
            !destination.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            })
        else { throw SSHHostConfigurationError.invalidDestination }

        let separator = cleanDestination.lastIndex(of: "@")
        let host = separator.map { String(cleanDestination[cleanDestination.index(after: $0)...]) }
            ?? cleanDestination
        if host.contains(":"), !host.contains("@") {
            // Reuse address validation to reject malformed brackets and scopes.
            _ = try SSHHostConfiguration(alias: "validation", hostname: host)
        } else {
            guard host.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+%\-]{0,254}$"#,
                options: .regularExpression) != nil
            else { throw SSHHostConfigurationError.invalidDestination }
        }
        if let separator {
            let originalUser = String(cleanDestination[..<separator])
            guard !originalUser.isEmpty else { throw SSHHostConfigurationError.invalidDestination }
            _ = try SSHHostConfiguration(alias: "validation", hostname: "localhost", username: originalUser)
        }

        let validated = try SSHHostConfiguration(
            alias: "validation", hostname: hostname, username: username, port: port
        )
        guard !validated.username.isEmpty else { throw SSHHostConfigurationError.invalidUsername }
        let updated = separator == nil ? cleanDestination : "\(validated.username)@\(host)"
        guard IdentifierValidator.isSSHDestination(updated) else {
            throw SSHHostConfigurationError.invalidDestination
        }
        self.destination = cleanDestination
        self.hostname = validated.hostname
        self.username = validated.username
        self.port = validated.port
        self.hostPattern = host
        self.hasExplicitUsername = separator != nil
    }
}

/// Connection settings that can be safely represented in an OpenSSH config.
public struct SSHHostConfiguration: Equatable, Sendable {
    public let alias: String
    public let hostname: String
    public let username: String
    public let port: Int
    public let identityFile: String?

    public init(
        alias: String,
        hostname: String,
        username: String = "",
        port: Int = 22,
        identityFile: String? = nil
    ) throws {
        let cleanAlias = alias.trimmingCharacters(in: .whitespaces)
        guard !Self.hasControlCharacters(alias), Self.matches(
            cleanAlias, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"#
        ) else { throw SSHHostConfigurationError.invalidAlias }

        var cleanHostname = hostname.trimmingCharacters(in: .whitespaces)
        if cleanHostname.hasPrefix("["), cleanHostname.hasSuffix("]") {
            cleanHostname = String(cleanHostname.dropFirst().dropLast())
            guard cleanHostname.contains(":") else {
                throw SSHHostConfigurationError.invalidHostname
            }
        }
        guard !Self.hasControlCharacters(hostname), Self.isHostname(cleanHostname) else {
            throw SSHHostConfigurationError.invalidHostname
        }

        let cleanUsername = username.trimmingCharacters(in: .whitespaces)
        guard !Self.hasControlCharacters(username), cleanUsername.isEmpty || Self.matches(
            cleanUsername, #"^[A-Za-z0-9_][A-Za-z0-9_.@+\-]{0,253}\$?$"#
        ) else { throw SSHHostConfigurationError.invalidUsername }
        guard (1...65535).contains(port) else { throw SSHHostConfigurationError.invalidPort }

        let cleanIdentityFile = identityFile?.trimmingCharacters(in: .whitespaces)
        if let original = identityFile, Self.hasControlCharacters(original) {
            throw SSHHostConfigurationError.invalidIdentityFile
        }
        if let path = cleanIdentityFile, !path.isEmpty {
            guard (path.hasPrefix("/") || path.hasPrefix("~/")),
                path.utf8.count <= 4096, !path.contains("${")
            else { throw SSHHostConfigurationError.invalidIdentityFile }
        }

        self.alias = cleanAlias
        self.hostname = cleanHostname
        self.username = cleanUsername
        self.port = port
        self.identityFile = cleanIdentityFile.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        if value.contains(":") {
            let parts = value.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            if parts.count == 2, !matches(String(parts[1]), #"^[A-Za-z0-9_.-]+$"#) {
                return false
            }
            var address = in6_addr()
            return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        let labels = value.dropLast(value.hasSuffix(".") ? 1 : 0)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({
            matches(String($0), #"^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$"#)
        }) else { return false }
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            var address = in_addr()
            return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
        }
        return true
    }
}

/// Writes normal OpenSSH configuration, so every SSH-based feature shares the
/// same host settings. Existing config is retained verbatim after a scope reset.
public struct SSHConfigWriter: Sendable {
    private static let maximumConfigurationBytes = 1_048_576
    private static let writeLock = NSLock()
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func add(_ configuration: SSHHostConfiguration) throws -> SSHHost {
        try Self.writeLock.withLock { try addLocked(configuration) }
    }

    public func update(_ settings: SSHConnectionSettings) throws -> SSHHost {
        try Self.writeLock.withLock { try updateLocked(settings) }
    }

    private func updateLocked(_ settings: SSHConnectionSettings) throws -> SSHHost {
        let configURL = homeDirectory.appendingPathComponent(".ssh/config")
        let targetURL = configURL.resolvingSymlinksInPath()
        let original = try readConfiguration(at: targetURL)
        // Validate included configuration with the same bounded reader used by
        // additions, without rewriting any included file.
        _ = try SSHConfigCatalog(homeDirectory: homeDirectory).loadForConfigurationEdit()
        let originalData = original?.data ?? Data()
        let withoutExisting = try Self.removingManagedProperties(
            for: settings.destination, from: originalData
        )
        if settings.updatedDestination != settings.destination,
            try Self.removingManagedProperties(for: settings.updatedDestination, from: withoutExisting) != withoutExisting {
            throw SSHHostConfigurationError.duplicateAlias(settings.updatedDestination)
        }
        let identifier = Self.managedIdentifier(settings.updatedDestination)
        // A user-qualified destination gets a user-qualified Match block. A
        // plain Host block would also change other users of the same address.
        let scope = settings.hasExplicitUsername
            ? "Match originalhost \(settings.hostPattern) user \(settings.username)"
            : "Host \(settings.hostPattern)"
        let block = Data(([
            "# BEGIN TmuxHub SSH properties \(identifier)",
            scope,
            "    HostName \(settings.hostname.replacingOccurrences(of: "%", with: "%%"))",
            "    User \(settings.username)",
            "    Port \(settings.port)",
            "Host *",
            "# END TmuxHub SSH properties \(identifier)",
            "",
        ].joined(separator: "\n")).utf8)
        // Keep user-qualified overrides ahead of general Host defaults even
        // when the plain alias is edited later.
        let insertionOffset = settings.hasExplicitUsername
            ? 0 : try Self.managedPrefixLength(in: withoutExisting)
        var replacement = withoutExisting
        replacement.insert(contentsOf: block, at: insertionOffset)
        // Avoid needless backups and disk writes when the user saves unchanged
        // properties and the managed block already has priority.
        if replacement != originalData {
            try save(replacement, original: original, configURL: configURL, targetURL: targetURL)
        }
        return SSHHost(
            destination: settings.updatedDestination,
            source: settings.hasExplicitUsername ? .custom : .configuration
        )
    }

    private static func managedIdentifier(_ destination: String) -> String {
        Data(destination.utf8).base64EncodedString()
    }

    private static func managedPrefixLength(in data: Data) throws -> Int {
        let beginPrefix = "# BEGIN TmuxHub SSH properties "
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        var offset = 0
        var completedOffset = 0
        var expectedEnd: String?
        for (index, line) in lines.enumerated() {
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if expectedEnd == nil {
                guard text.hasPrefix(beginPrefix) else { break }
                let identifier = String(text.dropFirst(beginPrefix.count))
                guard let decoded = Data(base64Encoded: identifier),
                    let destination = String(data: decoded, encoding: .utf8),
                    IdentifierValidator.isSSHDestination(destination)
                else { throw SSHHostConfigurationError.invalidManagedConfiguration }
                expectedEnd = "# END TmuxHub SSH properties \(identifier)"
            } else if text.hasPrefix(beginPrefix) {
                throw SSHHostConfigurationError.invalidManagedConfiguration
            }
            offset += line.count + (index < lines.count - 1 ? 1 : 0)
            if text == expectedEnd {
                expectedEnd = nil
                completedOffset = offset
            }
        }
        guard expectedEnd == nil else { throw SSHHostConfigurationError.invalidManagedConfiguration }
        return completedOffset
    }

    private static func removingManagedProperties(for destination: String, from original: Data) throws -> Data {
        let identifier = managedIdentifier(destination)
        let begin = "# BEGIN TmuxHub SSH properties \(identifier)"
        let end = "# END TmuxHub SSH properties \(identifier)"
        // Retain exact bytes, including the line endings and absence of a final
        // newline in user-owned configuration. Only complete owned blocks move.
        let lines = original.split(separator: 10, omittingEmptySubsequences: false)
        var offset = 0
        var start: Int?
        var removal: Range<Int>?
        for (index, line) in lines.enumerated() {
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let nextOffset = offset + line.count + (index < lines.count - 1 ? 1 : 0)
            if text == begin {
                guard start == nil, removal == nil else {
                    throw SSHHostConfigurationError.invalidManagedConfiguration
                }
                start = offset
            }
            if text == end {
                guard let start, removal == nil else {
                    throw SSHHostConfigurationError.invalidManagedConfiguration
                }
                removal = start..<nextOffset
            }
            offset = nextOffset
        }
        guard start == nil || removal != nil else {
            throw SSHHostConfigurationError.invalidManagedConfiguration
        }
        guard let removal else { return original }
        var result = original
        result.removeSubrange(removal)
        return result
    }

    private func addLocked(_ configuration: SSHHostConfiguration) throws -> SSHHost {
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        let configURL = sshDirectory.appendingPathComponent("config")
        let targetURL = configURL.resolvingSymlinksInPath()
        let original = try readConfiguration(at: targetURL)
        let catalog = SSHConfigCatalog(homeDirectory: homeDirectory)
        guard try !catalog.loadForConfigurationEdit().contains(where: {
            $0.destination.caseInsensitiveCompare(configuration.alias) == .orderedSame
        }) else {
            throw SSHHostConfigurationError.duplicateAlias(configuration.alias)
        }

        var lines = [
            "# Added by TmuxHub",
            "Host \(configuration.alias)",
            "    HostName \(configuration.hostname.replacingOccurrences(of: "%", with: "%%"))",
        ]
        if !configuration.username.isEmpty {
            lines.append("    User \(configuration.username)")
        }
        lines.append("    Port \(configuration.port)")
        if let identityFile = configuration.identityFile {
            let expanded = identityFile.hasPrefix("~/")
                ? homeDirectory.appendingPathComponent(String(identityFile.dropFirst(2))).path
                : identityFile
            lines.append("    IdentityFile \(Self.quotedPath(expanded))")
        }
        // OpenSSH takes the first value for most settings. Prepending gives the
        // new host's explicit settings priority; Host * restores the original
        // global scope instead of making old global directives host-specific.
        lines.append(contentsOf: ["", "Host *", ""])
        let block = Data((lines.joined(separator: "\n") + "\n").utf8)
        var replacement = original?.data ?? Data()
        replacement.insert(contentsOf: block, at: try Self.managedPrefixLength(in: replacement))
        try save(replacement, original: original, configURL: configURL, targetURL: targetURL)
        return SSHHost(destination: configuration.alias, source: .configuration)
    }

    private func save(
        _ replacement: Data, original: ExistingConfiguration?, configURL: URL, targetURL: URL
    ) throws {
        guard replacement.count <= Self.maximumConfigurationBytes else {
            throw SSHHostConfigurationError.unreadableConfiguration
        }
        let manager = FileManager.default
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        if !manager.fileExists(atPath: sshDirectory.path) {
            try manager.createDirectory(
                at: sshDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let parent = targetURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let temporaryURL = parent.appendingPathComponent(".tmuxhub-config-\(token)")
        try Self.writeExclusive(replacement, to: temporaryURL, permissions: original?.permissions ?? 0o600)
        defer { try? manager.removeItem(at: temporaryURL) }

        // Detect edits while validation and preparation were in progress.
        guard try readConfiguration(at: targetURL) == original,
            configURL.resolvingSymlinksInPath() == targetURL
        else { throw SSHHostConfigurationError.configurationChanged }
        if let original {
            let backupURL = parent.appendingPathComponent("config.tmuxhub-backup-\(token)")
            try Self.writeExclusive(original.data, to: backupURL, permissions: 0o600)
        }
        let result = temporaryURL.path.withCString { source in
            targetURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private struct ExistingConfiguration: Equatable {
        let data: Data
        let permissions: mode_t
        let fileNumber: UInt64
        let modificationDate: Date?
    }

    private func readConfiguration(at url: URL) throws -> ExistingConfiguration? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber,
            size.intValue <= Self.maximumConfigurationBytes
        else { throw SSHHostConfigurationError.unreadableConfiguration }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumConfigurationBytes + 1) ?? Data()
        guard data.count <= Self.maximumConfigurationBytes,
            String(data: data, encoding: .utf8) != nil
        else { throw SSHHostConfigurationError.unreadableConfiguration }
        return ExistingConfiguration(
            data: data,
            permissions: mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600),
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private static func quotedPath(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func writeExclusive(_ data: Data, to url: URL, permissions: mode_t) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard Darwin.fchmod(descriptor, permissions) == 0, Darwin.fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
