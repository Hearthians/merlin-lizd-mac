import Testing
@testable import MerlinLizdCore

@Suite("SSH master pool")
struct SSHMasterPoolTests {
    @Test("concurrent preparation for one alias launches one master")
    func coalescesPreparation() async {
        let runner = SSHMasterScriptedRunner(prepareExitCodes: [0])
        let pool = SSHMasterPool(testDirectory: temporarySSHDirectory(), runner: runner)
        async let first = pool.prepare(alias: "hl_gpu_2", priority: .background)
        async let second = pool.prepare(alias: "hl_gpu_2", priority: .foreground)
        #expect(await [first, second] == [.ready, .ready])
        #expect(await runner.count(argumentsContaining: "ControlMaster=yes") == 1)
    }

    @Test("foreground preparation jumps queued background aliases")
    func prioritizesForeground() async {
        let gate = AsyncStartGate()
        let runner = SSHMasterScriptedRunner(actions: [
            .exit(255), .wait(gate, then: .succeed),
            .exit(255), .succeed,
            .exit(255), .succeed,
        ])
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: runner,
            maxConcurrentPreparations: 1
        )
        let first = Task { await pool.prepare(alias: "first", priority: .background) }
        await gate.waitUntilEntered()
        let background = Task { await pool.prepare(alias: "background", priority: .background) }
        let foreground = Task { await pool.prepare(alias: "foreground", priority: .foreground) }
        await pool.waitUntilPreparationCountForTesting(3)
        await gate.open()
        _ = await [first.value, foreground.value, background.value]
        let starts = await runner.masterStartAliases()
        #expect(starts == ["first", "foreground", "background"])
    }

    @Test("read-only command rebuilds once after dead-master transport failure")
    func retriesReadOnce() async throws {
        let runner = SSHMasterScriptedRunner(actions: [
            .exit(255), .succeed, .exit(255), .exit(255), .succeed, .succeed,
        ])
        let pool = SSHMasterPool(testDirectory: temporarySSHDirectory(), runner: runner)
        let command = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "hl_gpu_2", "tmux list-sessions"]
        )
        let output = try await pool.run(command, alias: "hl_gpu_2", replay: .readOnly)
        #expect(output.exitCode == 0)
        #expect(await runner.childCommandCount(alias: "hl_gpu_2") == 2)
    }

    @Test("mutation command is never replayed")
    func neverReplaysMutation() async {
        let runner = SSHMasterScriptedRunner(actions: [.exit(255), .succeed, .exit(255)])
        let pool = SSHMasterPool(testDirectory: temporarySSHDirectory(), runner: runner)
        let command = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "hl_gpu_2", "tmux kill-session -t train"]
        )
        await #expect(throws: SSHMasterPoolError.commandFailed(exitCode: 255)) {
            try await pool.run(command, alias: "hl_gpu_2", replay: .never)
        }
        #expect(await runner.childCommandCount(alias: "hl_gpu_2") == 1)
    }

    @Test("read-only command does not replay a remote command failure")
    func doesNotReplayRemoteFailure() async {
        let runner = SSHMasterScriptedRunner(actions: [.exit(255), .succeed, .exit(1)])
        let pool = SSHMasterPool(testDirectory: temporarySSHDirectory(), runner: runner)
        let command = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "hl_gpu_2", "false"]
        )
        await #expect(throws: SSHMasterPoolError.commandFailed(exitCode: 1)) {
            try await pool.run(command, alias: "hl_gpu_2", replay: .readOnly)
        }
        #expect(await runner.childCommandCount(alias: "hl_gpu_2") == 1)
    }

    @Test("read-only command propagates cancellation without rebuilding")
    func doesNotReplayCancellation() async {
        let runner = SSHMasterCancellationRunner()
        let pool = SSHMasterPool(testDirectory: temporarySSHDirectory(), runner: runner)
        let command = CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-nT", "hl_gpu_2", "tmux list-sessions"]
        )
        await #expect(throws: CancellationError.self) {
            try await pool.run(command, alias: "hl_gpu_2", replay: .readOnly)
        }
        #expect(await runner.childCommandCount() == 1)
    }

    @Test("creates the app-owned socket directory with owner-only permissions")
    func securesSocketDirectory() async throws {
        let directory = temporarySSHDirectory()
        let runner = SSHMasterScriptedRunner(prepareExitCodes: [0])
        let pool = SSHMasterPool(testDirectory: directory, runner: runner)

        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .background) == .ready)
        #expect(try posixMode(of: directory) == 0o700)
    }

    @Test("removes a stale socket only after check reports it abandoned")
    func removesProvenStaleSocket() async throws {
        let directory = temporarySSHDirectory()
        try createDirectory(at: directory)
        let socketPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        try createEmptyFile(atPath: socketPath)
        let runner = SSHMasterScriptedRunner(actions: [.exit(255), .succeed])
        let pool = SSHMasterPool(testDirectory: directory, runner: runner)

        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .background) == .ready)
        #expect(!fileExists(atPath: socketPath))
    }

    @Test("keeps a socket when check fails without proving abandonment")
    func keepsSocketAfterThrownCheck() async throws {
        let directory = temporarySSHDirectory()
        try createDirectory(at: directory)
        let socketPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        try createEmptyFile(atPath: socketPath)
        let runner = SSHMasterScriptedRunner(actions: [.fail(.transport), .succeed])
        let pool = SSHMasterPool(testDirectory: directory, runner: runner)

        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .background) == .ready)
        #expect(fileExists(atPath: socketPath))
    }

    @Test("shutdown stops masters without issuing tmux commands")
    func stopsGracefully() async {
        let runner = SSHMasterScriptedRunner(actions: [
            .exit(255), .succeed, .exit(255), .succeed,
            .succeed, .exit(255), .succeed, .exit(255),
        ])
        let pool = SSHMasterPool(testDirectory: temporarySSHDirectory(), runner: runner)
        #expect(await pool.prepare(alias: "hl_gpu_2", priority: .background) == .ready)
        #expect(await pool.prepare(alias: "lq_gpu", priority: .background) == .ready)
        await pool.shutdown()
        let commands = await runner.commands()
        #expect(commands.filter { $0.arguments.contains("stop") }.count == 2)
        #expect(!commands.contains { $0.arguments.contains(where: { $0.contains("tmux") }) })
    }

    @Test("shutdown cancels queued preparations and rejects late work")
    func rejectsPreparationDuringShutdown() async {
        let gate = AsyncStartGate()
        let runner = SSHMasterScriptedRunner(actions: [
            .exit(255), .wait(gate, then: .succeed),
        ])
        let pool = SSHMasterPool(
            testDirectory: temporarySSHDirectory(),
            runner: runner,
            maxConcurrentPreparations: 1
        )
        let active = Task { await pool.prepare(alias: "active", priority: .background) }
        await gate.waitUntilEntered()
        let queued = Task { await pool.prepare(alias: "queued", priority: .background) }
        await pool.waitUntilPreparationCountForTesting(2)

        let shutdown = Task { await pool.shutdown() }
        await pool.waitUntilShuttingDownForTesting()
        #expect(await pool.prepare(alias: "late", priority: .foreground) == .failed)
        #expect(await queued.value == .failed)
        await gate.open()
        #expect(await active.value == .ready)
        await shutdown.value
        #expect(await runner.count(argumentsContaining: "ControlMaster=yes") == 1)
    }
}
