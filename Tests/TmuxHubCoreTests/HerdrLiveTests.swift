import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Optional live Herdr attachment integration")
struct HerdrLiveTests {
    @Test(
        "bound Herdr terminal survives focus changes and drives exact SFTP paths",
        .enabled(if: ProcessInfo.processInfo.environment["TMUXHUB_LIVE_HERDR_HOST"] != nil)
    )
    func boundTerminalTransfer() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["TMUXHUB_LIVE_HERDR_HOST"])
        try #require(IdentifierValidator.isSSHDestination(host))
        let target = TerminalTarget.ssh(destination: host)
        let token = UUID().uuidString.lowercased()
        let sessionName = "tmuxhub-live-" + String(token.prefix(12))
        let root = "/tmp/tmuxhub-herdr-live-" + token
        let originalDirectory = root + "/项目 A space"
        let movedDirectory = root + "/项目 A space/新目录"
        let otherDirectory = root + "/项目 B space"
        let fallbackDirectory = "tmuxhub-herdr-fallback-" + token
        let missingRelativePath = "missing-" + token + ".bin"
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-herdr-live-" + token, isDirectory: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/th-hl-" + String(token.prefix(12)))
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: socketDirectory)
        }

        let runner = TimedInventoryProcessRunner(
            timeout: .seconds(15), underlying: FoundationInventoryProcessRunner()
        )
        let pool = SSHMasterPool(testDirectory: socketDirectory, runner: runner)
        let herdr = HerdrService(sshMasterPool: pool)
        let attachments = AttachmentTransferService(sshMasterPool: pool, herdrService: herdr)
        let quote = HerdrCommands.shellQuote
        // Lifecycle changes below always name this newly generated test session.
        // The default server is only read by production discovery, never changed.
        let executable = "\"$HOME/.local/bin/herdr\""
        let named = executable + " --session " + quote(sessionName)

        func run(_ script: String) async throws -> InventoryProcessOutput {
            let command = CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                "exec /bin/sh -c " + quote(script),
            ])
            return try await pool.run(command, alias: host, replay: .never)
        }

        func namedSnapshot() async throws -> HerdrSessionSnapshot {
            let output = try await pool.run(
                HerdrCommands.snapshot(target: target, sessionName: sessionName),
                alias: host, replay: .readOnly
            )
            try #require(output.exitCode == 0, "\(output.stderr)")
            return try HerdrParser.snapshot(output.stdout, sessionName: sessionName)
        }

        let removeFiles = "rm -rf -- " + quote(root) + " \"$HOME\"/" + quote(fallbackDirectory)
        let cleanup = executable + " session stop " + quote(sessionName) + " --json && "
            + executable + " session delete " + quote(sessionName) + " --json; "
            + "cleanup_status=$?; " + removeFiles + "; exit \"$cleanup_status\""

        do {
            let setup = "umask 077; mkdir -p "
                + [originalDirectory, movedDirectory, otherDirectory].map(quote).joined(separator: " ")
                + " || exit; nohup " + named + " server > " + quote(root + "/server.log")
                + " 2>&1 < /dev/null &"
            let started = try await run(setup)
            try #require(started.exitCode == 0, "\(started.stderr)")
            var serverReady = false
            for _ in 0..<30 {
                if (try? await namedSnapshot()) != nil { serverReady = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(serverReady, "The disposable named Herdr server did not become ready")

            let createdA = try await run(
                named + " workspace create --cwd " + quote(originalDirectory)
                    + " --label bound-a --no-focus"
            )
            try #require(createdA.exitCode == 0, "\(createdA.stderr)")
            let initial = try await namedSnapshot()
            let workspaceA = try #require(initial.workspaces.first)
            let paneA = try #require(workspaceA.panes.first)
            let reference = paneA.reference
            let createdB = try await run(
                named + " workspace create --cwd " + quote(otherDirectory)
                    + " --label focused-b --focus"
            )
            try #require(createdB.exitCode == 0, "\(createdB.stderr)")

            let sessions = try await herdr.discover(target: target)
            let discovered = try #require(sessions.first { $0.sessionName == sessionName })
            #expect(discovered.workspaces.count == 2)
            #expect(discovered.workspaces.flatMap(\.panes).contains { $0.reference == reference })
            let context = try await attachments.context(
                target: target, sessionName: nil, localDirectory: "/",
                herdrReference: reference
            )
            #expect(context.workingDirectory == originalDirectory)
            #expect(context.herdrReference == reference)
            #expect(context.paneID == paneA.paneID)

            let source = local.appendingPathComponent("附件 space ' \" [*]?\\.bin")
            let payload = Data((0...255).map(UInt8.init)) + Data("Herdr-bound SFTP\n".utf8)
            try payload.write(to: source)
            let uploaded = try await attachments.transfer(
                file: source, screenshot: false, context: context, directoryOverride: ""
            )
            #expect(uploaded.hasPrefix(originalDirectory + "/.tmuxhub/attachments/"))
            #expect((uploaded as NSString).lastPathComponent == source.lastPathComponent)
            let downloaded = local.appendingPathComponent("downloaded.bin")
            try Data("replace existing file".utf8).write(to: downloaded)
            try await attachments.download(remotePath: uploaded, context: context, destination: downloaded)
            #expect(try Data(contentsOf: downloaded) == payload)

            let changed = try await run(
                named + " pane run " + quote(paneA.paneID) + " "
                    + quote("cd -- " + quote(movedDirectory))
            )
            try #require(changed.exitCode == 0, "\(changed.stderr)")
            var updatedContext = context
            for _ in 0..<30 {
                updatedContext = try await attachments.context(
                    target: target, sessionName: nil, localDirectory: "/",
                    herdrReference: reference
                )
                if updatedContext.workingDirectory == movedDirectory { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(updatedContext.workingDirectory == movedDirectory)
            #expect(updatedContext.herdrReference == reference)
            let movedUpload = try await attachments.transfer(
                file: source, screenshot: false, context: updatedContext, directoryOverride: ""
            )
            #expect(movedUpload.hasPrefix(movedDirectory + "/.tmuxhub/attachments/"))

            // This exact suffix exists in another owned project under $HOME,
            // where the legacy tmux fallback would otherwise find it.
            let makeFallback = "fallback=\"$HOME\"/" + quote(fallbackDirectory + "/project")
                + "; mkdir -p \"$fallback\" && printf wrong-project > \"$fallback/"
                + missingRelativePath + "\""
            let fallback = try await run(makeFallback)
            try #require(fallback.exitCode == 0, "\(fallback.stderr)")
            await #expect(throws: AttachmentError.downloadFailed) {
                try await attachments.resolveDownloadPath(missingRelativePath, context: updatedContext)
            }

            let closed = try await run(named + " workspace close " + quote(workspaceA.id))
            try #require(closed.exitCode == 0, "\(closed.stderr)")
            await #expect(throws: HerdrError.terminalUnavailable) {
                try await attachments.context(
                    target: target, sessionName: nil, localDirectory: otherDirectory,
                    herdrReference: reference
                )
            }
        } catch {
            _ = try? await run(cleanup)
            await pool.shutdown()
            throw error
        }
        let cleaned = try await run(cleanup)
        #expect(cleaned.exitCode == 0, "\(cleaned.stderr)")
        await pool.shutdown()
    }
}
