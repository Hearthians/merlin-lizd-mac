import Darwin
import Foundation

public enum LocalProcessDirectory {
    /// Read the local shell's actual cwd even when it does not emit OSC 7.
    public static func path(processID: pid_t) -> String? {
        guard processID > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let count = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, count) == count else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            let path = String(decoding: bytes[..<end], as: UTF8.self)
            return path.hasPrefix("/") ? path : nil
        }
    }
}

public enum AttachmentError: LocalizedError, Equatable, Sendable {
    case invalidPath
    case regularFileRequired
    case tooLarge
    case contextUnavailable
    case connectionFailed
    case transferFailed
    case fileNotFound(String)
    case ambiguousRemotePath(String)
    case remotePathLookupFailed
    case sftpDownloadFailed(String)
    case localSaveFailed(String)
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            "路径无效：请使用绝对路径，且不能包含控制字符。"
        case .regularFileRequired:
            "只支持普通文件；文件夹、软件包和符号链接请先打包。"
        case .tooLarge:
            "单个附件不能超过 100 MB。"
        case .contextUnavailable:
            "无法确定终端当前目录。请确认会话已连接，再重试。"
        case .connectionFailed:
            "SSH 连接不可用；请先完成认证，再重试文件传输。"
        case .transferFailed:
            "附件传输失败；请检查 SFTP 支持、目录权限和可用空间。"
        case let .fileNotFound(path):
            "找不到文件：\(path)。如果文件位于容器或计算节点，请先复制到 SSH 登录主机可见的目录。"
        case let .ambiguousRemotePath(path):
            "找到多个匹配文件，无法确定要下载哪一个：\(path)。请使用绝对路径。"
        case .remotePathLookupFailed:
            "无法在远端确认文件位置；请检查 SSH 连接后重试。"
        case let .sftpDownloadFailed(path):
            "已定位文件，但 SFTP 无法读取：\(path)。请检查远端权限，并确认文件对 SSH 登录主机可见。"
        case let .localSaveFailed(path):
            "无法写入本地位置：\(path)。请检查目录权限和可用空间。"
        case .downloadFailed:
            "文件下载失败；请检查远端路径、SFTP 支持和本地目录权限。"
        }
    }
}

public struct AttachmentContext: Equatable, Sendable {
    public let target: TerminalTarget
    public let sessionName: String?
    public let paneID: String?
    public let processName: String?
    public let workingDirectory: String
    public let herdrReference: HerdrTerminalReference?
    public let herdrOccupantID: String?
    public let sshEndpoint: CodexNotificationSSHEndpoint?

    public init(
        target: TerminalTarget, sessionName: String?, paneID: String?,
        processName: String?, workingDirectory: String,
        herdrReference: HerdrTerminalReference? = nil,
        herdrOccupantID: String? = nil,
        sshEndpoint: CodexNotificationSSHEndpoint? = nil
    ) {
        self.target = target
        self.sessionName = sessionName
        self.paneID = paneID
        self.processName = processName
        self.workingDirectory = workingDirectory
        self.herdrReference = herdrReference
        self.herdrOccupantID = herdrOccupantID
        self.sshEndpoint = sshEndpoint
    }
}

public enum AttachmentPaths {
    public static let maximumFileBytes = 100 * 1_024 * 1_024

    public static func validate(_ path: String) throws {
        guard path.hasPrefix("/"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AttachmentError.invalidPath }
    }

    public static func shellQuote(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AttachmentError.invalidPath }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func insertionText(_ paths: [String]) throws -> String {
        try paths.map { path in
            try validate(path)
            return try shellQuote(path)
        }.joined(separator: " ") + " "
    }

    /// OpenSSH's quoted-token lexer already protects glob characters. Only
    /// backslash and the enclosing quote need escaping here; escaping a quoted
    /// wildcard twice changes the actual filename (see sftp.c makeargv).
    static func sftpQuote(_ path: String) throws -> String {
        try validate(path)
        var result = "\""
        for character in path {
            if "\\\"".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result + "\""
    }

    static func sftpDestination(_ destination: String) -> String {
        guard destination.contains(":"), !destination.contains("[") else { return destination }
        if let at = destination.lastIndex(of: "@") {
            return String(destination[...at]) + "[" + destination[destination.index(after: at)...] + "]"
        }
        return "[\(destination)]"
    }

    public static func inspectFile(_ url: URL) throws -> Int {
        guard url.isFileURL else { throw AttachmentError.regularFileRequired }
        try validate(url.path)
        let info = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
        ])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
            info.isPackage != true else { throw AttachmentError.regularFileRequired }
        guard let size = info.fileSize, size <= maximumFileBytes else {
            throw AttachmentError.tooLarge
        }
        return size
    }

    static func parseContext(
        _ output: String, target: TerminalTarget, sessionName: String,
        sshEndpoint: CodexNotificationSSHEndpoint? = nil
    ) throws -> AttachmentContext {
        let line = output.hasSuffix("\n") ? String(output.dropLast()) : output
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3,
            fields[0].first == "%", fields[0].dropFirst().allSatisfy(\.isNumber),
            fields[0].count > 1 else { throw AttachmentError.contextUnavailable }
        let directory = String(fields[2])
        try validate(directory)
        return AttachmentContext(
            target: target, sessionName: sessionName, paneID: String(fields[0]),
            processName: String(fields[1]), workingDirectory: directory, sshEndpoint: sshEndpoint
        )
    }

    static func batch(localURL: URL, base: String, token: String) throws -> (text: String, path: String) {
        // Tokens are generated locally and never supplied by a remote peer.
        guard UUID(uuidString: token) != nil else { throw AttachmentError.invalidPath }
        try validate(base)
        let parent = (base as NSString).appendingPathComponent(".tmuxhub")
        let attachments = (parent as NSString).appendingPathComponent("attachments")
        let directory = (attachments as NSString).appendingPathComponent(token)
        let partial = (directory as NSString).appendingPathComponent(".partial-\(token)")
        let final = (directory as NSString).appendingPathComponent(localURL.lastPathComponent)
        let lines = [
            "-mkdir \(try sftpQuote(parent))",
            "-mkdir \(try sftpQuote(attachments))",
            "mkdir \(try sftpQuote(directory))",
            "chmod 700 \(try sftpQuote(directory))",
            "put \(try sftpQuote(localURL.path)) \(try sftpQuote(partial))",
            "chmod 600 \(try sftpQuote(partial))",
            "rename \(try sftpQuote(partial)) \(try sftpQuote(final))",
        ]
        return (lines.joined(separator: "\n") + "\n", final)
    }

    static func downloadBatch(remotePath: String, localPath: String) throws -> String {
        try validate(remotePath)
        try validate(localPath)
        return "get \(try sftpQuote(remotePath)) \(try sftpQuote(localPath))\n"
    }

    public static func resolvedRemotePath(_ link: String, workingDirectory: String) throws -> String {
        try validate(workingDirectory)
        let path = try linkPath(link)
        guard !path.hasPrefix("~/") else { throw AttachmentError.invalidPath }
        let absolute = path.hasPrefix("/")
            ? path
            : (workingDirectory as NSString).appendingPathComponent(path)
        let normalized = (absolute as NSString).standardizingPath
        try validate(normalized)
        return normalized
    }

    static func searchableRelativePath(_ link: String) throws -> String? {
        let path = try linkPath(link)
        guard !path.hasPrefix("/"), !path.hasPrefix("~/") else { return nil }
        let normalized = (path as NSString).standardizingPath
        guard normalized != ".", normalized != "..",
            !normalized.hasPrefix("../"), !normalized.hasPrefix("/")
        else { return nil }
        return normalized
    }

    /// Agent dashboards can start from HOME while the workspace lives below it.
    /// Prefer the exact context path, then accept only a unique full-suffix
    /// match in the existing one- and two-directory workspace layouts.
    static func lookupScript(
        resolved: String,
        relative: String?,
        includingDirectories: Bool
    ) throws -> String {
        try validate(resolved)
        let candidate = try shellQuote(resolved)
        let exists = includingDirectories
            ? "[ -f \"$candidate\" ] || [ -d \"$candidate\" ]"
            : "[ -f \"$candidate\" ]"
        var script = "candidate=\(candidate); "
            + "if \(exists); then "
            + "printf '%s\\n' \"$candidate\"; exit 0; fi"
        if let relative {
            script += "; relative=" + (try shellQuote(relative))
                + "; for root in \"$HOME\" \"$HOME\"/* \"$HOME\"/*/*; do "
                + "[ -d \"$root\" ] || continue; "
                + "candidate=\"$root/$relative\"; "
                + "if \(exists); then printf '%s\\n' \"$candidate\"; fi; "
                + "done; exit 0"
        } else {
            script += "; exit 0"
        }
        return script
    }

    static func lookupResult(
        _ output: String,
        resolved: String,
        relative: String?,
        remotePath: String
    ) throws -> String {
        let suffix = relative.map { "/" + $0 }
        var matches: [String] = []
        var seen: Set<String> = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = String(line)
            guard (try? validate(path)) != nil else { continue }
            let standardized = (path as NSString).standardizingPath
            guard standardized == resolved
                || suffix.map({ standardized.hasSuffix($0) }) == true
            else { continue }
            if seen.insert(standardized).inserted { matches.append(standardized) }
        }
        guard !matches.isEmpty else {
            throw AttachmentError.fileNotFound(resolved)
        }
        guard matches.count == 1, let match = matches.first else {
            throw AttachmentError.ambiguousRemotePath(relative ?? remotePath)
        }
        return match
    }

    private static func linkPath(_ link: String) throws -> String {
        guard !link.isEmpty,
            !link.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { throw AttachmentError.invalidPath }
        if link.hasPrefix("file:") {
            guard let url = URL(string: link), url.isFileURL else {
                throw AttachmentError.invalidPath
            }
            return url.path
        }
        return link
    }
}

/// Separate transport: never sends upload commands through the agent's PTY.
public actor AttachmentTransferService {
    private let pool: SSHMasterPool
    private let runner: any InventoryProcessRunning
    private let localTmux: String?
    private let herdr: HerdrService
    private let limit = BoundedAsyncOperationRunner(maxConcurrentOperations: 2, timeout: .seconds(300))

    public init(sshMasterPool: SSHMasterPool, herdrService: HerdrService? = nil) {
        pool = sshMasterPool
        herdr = herdrService ?? HerdrService(sshMasterPool: sshMasterPool)
        runner = TimedInventoryProcessRunner(timeout: .seconds(15), underlying: FoundationInventoryProcessRunner())
        localTmux = LocalTmuxResolver.resolve()
    }

    public func context(
        target: TerminalTarget, sessionName: String?, localDirectory: String,
        herdrReference: HerdrTerminalReference? = nil,
        notificationRoute: CodexNotificationRoute? = nil
    ) async throws -> AttachmentContext {
        if let notificationRoute {
            guard herdrReference == nil else { throw AttachmentError.contextUnavailable }
            let command = try CodexNotificationRouting.contextCommand(route: notificationRoute, target: target)
            let output: InventoryProcessOutput
            if let destination = target.sshDestination {
                do {
                    let connection = try CodexNotificationRouting.connectionPool(
                        route: notificationRoute, target: target, sshMasterPool: pool)
                    output = try await connection.run(command, alias: destination, replay: .readOnly)
                }
                catch is CancellationError { throw CancellationError() }
                catch { throw AttachmentError.connectionFailed }
            } else {
                output = try await runner.run(command)
            }
            guard output.exitCode == 0 else { throw AttachmentError.contextUnavailable }
            return try AttachmentPaths.parseContext(
                output.stdout, target: target, sessionName: notificationRoute.sessionID,
                sshEndpoint: notificationRoute.sshEndpoint
            )
        }
        if let herdrReference {
            guard sessionName == nil else { throw AttachmentError.contextUnavailable }
            let pane = try await herdr.resolve(target: target, reference: herdrReference)
            guard let directory = pane.workingDirectory else {
                throw AttachmentError.contextUnavailable
            }
            try AttachmentPaths.validate(directory)
            return AttachmentContext(
                target: target, sessionName: nil, paneID: pane.paneID,
                processName: pane.agent, workingDirectory: directory,
                herdrReference: herdrReference,
                herdrOccupantID: pane.occupantID
            )
        }
        guard let sessionName else {
            guard target == .local else { throw AttachmentError.contextUnavailable }
            try AttachmentPaths.validate(localDirectory)
            return AttachmentContext(
                target: .local, sessionName: nil, paneID: nil, processName: nil,
                workingDirectory: localDirectory
            )
        }
        guard let sessionName = IdentifierValidator.normalizedTmuxSessionName(sessionName) else {
            throw AttachmentError.contextUnavailable
        }
        let arguments = [
            "display-message", "-p", "-t", "=\(sessionName):",
            "#{pane_id}\t#{pane_current_command}\t#{pane_current_path}",
        ]
        let output: InventoryProcessOutput
        switch target {
        case .local:
            guard let localTmux else { throw AttachmentError.contextUnavailable }
            output = try await runner.run(CommandSpec(executable: localTmux, arguments: arguments))
        case let .ssh(destination):
            let remote = (["tmux"] + arguments).map { value -> String in
                // The format includes literal tabs, generated by us rather than user paths.
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
            let command = CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", destination, remote,
            ])
            do { output = try await pool.run(command, alias: destination, replay: .readOnly) }
            catch is CancellationError { throw CancellationError() }
            catch { throw AttachmentError.connectionFailed }
        }
        guard output.exitCode == 0 else { throw AttachmentError.contextUnavailable }
        return try AttachmentPaths.parseContext(output.stdout, target: target, sessionName: sessionName)
    }

    public func transfer(
        file: URL, screenshot: Bool, context: AttachmentContext, directoryOverride: String
    ) async throws -> String {
        let scope = file.startAccessingSecurityScopedResource()
        defer { if scope { file.stopAccessingSecurityScopedResource() } }
        _ = try AttachmentPaths.inspectFile(file)
        try Task.checkCancellation()
        if context.target == .local, !screenshot { return file.path }
        let base = directoryOverride.isEmpty ? context.workingDirectory : directoryOverride
        try AttachmentPaths.validate(base)
        let token = UUID().uuidString.lowercased()
        if context.target == .local {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AttachmentError.invalidPath
            }
            let directory = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(".tmuxhub/attachments/\(token)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination.path
        }
        guard let destination = context.target.sshDestination else { throw AttachmentError.contextUnavailable }
        let batch = try AttachmentPaths.batch(localURL: file, base: base, token: token)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-sftp-\(token)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let batchURL = staging.appendingPathComponent("transfer.batch")
        try Data(batch.text.utf8).write(to: batchURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: batchURL.path)
        let pool = try connectionPool(for: context)
        do {
            let output = try await limit.run {
                try await pool.transfer(batchFile: batchURL, alias: destination)
            }
            guard output.exitCode == 0 else { throw AttachmentError.transferFailed }
            try Task.checkCancellation()
            return batch.path
        } catch is CancellationError { throw CancellationError() }
        catch let error as AttachmentError { throw error }
        catch { throw AttachmentError.transferFailed }
    }

    private func connectionPool(for context: AttachmentContext) throws -> SSHMasterPool {
        guard let endpoint = context.sshEndpoint else { return pool }
        guard endpoint.destination == context.target.sshDestination else {
            throw AttachmentError.contextUnavailable
        }
        return try pool.pinned(to: endpoint)
    }

    public func download(
        remotePath: String,
        context: AttachmentContext,
        destination: URL
    ) async throws {
        guard let alias = context.target.sshDestination else {
            throw AttachmentError.contextUnavailable
        }
        let resolved = try AttachmentPaths.resolvedRemotePath(
            remotePath,
            workingDirectory: context.workingDirectory
        )
        guard destination.isFileURL else { throw AttachmentError.invalidPath }
        try AttachmentPaths.validate(destination.path)
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw AttachmentError.invalidPath }

        let token = UUID().uuidString.lowercased()
        let partial = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tmuxhub-\(token).partial"
        )
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-sftp-download-\(token)")
        do {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AttachmentError.localSaveFailed(destination.path)
        }
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: partial)
        }
        let batchURL = staging.appendingPathComponent("download.batch")
        let batch = try AttachmentPaths.downloadBatch(
            remotePath: resolved,
            localPath: partial.path
        )
        do {
            try Data(batch.utf8).write(to: batchURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: batchURL.path
            )
        } catch {
            throw AttachmentError.localSaveFailed(destination.path)
        }

        let pool = try connectionPool(for: context)
        let output: InventoryProcessOutput
        do {
            output = try await limit.runWithoutTimeout {
                try await pool.transfer(batchFile: batchURL, alias: alias)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AttachmentError.sftpDownloadFailed(resolved)
        }
        guard output.exitCode == 0 else {
            throw AttachmentError.sftpDownloadFailed(resolved)
        }
        try Task.checkCancellation()

        let info: URLResourceValues
        do {
            info = try partial.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
        } catch {
            throw AttachmentError.sftpDownloadFailed(resolved)
        }
        guard info.isRegularFile == true, info.isSymbolicLink != true else {
            throw AttachmentError.sftpDownloadFailed(resolved)
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: partial.path
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: partial,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } catch {
            throw AttachmentError.localSaveFailed(destination.path)
        }
    }

    /// Resolve a terminal file link before showing the Save panel. The remote
    /// lookup accepts regular files only, preserving download behavior.
    public func resolveDownloadPath(
        _ remotePath: String,
        context: AttachmentContext
    ) async throws -> String {
        try await resolvePath(remotePath, context: context, includingDirectories: false)
    }

    /// Resolve a file or directory link for browsing in SFTP Downloader. The
    /// captured terminal context remains the first and authoritative location.
    public func resolveBrowsePath(
        _ remotePath: String,
        context: AttachmentContext
    ) async throws -> String {
        try await resolvePath(remotePath, context: context, includingDirectories: true)
    }

    private func resolvePath(
        _ remotePath: String,
        context: AttachmentContext,
        includingDirectories: Bool
    ) async throws -> String {
        let resolved = try AttachmentPaths.resolvedRemotePath(
            remotePath,
            workingDirectory: context.workingDirectory
        )
        switch context.target {
        case .local:
            guard FileManager.default.fileExists(atPath: resolved) else {
                throw AttachmentError.fileNotFound(resolved)
            }
            return resolved
        case let .ssh(alias):
            // A Herdr reference already identifies the exact project. A missing
            // path must not silently resolve to another workspace under HOME.
            let relative = context.herdrReference == nil
                ? try AttachmentPaths.searchableRelativePath(remotePath) : nil
            let script = try AttachmentPaths.lookupScript(
                resolved: resolved,
                relative: relative,
                includingDirectories: includingDirectories
            )
            let command = CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                alias, script,
            ])
            let output: InventoryProcessOutput
            do {
                output = try await connectionPool(for: context).run(command, alias: alias, replay: .readOnly)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AttachmentError.remotePathLookupFailed
            }
            guard output.exitCode == 0 else {
                throw AttachmentError.remotePathLookupFailed
            }
            return try AttachmentPaths.lookupResult(
                output.stdout,
                resolved: resolved,
                relative: relative,
                remotePath: remotePath
            )
        }
    }
}
