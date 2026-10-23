import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Remote VS Code destination")
struct RemoteEditorDestinationTests {
    @Test("remote resources retain exact paths and explicit file or folder kinds")
    func pathsAndKinds() throws {
        let path = "/home/me/中文 + space/#?%&= ' \"folder.with.dot"
        for kind in [RemoteEditorDestination.Kind.folder, .file] {
            let destination = try RemoteEditorDestination(sshDestination: "user+tag@host", absolutePath: path, kind: kind)
            let components = try #require(URLComponents(url: destination.uri, resolvingAgainstBaseURL: false))
            #expect(components.scheme == "vscode-remote")
            #expect(components.percentEncodedHost?.removingPercentEncoding == "ssh-remote+user+tag@host")
            #expect(components.path == path)
            #expect(components.query == nil)
            #expect(components.fragment == nil)
            #expect(destination.cliArguments.first == (kind == .folder ? "--folder-uri" : "--file-uri"))
            #expect(destination.cliArguments.last == destination.uri.absoluteString)
        }
    }

    @Test("SSH destination punctuation cannot change URI authority structure", arguments: [
        "server", "user@server", "user+tag@host", "user@[2001:db8::1]", "user@fe80::1%en0",
    ])
    func authorityEncoding(_ host: String) throws {
        let destination = try RemoteEditorDestination(sshDestination: host, absolutePath: "/tmp/test", kind: .folder)
        let components = try #require(URLComponents(url: destination.uri, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedHost?.removingPercentEncoding == "ssh-remote+" + host)
        #expect(components.user == nil)
        #expect(components.password == nil)
        #expect(components.port == nil)
    }

    @Test("invalid paths and destinations are rejected")
    func rejectsInvalidRequests() {
        for path in ["", ".", "~/work", "relative", "/tmp/\nfile", "/tmp/\0file", "/tmp/\u{1b}file"] {
            #expect(throws: RemoteEditorError.invalidPath) {
                try RemoteEditorDestination(sshDestination: "server", absolutePath: path, kind: .file)
            }
        }
        for host in ["", "-host", "host/path", "host?x", "host\nHost *"] {
            #expect(throws: RemoteEditorError.invalidDestination) {
                try RemoteEditorDestination(sshDestination: host, absolutePath: "/tmp/test", kind: .file)
            }
        }
    }

    @Test("pinned config preserves authentication but does not replay commands or shared sockets")
    func scopedConfiguration() throws {
        let configuration = try RemoteEditorSSHConfiguration.configuration(endpoint: endpoint, resolvedConfiguration: resolved)
        #expect(configuration.contains("HostName 10.120.81.43"))
        #expect(configuration.contains("HostKeyAlias hpc4login.hpc.hkust-gz.edu.cn"))
        #expect(configuration.contains("StrictHostKeyChecking yes"))
        #expect(configuration.contains("identityfile \"~/.ssh/hpc4 key\""))
        #expect(configuration.contains("proxyjump gateway"))
        #expect(configuration.contains("ControlPath none"))
        #expect(!configuration.contains("/tmp/shared-master"))
        #expect(!configuration.contains("remote-side-command"))
        #expect(!configuration.contains("local-side-command"))
        #expect(!configuration.contains("9999 localhost:99"))
    }

    @Test("config install preserves a user's config symlink and remains idempotent")
    func configInstall() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let actual = home.appendingPathComponent("actual-config")
        let existing = "Host ordinary\n    HostName example.test\n"
        try Data(existing.utf8).write(to: actual)
        let link = home.appendingPathComponent(".ssh/config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let writer = RemoteEditorSSHConfiguration(homeDirectory: home)
        let alias = try writer.install(endpoint: endpoint, resolvedConfiguration: resolved)
        #expect(try writer.install(endpoint: endpoint, resolvedConfiguration: resolved) == alias)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        let updated = try String(contentsOf: actual, encoding: .utf8)
        #expect(updated.hasSuffix(existing))
        #expect(updated.components(separatedBy: "# BEGIN TmuxHub remote editor").count == 2)
        let managed = home.appendingPathComponent(".ssh/tmuxhub-code/\(alias).conf")
        let mode = try FileManager.default.attributesOfItem(atPath: managed.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("generated pinned configuration is accepted by the system OpenSSH client")
    func openSSHConfigurationRoundTrip() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".ssh/config")
        try Data("Host hpc4\n HostName hpc4login.hpc.hkust-gz.edu.cn\n User tester\n Port 2222\n IdentityFile \"/tmp/a key\"\n ProxyJump gateway\n".utf8).write(to: config)
        let runner = FoundationInventoryProcessRunner()
        let original = try await runner.run(CommandSpec(executable: "/usr/bin/ssh",
            arguments: ["-G", "-T", "-F", config.path, "hpc4"]))
        #expect(original.exitCode == 0)
        let alias = try RemoteEditorSSHConfiguration(homeDirectory: home)
            .install(endpoint: endpoint, resolvedConfiguration: original.stdout)
        let generated = try await runner.run(CommandSpec(executable: "/usr/bin/ssh",
            arguments: ["-G", "-T", "-F", config.path, alias]))
        #expect(generated.exitCode == 0)
        let properties = try SSHHostPropertiesReader.parse(generated.stdout, destination: alias)
        #expect(properties.hostname == endpoint.address)
        #expect(properties.username == "tester")
        #expect(properties.port == 2222)
        #expect(properties.identityFiles.contains("/tmp/a key"))
        #expect(properties.proxyJump == "gateway")
        #expect(generated.stdout.contains("stricthostkeychecking true\n") || generated.stdout.contains("stricthostkeychecking yes\n"))
        #expect(generated.stdout.contains("hostkeyalias hpc4login.hpc.hkust-gz.edu.cn\n"))
    }

    @Test("ordinary hosts keep their original alias and do not write configuration")
    func ordinaryHost() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = StaticEditorConfigurationRunner(output: "hostname example.test\nuser me\nport 22\n")
        let destination = try await RemoteEditorService.resolve(sshDestination: "my-host", absolutePath: "/work", kind: .folder,
            hostname: "machine", serverAddress: "10.0.0.2", runner: runner, homeDirectory: home)
        #expect(destination.sshDestination == "my-host")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh/config").path))
    }

    @Test("HPC requests pin the authenticated login node and reject mismatched identities")
    func pinnedResolution() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = StaticEditorConfigurationRunner(output: resolved)
        let destination = try await RemoteEditorService.resolve(sshDestination: "hpc4", absolutePath: "/work", kind: .folder,
            hostname: "HPC4-Login-3", serverAddress: "10.120.81.43", runner: runner, homeDirectory: home)
        #expect(destination.sshDestination.hasPrefix("tmuxhub-code-"))
        for (hostname, address) in [("HPC3-Login-1", "10.120.81.43"), ("HPC4-Login-3", "8.8.8.8")] {
            await #expect(throws: RemoteEditorError.unsupportedNode) {
                try await RemoteEditorService.resolve(sshDestination: "hpc4", absolutePath: "/work", kind: .folder,
                    hostname: hostname, serverAddress: address, runner: runner, homeDirectory: home)
            }
        }
    }

    private var endpoint: CodexNotificationSSHEndpoint {
        CodexNotificationSSHEndpoint(destination: "hpc4", address: "10.120.81.43", hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
    }

    private var resolved: String {
        """
        hostname hpc4login.hpc.hkust-gz.edu.cn
        user tester
        port 2222
        identityfile ~/.ssh/%n key
        proxyjump gateway
        identitiesonly yes
        controlpath /tmp/shared-master
        remotecommand remote-side-command
        localcommand local-side-command
        localforward 9999 localhost:99
        """
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-code-tests-\(UUID().uuidString)")
    }
}

private struct StaticEditorConfigurationRunner: InventoryProcessRunning {
    let output: String
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        InventoryProcessOutput(stdout: output, stderr: "", exitCode: 0)
    }
}
