import Foundation
import Testing
@testable import TmuxHubCore

@Suite("One-click tmux configuration")
struct TmuxConfigurationTests {
    @Test("backs up original bytes and permissions, preserves other settings, and is idempotent")
    func preservesExistingConfiguration() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let original = "# My settings\nset -g history-limit 50000\nset -g prefix C-b"
        try original.write(to: fixture.config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.config.path)

        let first = try await fixture.apply()
        #expect(first.changed)
        #expect(first.activation == .nextSession)
        let backup = try #require(first.backupPath)
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == original)
        let configured = try String(contentsOf: fixture.config, encoding: .utf8)
        #expect(configured.hasPrefix(original + "\n"))
        #expect(configured.hasSuffix(TmuxConfigurationPreset.contents))
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.config.path)[.posixPermissions] as? Int == 0o640)

        let second = try await fixture.apply()
        #expect(!second.changed)
        #expect(second.backupPath == nil)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == configured)
        #expect(try fixture.backups().count == 1)

        let edited = configured.replacingOccurrences(of: "set -g mouse on", with: "set -g mouse off")
        try edited.write(to: fixture.config, atomically: true, encoding: .utf8)
        let third = try await fixture.apply()
        #expect(third.changed)
        #expect(try String(contentsOfFile: #require(third.backupPath), encoding: .utf8) == edited)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == configured)
    }

    @Test("new configurations need no backup and are private")
    func createsNewConfiguration() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let result = try await fixture.apply()
        #expect(result.configurationPath == fixture.config.path)
        #expect(result.backupPath == nil)
        #expect(result.changed)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == TmuxConfigurationPreset.contents)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.config.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test("uses an existing XDG config without shadowing it with a new dotfile")
    func xdgConfiguration() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let xdgFile = fixture.xdg.appendingPathComponent("tmux/tmux.conf")
        try FileManager.default.createDirectory(at: xdgFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "set -g history-limit 12000\n".write(to: xdgFile, atomically: true, encoding: .utf8)
        let result = try await fixture.apply()
        #expect(result.configurationPath == xdgFile.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.config.path))
        #expect(try String(contentsOf: xdgFile, encoding: .utf8).hasPrefix("set -g history-limit 12000\n"))
        #expect(result.backupPath != nil)
    }

    @Test("keeps dotfile symlinks and backs up their actual target")
    func symlinkConfiguration() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let original = "# Dotfiles managed elsewhere\nset -g history-limit 18000\n"
        let target = fixture.directory.appendingPathComponent("dotfile")
        try original.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: fixture.config.path, withDestinationPath: "dotfile")
        let result = try await fixture.apply()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.config.path) == "dotfile")
        #expect(try String(contentsOf: target, encoding: .utf8).hasSuffix(TmuxConfigurationPreset.contents))
        #expect(try String(contentsOfFile: #require(result.backupPath), encoding: .utf8) == original)
    }

    @Test("malformed markers never discard existing configuration", arguments: [
        "# BEGIN TmuxHub preset\nset -g mouse off\n",
        "# END TmuxHub preset\n",
        "# BEGIN TmuxHub preset\n# BEGIN TmuxHub preset\n# END TmuxHub preset\n",
    ])
    func malformedBlock(original: String) async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try original.write(to: fixture.config, atomically: true, encoding: .utf8)
        await #expect(throws: TmuxConfigurationError.self) { try await fixture.apply() }
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == original)
        #expect(try fixture.backups().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .allSatisfy { !$0.hasPrefix(".tmux.conf.tmuxhub.") })
    }

    @Test("missing tmux leaves configuration untouched")
    func missingTmux() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.tmux)
        await #expect(throws: TmuxConfigurationError.tmuxNotFound) { try await fixture.apply() }
        #expect(!FileManager.default.fileExists(atPath: fixture.config.path))
    }

    @Test("only reloads the preset and reports a failed live reload as saved but inactive")
    func reloadFailure() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        try "run-shell 'do-not-run-again'\n".write(to: fixture.config, atomically: true, encoding: .utf8)
        try Data().write(to: fixture.directory.appendingPathComponent("running"))
        try Data().write(to: fixture.directory.appendingPathComponent("fail-reload"))
        let result = try await fixture.apply()
        #expect(result.activation == .reloadFailed)
        #expect(result.changed)
        #expect(result.backupPath != nil)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("sourced"), encoding: .utf8)
            == TmuxConfigurationPreset.contents)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("fail-reload"))
        let retry = try await fixture.apply()
        #expect(retry.activation == .reloaded)
        #expect(!retry.changed)
    }

    @Test("remote shell quoting executes the same installer with literal paths")
    func remoteCommand() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let command = try TmuxConfigurationPreset.command(target: .ssh(destination: "liuzk@tiger8"), localTmuxPath: "/unused")
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments.dropLast().last == "liuzk@tiger8")
        let remoteScript = try #require(command.arguments.last)
            + " " + ConfigurationFixture.quote(fixture.directory.path)
            + " " + ConfigurationFixture.quote(fixture.xdg.path)
        let output = try await FoundationInventoryProcessRunner().run(CommandSpec(
            executable: "/bin/sh", arguments: ["-c", remoteScript],
            environment: ["PATH": fixture.directory.path + ":/usr/bin:/bin"]
        ))
        #expect(output.exitCode == 0, "\(output.stderr)")
        #expect(try TmuxConfigurationResult.parse(output.stdout).configurationPath == fixture.config.path)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == TmuxConfigurationPreset.contents)
        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try TmuxConfigurationPreset.command(target: .ssh(destination: "host; touch injected"), localTmuxPath: "/unused")
        }
    }

    @Test("applies every setting to a real isolated tmux server without replacing its session")
    func realTmuxReload() async throws {
        guard let realTmux = LocalTmuxResolver.resolve() else { return }
        let fixture = try ConfigurationFixture()
        defer { fixture.remove() }
        let socket = "/tmp/tmuxhub-preset-\(UUID().uuidString.prefix(12))"
        let wrapper = "#!/bin/sh\nexec \(ConfigurationFixture.quote(realTmux)) -S \(ConfigurationFixture.quote(socket)) \"$@\"\n"
        try wrapper.write(to: fixture.tmux, atomically: false, encoding: .utf8)
        let runner = FoundationInventoryProcessRunner()
        func tmux(_ args: [String]) async throws -> InventoryProcessOutput {
            try await runner.run(CommandSpec(executable: realTmux, arguments: ["-S", socket] + args))
        }
        let start = try await tmux(["-f", "/dev/null", "new-session", "-d", "-s", "keep-running", "sleep 60"])
        #expect(start.exitCode == 0, "\(start.stderr)")
        do {
            let before = try await tmux(["display-message", "-p", "-t", "keep-running", "#{session_id}:#{pane_pid}"])
            let result = try await fixture.apply()
            #expect(result.activation == .reloaded)
            let after = try await tmux(["display-message", "-p", "-t", "keep-running", "#{session_id}:#{pane_pid}"])
            #expect(before.stdout == after.stdout)
            for (scope, option, expected) in [
                ("-g", "prefix", "C-a"), ("-g", "mouse", "on"),
                ("-g", "status-style", "bg=black,fg=white"), ("-g", "base-index", "1"),
                ("-gw", "pane-base-index", "1"), ("-gw", "pane-border-style", "fg=green"),
                ("-gw", "pane-active-border-style", "fg=red"),
                ("-s", "default-terminal", "screen-256color"),
                ("-s", "terminal-overrides", "xterm*:smcup@:rmcup@"),
            ] {
                let value = try await tmux(["show-options", scope, "-v", option])
                #expect(value.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
            }
            let keys = try await tmux(["list-keys", "-T", "prefix"])
            #expect(keys.stdout.contains("C-a") && keys.stdout.contains("send-prefix"))
        } catch {
            _ = try? await tmux(["kill-server"])
            throw error
        }
        _ = try await tmux(["kill-server"])
    }
}

private struct ConfigurationFixture {
    let directory: URL
    var tmux: URL { directory.appendingPathComponent("tmux") }
    var config: URL { directory.appendingPathComponent(".tmux.conf") }
    var xdg: URL { directory.appendingPathComponent("xdg") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-config-\(UUID().uuidString) space ' $() 中文", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let stub = """
            #!/bin/sh
            case "$1" in
                list-sessions)
                    if [ -f \(Self.quote(directory.appendingPathComponent("running").path)) ]; then exit 0; fi
                    printf '%s\\n' 'no server running' >&2
                    exit 1 ;;
                source-file)
                    cat "$2" > \(Self.quote(directory.appendingPathComponent("sourced").path))
                    if [ -f \(Self.quote(directory.appendingPathComponent("fail-reload").path)) ]; then exit 1; fi
                    exit 0 ;;
                *) exit 99 ;;
            esac
            """
        try stub.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmux.path)
    }

    func apply() async throws -> TmuxConfigurationResult {
        let controller = TmuxSessionController(
            processRunner: ConfigurationFixtureRunner(directory: directory, xdg: xdg),
            localTmuxPath: tmux.path
        )
        return try await controller.applyConfiguration(target: .local)
    }

    func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".tmuxhub-backup.") }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ConfigurationFixtureRunner: InventoryProcessRunning {
    let directory: URL
    let xdg: URL

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        try await FoundationInventoryProcessRunner().run(CommandSpec(
            executable: command.executable,
            arguments: command.arguments + [directory.path, xdg.path],
            environment: command.environment
        ))
    }
}
