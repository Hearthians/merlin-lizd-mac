import Testing
@testable import MerlinLizdCore

@Suite("Merlin inventory alias and readiness fallbacks")
struct MerlinInventoryAliasTests {
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
            .success(workerHeader),
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
            .success("""
                \(workerHeader)
                3966762   20     225    1      NVIDIA-H20                                          9000   2026-07-09T04:49:39  https://secret.invalid/worker
                """),
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

private let workerHeader =
    "id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell"

private let emptyDevboxPage = """
    {
      "ResponseBase": {"code": 0, "message": "success"},
      "data": [],
      "pagination": {"page_size": 100}
    }
    """

private func devboxPage(
    sid: String,
    name: String,
    status: String
) -> String {
    devboxPage(entries: [(sid: sid, name: name, status: status)])
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
