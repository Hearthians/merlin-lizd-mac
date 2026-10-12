import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Vim paste configuration")
struct VimPasteConfigurationTests {
    @Test("local and remote installers have equivalent safely quoted scripts")
    func commands() async throws {
        let local = try VimPasteConfiguration.command(target: .local)
        #expect(local.executable == "/bin/sh")
        #expect(local.arguments[0] == "-c")
        let remote = try VimPasteConfiguration.command(target: .ssh(destination: "alice@lab"))
        #expect(remote.executable == "/usr/bin/ssh")
        #expect(Array(remote.arguments.prefix(6)) == ["-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "alice@lab"])
        let quoted = "'" + local.arguments[1].replacingOccurrences(of: "'", with: "'\\''") + "'"
        #expect(remote.arguments.last == "sh -c \(quoted) tmuxhub-vim-paste")
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = try await TimedInventoryProcessRunner(timeout: .seconds(5), underlying: FoundationInventoryProcessRunner())
            .run(CommandSpec(executable: "/bin/sh", arguments: ["-c", try #require(remote.arguments.last)], environment: ["HOME": fixture.home.path]))
        #expect(output.exitCode == 0)
        #expect(try VimPasteConfigurationResult.parse(output.stdout).configurationPath == fixture.plugin.path)
        #expect(try String(contentsOf: fixture.plugin, encoding: .utf8) == VimPasteConfiguration.pluginContents)
        #expect(throws: CommandValidationError.invalidSSHDestination) {
            try VimPasteConfiguration.command(target: .ssh(destination: "-oProxyCommand=bad"))
        }
    }

    @Test("result parsing rejects incomplete or malformed responses")
    func parsing() throws {
        #expect(try VimPasteConfigurationResult.parse("banner\nTMUXHUB_VIM_PASTE_V1\tyes\n/tmp/plugin\n/tmp/backup\n")
            == VimPasteConfigurationResult(configurationPath: "/tmp/plugin", backupPath: "/tmp/backup", changed: true))
        for output in ["", "TMUXHUB_VIM_PASTE_V1\tmaybe\n/tmp/plugin\n\n",
                       "TMUXHUB_VIM_PASTE_V1\tyes\nrelative\n\n",
                       "TMUXHUB_VIM_PASTE_V1\tyes\n/tmp/plugin\n", "TMUXHUB_VIM_PASTE_V1\tyes\n/tmp/plugin\n\nextra"] {
            #expect(throws: VimPasteConfigurationError.unexpectedResponse) {
                try VimPasteConfigurationResult.parse(output)
            }
        }
    }

    @Test("installation is private, idempotent and preserves unrelated configuration")
    func installAndUpgrade() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let vimrc = fixture.home.appendingPathComponent(".vimrc")
        let tmux = fixture.home.appendingPathComponent(".tmux.conf")
        try Data("set autoindent\nset shiftwidth=7\n".utf8).write(to: vimrc)
        try Data("set -g mouse off\n".utf8).write(to: tmux)
        let first = try await fixture.install()
        #expect(first.changed && first.backupPath == nil)
        #expect(first.configurationPath == fixture.plugin.path)
        #expect(try String(contentsOf: fixture.plugin, encoding: .utf8) == VimPasteConfiguration.pluginContents)
        #expect(try fixture.permissions(fixture.plugin) == 0o600)
        let second = try await fixture.install()
        #expect(!second.changed && second.backupPath == nil)
        let old = Data("\" old plugin\r\nset number".utf8)
        try old.write(to: fixture.plugin)
        let upgrade = try await fixture.install()
        let backup = URL(fileURLWithPath: try #require(upgrade.backupPath))
        #expect(upgrade.changed)
        #expect(try Data(contentsOf: backup) == old)
        #expect(try fixture.permissions(backup) == 0o600)
        #expect(try String(contentsOf: vimrc, encoding: .utf8) == "set autoindent\nset shiftwidth=7\n")
        #expect(try String(contentsOf: tmux, encoding: .utf8) == "set -g mouse off\n")
    }

    @Test("symlinked plugins keep their link and receive an exact target backup")
    func symlink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = fixture.home.appendingPathComponent("managed.vim")
        let old = Data("\" managed previous plugin\n".utf8)
        try old.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.plugin, withDestinationURL: target)
        let result = try await fixture.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.plugin.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == VimPasteConfiguration.pluginContents)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(result.backupPath))) == old)
    }

    @Test("nonregular destinations fail without touching their contents")
    func directoryDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.plugin, withIntermediateDirectories: true)
        let sentinel = fixture.plugin.appendingPathComponent("keep")
        try Data("safe".utf8).write(to: sentinel)
        let output = try await fixture.runInstaller()
        #expect(output.exitCode != 0)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "safe")
    }

    @Test("normal Vim startup loads compatibility settings without changing indentation")
    func vimStartup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.install()
        try Data("set nocompatible\nset autoindent shiftwidth=7\n".utf8)
            .write(to: fixture.home.appendingPathComponent(".vimrc"))
        for terminal in ["screen-256color", "tmux-256color"] {
            let report = fixture.home.appendingPathComponent("options-\(terminal).json")
            let command = "call writefile([json_encode({'be': &t_BE, 'bd': &t_BD, 'ps': &t_PS, 'pe': &t_PE, 'ai': &autoindent, 'sw': &shiftwidth, 'paste': &paste})], '\(report.path.replacingOccurrences(of: "'", with: "''"))')"
            let output = try await TimedInventoryProcessRunner(timeout: .seconds(5), underlying: FoundationInventoryProcessRunner())
                .run(CommandSpec(executable: "/usr/bin/vim", arguments: ["-N", "-u", fixture.home.appendingPathComponent(".vimrc").path, "-i", "NONE", "-n", "-T", terminal, "-c", command, "-c", "qa!"], environment: ["HOME": fixture.home.path, "VIMINIT": "", "EXINIT": "", "TERM": terminal]))
            #expect(output.exitCode == 0, "\(output.stderr)")
            let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
            #expect(values["be"] as? String == "\u{1b}[?2004h")
            #expect(values["bd"] as? String == "\u{1b}[?2004l")
            #expect(values["ps"] as? String == "\u{1b}[200~")
            #expect(values["pe"] as? String == "\u{1b}[201~")
            #expect(values["ai"] as? Int == 1)
            #expect(values["sw"] as? Int == 7)
            #expect(values["paste"] as? Int == 0)
        }
    }

    private struct Fixture {
        let home: URL
        var plugin: URL { home.appendingPathComponent(".vim/plugin/tmuxhub-paste.vim") }

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-vim-\(UUID().uuidString) 'home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }

        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue
        }

        func runInstaller() async throws -> InventoryProcessOutput {
            let command = try VimPasteConfiguration.command(target: .local)
            return try await TimedInventoryProcessRunner(timeout: .seconds(5), underlying: FoundationInventoryProcessRunner())
                .run(CommandSpec(executable: command.executable, arguments: command.arguments + [home.path]))
        }

        func install() async throws -> VimPasteConfigurationResult {
            let output = try await runInstaller()
            #expect(output.exitCode == 0, "\(output.stderr)")
            return try VimPasteConfigurationResult.parse(output.stdout)
        }
    }
}
