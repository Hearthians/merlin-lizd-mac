import Testing
@testable import MerlinLizdCore

@Suite("Merlin inventory refresh")
struct MerlinInventoryTests {
    @Test("loads owner and shared Devbox roles concurrently")
    func loadsDevboxRolesConcurrently() async throws {
        let runner = RoleConcurrencyTrackingRunner()
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner,
            loadDevboxRolesConcurrently: true
        )

        _ = try await inventory.refresh(sshAliases: [])

        #expect(await runner.maximumConcurrentCount() == 2)
    }

    @Test("bounds concurrent child processes")
    func boundsConcurrentProcesses() async {
        let underlying = ConcurrencyTrackingProcessRunner()
        let runner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 2,
            underlying: underlying
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    _ = try? await runner.run(CommandSpec(
                        executable: "/usr/bin/true",
                        arguments: ["\(index)"]
                    ))
                }
            }
        }

        #expect(await underlying.maximumConcurrentCount() == 2)
    }

    @Test("executes an argument-array command and captures its output")
    func executesProcess() async throws {
        let runner = FoundationInventoryProcessRunner()

        let output = try await runner.run(CommandSpec(
            executable: "/usr/bin/printf",
            arguments: ["safe-output"]
        ))

        #expect(output.stdout == "safe-output")
        #expect(output.stderr.isEmpty)
        #expect(output.exitCode == 0)
    }

    @Test("coalesces overlapping refresh requests")
    func coalescesRefreshes() async throws {
        let runner = DelayedEmptyInventoryProcessRunner()
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        async let first = inventory.refresh(sshAliases: [])
        async let second = inventory.refresh(sshAliases: [])
        _ = try await (first, second)

        #expect(await runner.commandCount() == 2)
    }

    @Test("loads Workers from different running Devboxes concurrently")
    func loadsWorkerInventoriesConcurrently() async throws {
        let runner = MultiDevboxInventoryProcessRunner()
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["devbox_one", "devbox_two"])

        #expect(snapshot.devboxes.map(\.workerStatus) == [.notQueried, .notQueried])
        let firstMachine = try #require(snapshot.devboxes.first)
        let secondMachine = try #require(snapshot.devboxes.dropFirst().first)
        let firstAlias = try #require(firstMachine.sshAlias)
        let secondAlias = try #require(secondMachine.sshAlias)
        async let first = inventory.loadWorkers(
            for: firstMachine.devbox,
            sshAlias: firstAlias
        )
        async let second = inventory.loadWorkers(
            for: secondMachine.devbox,
            sshAlias: secondAlias
        )
        let loaded = await [first, second]

        #expect(loaded.map(\.workerStatus) == [.loaded, .loaded])
        #expect(await runner.maximumConcurrentWorkerLists() == 2)
    }

    @Test("resolves merlin-cli from the absolute installation path, not shell PATH")
    func resolvesAbsoluteMerlinCLIPath() throws {
        let path = try MerlinCLIResolver.resolve(
            homeDirectoryPath: "/Users/test",
            isExecutable: { $0 == "/Users/test/.merlin-cli/bin/merlin-cli" }
        )

        #expect(path == "/Users/test/.merlin-cli/bin/merlin-cli")
        #expect(path.first == "/")
    }

    @Test("loads every owner and shared Devbox page with an absolute CLI path")
    func loadsOwnerAndSharedPages() async throws {
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(
                sid: "dbx_owner_1",
                role: "OWNER",
                nextPageToken: "opaque-owner-cursor"
            ),
            devboxPage(sid: "dbx_owner_2", role: "OWNER"),
            devboxPage(sid: "dbx_shared_1", role: "SHARED"),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner,
            now: { .init(timeIntervalSince1970: 1_700_000_000) }
        )

        let snapshot = try await inventory.refresh(sshAliases: [])

        #expect(snapshot.devboxes.map(\.devbox.sid) == [
            "dbx_owner_1", "dbx_owner_2", "dbx_shared_1",
        ])
        #expect(snapshot.refreshedAt.timeIntervalSince1970 == 1_700_000_000)

        let commands = await runner.recordedCommands()
        #expect(commands.count == 3)
        #expect(commands.allSatisfy {
            $0.executable == "/Users/test/.merlin-cli/bin/merlin-cli"
        })
        let firstBody = try requestBody(in: commands[0])
        let secondBody = try requestBody(in: commands[1])
        let sharedBody = try requestBody(in: commands[2])
        #expect(firstBody.contains(#""access_role":"OWNER""#))
        #expect(!firstBody.contains(#""page_token""#))
        #expect(secondBody.contains(#""access_role":"OWNER""#))
        #expect(secondBody.contains(
            #""page_token":"opaque-owner-cursor""#
        ))
        #expect(sharedBody.contains(#""access_role":"SHARED""#))
    }

    @Test("matches a safe SSH alias and never exposes routing or Worker network secrets")
    func loadsWorkersThroughSafeAlias() async throws {
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(sid: "dbx_135679", role: "OWNER", status: "running"),
            emptyDevboxPage(),
            """
            host hl_gpu_2
            user 135679.some-account.cn
            proxycommand secret-proxy --credential must-not-escape
            identityfile /secret/private/key
            """,
            """
            id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell
            3960209   100    240    0                  fdbd:dc02:2b:84e::37                    9221   2026-07-08T05:20:59  https://secret.invalid/signed-worker-url
            """,
            "probe-ok",
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu_2"])

        let discoveredMachine = try #require(snapshot.devboxes.first)
        #expect(discoveredMachine.workerStatus == .notQueried)
        #expect(discoveredMachine.workers.isEmpty)
        #expect(await runner.recordedCommands().allSatisfy {
            $0.arguments.last?.contains("mlx worker") != true
        })

        let machine = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: try #require(discoveredMachine.sshAlias)
        )
        #expect(machine.sshAlias == "hl_gpu_2")
        #expect(machine.workerStatus == .loaded)
        #expect(machine.workers.map(\.id) == ["3960209"])
        #expect(machine.workers.map(\.readiness) == [.listed])
        let readiness = await inventory.probeWorker(
            sshAlias: "hl_gpu_2",
            workerID: "3960209"
        )
        #expect(readiness == .ready)
        let persistedDescription = String(reflecting: (snapshot, machine))
        #expect(!persistedDescription.contains("secret-proxy"))
        #expect(!persistedDescription.contains("fdbd:dc02:2b:84e::37"))
        #expect(!persistedDescription.contains("signed-worker-url"))

        let commands = await runner.recordedCommands()
        let aliasCommand = try #require(commands.first { $0.arguments.first == "-G" })
        #expect(aliasCommand.executable == "/usr/bin/ssh")
        #expect(aliasCommand.arguments == ["-G", "hl_gpu_2"])
        let workerCommand = try #require(commands.first {
            $0.arguments.last?.contains("mlx worker list") == true
        })
        #expect(workerCommand.executable == "/usr/bin/ssh")
        #expect(workerCommand.arguments == [
            "-nT",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "hl_gpu_2",
            "NO_COLOR=1 TERM=dumb mlx worker list --limit 100 --offset 0",
        ])
        let probeCommand = try #require(commands.first {
            $0.arguments.last?.contains("mlx worker login 3960209 -- true") == true
        })
        #expect(probeCommand.arguments.last ==
            "NO_COLOR=1 TERM=dumb mlx worker login 3960209 -- true")
    }

    @Test("rejects an unsafe alias before launching ssh")
    func rejectsUnsafeAlias() async throws {
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(sid: "dbx_135679", role: "OWNER", status: "running"),
            emptyDevboxPage(),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu_2;touch /tmp/pwned"])

        #expect(snapshot.devboxes[0].sshAlias == nil)
        let commands = await runner.recordedCommands()
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.executable != "/usr/bin/ssh" })
    }

    @Test("continues Worker inventory with offset pagination")
    func paginatesWorkersByOffset() async throws {
        let header = "id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell"
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(sid: "dbx_135679", role: "OWNER", status: "running"),
            emptyDevboxPage(),
            "user 135679.some-account.cn",
            """
            \(header)
            3960209   100    240    0                  fdbd:dc02:2b:84e::37                    9221   2026-07-08T05:20:59  https://secret.invalid/worker
            """,
            header,
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner,
            workerPageSize: 1
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu_2"])
        let discoveredMachine = try #require(snapshot.devboxes.first)
        let machine = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: try #require(discoveredMachine.sshAlias)
        )

        #expect(machine.workers.map(\.id) == ["3960209"])
        let commands = await runner.recordedCommands().filter {
            $0.arguments.last?.contains("mlx worker list") == true
        }
        #expect(commands.map(\.arguments.last) == [
            "NO_COLOR=1 TERM=dumb mlx worker list --limit 1 --offset 0",
            "NO_COLOR=1 TERM=dumb mlx worker list --limit 1 --offset 1",
        ])
    }

    private func devboxPage(
        sid: String,
        role: String,
        status: String = "stopped",
        nextPageToken: String? = nil
    ) -> String {
        let token = nextPageToken.map { #", "next_page_token": "\#($0)""# } ?? ""
        return """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "\(sid)",
            "name": "\(sid)",
            "status": "\(status)",
            "access_role": "\(role)",
            "environment_variables": {"TOKEN": "must-never-enter-the-snapshot"},
            "ssh_proxy_cmd": "must-never-enter-the-snapshot"
          }],
          "pagination": {"page_size": 100\(token)}
        }
        """
    }

    private func emptyDevboxPage() -> String {
        """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [],
          "pagination": {"page_size": 100}
        }
        """
    }

    private func requestBody(in command: CommandSpec) throws -> String {
        let jsonIndex = try #require(command.arguments.firstIndex(of: "--json"))
        return command.arguments[jsonIndex + 1]
    }
}

private actor ScriptedInventoryProcessRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private var commands: [CommandSpec] = []

    init(stdout: [String]) {
        self.outputs = stdout.map {
            InventoryProcessOutput(stdout: $0, stderr: "", exitCode: 0)
        }
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        commands.append(command)
        guard !outputs.isEmpty else {
            throw ScriptedRunnerError.missingOutput
        }
        return outputs.removeFirst()
    }

    func recordedCommands() -> [CommandSpec] {
        commands
    }
}

private enum ScriptedRunnerError: Error {
    case missingOutput
}

private actor ConcurrencyTrackingProcessRunner: InventoryProcessRunning {
    private var active = 0
    private var maximumActive = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        active += 1
        maximumActive = max(maximumActive, active)
        try await Task.sleep(nanoseconds: 20_000_000)
        active -= 1
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func maximumConcurrentCount() -> Int {
        maximumActive
    }
}

private actor RoleConcurrencyTrackingRunner: InventoryProcessRunning {
    private var active = 0
    private var maximumActive = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        active += 1
        maximumActive = max(maximumActive, active)
        try await Task.sleep(for: .milliseconds(20))
        active -= 1
        return InventoryProcessOutput(
            stdout: """
            {
              "ResponseBase": {"code": 0, "message": "success"},
              "data": [],
              "pagination": {"page_size": 100}
            }
            """,
            stderr: "",
            exitCode: 0
        )
    }

    func maximumConcurrentCount() -> Int {
        maximumActive
    }
}

private actor DelayedEmptyInventoryProcessRunner: InventoryProcessRunning {
    private var commands = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        commands += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        return InventoryProcessOutput(
            stdout: """
            {
              "ResponseBase": {"code": 0, "message": "success"},
              "data": [],
              "pagination": {"page_size": 100}
            }
            """,
            stderr: "",
            exitCode: 0
        )
    }

    func commandCount() -> Int {
        commands
    }
}

private actor MultiDevboxInventoryProcessRunner: InventoryProcessRunning {
    private var activeWorkerLists = 0
    private var maximumWorkerLists = 0

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if command.arguments.first == "cpu-devbox" {
            let body = command.arguments.last ?? ""
            let data: String
            if body.contains(#""access_role":"OWNER""#) {
                data = """
                {
                  "ResponseBase": {"code": 0, "message": "success"},
                  "data": [
                    {"sid": "dbx_1001", "name": "one", "status": "running"},
                    {"sid": "dbx_1002", "name": "two", "status": "running"}
                  ],
                  "pagination": {"page_size": 100}
                }
                """
            } else {
                data = Self.emptyDevboxPage
            }
            return InventoryProcessOutput(stdout: data, stderr: "", exitCode: 0)
        }

        if command.arguments.first == "-G" {
            let alias = command.arguments.last
            let user = alias == "devbox_one" ? "1001.user.cn" : "1002.user.cn"
            return InventoryProcessOutput(
                stdout: "user \(user)\nproxycommand secret-must-be-discarded",
                stderr: "",
                exitCode: 0
            )
        }

        activeWorkerLists += 1
        maximumWorkerLists = max(maximumWorkerLists, activeWorkerLists)
        try await Task.sleep(nanoseconds: 30_000_000)
        activeWorkerLists -= 1
        return InventoryProcessOutput(
            stdout: Self.workerHeader,
            stderr: "",
            exitCode: 0
        )
    }

    func maximumConcurrentWorkerLists() -> Int {
        maximumWorkerLists
    }

    private static let workerHeader =
        "id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell"

    private static let emptyDevboxPage = """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [],
          "pagination": {"page_size": 100}
        }
        """
}
