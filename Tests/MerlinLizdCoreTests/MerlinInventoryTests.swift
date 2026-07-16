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
            workerPage(
                sid: "wkr_3960209",
                status: "running",
                cpuCores: 100,
                memoryBytes: 257_698_037_760,
                gpuCount: 0
            ),
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
            sshAlias: discoveredMachine.sshAlias
        )
        #expect(machine.sshAlias == "hl_gpu_2")
        #expect(machine.workerStatus == .loaded)
        #expect(machine.workers.map(\.id) == ["3960209"])
        #expect(machine.workers.map(\.platformStatus) == ["running"])
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
            $0.arguments.starts(with: ["cpu-devbox", "workers", "list"])
        })
        #expect(workerCommand.executable == "/Users/test/.merlin-cli/bin/merlin-cli")
        #expect(workerCommand.arguments == [
            "cpu-devbox", "workers", "list",
            "--control-plane", "cn",
            "--json", #"{"filter":{"instance_sid":"dbx_135679"},"page_size":100}"#,
        ])
        #expect(!commands.contains {
            $0.arguments.last?.contains("mlx worker list") == true
        })
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

    @Test("enriches a missing platform GPU type from safe SSH inventory")
    func enrichesMissingGPUTypeFromSSH() async throws {
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(sid: "dbx_135679", role: "OWNER", status: "running"),
            emptyDevboxPage(),
            "user 135679.some-account.cn",
            workerPage(
                sid: "wkr_4031877",
                status: "running",
                cpuCores: 22,
                memoryBytes: 123_480_309_760,
                gpuCount: 1
            ),
        ])
        let directory = temporarySSHDirectory()
        let poolRunner = InventorySSHMasterRunner(workerList: """
            id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell
            4031877   99     999    9      NVIDIA-L40  fdbd:secret::1                          9000   2026-07-15T07:44:24  https://secret.invalid/worker
            """)
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let inventory = try MerlinInventory(
            sshMasterPool: pool,
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu_2"])
        let discoveredMachine = try #require(snapshot.devboxes.first)
        let loaded = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: discoveredMachine.sshAlias
        )

        let worker = try #require(loaded.workers.first)
        #expect(loaded.workerStatus == .loaded)
        #expect(worker.id == "4031877")
        #expect(worker.gpuType == "NVIDIA-L40")
        #expect(worker.cpuCores == 22)
        #expect(worker.memoryGiB == 115)
        #expect(worker.gpuCount == 1)
        #expect(worker.platformStatus == "running")
        #expect(worker.createdAt == "2026-07-09T04:50:08Z")
        let safeDescription = String(reflecting: loaded)
        #expect(!safeDescription.contains("fdbd:secret::1"))
        #expect(!safeDescription.contains("secret.invalid"))
    }

    @Test("continues platform Worker inventory with cursor pagination")
    func paginatesWorkersByCursor() async throws {
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(sid: "dbx_135679", role: "OWNER", status: "running"),
            emptyDevboxPage(),
            "user 135679.some-account.cn",
            workerPage(
                sid: "wkr_3960209",
                status: "running",
                cpuCores: 100,
                memoryBytes: 257_698_037_760,
                gpuCount: 0,
                nextPageToken: "opaque-worker-cursor"
            ),
            emptyWorkerPage(),
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
            sshAlias: discoveredMachine.sshAlias
        )

        #expect(machine.workers.map(\.id) == ["3960209"])
        let commands = await runner.recordedCommands().filter {
            $0.arguments.starts(with: ["cpu-devbox", "workers", "list"])
        }
        #expect(try commands.map { try requestBody(in: $0) } == [
            #"{"filter":{"instance_sid":"dbx_135679"},"page_size":1}"#,
            #"{"filter":{"instance_sid":"dbx_135679"},"page_size":1,"page_token":"opaque-worker-cursor"}"#,
        ])
    }

    @Test("falls back to SSH mlx only when the platform Worker command fails")
    func fallsBackToMLXWorkerList() async throws {
        let runner = ScriptedInventoryProcessRunner(outputs: [
            InventoryProcessOutput(
                stdout: devboxPage(
                    sid: "dbx_135679",
                    role: "OWNER",
                    status: "running"
                ),
                stderr: "",
                exitCode: 0
            ),
            InventoryProcessOutput(
                stdout: emptyDevboxPage(),
                stderr: "",
                exitCode: 0
            ),
            InventoryProcessOutput(
                stdout: "user 135679.some-account.cn",
                stderr: "",
                exitCode: 0
            ),
            InventoryProcessOutput(
                stdout: "",
                stderr: "unsupported command",
                exitCode: 64
            ),
        ])
        let directory = temporarySSHDirectory()
        let poolRunner = InventorySSHMasterRunner(workerList: """
            id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell
            3966762   20     225    1      NVIDIA-H20                                          9000   2026-07-09T04:49:39  https://secret.invalid/worker
            """)
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let inventory = try MerlinInventory(
            sshMasterPool: pool,
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu_2"])
        let discoveredMachine = try #require(snapshot.devboxes.first)
        let loaded = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: discoveredMachine.sshAlias
        )

        #expect(loaded.workerStatus == .loaded)
        #expect(loaded.workers.map(\.id) == ["3966762"])
        #expect(loaded.workers.first?.platformStatus == nil)
        let commands = await runner.recordedCommands()
        #expect(commands.contains {
            $0.arguments.starts(with: ["cpu-devbox", "workers", "list"])
        })
        #expect(commands.contains {
            $0.arguments == ["-G", "hl_gpu_2"]
        })
        #expect(!commands.first(where: { $0.arguments == ["-G", "hl_gpu_2"] })!
            .arguments.contains(where: { $0.contains("ControlMaster") }))
        let remoteCommands = await poolRunner.commands()
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(remoteCommands.last?.arguments.contains("ControlPath=\(expectedPath)") == true)
    }

    @Test("probes Worker readiness through the shared SSH control path")
    func probesWorkerReadinessThroughPool() async throws {
        let directory = temporarySSHDirectory()
        let poolRunner = InventorySSHMasterRunner(workerList: "")
        let pool = SSHMasterPool(testDirectory: directory, runner: poolRunner)
        let inventory = try MerlinInventory(
            sshMasterPool: pool,
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: ScriptedInventoryProcessRunner(stdout: [])
        )

        let readiness = await inventory.probeWorker(
            sshAlias: "hl_gpu_2", workerID: "3966762"
        )

        #expect(readiness == .ready)
        let expectedPath = try SSHMasterCommands(directory: directory)
            .socketPath(alias: "hl_gpu_2")
        #expect(await poolRunner.commands().last?.arguments
            .contains("ControlPath=\(expectedPath)") == true)
    }

    @Test("loads platform Workers without an SSH alias")
    func loadsPlatformWorkersWithoutAlias() async throws {
        let runner = ScriptedInventoryProcessRunner(stdout: [
            devboxPage(sid: "dbx_135679", role: "OWNER", status: "running"),
            emptyDevboxPage(),
            workerPage(
                sid: "wkr_3966773",
                status: "running",
                cpuCores: 22,
                memoryBytes: 123_480_309_760,
                gpuCount: 1
            ),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: [])
        let discoveredMachine = try #require(snapshot.devboxes.first)
        let loaded = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: nil
        )

        #expect(loaded.sshAlias == nil)
        #expect(loaded.workerStatus == .loaded)
        #expect(loaded.workers.map(\.id) == ["3966773"])
        #expect(await runner.recordedCommands().allSatisfy {
            $0.executable != "/usr/bin/ssh"
        })
    }

    @Test("reports a platform failure when no SSH fallback route exists")
    func reportsWorkerFailureWithoutAlias() async throws {
        let runner = ScriptedInventoryProcessRunner(outputs: [
            InventoryProcessOutput(
                stdout: devboxPage(
                    sid: "dbx_135679",
                    role: "OWNER",
                    status: "running"
                ),
                stderr: "",
                exitCode: 0
            ),
            InventoryProcessOutput(
                stdout: emptyDevboxPage(),
                stderr: "",
                exitCode: 0
            ),
            InventoryProcessOutput(
                stdout: "",
                stderr: "not available",
                exitCode: 127
            ),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: [])
        let discoveredMachine = try #require(snapshot.devboxes.first)
        let loaded = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: nil
        )

        #expect(loaded.workerStatus == .failed(.commandFailed(exitCode: 127)))
        #expect(loaded.workers.isEmpty)
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

    private func workerPage(
        sid: String,
        status: String,
        cpuCores: Int,
        memoryBytes: UInt64,
        gpuCount: Int,
        nextPageToken: String? = nil
    ) -> String {
        let token = nextPageToken.map {
            #", "next_page_token": "\#($0)""#
        } ?? ""
        return """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "\(sid)",
            "status": "\(status)",
            "gpu_count": \(gpuCount),
            "gpu_type": null,
            "cpu_cores": \(cpuCores),
            "memory_bytes": \(memoryBytes),
            "created_at": "2026-07-09T04:50:08Z",
            "pod_ip": "2605:secret::1",
            "host_ip": "2605:secret::2",
            "ssh_proxy_cmd": "must-not-escape",
            "webshell_url": "https://secret.invalid/signed-worker-url"
          }],
          "pagination": {"page_size": 100\(token)}
        }
        """
    }

    private func emptyWorkerPage() -> String {
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

    init(outputs: [InventoryProcessOutput]) {
        self.outputs = outputs
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

private actor InventorySSHMasterRunner: InventoryProcessRunning {
    let workerList: String
    private var recorded: [CommandSpec] = []

    init(workerList: String) { self.workerList = workerList }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recorded.append(command)
        if command.arguments.starts(with: ["-O", "check"]) {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 255)
        }
        if command.arguments.first == "-MNf" {
            return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
        return InventoryProcessOutput(stdout: workerList, stderr: "", exitCode: 0)
    }

    func commands() -> [CommandSpec] { recorded }
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
        if command.arguments.starts(with: ["cpu-devbox", "instances", "list"]) {
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

        if command.arguments.starts(with: ["cpu-devbox", "workers", "list"]) {
            activeWorkerLists += 1
            maximumWorkerLists = max(maximumWorkerLists, activeWorkerLists)
            try await Task.sleep(nanoseconds: 30_000_000)
            activeWorkerLists -= 1
            return InventoryProcessOutput(
                stdout: Self.emptyWorkerPage,
                stderr: "",
                exitCode: 0
            )
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

        throw ScriptedRunnerError.missingOutput
    }

    func maximumConcurrentWorkerLists() -> Int {
        maximumWorkerLists
    }

    private static let emptyDevboxPage = """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [],
          "pagination": {"page_size": 100}
        }
        """

    private static let emptyWorkerPage = """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [],
          "pagination": {"page_size": 100}
        }
        """
}
