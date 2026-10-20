import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Network mesh measurement and health")
struct NetworkMeshTests {
    private var sourceEndpoint: NetworkMeshEndpoint {
        .init(label: "校园", address: "10.1.0.2", username: "alice", sshDestination: "source-campus", networkKind: .campus)
    }
    private var targetEndpoint: NetworkMeshEndpoint {
        .init(label: "ZeroTier", address: "10.61.0.3", username: "bob", port: 2222,
              sshDestination: "target-zerotier", networkKind: .zeroTier)
    }
    private var success: InventoryProcessOutput {
        .init(stdout: "TMUXHUB_MESH_SOURCE_READY\nTMUXHUB_MESH_TARGET_LOGIN\nTMUXHUB_MESH_LOGIN_EXIT=0\n",
              stderr: "", exitCode: 0)
    }
    private var ready: InventoryProcessOutput {
        .init(stdout: "TMUXHUB_MESH_SOURCE_READY\n", stderr: "", exitCode: 0)
    }

    @Test("Older saved catalogs decode without automatically enrolling hosts")
    func oldCatalogDefaults() throws {
        let json = #"{"name":"lab","endpoints":[{"address":"10.0.0.2","label":"old"}]}"#
        let host = try JSONDecoder().decode(NetworkMeshHost.self, from: Data(json.utf8))
        #expect(!host.isMember)
        #expect(host.endpoints[0].environmentID == "main")
        #expect(host.endpoints[0].environmentName == "Linux")
        #expect(host.endpoints[0].platform == .posix)
        #expect(host.endpoints[0].bandwidthPort == 5201)
        #expect(try JSONDecoder().decode(NetworkMeshHost.self, from: JSONEncoder().encode(host)) == host)
    }

    @Test("Routes distinguish directions and every pair of interfaces")
    func routeIdentity() {
        let a = UUID(), b = UUID(), e1 = UUID(), e2 = UUID(), e3 = UUID()
        let route = NetworkMeshRoute(sourceHostID: a, sourceEndpointID: e1, targetHostID: b, targetEndpointID: e2)
        #expect(route.id == route.id)
        #expect(route.id != NetworkMeshRoute(sourceHostID: b, sourceEndpointID: e2, targetHostID: a, targetEndpointID: e1).id)
        #expect(route.id != NetworkMeshRoute(sourceHostID: a, sourceEndpointID: e3, targetHostID: b, targetEndpointID: e2).id)
    }

    @Test("Source control candidates preserve environment and account")
    func controlSelection() {
        let campus = sourceEndpoint
        let zt = NetworkMeshEndpoint(label: "ZT", address: "10.61.0.2", username: "alice", sshDestination: "source-zt", networkKind: .zeroTier)
        let windows = NetworkMeshEndpoint(label: "Windows", address: "10.1.0.2", username: "alice",
                                         environmentID: "windows", platform: .windows)
        let otherUser = NetworkMeshEndpoint(label: "root", address: "10.1.0.2", username: "root")
        let host = NetworkMeshHost(name: "same machine", endpoints: [windows, otherUser, zt, campus])
        #expect(NetworkMeshCommands.controlEndpoints(for: host, sourceEndpoint: zt).map(\.id) == [campus.id, zt.id])
    }

    @Test("Control SSH is separate from source-bound direct target SSH")
    func boundCommands() throws {
        let src = sourceEndpoint, dst = targetEndpoint
        let host = NetworkMeshHost(name: "source", endpoints: [src])
        let command = try NetworkMeshCommands.probe(source: host, sourceEndpoint: src, targetEndpoint: dst, mode: .speed)
        #expect(command.arguments.contains("source-campus"))
        #expect(command.arguments.contains("Hostname=10.1.0.2"))
        // Source control uses the selected alias credentials, including before first-time onboarding.
        #expect(!command.arguments.contains("-i"))
        let script = try #require(command.arguments.last)
        #expect(script.contains("'-b'"))
        #expect(script.contains("10.1.0.2"))
        #expect(script.contains("10.61.0.3"))
        #expect(script.contains("'-F'"))
        #expect(script.contains("/dev/null"))
        #expect(script.contains("ProxyCommand=none"))
        #expect(script.contains("ProxyJump=none"))
        #expect(script.contains("ControlMaster=no"))
        #expect(script.contains("ControlPath=none"))
        #expect(script.contains("Compression=no"))
        #expect(script.contains("StrictHostKeyChecking=yes"))
        #expect(script.contains("IdentitiesOnly=yes"))
        #expect(!command.arguments.contains("IdentitiesOnly=yes"))
        #expect(script.contains("UserKnownHostsFile=~/.ssh/tmuxhub_mesh_known_hosts"))
        #expect(script.contains("count=32"))
        #expect(!script.contains("target-zerotier"))
        #expect(!script.contains("ForwardAgent=yes"))
    }

    @Test("Literal IPv6 health destinations retain a valid SSH argv boundary")
    func ipv6ControlDestination() throws {
        let endpoint = NetworkMeshEndpoint(label: "IPv6", address: "::1", username: "alice")
        let command = try NetworkMeshCommands.controlCommand(endpoint: endpoint, remoteCommand: "true")
        #expect(command.arguments.contains("[::1]"))
        #expect(command.arguments.contains("Hostname=::1"))
    }

    @Test("Scoped IPv6 control hosts escape the OpenSSH percent expansion")
    func scopedIPv6ControlDestination() throws {
        let endpoint = NetworkMeshEndpoint(label: "IPv6", address: "fe80::1%en0", username: "alice")
        let command = try NetworkMeshCommands.controlCommand(endpoint: endpoint, remoteCommand: "true")
        #expect(command.arguments.contains("[fe80::1%en0]"))
        #expect(command.arguments.contains("Hostname=fe80::1%%en0"))
        #expect(!command.arguments.contains("Hostname=fe80::1%en0"))
    }

    @Test("Windows sources use an encoded PowerShell script and binary streams")
    func windowsCommand() throws {
        var src = sourceEndpoint
        src.platform = .windows
        let host = NetworkMeshHost(name: "Windows", endpoints: [src])
        var dst = targetEndpoint
        dst.platform = .windows
        let command = try NetworkMeshCommands.probe(source: host, sourceEndpoint: src, targetEndpoint: dst, mode: .speed)
        let remote = try #require(command.arguments.last)
        let base64 = try #require(remote.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(base64)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(remote.hasPrefix("powershell.exe "))
        #expect(script.contains("BaseStream.Write"))
        #expect(script.contains("'NUL'"))
        #expect(script.contains("'-b', '10.1.0.2'"))
        #expect(script.contains("TMUXHUB_MESH_TRANSFER_EXIT="))
    }

    @Test("Diagnostics strip controls, retain newlines, and bound saved remote output")
    func diagnosticSanitization() {
        #expect(networkMeshDiagnostic(" \u{0}\u{1B}hello\r\nworld\u{7F} ") == "hello\nworld")
        #expect(networkMeshDiagnostic("\u{0}\r\t\n ") == nil)
        #expect(networkMeshDiagnostic(String(repeating: "x", count: 5000))?.count == 4096)
    }

    @Test("Shell quoting preserves dangerous text as data")
    func quoteBoundary() async throws {
        let value = "literal $(echo unexpected) ' \" \n end"
        let output = try await FoundationInventoryProcessRunner().run(
            .init(executable: "/bin/sh", arguments: ["-c", "printf %s " + NetworkMeshCommands.quote(value)])
        )
        #expect(output.stdout == value)
        #expect(output.exitCode == 0)
    }

    @Test("Malformed or DNS source addresses never execute a subprocess")
    func invalidAddress() async {
        var src = sourceEndpoint
        src.address = "host.example"
        let runner = MeshScriptedRunner(steps: [])
        let result = await NetworkMeshProbeService(runner: runner).probe(
            source: .init(name: "local", isLocal: true), sourceEndpoint: src,
            target: .init(name: "target"), targetEndpoint: targetEndpoint, mode: .connectivity
        )
        #expect(result.status == .unsupported)
        #expect(await runner.commands().isEmpty)
        src.address = "10.1.0.2\n$(touch /tmp/mesh-test)"
        let second = await NetworkMeshProbeService(runner: runner).probe(
            source: .init(name: "local", isLocal: true), sourceEndpoint: src,
            target: .init(name: "target"), targetEndpoint: targetEndpoint, mode: .speed
        )
        #expect(second.status == .unsupported)
        #expect(await runner.commands().isEmpty)
    }

    @Test("TCP success alone never establishes SSH mesh authorization")
    func tcpIsNotAuthentication() {
        let output = InventoryProcessOutput(stdout: "TMUXHUB_MESH_SOURCE_READY\nTMUXHUB_MESH_TCP_REACHABLE\n",
                                            stderr: "", exitCode: 0)
        let result = NetworkMeshProbeParser.parse(output, route: route(), mode: .connectivity)
        #expect(result.status == .unreachable)
        #expect(result.throughputMbps == nil)
    }

    @Test("RTT uses source-side ping statistics rather than control elapsed time")
    func rttStatistics() {
        var output = success
        output = .init(stdout: output.stdout + "rtt min/avg/max/mdev = 0.4/1.25/2.3/0.8 ms\n", stderr: "", exitCode: 0)
        let result = NetworkMeshProbeParser.parse(output, route: route(), mode: .connectivity)
        #expect(result.status == .reachable)
        #expect(result.latencyMilliseconds == 1.25)
        #expect(NetworkMeshProbeParser.averagePingMilliseconds("round-trip min/avg/max/stddev = 1.0/2.0/3.0/0.5 ms") == 2)
    }

    @Test("BSD, GNU and Windows receive statistics produce the same SSH throughput")
    func transferStatistics() {
        let statistics = [
            "33554432 bytes transferred in 2.000000 secs (16777216 bytes/sec)",
            "33554432 bytes (34 MB, 32 MiB) copied, 2.0 s, 16.8 MB/s",
            "TMUXHUB_MESH_WINDOWS_TRANSFER=33554432/2.0",
        ]
        for text in statistics {
            let output = InventoryProcessOutput(
                stdout: "TMUXHUB_MESH_SOURCE_READY\nTMUXHUB_MESH_TARGET_LOGIN\nTMUXHUB_MESH_TRANSFER_EXIT=0\n",
                stderr: text, exitCode: 0
            )
            let result = NetworkMeshProbeParser.parse(output, route: route(), mode: .speed)
            #expect(result.status == .reachable)
            #expect(result.throughputMbps == 134.217728)
            #expect(result.latencyMilliseconds == nil)
            #expect(result.mode == .speed)
        }
        #expect(NetworkMeshProbeParser.transferredBytesAndSeconds("33554432 bytes transferred in 0 secs") == nil)
    }

    @Test("Partial or missing transfers never yield fabricated throughput")
    func incompleteTransfer() {
        let output = InventoryProcessOutput(
            stdout: "TMUXHUB_MESH_SOURCE_READY\nTMUXHUB_MESH_TARGET_LOGIN\nTMUXHUB_MESH_TRANSFER_EXIT=0\n",
            stderr: "100 bytes transferred in 1 secs", exitCode: 0
        )
        let result = NetworkMeshProbeParser.parse(output, route: route(), mode: .speed)
        #expect(result.status == .unsupported)
        #expect(result.throughputMbps == nil)
    }

    @Test("Network failures can fall back from campus control to ZeroTier")
    func controlNetworkFallback() async {
        let src = sourceEndpoint
        let zt = NetworkMeshEndpoint(label: "ZT", address: "10.61.0.2", username: "alice",
                                    sshDestination: "source-zt", networkKind: .zeroTier)
        let host = NetworkMeshHost(name: "source", endpoints: [zt, src])
        let runner = MeshScriptedRunner(steps: [
            .output(.init(stdout: "", stderr: "Connection timed out", exitCode: 255)),
            .output(ready), .output(success),
        ])
        let result = await NetworkMeshProbeService(runner: runner).probe(
            source: host, sourceEndpoint: zt, target: .init(name: "target"), targetEndpoint: targetEndpoint, mode: .connectivity
        )
        #expect(result.status == .reachable)
        let commands = await runner.commands()
        #expect(commands.count == 3)
        #expect(commands[0].arguments.contains("source-campus"))
        #expect(commands[1].arguments.contains("source-zt"))
        #expect(commands[2].arguments.contains("source-zt"))
        #expect(result.route.sourceEndpointID == zt.id)
    }

    @Test("Authentication and host-key errors stop control fallback")
    func securityFailureStopsFallback() async {
        for (error, status) in [
            ("Permission denied (publickey,password).", NetworkMeshProbeStatus.authenticationRequired),
            ("Host key verification failed.", NetworkMeshProbeStatus.hostKeyFailure),
            ("Received disconnect: Too many authentication failures\nConnection closed", .authenticationRequired),
            ("No supported authentication methods available\nConnection closed", .authenticationRequired),
            ("sign_and_send_pubkey: signing failed: agent refused operation", .authenticationRequired),
            ("Bad configuration option: InvalidSetting\nConnection closed", .unsupported),
            ("Unable to negotiate: no matching key exchange method found\nConnection closed", .unsupported),
            ("Unknown SSH failure", .unsupported),
        ] {
            let src = sourceEndpoint
            let zt = NetworkMeshEndpoint(label: "ZT", address: "10.61.0.2", username: "alice", networkKind: .zeroTier)
            let runner = MeshScriptedRunner(steps: [.output(.init(stdout: "", stderr: error, exitCode: 255)), .output(ready)])
            let result = await NetworkMeshProbeService(runner: runner).probe(
                source: .init(name: "source", endpoints: [src, zt]), sourceEndpoint: src,
                target: .init(name: "target"), targetEndpoint: targetEndpoint, mode: .connectivity
            )
            #expect(result.status == status)
            #expect(await runner.commands().count == 1)
        }
    }

    @Test("Timeout after source readiness does not reroute the measurement")
    func measuredTimeoutDoesNotFallback() async {
        let src = sourceEndpoint
        let zt = NetworkMeshEndpoint(label: "ZT", address: "10.61.0.2", username: "alice", networkKind: .zeroTier)
        let runner = MeshScriptedRunner(steps: [.output(ready), .sleep])
        let result = await NetworkMeshProbeService(runner: runner, timeoutSeconds: 0.02).probe(
            source: .init(name: "source", endpoints: [src, zt]), sourceEndpoint: src,
            target: .init(name: "target"), targetEndpoint: targetEndpoint, mode: .speed
        )
        #expect(result.status == .unreachable)
        #expect(result.throughputMbps == nil)
        #expect(await runner.commands().count == 2)
        #expect(await runner.wasCancelled())
    }

    @Test("Cancellation is preserved and cancels the underlying operation")
    func cancellation() async throws {
        let runner = MeshScriptedRunner(steps: [.sleep])
        let service = NetworkMeshProbeService(runner: runner)
        let src = sourceEndpoint, dst = targetEndpoint
        let task = Task {
            await service.probe(source: .init(name: "local", isLocal: true), sourceEndpoint: src,
                                target: .init(name: "target"), targetEndpoint: dst, mode: .connectivity)
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        #expect(await task.value.status == .cancelled)
        #expect(await runner.wasCancelled())
    }

    @Test("Concurrent mesh requests honor the configured process limit")
    func boundedConcurrency() async {
        let runner = MeshConcurrencyRunner()
        let service = NetworkMeshProbeService(runner: runner, maxConcurrentProbes: 2)
        let src = sourceEndpoint, dst = targetEndpoint
        await withTaskGroup(of: NetworkMeshProbeResult.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await service.probe(source: .init(name: "local", isLocal: true), sourceEndpoint: src,
                                        target: .init(name: "target"), targetEndpoint: dst, mode: .connectivity)
                }
            }
            for await result in group { #expect(result.status == .reachable) }
        }
        #expect(await runner.maximumActive() == 2)
    }

    @Test("Health requires a fresh executed marker rather than just an SSH exit")
    func healthMarker() async {
        let endpoint = targetEndpoint
        let runner = MeshHealthRunner()
        let before = Date()
        let result = await NetworkMeshHealthService(runner: runner).check(host: .init(name: "target"), endpoint: endpoint)
        #expect(result.status == .online)
        #expect(result.sshAuthenticated)
        #expect(result.checkedAt >= before)
        #expect(result.endpointID == endpoint.id)
    }

    @Test("Health timeout records a fresh observation without inferring shutdown")
    func healthTimeout() async {
        let runner = MeshScriptedRunner(steps: [.sleep, .sleep])
        let before = Date()
        let result = await NetworkMeshHealthService(runner: runner, timeoutSeconds: 0.01).check(
            host: .init(name: "target"), endpoint: targetEndpoint
        )
        #expect(result.status == .unreachable)
        #expect(result.message.contains("不能据此判断关机"))
        #expect(result.checkedAt >= before)
        #expect(!result.sshAuthenticated)
        #expect(await runner.wasCancelled())
    }

    @Test("TCP-only health remains separate from authenticated health")
    func healthTCPOnly() async {
        let runner = MeshScriptedRunner(steps: [
            .output(.init(stdout: "", stderr: "Connection closed", exitCode: 255)),
            .output(.init(stdout: "", stderr: "", exitCode: 0)),
        ])
        let result = await NetworkMeshHealthService(runner: runner).check(host: .init(name: "target"), endpoint: targetEndpoint)
        #expect(result.status == .networkOnly)
        #expect(result.networkResponded)
        #expect(!result.sshAuthenticated)
        #expect(await runner.commands().last?.executable == "/usr/bin/nc")
    }

    private func route() -> NetworkMeshRoute {
        .init(sourceHostID: UUID(), sourceEndpointID: UUID(), targetHostID: UUID(), targetEndpointID: UUID())
    }
}

private actor MeshScriptedRunner: InventoryProcessRunning {
    enum Step: Sendable { case output(InventoryProcessOutput), sleep }
    private var steps: [Step]
    private var recorded: [CommandSpec] = []
    private var cancelled = false
    init(steps: [Step]) { self.steps = steps }
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recorded.append(command)
        guard !steps.isEmpty else { return .init(stdout: "", stderr: "unexpected command", exitCode: 1) }
        switch steps.removeFirst() {
        case .output(let output): return output
        case .sleep:
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
    }
    func commands() -> [CommandSpec] { recorded }
    func wasCancelled() -> Bool { cancelled }
}

private actor MeshConcurrencyRunner: InventoryProcessRunning {
    private var active = 0
    private var maximum = 0
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return .init(stdout: "TMUXHUB_MESH_SOURCE_READY\nTMUXHUB_MESH_TARGET_LOGIN\nTMUXHUB_MESH_LOGIN_EXIT=0\n",
                     stderr: "", exitCode: 0)
    }
    func maximumActive() -> Int { maximum }
}

private struct MeshHealthRunner: InventoryProcessRunning {
    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        let text = command.arguments.joined(separator: " ")
        let regex = try NSRegularExpression(pattern: "TMUXHUB_MESH_HEALTH_[A-Z0-9]+")
        let match = try #require(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let range = try #require(Range(match.range, in: text))
        return .init(stdout: String(text[range]) + "\n", stderr: "", exitCode: 0)
    }
}
