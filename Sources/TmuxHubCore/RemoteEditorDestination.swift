import CryptoKit
import Darwin
import Foundation

public enum RemoteEditorError: LocalizedError, Equatable, Sendable {
    case invalidDestination
    case invalidPath
    case invalidConfiguration
    case configurationChanged
    case unsupportedNode

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: "无法识别此终端的 SSH 连接。"
        case .invalidPath: "VS Code 需要有效的远端绝对路径。"
        case .invalidConfiguration: "无法安全读取或保存 VS Code 所需的 SSH 配置。"
        case .configurationChanged: "SSH 配置已发生变化，请重新运行 code。"
        case .unsupportedNode: "无法确认此终端的实际登录节点，未打开其他节点上的同名路径。"
        }
    }
}

public struct RemoteEditorDestination: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder }

    public let sshDestination: String
    public let absolutePath: String
    public let kind: Kind
    public let uri: URL

    public init(sshDestination: String, absolutePath: String, kind: Kind) throws {
        guard IdentifierValidator.isSSHDestination(sshDestination) else {
            throw RemoteEditorError.invalidDestination
        }
        guard absolutePath.hasPrefix("/"), absolutePath.utf8.count <= 16_384,
            !absolutePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw RemoteEditorError.invalidPath }
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let host = sshDestination.addingPercentEncoding(withAllowedCharacters: unreserved),
            let path = absolutePath.addingPercentEncoding(
                withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "/"))),
            let uri = URL(string: "vscode-remote://ssh-remote+\(host)\(path)")
        else { throw RemoteEditorError.invalidPath }
        self.sshDestination = sshDestination
        self.absolutePath = absolutePath
        self.kind = kind
        self.uri = uri
    }

    /// Launch the local VS Code CLI with arguments, never a shell command.
    /// Explicit resource kinds avoid guessing that a dotted folder is a file.
    public var cliArguments: [String] {
        [kind == .folder ? "--folder-uri" : "--file-uri", uri.absoluteString]
    }
}

/// A pinned login node needs its own alias that VS Code's independent SSH
/// process can resolve. Values come only from the local `ssh -G` output.
public struct RemoteEditorSSHConfiguration: Sendable {
    private static let lock = NSLock()
    private static let maximumBytes = 1_048_576
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func install(endpoint: CodexNotificationSSHEndpoint, resolvedConfiguration: String) throws -> String {
        try Self.lock.withLock {
            try installLocked(endpoint: endpoint, resolvedConfiguration: resolvedConfiguration)
        }
    }

    static func alias(for endpoint: CodexNotificationSSHEndpoint) -> String {
        let identity = [endpoint.destination, endpoint.address, endpoint.hostKeyAlias].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "tmuxhub-code-" + hash.prefix(24)
    }

    static func configuration(endpoint: CodexNotificationSSHEndpoint, resolvedConfiguration: String) throws -> String {
        guard endpoint.isValid, resolvedConfiguration.utf8.count <= maximumBytes else {
            throw RemoteEditorError.invalidConfiguration
        }
        let properties = try SSHHostPropertiesReader.parse(resolvedConfiguration, destination: endpoint.destination)
        guard properties.hostname.lowercased() == endpoint.hostKeyAlias.lowercased() else {
            throw RemoteEditorError.unsupportedNode
        }
        _ = try SSHHostConfiguration(alias: "validation", hostname: properties.hostname,
            username: properties.username, port: properties.port)

        // Retain authentication and transport policy. Do not replay session
        // commands, tunnels, agent forwarding, or another app's control socket.
        let allowed: Set<String> = [
            "identityfile", "certificatefile", "identityagent", "identitiesonly",
            "proxyjump", "proxycommand", "proxyusefdpass", "pubkeyauthentication",
            "preferredauthentications", "passwordauthentication", "kbdinteractiveauthentication",
            "hostbasedauthentication", "gssapiauthentication", "gssapidelegatecredentials",
            "usekeychain", "connectionattempts", "connecttimeout", "serveraliveinterval",
            "serveralivecountmax", "tcpkeepalive", "bindaddress", "bindinterface",
            "addressfamily", "compression", "ciphers", "macs", "kexalgorithms",
            "hostkeyalgorithms", "pubkeyacceptedalgorithms", "casignaturealgorithms",
            "requiredrsasize", "rekeylimit", "userknownhostsfile", "globalknownhostsfile",
            "verifyhostkeydns", "fingerprinthash", "hashknownhosts", "checkhostip",
            "updatehostkeys", "revokedhostkeys", "securitykeyprovider", "pkcs11provider",
        ]
        let pathValues: Set<String> = ["identityfile", "certificatefile", "identityagent", "revokedhostkeys"]
        let originalHost = String(endpoint.destination.split(separator: "@").last ?? Substring(endpoint.destination))
        var lines = [
            "# Managed by TmuxHub: local VS Code opens this exact login node.",
            "Host \(alias(for: endpoint))",
            "    HostName \(endpoint.address)",
            "    HostKeyAlias \(endpoint.hostKeyAlias)",
            "    User \(properties.username)",
            "    Port \(properties.port)",
            "    StrictHostKeyChecking yes",
            "    ControlMaster no",
            "    ControlPath none",
            "    ControlPersist no",
            "    ForwardAgent no",
            "    ForwardX11 no",
            "    ForwardX11Trusted no",
            "    PermitLocalCommand no",
            "    RemoteCommand none",
            "    RequestTTY no",
            "    SessionType default",
        ]
        for rawLine in resolvedConfiguration.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !rawLine.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\t"
            }) else { throw RemoteEditorError.invalidConfiguration }
            let fields = rawLine.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let key = fields[0].lowercased()
            guard allowed.contains(key) else { continue }
            var value = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw RemoteEditorError.invalidConfiguration }
            value = replaceOriginalHostToken(value, with: originalHost)
            if pathValues.contains(key) {
                // Credential paths continue to refer to the original SSH alias.
                value = replaceToken(value, token: "h", with: properties.hostname)
                value = quote(value)
            }
            lines.append("    \(key) \(value)")
        }
        lines += ["Host *", ""]
        return lines.joined(separator: "\n")
    }

    private func installLocked(endpoint: CodexNotificationSSHEndpoint, resolvedConfiguration: String) throws -> String {
        let alias = Self.alias(for: endpoint)
        let content = try Self.configuration(endpoint: endpoint, resolvedConfiguration: resolvedConfiguration)
        let manager = FileManager.default
        let ssh = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        let directory = ssh.appendingPathComponent("tmuxhub-code", isDirectory: true)
        let config = ssh.appendingPathComponent("config")
        let target = config.resolvingSymlinksInPath()
        let original = try Self.read(target)
        let includePath = directory.appendingPathComponent("*.conf").path
        guard !includePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteEditorError.invalidConfiguration
        }
        let prefix = "# BEGIN TmuxHub remote editor\nInclude \(Self.quote(includePath))\nHost *\n# END TmuxHub remote editor\n"
        let existing = original?.data ?? Data()
        guard let text = String(data: existing, encoding: .utf8) else { throw RemoteEditorError.invalidConfiguration }
        let hasMarker = text.contains("# BEGIN TmuxHub remote editor") || text.contains("# END TmuxHub remote editor")
        guard !hasMarker || text.hasPrefix(prefix) else { throw RemoteEditorError.invalidConfiguration }
        let replacement = text.hasPrefix(prefix) ? existing : Data(prefix.utf8) + existing
        guard replacement.count <= Self.maximumBytes else { throw RemoteEditorError.invalidConfiguration }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw RemoteEditorError.invalidConfiguration
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let managed = directory.appendingPathComponent(alias + ".conf")
        try Self.atomicWrite(Data(content.utf8), to: managed, permissions: 0o600)
        if replacement != existing {
            guard try Self.read(target) == original, config.resolvingSymlinksInPath() == target else {
                throw RemoteEditorError.configurationChanged
            }
            try Self.atomicWrite(replacement, to: target, permissions: original?.permissions ?? 0o600)
        }
        return alias
    }

    private struct Snapshot: Equatable {
        let data: Data
        let permissions: Int
        let inode: UInt64
        let modified: Date?
    }

    private static func read(_ url: URL) throws -> Snapshot? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw RemoteEditorError.invalidConfiguration
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw RemoteEditorError.invalidConfiguration }
        return Snapshot(data: data,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date)
    }

    private static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmuxhub-code-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func replaceOriginalHostToken(_ value: String, with hostname: String) -> String {
        replaceToken(value, token: "n", with: hostname)
    }

    private static func replaceToken(_ value: String, token: Character, with replacement: String) -> String {
        let characters = Array(value)
        var result = "", index = 0
        while index < characters.count {
            if characters[index] == "%", index + 1 < characters.count {
                let next = characters[index + 1]
                result += next == token ? replacement.replacingOccurrences(of: "%", with: "%%") : "%\(next)"
                index += 2
            } else { result.append(characters[index]); index += 1 }
        }
        return result
    }
}
