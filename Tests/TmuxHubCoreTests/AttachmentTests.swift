import Darwin
import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Attachment transport and path safety")
struct AttachmentTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-attachment-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @Test("insertion preserves shell metacharacters and never sends Enter")
    func insertionQuoting() async throws {
        let path = "/tmp/中文 screenshot ' \" $(false); [x]*?.png"
        let insertion = try AttachmentPaths.insertionText([path])
        #expect(!insertion.contains("\n"))
        #expect(!insertion.contains("\r"))
        #expect(insertion.hasSuffix(" "))
        let result = try await FoundationInventoryProcessRunner().run(CommandSpec(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' " + insertion]
        ))
        #expect(result.exitCode == 0)
        #expect(result.stdout == path)
    }

    @Test("rejects control characters and relative paths")
    func unsafePaths() {
        for path in ["relative.png", "/tmp/a\nput /secret /remote", "/tmp/a\r", "/tmp/a\t", "/tmp/a\u{1b}"] {
            #expect(throws: AttachmentError.self) { try AttachmentPaths.insertionText([path]) }
        }
    }

    @Test("reads local cwd without relying on shell escape sequences")
    func localWorkingDirectory() {
        #expect(LocalProcessDirectory.path(processID: getpid()) == FileManager.default.currentDirectoryPath)
        #expect(LocalProcessDirectory.path(processID: -1) == nil)
    }

    @Test("parses exact tmux pane context and rejects ambiguous output")
    func paneContext() throws {
        let context = try AttachmentPaths.parseContext("%12\tzsh\t/home/user/my project\n", target: .local, sessionName: "main")
        #expect(context.paneID == "%12")
        #expect(context.processName == "zsh")
        #expect(context.workingDirectory == "/home/user/my project")
        for output in ["%\tzsh\t/tmp", "%1\tzsh\trelative", "%1\tzsh\t/tmp\nextra", "%1\tzsh\t/tmp\tbad"] {
            #expect(throws: AttachmentError.self) {
                try AttachmentPaths.parseContext(output, target: .local, sessionName: "main")
            }
        }
    }

    @Test("SFTP shares the prepared socket and cannot silently start another connection")
    func sharedMaster() throws {
        let commands = SSHMasterCommands(directory: URL(fileURLWithPath: "/tmp/th-transfer"))
        let master = try commands.prepare(alias: "lizd@gfyh.fun")
        #expect(master.arguments.contains("ServerAliveInterval=15"))
        #expect(master.arguments.contains("ServerAliveCountMax=3"))
        let command = try commands.sftp(batchFile: URL(fileURLWithPath: "/tmp/batch"), alias: "lizd@gfyh.fun")
        #expect(command.executable == "/usr/bin/sftp")
        #expect(command.arguments.contains("ControlPath=\(try commands.socketPath(alias: "lizd@gfyh.fun"))"))
        #expect(command.arguments.contains("ProxyCommand=/usr/bin/false"))
        #expect(command.arguments.contains("BatchMode=yes"))
        #expect(command.arguments.contains("ServerAliveInterval=15"))
        #expect(command.arguments.contains("ServerAliveCountMax=3"))
        #expect(command.environment.isEmpty)
        #expect(AttachmentPaths.sftpDestination("user@2001:db8::1") == "user@[2001:db8::1]")
        #expect(AttachmentPaths.sftpDestination("[::1]") == "[::1]")
        #expect(throws: SSHMasterCommandError.self) {
            try commands.sftp(batchFile: URL(fileURLWithPath: "/tmp/batch"), alias: "-bad")
        }
    }

    @Test("local references stay in place; screenshots receive private durable copies")
    func localTransfer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("image.png")
        let payload = Data([0, 1, 2, 255])
        try payload.write(to: source)
        let pool = SSHMasterPool()
        let service = AttachmentTransferService(sshMasterPool: pool)
        let context = try await service.context(target: .local, sessionName: nil, localDirectory: directory.path)
        let reference = try await service.transfer(file: source, screenshot: false, context: context, directoryOverride: "")
        #expect(reference == source.path)
        let copy = try await service.transfer(file: source, screenshot: true, context: context, directoryOverride: "")
        #expect(copy.hasPrefix(directory.path + "/.tmuxhub/attachments/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: copy)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: AttachmentError.self) { try AttachmentPaths.inspectFile(directory) }
        let symlink = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        #expect(throws: AttachmentError.self) { try AttachmentPaths.inspectFile(symlink) }
        let large = directory.appendingPathComponent("large")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(AttachmentPaths.maximumFileBytes + 1))
        try handle.close()
        #expect(throws: AttachmentError.self) { try AttachmentPaths.inspectFile(large) }
    }

    @Test("real SFTP round trips spaces, quotes, backslashes, Unicode and glob characters")
    func realSFTPRoundTrip() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("remote space ' \" 中文 [*]?{}\\", isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("local space ' \" 中文 [*]?{}\\", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        for name in ["simple.png", "中文 space ' \" [*]?{}\\ $(false);.png", ".upload-part"] {
            let source = sourceDirectory.appendingPathComponent(name)
            let payload = Data(("contents: " + name).utf8)
            try payload.write(to: source)
            let batch = try AttachmentPaths.batch(localURL: source, base: base.path, token: UUID().uuidString)
            let batchFile = directory.appendingPathComponent("batch")
            try Data(batch.text.utf8).write(to: batchFile)
            let output = try await TimedInventoryProcessRunner(timeout: .seconds(10), underlying: FoundationInventoryProcessRunner()).run(CommandSpec(
                executable: "/usr/bin/sftp", arguments: ["-D", "/usr/libexec/sftp-server", "-b", batchFile.path]
            ))
            #expect(output.exitCode == 0, "\(output.stderr)\n\(output.stdout)")
            let target = URL(fileURLWithPath: batch.path)
            #expect(try Data(contentsOf: target) == payload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == [name])
        }
    }

    @Test("resolves terminal links against the captured pane directory")
    func resolvesRemotePaths() throws {
        #expect(try AttachmentPaths.resolvedRemotePath(
            "temp_output/r256/model/38.ply",
            workingDirectory: "/home/user/project"
        ) == "/home/user/project/temp_output/r256/model/38.ply")
        #expect(try AttachmentPaths.resolvedRemotePath(
            "TRELLIS.2/log/run/results/glb_epoch0950.zip",
            workingDirectory: "/home/user/project"
        ) == "/home/user/project/TRELLIS.2/log/run/results/glb_epoch0950.zip")
        #expect(try AttachmentPaths.resolvedRemotePath(
            "../shared/mesh.ply",
            workingDirectory: "/home/user/project"
        ) == "/home/user/shared/mesh.ply")
        #expect(try AttachmentPaths.resolvedRemotePath(
            "file:///tmp/mesh%20output.ply",
            workingDirectory: "/ignored"
        ) == "/tmp/mesh output.ply")
        for value in ["", "~/secret", "bad\npath"] {
            #expect(throws: AttachmentError.self) {
                try AttachmentPaths.resolvedRemotePath(value, workingDirectory: "/tmp")
            }
        }
        #expect(try AttachmentPaths.searchableRelativePath(
            "temp_output/r256/model/38.ply"
        ) == "temp_output/r256/model/38.ply")
        #expect(try AttachmentPaths.searchableRelativePath("../shared/mesh.ply") == nil)
        #expect(try AttachmentPaths.searchableRelativePath("/tmp/mesh.ply") == nil)

        let missing = AttachmentError.fileNotFound("/remote/result.zip").localizedDescription
        #expect(missing.contains("/remote/result.zip"))
        #expect(missing.contains("容器或计算节点"))
    }

    @Test("real SFTP downloads an exact remote path into a local partial file")
    func realSFTPDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("远端 space ' \" [*]?{}\\.ply")
        let local = directory.appendingPathComponent("本地 space ' \" [*]?{}\\.ply")
        let payload = Data("ply\nformat ascii 1.0\nend_header\n".utf8)
        try payload.write(to: remote)
        let batch = try AttachmentPaths.downloadBatch(
            remotePath: remote.path,
            localPath: local.path
        )
        let batchFile = directory.appendingPathComponent("download.batch")
        try Data(batch.utf8).write(to: batchFile)
        let output = try await TimedInventoryProcessRunner(
            timeout: .seconds(10),
            underlying: FoundationInventoryProcessRunner()
        ).run(CommandSpec(
            executable: "/usr/bin/sftp",
            arguments: ["-D", "/usr/libexec/sftp-server", "-b", batchFile.path]
        ))
        #expect(output.exitCode == 0, "\(output.stderr)\n\(output.stdout)")
        #expect(try Data(contentsOf: local) == payload)
    }

    @Test("cancellation stops work before creating a local attachment")
    func cancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("image.png")
        try Data([1]).write(to: source)
        let service = AttachmentTransferService(sshMasterPool: SSHMasterPool())
        let context = try await service.context(target: .local, sessionName: nil, localDirectory: directory.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.transfer(file: source, screenshot: true, context: context, directoryOverride: "")
        }
        do { _ = try await task.value; Issue.record("Cancelled transfer succeeded") }
        catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".tmuxhub").path))
    }

    @Test("optional live SSH/tmux attachment round trip", .enabled(if: ProcessInfo.processInfo.environment["TMUXHUB_LIVE_ATTACHMENT_HOST"] != nil))
    func liveSSHTransfer() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["TMUXHUB_LIVE_ATTACHMENT_HOST"])
        try #require(IdentifierValidator.isSSHDestination(host))
        let token = UUID().uuidString.lowercased()
        // Match auto-created tabs for user@IPv4 hosts: tmux rewrites the dots
        // even though the caller still has the originally requested name.
        let session = "hub-attachment-10.30.45.144-" + String(token.prefix(12))
        let normalizedSession = try #require(IdentifierValidator.normalizedTmuxSessionName(session))
        let remoteDirectory = "/tmp/tmuxhub-attachment-test-" + token
        let socketDirectory = URL(fileURLWithPath: "/tmp/th-at-" + String(token.prefix(12)))
        let local = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        let runner = TimedInventoryProcessRunner(timeout: .seconds(15), underlying: FoundationInventoryProcessRunner())
        let pool = SSHMasterPool(testDirectory: socketDirectory, runner: runner)
        let service = AttachmentTransferService(sshMasterPool: pool)
        let quotedDirectory = try AttachmentPaths.shellQuote(remoteDirectory)
        let setup = "umask 077; mkdir \(quotedDirectory) && tmux new-session -d -s \(session) -c \(quotedDirectory)"
        let cleanup = "tmux kill-session -t '=\(normalizedSession)' 2>/dev/null; "
            + "rm -rf -- \(quotedDirectory) \"$HOME/tmuxhub-resolve-\(token)\""
        func command(_ script: String) -> CommandSpec {
            CommandSpec(executable: "/usr/bin/ssh", arguments: ["-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, script])
        }
        do {
            let setupResult = try await pool.run(command(setup), alias: host, replay: .never)
            try #require(setupResult.exitCode == 0, "\(setupResult.stderr)")
            let context = try await service.context(target: .ssh(destination: host), sessionName: session, localDirectory: "/")
            #expect(context.sessionName == normalizedSession)
            #expect(context.workingDirectory == remoteDirectory)
            let normalizedContext = try await service.context(target: .ssh(destination: host), sessionName: normalizedSession, localDirectory: "/")
            #expect(normalizedContext == context)
            let source = local.appendingPathComponent("测试 file ' \" [*]?\\.txt")
            let text = "TmuxHub real SSH + tmux + SFTP round trip\n"
            try Data(text.utf8).write(to: source)
            let path = try await service.transfer(file: source, screenshot: false, context: context, directoryOverride: "")
            let readback = try await pool.run(command("cat " + AttachmentPaths.shellQuote(path)), alias: host, replay: .readOnly)
            #expect(readback.exitCode == 0)
            #expect(readback.stdout == text)
            let downloaded = local.appendingPathComponent("downloaded.txt")
            try Data("old contents".utf8).write(to: downloaded)
            try await service.download(
                remotePath: path,
                context: context,
                destination: downloaded
            )
            #expect(try Data(contentsOf: downloaded) == Data(text.utf8))

            let suffix = "tmuxhub-fallback-\(token)/nested/file.txt"
            let fallbackRelative = "tmuxhub-resolve-\(token)/project/" + suffix
            let makeFallback = "fallback=\"$HOME\"/"
                + (try AttachmentPaths.shellQuote(fallbackRelative))
                + "; mkdir -p \"$(dirname \"$fallback\")\"; "
                + "printf fallback > \"$fallback\""
            let madeFallback = try await pool.run(
                command(makeFallback), alias: host, replay: .never
            )
            try #require(
                madeFallback.exitCode == 0,
                "\(madeFallback.stderr)\n\(madeFallback.stdout)"
            )
            let homeContext = AttachmentContext(
                target: .ssh(destination: host), sessionName: normalizedSession,
                paneID: context.paneID, processName: context.processName,
                workingDirectory: "/"
            )
            let found = try await service.resolveDownloadPath(
                suffix,
                context: homeContext
            )
            #expect(found.hasSuffix("/tmuxhub-resolve-\(token)/project/\(suffix)"))
        } catch {
            _ = try? await pool.run(command(cleanup), alias: host, replay: .never)
            await pool.shutdown()
            throw error
        }
        let cleaned = try await pool.run(command(cleanup), alias: host, replay: .never)
        #expect(cleaned.exitCode == 0)
        await pool.shutdown()
    }

    @Test("operation runner supports transfers without a fixed wall-clock timeout")
    func operationRunnerWithoutTimeout() async throws {
        let policy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: 1,
            timeout: .seconds(300)
        )
        let value = try await policy.runWithoutTimeout {
            try await Task.sleep(for: .milliseconds(25))
            return 42
        }
        #expect(value == 42)
    }

    @Test("operation runner still enforces configured timeouts")
    func operationRunnerTimeout() async {
        let policy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: 1,
            timeout: .milliseconds(10)
        )
        await #expect(throws: InventoryProcessTimeoutError.timedOut) {
            try await policy.run {
                try await Task.sleep(for: .seconds(60))
                return 0
            }
        }
    }
}
