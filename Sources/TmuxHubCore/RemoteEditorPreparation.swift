import Foundation

/// Runs on the Mac receiving the request, so a second computer gets its own
/// settings, Remote - SSH extension, compatible downloads and SSH credentials.
public enum RemoteEditorPreparation {
    private static let preparationGate = BoundedAsyncOperationRunner(maxConcurrentOperations: 1, timeout: .seconds(900))

    public static func prepare(
        application: URL,
        destination: RemoteEditorDestination,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws {
        try await preparationGate.run {
            try await prepare(application: application, destination: destination,
                home: FileManager.default.homeDirectoryForCurrentUser,
                cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("TmuxHub/remote-editor"),
                runner: FoundationInventoryProcessRunner(), progress: progress)
        }
    }

    static func prepare(
        application: URL,
        destination: RemoteEditorDestination,
        home: URL,
        cache: URL,
        runner: any InventoryProcessRunning,
        session: URLSession = .shared,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        await progress?("正在配置本机 VS Code…")
        let settings = RemoteEditorVSCodeSettings(url: home.appendingPathComponent("Library/Application Support/Code/User/settings.json"))
        let preferences = try settings.prepare()
        let cli = application.appendingPathComponent("Contents/Resources/app/bin/code").path
        let local = TimedInventoryProcessRunner(timeout: .seconds(180), underlying: runner)
        let installed = try await local.run(CommandSpec(executable: cli, arguments: ["--list-extensions"]))
        guard installed.exitCode == 0 else { throw RemoteEditorSetupError.failed("无法检查本机 VS Code 扩展，请确认 VS Code 可正常运行。") }
        let localIDs = Set(installed.stdout.split(whereSeparator: \.isNewline).map { $0.lowercased() }
            .filter(RemoteEditorVSCodeSettings.validExtensionID))
        if !localIDs.contains("ms-vscode-remote.remote-ssh") {
            await progress?("首次使用：正在安装 VS Code Remote - SSH…")
            let result = try await local.run(CommandSpec(executable: cli,
                arguments: ["--install-extension", "ms-vscode-remote.remote-ssh", "--do-not-sync"]))
            guard result.exitCode == 0 else {
                throw RemoteEditorSetupError.failed("无法自动安装 Remote - SSH，请检查本机网络后重试 code。")
            }
        }
        let configured = try RemoteEditorVSCodeSettings.extensionIDs(preferences["remote.SSH.defaultExtensions"])
        let conditional = try RemoteEditorVSCodeSettings.extensionIDs(preferences["remote.SSH.defaultExtensionsIfInstalledLocally"])
        let requested = Array(Set(configured + conditional.filter { localIDs.contains($0) })).sorted()
        // With no mandatory defaults, Remote - SSH can start immediately and
        // install optional extensions through the client's local downloader.
        guard !requested.isEmpty else { return }
        let build = try RemoteEditorBuild(application: application)
        let remote = TimedInventoryProcessRunner(timeout: .seconds(320), underlying: runner)
        let probeOutput = try await remote.run(RemoteEditorRemoteSetup.command(destination: destination.sshDestination,
            action: "probe", arguments: [build.commit, RemoteEditorRemoteSetup.encoded(requested)]))
        guard probeOutput.exitCode == 0, probeOutput.stdout.utf8.count <= 128 * 1_024,
            let probe = try? JSONDecoder().decode(RemoteEditorRemoteSetup.Probe.self, from: Data(probeOutput.stdout.utf8)),
            ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"].contains(probe.platform),
            probe.installed.count <= 4096, probe.missing.count <= 96,
            (probe.installed + probe.missing).allSatisfy(RemoteEditorVSCodeSettings.validExtensionID) else {
            throw RemoteEditorSetupError.failed("无法检查远端 VS Code 扩展。远端需有 Python 3.6+，且主目录可写。")
        }
        guard !probe.missing.isEmpty else { return }
        await progress?("首次使用：正在通过本机下载远端 VS Code 扩展…")
        let marketplace = RemoteEditorMarketplace(runner: local,
            cache: cache.appendingPathComponent(probe.platform), session: session)
        try FileManager.default.createDirectory(at: marketplace.cache, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var pending = probe.missing
        var visited = Set(probe.installed)
        var files: [SetupFile] = []
        while !pending.isEmpty {
            try Task.checkCancellation()
            let id = pending.removeFirst()
            if visited.contains(id) { continue }
            guard files.count < 96 else { throw RemoteEditorSetupError.failed("默认远端扩展依赖过多，请检查 VS Code 设置。") }
            visited.insert(id)
            let selected = try await marketplace.select(id: id, platform: probe.platform, version: build.version)
            let (file, dependencies) = try await marketplace.package(selected, vscodeVersion: build.version)
            files.append(try SetupFile(file: file, name: file.lastPathComponent))
            pending += dependencies
        }
        if probe.needsManager {
            await progress?("首次连接：正在下载匹配此版本的 VS Code 扩展安装组件…")
            let server = try await marketplace.server(commit: build.commit, platform: probe.platform)
            files.append(try SetupFile(file: server, name: "server.tar.gz"))
        }
        try Task.checkCancellation()
        await progress?("正在安装远端 VS Code 扩展…")
        let stageOutput = try await remote.run(RemoteEditorRemoteSetup.command(destination: destination.sshDestination,
            action: "stage", arguments: []))
        let stage = stageOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stageOutput.exitCode == 0, stage.utf8.count <= 8192, stage.hasPrefix("/"),
            stage.contains("/.cache/tmuxhub/remote-editor/stage-"),
            !stage.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteEditorSetupError.failed("无法创建远端 VS Code 安装目录。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let batch = temporary.appendingPathComponent("upload.batch")
        let commands = try files.map { file in
            "put \(try AttachmentPaths.sftpQuote(file.file.path)) \(try AttachmentPaths.sftpQuote(stage + "/" + file.name))"
        }.joined(separator: "\n") + "\n"
        try Data(commands.utf8).write(to: batch)
        let transferred = try await remote.run(CommandSpec(executable: "/usr/bin/sftp", arguments: [
            "-b", batch.path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", destination.sshDestination,
        ]))
        guard transferred.exitCode == 0 else {
            _ = try? await remote.run(RemoteEditorRemoteSetup.command(destination: destination.sshDestination,
                action: "cleanup", arguments: [stage]))
            throw RemoteEditorSetupError.failed("VS Code 扩展传输失败，请检查 SSH/SFTP 后重试 code。")
        }
        let plan = SetupPlan(stage: stage, commit: build.commit, platform: probe.platform, requested: requested, files: files)
        let output = try await remote.run(RemoteEditorRemoteSetup.command(destination: destination.sshDestination,
            action: "install", arguments: [RemoteEditorRemoteSetup.encoded(plan)]))
        guard output.exitCode == 0, output.stdout.contains("TMUXHUB_VSCODE_READY_V1") else {
            throw RemoteEditorSetupError.failed("远端 VS Code 扩展自动安装失败，请重新运行 code。\n" + String(output.stderr.suffix(800)))
        }
    }

    struct SetupFile: Encodable {
        let file: URL
        let name: String
        let sha256: String
        enum CodingKeys: String, CodingKey { case name, sha256 }
        init(file: URL, name: String) throws {
            self.file = file
            self.name = name
            sha256 = try RemoteEditorMarketplace.sha256(file)
        }
    }

    struct SetupPlan: Encodable {
        let stage: String
        let commit: String
        let platform: String
        let requested: [String]
        let files: [SetupFile]
    }
}
