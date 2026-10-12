import Foundation
import Testing
@testable import TmuxHubCore

@Suite("SSH control-master local forwarding")
struct SSHLocalForwardControlTests {
    @Test("builds isolated argv-only forwarding operations")
    func buildsForwardingCommands() throws {
        let directory = URL(fileURLWithPath: "/tmp/th-forward-command", isDirectory: true)
        let commands = SSHMasterCommands(directory: directory)
        let socket = try commands.socketPath(alias: "prod")

        let forward = try commands.openLocalForward(
            alias: "prod",
            localPort: 49_321,
            remoteHost: "127.0.0.1",
            remotePort: 8_765
        )
        #expect(forward == CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-F", "/dev/null", "-S", socket,
            "-O", "forward",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:49321:127.0.0.1:8765",
            "prod",
        ]))

        let localhost = try commands.openLocalForward(
            alias: "prod",
            localPort: 49_323,
            remoteHost: "localhost",
            remotePort: 3_000
        )
        #expect(localhost.arguments.contains("127.0.0.1:49323:localhost:3000"))

        let cancel = try commands.cancelLocalForward(
            alias: "prod",
            localPort: 49_322,
            remoteHost: "::1",
            remotePort: 6_006
        )
        #expect(cancel == CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-F", "/dev/null", "-S", socket,
            "-O", "cancel",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:49322:[::1]:6006",
            "prod",
        ]))
    }

    @Test("rejects invalid forwarding endpoints before running SSH")
    func rejectsInvalidEndpoints() async {
        let runner = ForwardControlRunner(outputs: [])
        let pool = SSHMasterPool(
            testDirectory: URL(fileURLWithPath: "/tmp/th-forward-invalid"),
            runner: runner
        )

        await #expect(throws: SSHMasterCommandError.invalidForwardHost) {
            try await pool.openLocalForward(
                alias: "prod",
                localPort: 8_765,
                remoteHost: "0.0.0.0",
                remotePort: 8_765
            )
        }
        await #expect(throws: SSHMasterCommandError.invalidForwardPort) {
            try await pool.openLocalForward(
                alias: "prod",
                localPort: 0,
                remoteHost: "127.0.0.1",
                remotePort: 8_765
            )
        }
        #expect(await runner.commands().isEmpty)
    }

    @Test("prepares once and submits the forward without replay")
    func preparesAndForwards() async throws {
        let runner = ForwardControlRunner(outputs: [
            .init(stdout: "", stderr: "No such control socket", exitCode: 255),
            .init(stdout: "", stderr: "", exitCode: 0),
            .init(stdout: "", stderr: "", exitCode: 0),
        ])
        let directory = URL(fileURLWithPath: "/tmp/th-forward-prepare")
        let pool = SSHMasterPool(testDirectory: directory, runner: runner)

        try await pool.openLocalForward(
            alias: "prod",
            localPort: 49_321,
            remoteHost: "127.0.0.1",
            remotePort: 8_765
        )

        let history = await runner.commands()
        #expect(history.count == 3)
        #expect(history[0].arguments.contains("check"))
        #expect(history[1].arguments.contains("-MNf"))
        #expect(history[2].arguments.contains("forward"))
        #expect(!history[2].arguments.contains("-MNf"))
    }

    @Test("reports a bind collision distinctly")
    func reportsBindCollision() async {
        let runner = ForwardControlRunner(outputs: [
            .init(stdout: "", stderr: "", exitCode: 0),
            .init(
                stdout: "",
                stderr: "mux_client_forward: forwarding request failed: Port forwarding failed\n"
                    + "muxclient: master forward request failed\n",
                exitCode: 255
            ),
        ])
        let pool = SSHMasterPool(
            testDirectory: URL(fileURLWithPath: "/tmp/th-forward-collision"),
            runner: runner
        )

        await #expect(throws: SSHLocalForwardingError.localPortUnavailable(8_765)) {
            try await pool.openLocalForward(
                alias: "prod",
                localPort: 8_765,
                remoteHost: "127.0.0.1",
                remotePort: 8_765
            )
        }
        #expect(await runner.commands().count == 2)
    }

    @Test("does not replay an ambiguous failed forwarding request")
    func doesNotReplayFailure() async {
        let runner = ForwardControlRunner(outputs: [
            .init(stdout: "", stderr: "", exitCode: 0),
            .init(stdout: "", stderr: "broken control connection", exitCode: 255),
        ])
        let pool = SSHMasterPool(
            testDirectory: URL(fileURLWithPath: "/tmp/th-forward-no-replay"),
            runner: runner
        )

        await #expect(throws: SSHMasterPoolError.connectionFailed(
            exitCode: 255,
            message: "broken control connection"
        )) {
            try await pool.openLocalForward(
                alias: "prod",
                localPort: 49_321,
                remoteHost: "127.0.0.1",
                remotePort: 8_765
            )
        }
        #expect(await runner.commands().count == 2)
    }

    @Test("cancellation and status checks never prepare a missing master")
    func controlOnlyOperationsDoNotPrepare() async {
        let runner = ForwardControlRunner(outputs: [
            .init(stdout: "", stderr: "missing", exitCode: 255),
            .init(stdout: "", stderr: "missing", exitCode: 255),
        ])
        let pool = SSHMasterPool(
            testDirectory: URL(fileURLWithPath: "/tmp/th-forward-control-only"),
            runner: runner
        )

        await pool.cancelLocalForward(
            alias: "prod",
            localPort: 49_321,
            remoteHost: "127.0.0.1",
            remotePort: 8_765
        )
        #expect(!(await pool.isMasterRunning(alias: "prod")))

        let history = await runner.commands()
        #expect(history.count == 2)
        #expect(history[0].arguments.contains("cancel"))
        #expect(history[1].arguments.contains("check"))
        #expect(history.allSatisfy { !$0.arguments.contains("-MNf") })
    }

    @Test("shutdown waits for an admitted forwarding command")
    func shutdownWaitsForForward() async throws {
        let runner = BlockingForwardControlRunner()
        let pool = SSHMasterPool(
            testDirectory: URL(fileURLWithPath: "/tmp/th-forward-shutdown"),
            runner: runner
        )
        let forwarding = Task {
            try await pool.openLocalForward(
                alias: "prod",
                localPort: 49_321,
                remoteHost: "127.0.0.1",
                remotePort: 8_765
            )
        }
        await runner.waitUntilForwardStarts()

        let shutdown = Task { await pool.shutdown() }
        await pool.waitUntilShutdownIsWaitingForCommandsForTesting()
        #expect(await runner.stopCount() == 0)

        await runner.releaseForward()
        try await forwarding.value
        await shutdown.value
        #expect(await runner.stopCount() == 1)
    }
}

private actor ForwardControlRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var history: [CommandSpec] = []

    init(outputs: [InventoryProcessOutput]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        history.append(command)
        guard !outputs.isEmpty else {
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        return outputs.removeFirst()
    }

    func commands() -> [CommandSpec] { history }
}

private actor BlockingForwardControlRunner: InventoryProcessRunning {
    private var forwardStarted = false
    private var forwardStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var forwardContinuation: CheckedContinuation<Void, Never>?
    private var stops = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.contains("forward") {
            forwardStarted = true
            forwardStartWaiters.forEach { $0.resume() }
            forwardStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                forwardContinuation = continuation
            }
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        if command.arguments.contains("stop") {
            stops += 1
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        if command.arguments.contains("check") {
            return .init(
                stdout: "",
                stderr: stops == 0 ? "" : "missing",
                exitCode: stops == 0 ? 0 : 255
            )
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    func waitUntilForwardStarts() async {
        guard !forwardStarted else { return }
        await withCheckedContinuation { continuation in
            forwardStartWaiters.append(continuation)
        }
    }

    func releaseForward() {
        forwardContinuation?.resume()
        forwardContinuation = nil
    }

    func stopCount() -> Int { stops }
}
