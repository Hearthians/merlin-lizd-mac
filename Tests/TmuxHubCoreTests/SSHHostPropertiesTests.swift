import Foundation
import Testing
@testable import TmuxHubCore

@Suite("SSH host properties")
struct SSHHostPropertiesTests {
    private let output = """
        host lab
        hostname 192.0.2.42
        user research
        port 2222
        identityfile ~/.ssh/lab key
        identityfile ~/.ssh/backup
        proxyjump user@gateway.example:2200
        """

    @Test("configuration evaluation uses argv without connecting or invoking a shell")
    func command() async throws {
        let runner = PropertiesRunner(result: .init(stdout: output, stderr: "", exitCode: 0))
        let config = URL(fileURLWithPath: "/tmp/SSH config fixture")
        let properties = try await SSHHostPropertiesReader(runner: runner, configFile: config)
            .load(destination: "alice@lab")
        #expect(properties.destination == "alice@lab")
        #expect(properties.hostname == "192.0.2.42")
        #expect(properties.username == "research")
        #expect(properties.port == 2222)
        #expect(properties.identityFiles == ["~/.ssh/lab key", "~/.ssh/backup"])
        #expect(properties.proxyJump == "user@gateway.example:2200")
        #expect(properties.proxyCommand == nil)
        #expect(await runner.commands() == [CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-G", "-T", "-F", config.path, "--", "alice@lab"],
            environment: ["LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]
        )])
    }

    @Test("invalid destinations are rejected before starting a process")
    func invalidDestinations() async throws {
        let runner = PropertiesRunner(result: .init(stdout: output, stderr: "", exitCode: 0))
        let reader = SSHHostPropertiesReader(runner: runner)
        for destination in ["", "-F/tmp/config", "host\nProxyCommand bad", "host;touch /tmp/bad"] {
            await #expect(throws: SSHHostPropertiesError.invalidDestination) {
                try await reader.load(destination: destination)
            }
        }
        #expect(await runner.commands().isEmpty)
    }

    @Test("multiple identity files, proxy commands and disabled settings retain their meaning")
    func parser() throws {
        let properties = try SSHHostPropertiesReader.parse("""
            hostname example.test
            user me
            port 22
            identityfile none
            identityfile /Users/me/My Keys/key
            identityfile /Users/me/My Keys/key
            proxyjump none
            proxycommand /usr/bin/nc -x proxy.example:1080 %h %p
            """, destination: "example")
        #expect(properties.identityFiles == ["/Users/me/My Keys/key"])
        #expect(properties.proxyJump == nil)
        #expect(properties.proxyCommand == "/usr/bin/nc -x proxy.example:1080 %h %p")
        #expect(throws: SSHHostPropertiesError.invalidOutput) {
            try SSHHostPropertiesReader.parse("hostname example\nuser me\nport 65536", destination: "example")
        }
        #expect(throws: SSHHostPropertiesError.invalidOutput) {
            try SSHHostPropertiesReader.parse("hostname example\nport 22", destination: "example")
        }
    }

    @Test("errors preserve a bounded diagnostic without terminal control characters")
    func diagnostic() async throws {
        let message = "\u{0000}\u{001B}Bad configuration option\n" + String(repeating: "x", count: 6_000)
        let runner = PropertiesRunner(result: .init(stdout: "", stderr: message, exitCode: 255))
        do {
            _ = try await SSHHostPropertiesReader(runner: runner).load(destination: "lab")
            Issue.record("Expected a configuration error")
        } catch let SSHHostPropertiesError.commandFailed(value) {
            #expect(value.hasPrefix("Bad configuration option\n"))
            #expect(value.count == 4_096)
            #expect(!value.contains("\u{0000}"))
            #expect(!value.contains("\u{001B}"))
        }
    }

    @Test("oversized outputs are rejected even for injected runners")
    func outputBound() async throws {
        let runner = PropertiesRunner(result: .init(
            stdout: String(repeating: "x", count: 1_048_577), stderr: "", exitCode: 0
        ))
        await #expect(throws: SSHHostPropertiesError.outputTooLarge) {
            try await SSHHostPropertiesReader(runner: runner).load(destination: "lab")
        }
    }

    @Test("cancellation remains cancellation and timeouts have a useful message")
    func interruptedRead() async throws {
        await #expect(throws: CancellationError.self) {
            try await SSHHostPropertiesReader(runner: InterruptedPropertiesRunner(cancelled: true))
                .load(destination: "lab")
        }
        await #expect(throws: SSHHostPropertiesError.timedOut) {
            try await SSHHostPropertiesReader(runner: InterruptedPropertiesRunner(cancelled: false))
                .load(destination: "lab")
        }
    }

    @Test("system OpenSSH resolves aliases, includes, wildcard defaults and user overrides")
    func systemEvaluation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-properties-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let included = directory.appendingPathComponent("included-config")
        try Data("""
            Host properties-fixture
                HostName 192.0.2.42
                User config-user
                Port 2222
                IdentityFile "/tmp/fixture key"
                ProxyJump jump.example
            Host *
                User fallback
                Port 2022
            """.utf8).write(to: included)
        try Data("Include \"\(included.path)\"\n".utf8).write(to: config)
        let reader = SSHHostPropertiesReader(configFile: config)
        let host = try await reader.load(destination: "properties-fixture")
        #expect(host.hostname == "192.0.2.42")
        #expect(host.username == "config-user")
        #expect(host.port == 2222)
        #expect(host.identityFiles == ["/tmp/fixture key"])
        #expect(host.proxyJump == "jump.example")
        let overridden = try await reader.load(destination: "explicit-user@properties-fixture")
        #expect(overridden.username == "explicit-user")
        #expect(overridden.hostname == "192.0.2.42")
        let fallback = try await reader.load(destination: "other-fixture")
        #expect(fallback.username == "fallback")
        #expect(fallback.port == 2022)
    }
}

private actor PropertiesRunner: InventoryProcessRunning {
    private let result: InventoryProcessOutput
    private var history: [CommandSpec] = []

    init(result: InventoryProcessOutput) { self.result = result }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        history.append(command)
        return result
    }

    func commands() -> [CommandSpec] { history }
}

private struct InterruptedPropertiesRunner: InventoryProcessRunning {
    let cancelled: Bool

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if cancelled { throw CancellationError() }
        throw InventoryProcessTimeoutError.timedOut
    }
}
