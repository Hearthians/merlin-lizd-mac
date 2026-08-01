import Testing
@testable import MerlinLizdCore

@Suite("Merlin task inventory")
struct MerlinTaskInventoryTests {
    @Test("paginates the current user's task list on the cn control plane")
    func paginatesTaskList() async throws {
        let firstPageItems = [
            taskPayload(
                id: "first-user-task",
                name: "first",
                status: "RUNNING",
                type: "Train",
                trigger: "MANUAL",
                time: 101
            ),
        ] + (1..<100).map { index in
            taskPayload(
                id: "worker-\(index)",
                name: "worker",
                status: "DONE",
                type: "WorkspaceWorker",
                trigger: "FROM_API",
                time: Int64(101 - index)
            )
        }
        let secondPageItems = [taskPayload(
            id: "second-user-task",
            name: "second",
            status: "FAILED",
            type: "DataProcessing",
            trigger: "MANUAL",
            time: 1
        )]
        let runner = TaskInventoryScriptedRunner(outputs: [
            try taskPageJSON(total: 101, items: firstPageItems),
            try taskPageJSON(total: 101, items: secondPageItems),
        ])
        let inventory = try MerlinTaskInventory(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            now: { taskTestDate(123) }
        )

        let snapshot = try await inventory.refresh()

        #expect(snapshot.runs.map(\.id) == [
            "first-user-task",
            "second-user-task",
        ])
        #expect(taskSnapshotTimestamp(snapshot) == 123)

        let commands = await runner.commands()
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.executable == "/opt/merlin-cli" })
        #expect(commands.allSatisfy {
            Array($0.arguments.prefix(2)) == ["job", "list-run"]
        })
        #expect(commands.allSatisfy {
            commandContainsAdjacentArguments(
                ["--control-plane", "cn"],
                command: $0
            )
        })
        #expect(try taskRequestPage(from: commands[0]) == 1)
        #expect(try taskRequestPage(from: commands[1]) == 2)
        #expect(try taskRequestPageSize(from: commands[0]) == 100)
    }

    @Test("coalesces overlapping refresh callers")
    func coalescesOverlappingRefreshes() async throws {
        let gate = AsyncStartGate()
        let output = try taskPageJSON(total: 1, items: [taskPayload(
            id: "shared-task",
            name: "shared",
            status: "RUNNING",
            type: "Train",
            trigger: "MANUAL",
            time: 1
        )])
        let runner = GatedTaskInventoryRunner(gate: gate, output: output)
        let inventory = try MerlinTaskInventory(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            now: { taskTestDate(1) }
        )

        async let first = inventory.refresh()
        await gate.waitUntilEntered()
        async let second = inventory.refresh()
        await Task.yield()

        #expect(await runner.commandCount() == 1)
        await gate.open()
        let snapshots = try await (first, second)

        #expect(snapshots.0 == snapshots.1)
        #expect(await runner.commandCount() == 1)
    }

    @Test("a cancelled coalesced caller returns before shared work finishes")
    func promptlyCancelsCoalescedCaller() async throws {
        let gate = AsyncStartGate()
        let output = try taskPageJSON(total: 0, items: [])
        let runner = GatedTaskInventoryRunner(gate: gate, output: output)
        let inventory = try MerlinTaskInventory(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner
        )
        let survivor = Task { try await inventory.refresh() }
        await gate.waitUntilEntered()
        let completion = AsyncCompletionProbe()
        let cancelled = Task {
            do {
                _ = try await inventory.refresh()
            } catch {}
            await completion.complete()
        }
        for _ in 0..<20 { await Task.yield() }

        cancelled.cancel()
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeSharedWork = await completion.count()
        await gate.open()
        _ = try await survivor.value
        await cancelled.value

        #expect(completedBeforeSharedWork == 1)
        #expect(await runner.commandCount() == 1)
    }

    @Test("clears a failed in-flight refresh so a later call can retry")
    func retriesAfterFailure() async throws {
        let success = try taskPageJSON(total: 1, items: [taskPayload(
            id: "retry-task",
            name: "retry",
            status: "RUNNING",
            type: "Train",
            trigger: "MANUAL",
            time: 1
        )])
        let runner = SequencedTaskInventoryRunner(results: [
            .init(stdout: "", exitCode: 7),
            .init(stdout: success, exitCode: 0),
        ])
        let inventory = try MerlinTaskInventory(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            now: { taskTestDate(1) }
        )

        await #expect(throws: MerlinInventoryError.commandFailed(exitCode: 7)) {
            try await inventory.refresh()
        }
        let snapshot = try await inventory.refresh()

        #expect(snapshot.runs.map(\.id) == ["retry-task"])
        #expect(await runner.commandCount() == 2)
    }

    @Test("cancelling the only refresh cancels its CLI process")
    func cancelsUnobservedRefresh() async throws {
        let runner = CancellableTaskInventoryRunner()
        let inventory = try MerlinTaskInventory(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner
        )
        let refresh = Task { try await inventory.refresh() }
        await runner.waitUntilStarted()

        refresh.cancel()

        await #expect(throws: CancellationError.self) {
            try await refresh.value
        }
        #expect(await runner.wasCancelled())
    }

    @Test("bounds pagination when the server reports an excessive total")
    func boundsPagination() async throws {
        let items = (0..<100).map { index in
            taskPayload(
                id: "task-\(index)",
                name: "task-\(index)",
                status: "RUNNING",
                type: "Train",
                trigger: "MANUAL",
                time: Int64(index)
            )
        }
        let runner = RepeatingTaskInventoryRunner(
            output: try taskPageJSON(total: 10_000, items: items)
        )
        let inventory = try MerlinTaskInventory(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner
        )

        await #expect(throws: MerlinInventoryError.paginationLimitExceeded) {
            try await inventory.refresh()
        }
        #expect(await runner.commandCount() == 20)
    }

    private func taskPayload(
        id: String,
        name: String,
        status: String,
        type: String,
        trigger: String,
        time: Int64
    ) -> [String: Any] {
        [
            "id": id,
            "job_def_name": name,
            "status": status,
            "job_type": type,
            "trigger_mode": trigger,
            "creation_time": String(time),
        ]
    }

}

private actor CancellableTaskInventoryRunner: InventoryProcessRunning {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(2))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return InventoryProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor RepeatingTaskInventoryRunner: InventoryProcessRunning {
    private let output: String
    private var count = 0

    init(output: String) {
        self.output = output
    }

    func run(_ command: CommandSpec) -> InventoryProcessOutput {
        count += 1
        return InventoryProcessOutput(
            stdout: output,
            stderr: "",
            exitCode: 0
        )
    }

    func commandCount() -> Int {
        count
    }
}
