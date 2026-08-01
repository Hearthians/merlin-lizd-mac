import Testing
@testable import MerlinLizdCore

@Suite("Merlin inventory alias and readiness fallbacks")
struct MerlinInventoryAliasTests {
    @Test("prefers the platform SSH destination over a local alias")
    func usesPlatformSSHDestination() async throws {
        let runner = AliasScriptedRunner(outputs: [
            .success(devboxPage(
                sid: "dbx_140542",
                name: "hl_gpu",
                status: "running",
                sshProxyDestination:
                    "140542.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
            )),
            .success(emptyDevboxPage),
            .success("user 140542.lizhuodong.ws"),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu"])
        let machine = try #require(snapshot.devboxes.first)

        #expect(machine.sshAlias == "hl_gpu")
        #expect(machine.sshConnectionTarget ==
            "140542.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org")
        #expect(machine.displayName == "hl_gpu")
    }

    @Test("matches a unique Devbox name when SSH User has no SID")
    func matchesUniqueDevboxName() async throws {
        let runner = AliasScriptedRunner(outputs: [
            .success(devboxPage(
                sid: "dbx_named",
                name: "named_devbox",
                status: "running"
            )),
            .success(emptyDevboxPage),
            .success("user account-without-numeric-sid"),
            .success(emptyWorkerPage),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["named_devbox"])

        #expect(snapshot.devboxes.first?.sshAlias == "named_devbox")
        let discoveredMachine = try #require(snapshot.devboxes.first)
        #expect(discoveredMachine.workerStatus == .notQueried)
        let loaded = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: "named_devbox"
        )
        #expect(loaded.workerStatus == .loaded)
    }

    @Test("does not guess when more than one Devbox has the same name")
    func rejectsAmbiguousDevboxName() async throws {
        let runner = AliasScriptedRunner(outputs: [
            .success(devboxPage(entries: [
                (sid: "dbx_one", name: "shared_name", status: "stopped"),
                (sid: "dbx_two", name: "shared_name", status: "stopped"),
            ])),
            .success(emptyDevboxPage),
            .success("user account-without-numeric-sid"),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["shared_name"])

        #expect(snapshot.devboxes.allSatisfy { $0.sshAlias == nil })
    }

    @Test("does not match a Devbox name when SSH User contains a stale SID")
    func rejectsNameMatchWithStaleSID() async throws {
        let runner = AliasScriptedRunner(outputs: [
            .success(devboxPage(
                sid: "dbx_139503",
                name: "hl_gpu",
                status: "running"
            )),
            .success(emptyDevboxPage),
            .success("user 133757.account.ws"),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu"])

        #expect(snapshot.devboxes.first?.sshAlias == nil)
    }

    @Test("keeps mlx not-ready evidence as Worker readiness")
    func preservesWorkerNotReadyEvidence() async throws {
        let runner = AliasScriptedRunner(outputs: [
            .success(devboxPage(
                sid: "dbx_135679",
                name: "wt_hl",
                status: "running"
            )),
            .success(emptyDevboxPage),
            .success("user 135679.some-account.cn"),
            .success(workerPage(
                sid: "wkr_3966762",
                status: "running",
                cpuCores: 20,
                memoryBytes: 241_591_910_400,
                gpuCount: 1
            )),
            InventoryProcessOutput(
                stdout: "",
                stderr: "worker has not been ready yet",
                exitCode: 1
            ),
        ])
        let inventory = try MerlinInventory(
            merlinCLIPath: "/Users/test/.merlin-cli/bin/merlin-cli",
            processRunner: runner
        )

        let snapshot = try await inventory.refresh(sshAliases: ["hl_gpu_2"])

        let discoveredMachine = try #require(snapshot.devboxes.first)
        let loaded = await inventory.loadWorkers(
            for: discoveredMachine.devbox,
            sshAlias: "hl_gpu_2"
        )
        #expect(loaded.workers.first?.readiness == .listed)
        let readiness = await inventory.probeWorker(
            sshAlias: "hl_gpu_2",
            workerID: "3966762"
        )
        #expect(readiness == .notReady)
    }
}

private actor AliasScriptedRunner: InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]

    init(outputs: [InventoryProcessOutput]) {
        self.outputs = outputs
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        guard !outputs.isEmpty else {
            throw AliasScriptedRunnerError.missingOutput
        }
        return outputs.removeFirst()
    }
}

private enum AliasScriptedRunnerError: Error {
    case missingOutput
}

private extension InventoryProcessOutput {
    static func success(_ stdout: String) -> InventoryProcessOutput {
        InventoryProcessOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
}

private let emptyDevboxPage = """
    {
      "ResponseBase": {"code": 0, "message": "success"},
      "data": [],
      "pagination": {"page_size": 100}
    }
    """

private let emptyWorkerPage = """
    {
      "ResponseBase": {"code": 0, "message": "success"},
      "data": [],
      "pagination": {"page_size": 100}
    }
    """

private func workerPage(
    sid: String,
    status: String,
    cpuCores: Int,
    memoryBytes: UInt64,
    gpuCount: Int
) -> String {
    """
    {
      "ResponseBase": {"code": 0, "message": "success"},
      "data": [{
        "sid": "\(sid)",
        "status": "\(status)",
        "gpu_count": \(gpuCount),
        "cpu_cores": \(cpuCores),
        "memory_bytes": \(memoryBytes),
        "created_at": "2026-07-09T04:49:39Z"
      }],
      "pagination": {"page_size": 100}
    }
    """
}

private func devboxPage(
    sid: String,
    name: String,
    status: String,
    sshProxyDestination: String? = nil
) -> String {
    let proxyField = sshProxyDestination.map {
        ",\"ssh_proxy_cmd\":\"\($0)\""
    } ?? ""
    return """
    {
      "ResponseBase": {"code": 0, "message": "success"},
      "data": [{"sid":"\(sid)","name":"\(name)","status":"\(status)"\(proxyField)}],
      "pagination": {"page_size": 100}
    }
    """
}

private func devboxPage(
    entries: [(sid: String, name: String, status: String)]
) -> String {
    let objects = entries.map { entry in
        """
        {"sid":"\(entry.sid)","name":"\(entry.name)","status":"\(entry.status)"}
        """
    }.joined(separator: ",")
    return """
    {
      "ResponseBase": {"code": 0, "message": "success"},
      "data": [\(objects)],
      "pagination": {"page_size": 100}
    }
    """
}
