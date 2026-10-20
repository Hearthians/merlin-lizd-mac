import Foundation

public struct RemoteFileEntry: Codable, Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isFile: Bool
    public let size: Int64
    public let modified: Double
}

public struct RemoteFileListing: Codable, Sendable {
    public let path: String
    public let entries: [RemoteFileEntry]
}

public enum RemoteFileError: LocalizedError {
    case failed(String)
    case destinationExists
    public var errorDescription: String? {
        switch self {
        case let .failed(message): message
        case .destinationExists: "本地已有同名项目，请选择其他位置或重命名。"
        }
    }
}

/// Read-only remote browsing and SFTP downloads over the app's authenticated master.
public struct RemoteFileService: Sendable {
    private let pool: SSHMasterPool
    public init(pool: SSHMasterPool) { self.pool = pool }

    static let listingScript = #"""
    import os, sys, json, stat
    p = os.path.realpath(os.path.expanduser(sys.argv[1]))
    rows = []
    with os.scandir(p) as items:
        for e in items:
            if len(rows) >= 20000:
                raise RuntimeError('Directory exceeds 20000 entries; open a subdirectory by path')
            try:
                s = e.stat()
                rows.append(dict(name=e.name, path=e.path, isDirectory=stat.S_ISDIR(s.st_mode),
                                 isFile=stat.S_ISREG(s.st_mode), size=s.st_size, modified=s.st_mtime))
            except FileNotFoundError:
                pass
    print(json.dumps(dict(path=p, entries=rows)))
    """#

    static func listingCommand(alias: String, path: String) throws -> CommandSpec {
        guard IdentifierValidator.isSSHDestination(alias) else { throw AttachmentError.invalidPath }
        let script = "'" + listingScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let argument = try AttachmentPaths.shellQuote(path)
        return CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-T", "-o", "BatchMode=yes", alias, "python3 -c \(script) \(argument)",
        ])
    }

    public func list(alias: String, path: String) async throws -> RemoteFileListing {
        let command = try Self.listingCommand(alias: alias, path: path)
        let output = try await pool.run(command, alias: alias, replay: .readOnly)
        guard output.exitCode == 0 else {
            throw RemoteFileError.failed("无法读取目录（远端需安装 Python 3）：\n" + String(output.stderr.suffix(1600)))
        }
        return try JSONDecoder().decode(RemoteFileListing.self, from: Data(output.stdout.utf8))
    }

    // Share the OpenSSH batch lexer quoting used by attachment downloads.
    static func quote(_ path: String) throws -> String {
        try AttachmentPaths.sftpQuote(path)
    }

    static func batch(path: String, directory: Bool, local: String) throws -> String {
        guard path.hasPrefix("/") else { throw AttachmentError.invalidPath }
        return "get \(directory ? "-R " : "")\(try quote(path)) \(try quote(local))\n"
    }

    public func download(alias: String, path: String, directory: Bool, destination: URL) async throws {
        guard destination.isFileURL else { throw AttachmentError.invalidPath }
        try AttachmentPaths.validate(destination.path)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw RemoteFileError.destinationExists }
        // Stage beside the destination: failures/cancellation never leave a completed-looking download.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmuxhub-download-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("payload")
        let batchFile = staging.appendingPathComponent("transfer.batch")
        let text = try Self.batch(path: path, directory: directory, local: partial.path)
        try Data(text.utf8).write(to: batchFile)
        let output = try await pool.transfer(batchFile: batchFile, alias: alias)
        guard output.exitCode == 0 else {
            throw RemoteFileError.failed("下载失败：\n" + String(output.stderr.suffix(1600)))
        }
        try Task.checkCancellation()
        guard fm.fileExists(atPath: partial.path) else { throw AttachmentError.downloadFailed }
        // moveItem refuses an existing target, including one created during the transfer.
        try fm.moveItem(at: partial, to: destination)
    }
}
