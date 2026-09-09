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

public enum AttachmentError: LocalizedError, Sendable {
    case invalidPath
    case regularFileRequired
    case tooLarge
    case contextUnavailable
    case connectionFailed
    case transferFailed
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "路径无效：请使用绝对路径，且不能包含控制字符。"
        case .regularFileRequired: "只支持普通文件；文件夹、软件包和符号链接请先打包。"
        case .tooLarge: "单个附件不能超过 100 MB。"
        case .contextUnavailable: "无法确定终端当前目录。请确认会话已连接，再重试。"
        case .connectionFailed: "SSH 连接不可用；请先完成认证，再重试上传。"
        case .transferFailed: "附件传输失败；请检查 SFTP 支持、目录权限和可用空间。"
        case .downloadFailed: "文件下载失败；请检查远端路径、SFTP 支持和本地目录权限。"
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

    public init(
        target: TerminalTarget, sessionName: String?, paneID: String?,
        processName: String?, workingDirectory: String,
        herdrReference: HerdrTerminalReference? = nil,
        herdrOccupantID: String? = nil
    ) {
        self.target = target
        self.sessionName = sessionName
        self.paneID = paneID
        self.processName = processName
        self.workingDirectory = workingDirectory
        self.herdrReference = herdrReference
        self.herdrOccupantID = herdrOccupantID
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
        _ output: String, target: TerminalTarget, sessionName: String
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
            processName: String(fields[1]), workingDirectory: directory
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
        herdrReference: HerdrTerminalReference? = nil
    ) async throws -> AttachmentContext {
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
        let pool = pool
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
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: partial)
        }
        let batchURL = staging.appendingPathComponent("download.batch")
        let batch = try AttachmentPaths.downloadBatch(
            remotePath: resolved,
            localPath: partial.path
        )
        try Data(batch.utf8).write(to: batchURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: batchURL.path
        )

        let pool = pool
        do {
            let output = try await limit.run {
                try await pool.transfer(batchFile: batchURL, alias: alias)
            }
            guard output.exitCode == 0 else { throw AttachmentError.downloadFailed }
            try Task.checkCancellation()
            let info = try partial.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard info.isRegularFile == true, info.isSymbolicLink != true else {
                throw AttachmentError.downloadFailed
            }
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AttachmentError {
            throw error
        } catch {
            throw AttachmentError.downloadFailed
        }
    }

    /// Resolve a terminal link before showing the Save panel. Agent dashboards
    /// can run from `$HOME` while their active workspace lives deeper below it,
    /// making tmux's `pane_current_path` an incomplete base for relative output.
    /// Prefer the exact pane-relative path; if it is absent, inspect the common
    /// one- and two-directory workspace layouts below `$HOME`, accepting only a
    /// unique file with the same full relative suffix.
    public func resolveDownloadPath(
        _ remotePath: String,
        context: AttachmentContext
    ) async throws -> String {
        let resolved = try AttachmentPaths.resolvedRemotePath(
            remotePath,
            workingDirectory: context.workingDirectory
        )
        switch context.target {
        case .local:
            guard FileManager.default.fileExists(atPath: resolved) else {
                throw AttachmentError.downloadFailed
            }
            return resolved
        case let .ssh(alias):
            // A Herdr reference already identifies the exact project. A missing
            // file must not silently resolve to another workspace under HOME.
            let relative = context.herdrReference == nil
                ? try AttachmentPaths.searchableRelativePath(remotePath) : nil
            let candidate = try AttachmentPaths.shellQuote(resolved)
            var script = "candidate=\(candidate); "
                + "if [ -f \"$candidate\" ]; then "
                + "printf '%s\\n' \"$candidate\"; exit 0; fi"
            if let relative {
                script += "; relative="
                    + (try AttachmentPaths.shellQuote(relative))
                    + "; for root in \"$HOME\" \"$HOME\"/* \"$HOME\"/*/*; do "
                    + "[ -d \"$root\" ] || continue; "
                    + "candidate=\"$root/$relative\"; "
                    + "[ -f \"$candidate\" ] && printf '%s\\n' \"$candidate\"; "
                    + "done; exit 0"
            } else {
                script += "; exit 1"
            }
            let command = CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                alias, script,
            ])
            let output: InventoryProcessOutput
            do {
                output = try await pool.run(command, alias: alias, replay: .readOnly)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AttachmentError.downloadFailed
            }
            guard output.exitCode == 0 else { throw AttachmentError.downloadFailed }
            let suffix = relative.map { "/" + $0 }
            var matches: [String] = []
            var seen: Set<String> = []
            for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                let path = String(line)
                guard (try? AttachmentPaths.validate(path)) != nil else { continue }
                let standardized = (path as NSString).standardizingPath
                guard standardized == resolved
                    || suffix.map({ standardized.hasSuffix($0) }) == true
                else { continue }
                if seen.insert(standardized).inserted { matches.append(standardized) }
            }
            guard matches.count == 1, let match = matches.first else {
                throw AttachmentError.downloadFailed
            }
            return match
        }
    }
}
