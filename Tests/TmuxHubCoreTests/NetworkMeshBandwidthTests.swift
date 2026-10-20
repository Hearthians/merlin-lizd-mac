import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Owned temporary bandwidth server")
struct NetworkMeshBandwidthTests {
    private var source: NetworkMeshEndpoint {
        .init(label: "campus", address: "10.1.0.2", username: "alice",
              sshDestination: "source-campus", networkKind: .campus)
    }
    private var target: NetworkMeshEndpoint {
        .init(label: "ZT", address: "10.61.0.3", username: "bob",
              sshDestination: "target-zt", networkKind: .zeroTier)
    }

    @Test("Receiver bits per second use decimal Mbps and verify the bound source")
    func parserUnitsAndSource() throws {
        let json = meshBandwidthJSON(source: "10.1.0.2", cookie: "same", bps: 12_000_000)
        let parsed = try NetworkMeshBandwidthParser.measurement(json, expectedSource: "10.1.0.2")
        #expect(parsed.mbps == 12)
        #expect(parsed.seconds == 3)
        #expect(throws: (any Error).self) {
            try NetworkMeshBandwidthParser.measurement(json, expectedSource: "10.1.0.99")
        }
        let ipv6 = meshBandwidthJSON(source: "2001:db8::2", cookie: "same", bps: 12_000_000)
        #expect(try NetworkMeshBandwidthParser.measurement(ipv6, expectedSource: "2001:0db8:0:0:0:0:0:2").mbps == 12)
    }

    @Test("Client and the owned server must share an iperf cookie")
    func sessionCookie() throws {
        let client = meshBandwidthJSON(source: "10.1.0.2", cookie: "ours", bps: 5_000_000)
        let ownedServer = meshBandwidthJSON(source: "10.61.0.3", cookie: "ours", bps: 7_000_000)
        #expect(try NetworkMeshBandwidthParser.measurement(client, expectedSource: "10.1.0.2", serverText: ownedServer).mbps == 7)
        let other = meshBandwidthJSON(source: "10.61.0.3", cookie: "someone-else", bps: 100_000_000)
        #expect(throws: (any Error).self) {
            try NetworkMeshBandwidthParser.measurement(client, expectedSource: "10.1.0.2", serverText: other)
        }
    }

    @Test("Lifecycle scripts verify PID ownership without a TCP probe and keep brew paths")
    func generatedLifecycle() throws {
        let token = UUID().uuidString
        let server = try NetworkMeshBandwidthCommands.server(sourceEndpoint: source, targetEndpoint: target, token: token)
        let readiness = try NetworkMeshBandwidthCommands.readiness(targetEndpoint: target, token: token)
        let cleanup = try NetworkMeshBandwidthCommands.cleanup(targetEndpoint: target, token: token)
        #expect(server.contains("trap cleanup_server EXIT"))
        #expect(server.contains("server.start"))
        #expect(server.contains("\"$second\" -lt 45"))
        #expect(server.contains("mkdir -m 700"))
        #expect(readiness.contains("has_owned_listener"))
        #expect(readiness.contains("lsof -nP -a -p"))
        #expect(readiness.contains("ss -ltnp"))
        #expect(readiness.contains("/proc/$pid/net/tcp"))
        #expect(!readiness.contains("nc -z"))
        #expect(cleanup.contains("stop_owned"))
        #expect(!cleanup.contains("pkill"))
        #expect(!cleanup.contains("killall"))
        for script in [server, readiness, try NetworkMeshBandwidthCommands.client(sourceEndpoint: source, targetEndpoint: target)] {
            #expect(script.contains("/opt/homebrew/bin:/usr/local/bin"))
        }
        #expect(throws: (any Error).self) {
            try NetworkMeshBandwidthCommands.cleanup(targetEndpoint: target, token: "$(echo arbitrary)")
        }
    }

    @Test("Windows lifecycle identifies native PID/start time and has detached watchdog and finally")
    func windowsLifecycle() throws {
        var windows = target
        windows.platform = .windows
        let token = UUID().uuidString
        let server = try NetworkMeshBandwidthCommands.server(sourceEndpoint: source, targetEndpoint: windows, token: token)
        let readiness = try NetworkMeshBandwidthCommands.readiness(targetEndpoint: windows, token: token)
        #expect(server.contains("finally"))
        #expect(server.contains("StartTime.Ticks"))
        #expect(server.contains("[Diagnostics.Process]::Start($watchInfo)"))
        #expect(server.contains("ReadToEndAsync"))
        #expect(readiness.contains("Get-NetTCPConnection"))
        #expect(readiness.contains("netstat.exe -ano"))
        #expect(readiness.contains("OwningProcess"))
    }

    @Test("Successful measurement waits for owned readiness and always cleans")
    func successLifecycle() async {
        let runner = MeshBandwidthRunner(scenario: .success)
        let result = await run(runner)
        #expect(result.status == .reachable)
        #expect(result.throughputMbps == 7)
        #expect(result.mode == .bandwidth)
        let stages = await runner.stages()
        let ready = stages.firstIndex(of: "readiness")
        let client = stages.firstIndex(of: "client")
        #expect(ready != nil && client != nil && ready! < client!)
        #expect(stages.last == "cleanup")
    }

    @Test("A busy or failed server never starts a client against an existing listener")
    func failedStartup() async {
        let runner = MeshBandwidthRunner(scenario: .serverFailure)
        let result = await run(runner)
        #expect(result.status != .reachable)
        #expect(result.throughputMbps == nil)
        #expect(!(await runner.stages()).contains("client"))
        #expect((await runner.stages()).contains("cleanup"))
    }

    @Test("Cancellation cancels server/client and runs cleanup outside cancellation")
    func cancellationCleanup() async throws {
        let runner = MeshBandwidthRunner(scenario: .clientWait)
        let task = Task { await run(runner) }
        for _ in 0..<100 {
            if (await runner.stages()).contains("client") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled)
        #expect((await runner.stages()).contains("cleanup"))
        #expect(await runner.serverWasCancelled())
        #expect(await runner.clientWasCancelled())
    }

    @Test("Only a control network failure falls back; authentication failure does not")
    func controlFallback() async {
        let network = MeshBandwidthRunner(scenario: .campusNetworkFailure)
        #expect(await run(network).status == .reachable)
        let commands = await network.commands()
        #expect(commands.contains { $0.arguments.contains("source-campus") })
        #expect(commands.contains { $0.arguments.contains("source-zt") })
        let auth = MeshBandwidthRunner(scenario: .campusAuthenticationFailure)
        #expect(await run(auth).status == .authenticationRequired)
        #expect(!(await auth.commands()).contains { $0.arguments.contains("source-zt") })
        #expect(!(await auth.stages()).contains("server"))
    }

    private func run(_ runner: MeshBandwidthRunner) async -> NetworkMeshProbeResult {
        let src = source
        let zt = NetworkMeshEndpoint(label: "ZT", address: "10.61.0.2", username: "alice",
                                    sshDestination: "source-zt", networkKind: .zeroTier)
        return await NetworkMeshBandwidthService(runner: runner, pollMilliseconds: 1).probe(
            source: .init(name: "source", endpoints: [src, zt]), sourceEndpoint: src,
            target: .init(name: "target", endpoints: [target]), targetEndpoint: target
        )
    }
}

private func meshBandwidthJSON(source: String, cookie: String, bps: Double) -> String {
    """
    {"start":{"cookie":"\(cookie)","connected":[{"local_host":"\(source)"}]},
     "end":{"sum_received":{"seconds":3,"bytes":2625000,"bits_per_second":\(bps)}}}
    """
}

private actor MeshBandwidthRunner: InventoryProcessRunning {
    enum Scenario { case success, serverFailure, clientWait, campusNetworkFailure, campusAuthenticationFailure }
    private let scenario: Scenario
    private var recorded: [CommandSpec] = []
    private var recordedStages: [String] = []
    private var serverContinuation: CheckedContinuation<InventoryProcessOutput, any Error>?
    private var serverStarted = false
    private var serverCancelled = false
    private var clientCancelled = false
    init(scenario: Scenario) { self.scenario = scenario }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recorded.append(command)
        let script = command.arguments.joined(separator: " ")
        let token = extractToken(script)
        if script.contains("TMUXHUB_BANDWIDTH_AVAILABILITY") {
            recordedStages.append("availability")
            if command.arguments.contains("source-campus") {
                if scenario == .campusNetworkFailure { return .init(stdout: "", stderr: "Connection timed out", exitCode: 255) }
                if scenario == .campusAuthenticationFailure { return .init(stdout: "", stderr: "Permission denied (publickey)", exitCode: 255) }
            }
            return .init(stdout: "TMUXHUB_IPERF_READY\n", stderr: "", exitCode: 0)
        }
        if script.contains("# TMUXHUB_BANDWIDTH_SERVER") {
            recordedStages.append("server")
            serverStarted = true
            if scenario == .serverFailure { return .init(stdout: "", stderr: "Address already in use", exitCode: 1) }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { serverContinuation = $0 }
            } onCancel: { Task { await self.cancelServer() } }
        }
        if script.contains("# TMUXHUB_BANDWIDTH_READINESS") {
            recordedStages.append("readiness")
            if scenario == .serverFailure { return .init(stdout: "", stderr: "Address already in use", exitCode: 1) }
            return .init(stdout: serverStarted ? "TMUXHUB_IPERF_OWNED_READY:\(token)\n" : "TMUXHUB_IPERF_PENDING\n",
                         stderr: "", exitCode: 0)
        }
        if script.contains("# TMUXHUB_BANDWIDTH_CLIENT") {
            recordedStages.append("client")
            if scenario == .clientWait {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { clientCancelled = true; throw error }
            }
            serverContinuation?.resume(returning: .init(
                stdout: meshBandwidthJSON(source: "10.61.0.3", cookie: "ours", bps: 7_000_000), stderr: "", exitCode: 0
            ))
            serverContinuation = nil
            return .init(stdout: meshBandwidthJSON(source: "10.1.0.2", cookie: "ours", bps: 5_000_000), stderr: "", exitCode: 0)
        }
        if script.contains("# TMUXHUB_BANDWIDTH_CLEANUP") {
            recordedStages.append("cleanup")
            #expect(!Task.isCancelled)
            return .init(stdout: "TMUXHUB_IPERF_CLEANED:\(token)\n", stderr: "", exitCode: 0)
        }
        return .init(stdout: "", stderr: "Unexpected test command", exitCode: 1)
    }

    private func cancelServer() {
        serverCancelled = true
        serverContinuation?.resume(throwing: CancellationError())
        serverContinuation = nil
    }
    private func extractToken(_ text: String) -> String {
        let pattern = #"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return "" }
        return String(text[range])
    }
    func stages() -> [String] { recordedStages }
    func commands() -> [CommandSpec] { recorded }
    func serverWasCancelled() -> Bool { serverCancelled }
    func clientWasCancelled() -> Bool { clientCancelled }
}
