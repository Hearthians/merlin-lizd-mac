import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Automatic remote editor preparation")
struct RemoteEditorPreparationTests {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-code-prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test("JSONC edits preserve comments, nested preferences and default extensions")
    func jsoncSettings() throws {
        let original = #"""
        {
            // Keep my defaults, including this URL: https://example.com/*text*/
            "remote.SSH.defaultExtensions": ["ms-python.python",],
            "editor.fontFamily": "A \"quoted\" font // not a comment",
            "nested": {"remote.downloadExtensionsLocally": false,},
            "remote.downloadExtensionsLocally": false,
            /* keep this comment */ "remote.SSH.localServerDownload": "off",
        }
        """#
        let document = try RemoteEditorVSCodeSettings.Document(Data(original.utf8))
        let result = try document.replacing(["remote.downloadExtensionsLocally": "true", "remote.SSH.localServerDownload": "\"always\""])
        let parsed = try RemoteEditorVSCodeSettings.Document(result)
        let text = String(decoding: result, as: UTF8.self)
        #expect(text.contains("// Keep my defaults, including this URL: https://example.com/*text*/"))
        #expect(text.contains("/* keep this comment */"))
        #expect(text.contains("\"nested\": {\"remote.downloadExtensionsLocally\": false,}"))
        #expect(parsed.values["remote.downloadExtensionsLocally"] as? Bool == true)
        #expect(parsed.values["remote.SSH.localServerDownload"] as? String == "always")
        #expect(parsed.values["remote.SSH.defaultExtensions"] as? [String] == ["ms-python.python"])
        #expect(try parsed.replacing(["remote.downloadExtensionsLocally": "true", "remote.SSH.localServerDownload": "\"always\""]) == result)
    }

    @Test("new settings, trailing comments and duplicate keys stay valid and idempotent")
    func settingsVariants() throws {
        for source in ["{}", "{ /* keep */ }", "{\"test\": 1 // trailing\n}", "{\"test\": 1,\n}",
                       "\u{FEFF}{\"test\": [1,2,],}", "{\"remote.downloadExtensionsLocally\":false,\"remote.downloadExtensionsLocally\":false}"] {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let file = home.appendingPathComponent("settings.json")
            try Data(source.utf8).write(to: file)
            let settings = RemoteEditorVSCodeSettings(url: file)
            _ = try settings.prepare()
            let first = try Data(contentsOf: file)
            let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
            _ = try settings.prepare()
            #expect(try Data(contentsOf: file) == first)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == inode)
            let parsed = try RemoteEditorVSCodeSettings.Document(first)
            #expect(parsed.values["remote.downloadExtensionsLocally"] as? Bool == true)
            #expect(parsed.values["remote.SSH.localServerDownload"] as? String == "always")
        }
    }

    @Test("invalid settings are never overwritten and owned symlinks remain intact")
    func settingsSafety() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("settings.json")
        for source in ["{ broken }", "[]", "{\"foo\": 1 /* unfinished", "{\"foo\":}", "{\"foo\": 1 / nope}"] {
            try Data(source.utf8).write(to: file)
            #expect(throws: (any Error).self) { _ = try RemoteEditorVSCodeSettings(url: file).prepare() }
            #expect(try String(contentsOf: file, encoding: .utf8) == source)
        }
        try Data("{}".utf8).write(to: file)
        let link = home.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        _ = try RemoteEditorVSCodeSettings(url: link).prepare()
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try RemoteEditorVSCodeSettings.Document(Data(contentsOf: file)).values["remote.downloadExtensionsLocally"] as? Bool == true)
    }

    @Test("fresh Macs install only the required local Remote SSH extension")
    func newMac() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = EditorPreparationRunner(localIDs: [], probe: nil)
        try await RemoteEditorPreparation.prepare(application: home.appendingPathComponent("VS Code.app"),
            destination: RemoteEditorDestination(sshDestination: "host", absolutePath: "/work", kind: .folder),
            home: home, cache: home.appendingPathComponent("cache"), runner: runner)
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands[0].arguments == ["--list-extensions"])
        #expect(commands[1].arguments == ["--install-extension", "ms-vscode-remote.remote-ssh", "--do-not-sync"])
        #expect(!commands.contains { $0.executable == "/usr/bin/ssh" })
    }

    @Test("ready nodes skip downloads and keep conditional extension preferences scoped to this Mac")
    func readyNode() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"remote.SSH.defaultExtensions":["ms-python.python"],"remote.SSH.defaultExtensionsIfInstalledLocally":["ms-python.vscode-pylance","unknown.other"]}"#.utf8).write(to: file)
        let product = home.appendingPathComponent("VS Code.app/Contents/Resources/app/product.json")
        try FileManager.default.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"commit":"1111111111111111111111111111111111111111","version":"1.142.0"}"#.utf8).write(to: product)
        let runner = EditorPreparationRunner(localIDs: ["ms-vscode-remote.remote-ssh", "ms-python.vscode-pylance"],
            probe: #"{"platform":"linux-x64","installed":["ms-python.python","ms-python.vscode-pylance"],"missing":[],"needsManager":false}"#)
        let destination = try RemoteEditorDestination(sshDestination: "tmuxhub-code-exact-node", absolutePath: "/work", kind: .folder)
        try await RemoteEditorPreparation.prepare(application: home.appendingPathComponent("VS Code.app"), destination: destination,
            home: home, cache: home.appendingPathComponent("cache"), runner: runner)
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands[1].arguments[commands[1].arguments.count - 2] == "tmuxhub-code-exact-node")
        let expected = try RemoteEditorRemoteSetup.encoded(["ms-python.python", "ms-python.vscode-pylance"])
        #expect(commands[1].arguments.last?.contains(expected) == true)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("cache").path))
    }

    @Test("cancelled opens never modify a fresh Mac's settings")
    func cancellation() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = EditorPreparationRunner(localIDs: [], probe: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await RemoteEditorPreparation.prepare(application: home.appendingPathComponent("VS Code.app"),
                destination: RemoteEditorDestination(sshDestination: "host", absolutePath: "/work", kind: .folder),
                home: home, cache: home.appendingPathComponent("cache"), runner: runner)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runner.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
    }

    @Test("Marketplace chooses a stable version compatible with both the Mac's VS Code and remote architecture")
    func marketplaceVersions() throws {
        let versions: [[String: Any]] = [
            ["version": "4.0.0", "targetPlatform": "linux-x64", "properties": [["key": "Microsoft.VisualStudio.Code.Engine", "value": "^1.150.0"]]],
            ["version": "3.0.0", "targetPlatform": "linux-x64", "properties": [["key": "Microsoft.VisualStudio.Code.Engine", "value": "^1.100.0"], ["key": "Microsoft.VisualStudio.Code.PreRelease", "value": "true"]]],
            ["version": "2.0.0", "targetPlatform": "darwin-arm64", "properties": [["key": "Microsoft.VisualStudio.Code.Engine", "value": "^1.100.0"]]],
            ["version": "1.5.0", "targetPlatform": "linux-x64", "properties": [["key": "Microsoft.VisualStudio.Code.Engine", "value": "^1.100.0"]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["results": [["extensions": [["versions": versions]]]]])
        let chosen = try RemoteEditorMarketplace.select(id: "ms-python.python", platform: "linux-x64", version: "1.142.0", response: data)
        #expect(chosen.version == "1.5.0")
        #expect(chosen.packageURL.absoluteString.contains("targetPlatform=linux-x64"))
        #expect(throws: (any Error).self) {
            _ = try RemoteEditorMarketplace.select(id: "ms-python.python", platform: "linux-arm64", version: "1.90.0", response: data)
        }
        for engine in ["^1.95.0", "^1.79.0-insider", ">=1.100.0 <1.150.0", "~1.142.0", "*"] {
            #expect(RemoteEditorMarketplace.compatible("1.142.0", with: engine))
        }
        for engine in ["^1.150.0", "^0.10.0", "~1.141.0", "nonsense", ">=1.0.0 || invalid", ""] {
            // The valid left side of an OR is allowed even if the other side is unknown.
            #expect(RemoteEditorMarketplace.compatible("1.142.0", with: engine) == (engine == ">=1.0.0 || invalid"))
        }
    }

    @Test("cached gzip-wrapped VSIX packages normalize, validate and expose dependencies without Python in production")
    func cachedPackage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sample.extension-1.0.0-linux-x64.vsix")
        let raw = home.appendingPathComponent("expected.vsix")
        let script = #"""
        import gzip,json,sys,zipfile
        with zipfile.ZipFile(sys.argv[1], 'w') as archive:
            archive.writestr('extension/package.json', json.dumps(dict(publisher='sample',name='extension',version='1.0.0',
                engines={'vscode':'^1.95.0'},extensionDependencies=['sample.dependency'],extensionPack=['sample.pack'])))
        with open(sys.argv[1],'rb') as stream: data=stream.read()
        with open(sys.argv[2],'wb') as stream: stream.write(data)
        with open(sys.argv[1],'wb') as stream: stream.write(gzip.compress(data))
        """#
        let runner = TimedInventoryProcessRunner(timeout: .seconds(15), underlying: FoundationInventoryProcessRunner())
        let fixture = try await runner.run(CommandSpec(executable: "/usr/bin/env", arguments: ["python3", "-c", script, file.path, raw.path]))
        #expect(fixture.exitCode == 0)
        let selected = RemoteEditorExtension(id: "sample.extension", version: "1.0.0", platform: "linux-x64",
            engine: "^1.95.0", sha256: try RemoteEditorMarketplace.sha256(raw))
        let marketplace = RemoteEditorMarketplace(runner: runner, cache: home)
        let (package, dependencies) = try await marketplace.package(selected, vscodeVersion: "1.142.0")
        #expect(package == file)
        #expect(dependencies == ["sample.dependency", "sample.pack"])
        #expect(try Data(contentsOf: package) == Data(contentsOf: raw))
        var corrupted = try Data(contentsOf: package)
        corrupted.append(0)
        try corrupted.write(to: package)
        await #expect(throws: (any Error).self) { _ = try await marketplace.package(selected, vscodeVersion: "1.142.0") }
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }
}

private actor EditorPreparationRunner: InventoryProcessRunning {
    let localIDs: [String]
    let probe: String?
    var commands: [CommandSpec] = []
    init(localIDs: [String], probe: String?) { self.localIDs = localIDs; self.probe = probe }
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        commands.append(command)
        if command.arguments == ["--list-extensions"] {
            return InventoryProcessOutput(stdout: localIDs.joined(separator: "\n"), stderr: "", exitCode: 0)
        }
        if command.executable == "/usr/bin/ssh", let probe {
            return InventoryProcessOutput(stdout: probe, stderr: "", exitCode: 0)
        }
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }
}
