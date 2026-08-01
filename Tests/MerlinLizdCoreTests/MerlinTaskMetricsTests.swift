import Testing
@testable import MerlinLizdCore

@Suite("Merlin task metrics")
struct MerlinTaskMetricsTests {
    @Test("loads task GPU and memory panels through merlin-cli")
    func loadsMetricsThroughMerlinCLI() async throws {
        let runner = TaskMetricsScriptedRunner()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            batchSize: 2,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1,
            startedAtMilliseconds: 2
        )

        let refresh = await provider.refresh(runs: [run])

        #expect(refresh.attemptedRunIDs == ["job-run"])
        #expect(refresh.metricsByRunID["job-run"]?.gpuUtilization == 50)
        #expect(refresh.metricsByRunID["job-run"]?.memoryUsedBytes == 3_000)
        let commands = await runner.commands()
        #expect(commands.count == 4)
        #expect(commands.allSatisfy {
            commandContainsAdjacentArguments(
                ["--control-plane", "cn"],
                command: $0
            )
        })
        #expect(try taskMetricPanelIDs(from: commands) == [42, 71])
        #expect(try taskMetricJobRunID(from: commands) == "job-run")
    }

    @Test("loads the selected task batch concurrently")
    func loadsBatchConcurrently() async throws {
        let gate = AsyncStartGate()
        let runner = ConcurrentTaskMetricsRunner(gate: gate)
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            batchSize: 2,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let runs = ["one", "two"].map { id in
            MerlinTaskRun(
                id: id,
                name: id,
                status: .running,
                createdAtMilliseconds: 1
            )
        }

        async let refresh = provider.refresh(runs: runs)
        await gate.waitUntilEntered()
        for _ in 0..<20 { await Task.yield() }
        let commandCountWhileBlocked = await runner.commandCount()
        await gate.open()
        _ = await refresh

        #expect(commandCountWhileBlocked == 2)
        #expect(await runner.describeCommandCount() == 1)
    }

    @Test("rotates through untouched tasks before retrying a recent sample")
    func rotatesMetricsBatch() async throws {
        let runner = TaskMetricsScriptedRunner()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            batchSize: 2,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let runs = (1...3).map { index in
            MerlinTaskRun(
                id: "run-\(index)",
                name: "run-\(index)",
                status: .running,
                createdAtMilliseconds: Int64(index)
            )
        }

        let first = await provider.refresh(runs: runs)
        let second = await provider.refresh(runs: runs)

        #expect(first.attemptedRunIDs == ["run-2", "run-3"])
        #expect(second.attemptedRunIDs == ["run-1"])
    }

    @Test("rediscovers semantic panels after the dashboard cache expires")
    func expiresDashboardCatalog() async throws {
        let clock = TaskMetricsTestClock(now: taskTestDate(100))
        let runner = TaskMetricsScriptedRunner()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            batchSize: 1,
            minimumRefreshInterval: 0,
            now: { clock.now }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1
        )

        _ = await provider.refresh(runs: [run])
        _ = await provider.refresh(runs: [run])
        let beforeExpiry = await runner.commands().filter {
            Array($0.arguments.prefix(2)) == ["grafana", "describe"]
        }.count
        clock.advance(by: 301)
        _ = await provider.refresh(runs: [run])
        let afterExpiry = await runner.commands().filter {
            Array($0.arguments.prefix(2)) == ["grafana", "describe"]
        }.count

        #expect(beforeExpiry == 1)
        #expect(afterExpiry == 2)
    }

    @Test("cancels panel discovery when its only refresh is cancelled")
    func cancelsUnusedPanelDiscovery() async throws {
        let runner = CancellableDescribeRunner()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            batchSize: 1,
            minimumRefreshInterval: 0,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1
        )
        let refresh = Task {
            await provider.refresh(runs: [run])
        }
        await runner.waitUntilDescribeStarted()

        refresh.cancel()
        _ = await refresh.value
        for _ in 0..<100 { await Task.yield() }

        #expect(await runner.wasDescribeCancelled())
    }

    @Test("a cancelled discovery cannot overwrite its immediate retry")
    func isolatesReplacementDiscovery() async throws {
        let runner = ReplacementDescribeRunner()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            batchSize: 1,
            minimumRefreshInterval: 0,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1
        )
        let first = Task { await provider.refresh(runs: [run]) }
        await runner.waitUntilFirstDescribeStarted()
        first.cancel()
        _ = await first.value
        await runner.waitUntilFirstDescribeCancelled()

        let retry = Task { await provider.refresh(runs: [run]) }
        await runner.waitUntilSecondDescribeStarted()
        await runner.releaseFirstDescribe()
        for _ in 0..<100 { await Task.yield() }
        await runner.releaseSecondDescribe()
        let refresh = await retry.value

        #expect(refresh.metricsByRunID[run.id]?.gpuUtilization == 50)
        #expect(await runner.describeCommandCount() == 2)
    }

    @Test("averages the latest GPU utilization across task series")
    func averagesGPUUtilization() {
        let gpuOutput = """
        {
          "total": [{
            "data": [{
              "metric": "lab.arnold.instance_monitor.gpu_duty_cycle",
              "tags": {"pod_name": "worker-0"},
              "dps": {"10": 20, "20": 40}
            }, {
              "metric": "lab.arnold.instance_monitor.gpu_duty_cycle",
              "tags": {"pod_name": "worker-1"},
              "dps": {"10": 50, "20": 60}
            }]
          }]
        }
        """

        let metrics = MerlinTaskMetricsParser.parse(
            gpuOutput: gpuOutput,
            memoryOutput: nil
        )

        #expect(metrics?.gpuUtilization == 50)
        #expect(metrics?.gpu?.sampledAt == taskTestDate(20))
        #expect(metrics?.memoryUsedBytes == nil)
    }

    @Test("sums the latest memory usage and limits across task pods")
    func aggregatesMemory() {
        let memoryOutput = """
        {
          "total": [{
            "data": [{
              "metric": "lab.arnold.instance_monitor.mem_usage",
              "tags": {"pod_name": "worker-0"},
              "dps": {"20": 1000}
            }, {
              "metric": "lab.arnold.instance_monitor.mem_usage",
              "tags": {"pod_name": "worker-1"},
              "dps": {"20": 2000}
            }, {
              "metric": "lab.arnold.instance_monitor.mem_limit",
              "tags": {"pod_name": "worker-0"},
              "dps": {"20": 4000}
            }, {
              "metric": "lab.arnold.instance_monitor.mem_limit",
              "tags": {"pod_name": "worker-1"},
              "dps": {"20": 4000}
            }]
          }]
        }
        """

        let metrics = MerlinTaskMetricsParser.parse(
            gpuOutput: nil,
            memoryOutput: memoryOutput
        )

        #expect(metrics?.gpuUtilization == nil)
        #expect(metrics?.memoryUsedBytes == 3_000)
        #expect(metrics?.memoryTotalBytes == 8_000)
        #expect(metrics?.memoryUtilization == 37.5)
        #expect(metrics?.memory?.sampledAt == taskTestDate(20))
    }

    @Test("keeps GPU and memory sample times independent")
    func keepsMetricSampleTimesIndependent() {
        let metrics = MerlinTaskMetricsParser.parse(
            gpuOutput: """
            {"total":[{"data":[{
              "metric":"lab.arnold.instance_monitor.gpu_duty_cycle",
              "tags":{"pod_name":"worker-0"},
              "dps":{"10":75}
            }]}]}
            """,
            memoryOutput: """
            {"total":[{"data":[{
              "metric":"lab.arnold.instance_monitor.mem_usage",
              "tags":{"pod_name":"worker-0"},
              "dps":{"20":3000}
            }]}]}
            """
        )

        #expect(metrics?.gpu?.sampledAt == taskTestDate(10))
        #expect(metrics?.memory?.sampledAt == taskTestDate(20))
    }

    @Test("does not blend stale devices or pods into current aggregates")
    func excludesStaleAggregateInputs() {
        let metrics = MerlinTaskMetricsParser.parse(
            gpuOutput: """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"gpu":"0"},"dps":{"10":20}},
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"gpu":"1"},"dps":{"100":80}}
            ]}]}
            """,
            memoryOutput: """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"pod_name":"old"},"dps":{"10":1000}},
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"pod_name":"new"},"dps":{"100":2000}},
              {"metric":"lab.arnold.instance_monitor.mem_limit","tags":{"pod_name":"old"},"dps":{"10":4000}},
              {"metric":"lab.arnold.instance_monitor.mem_limit","tags":{"pod_name":"new"},"dps":{"100":4000}}
            ]}]}
            """
        )

        #expect(metrics?.gpuUtilization == 80)
        #expect(metrics?.gpu?.sampledAt == taskTestDate(100))
        #expect(metrics?.memory == nil)
    }
}

private actor TaskMetricsScriptedRunner: InventoryProcessRunning {
    private var recordedCommands: [CommandSpec] = []

    func run(_ command: CommandSpec) throws -> InventoryProcessOutput {
        recordedCommands.append(command)
        if Array(command.arguments.prefix(2)) == ["job", "get-grafana"] {
            return InventoryProcessOutput(
                stdout: #"{"grafana_url":"https://grafana.byted.org/d/rn3WCutvk/task?from=1&to=2"}"#,
                stderr: "",
                exitCode: 0
            )
        }
        if Array(command.arguments.prefix(2)) == ["grafana", "describe"] {
            return InventoryProcessOutput(
                stdout: """
                {"dashboards":[{"dashboard_uid":"rn3WCutvk","dashboard_panels":[{"panels":[
                  {"id":71,"title":"GPU DutyCycle (GPU 利用率)"},
                  {"id":42,"title":"Memory"}
                ]}]}]}
                """,
                stderr: "",
                exitCode: 0
            )
        }
        let panelID = try taskMetricPanelID(from: command)
        let stdout: String
        if panelID == 71 {
            stdout = """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"pod_name":"a"},"dps":{"90":40}},
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"pod_name":"b"},"dps":{"90":60}}
            ]}]}
            """
        } else {
            stdout = """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"pod_name":"a"},"dps":{"90":1000}},
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"pod_name":"b"},"dps":{"90":2000}},
              {"metric":"lab.arnold.instance_monitor.mem_limit","tags":{"pod_name":"a"},"dps":{"90":4000}},
              {"metric":"lab.arnold.instance_monitor.mem_limit","tags":{"pod_name":"b"},"dps":{"90":4000}}
            ]}]}
            """
        }
        return InventoryProcessOutput(stdout: stdout, stderr: "", exitCode: 0)
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

private actor ConcurrentTaskMetricsRunner: InventoryProcessRunning {
    private let gate: AsyncStartGate
    private var count = 0
    private var describeCount = 0

    init(gate: AsyncStartGate) {
        self.gate = gate
    }

    func run(_ command: CommandSpec) async -> InventoryProcessOutput {
        count += 1
        if Array(command.arguments.prefix(2)) == ["job", "get-grafana"] {
            await gate.wait()
            return InventoryProcessOutput(
                stdout: #"{"grafana_url":"https://grafana.byted.org/d/rn3WCutvk/task"}"#,
                stderr: "",
                exitCode: 0
            )
        }
        if Array(command.arguments.prefix(2)) == ["grafana", "describe"] {
            describeCount += 1
            return InventoryProcessOutput(
                stdout: """
                {"dashboards":[{"dashboard_uid":"rn3WCutvk","dashboard_panels":[{"panels":[
                  {"id":71,"title":"GPU DutyCycle"},
                  {"id":42,"title":"Memory"}
                ]}]}]}
                """,
                stderr: "",
                exitCode: 0
            )
        }
        return InventoryProcessOutput(
            stdout: #"{"total":[]}"#,
            stderr: "",
            exitCode: 0
        )
    }

    func commandCount() -> Int {
        count
    }

    func describeCommandCount() -> Int {
        describeCount
    }
}

private actor CancellableDescribeRunner: InventoryProcessRunning {
    private var describeStarted = false
    private var describeCancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if Array(command.arguments.prefix(2)) == ["job", "get-grafana"] {
            return InventoryProcessOutput(
                stdout: #"{"grafana_url":"https://grafana.byted.org/d/rn3WCutvk/task"}"#,
                stderr: "",
                exitCode: 0
            )
        }
        if Array(command.arguments.prefix(2)) == ["grafana", "describe"] {
            describeStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                describeCancelled = true
                throw CancellationError()
            }
            return InventoryProcessOutput(
                stdout: #"{"dashboards":[]}"#,
                stderr: "",
                exitCode: 0
            )
        }
        return InventoryProcessOutput(
            stdout: #"{"total":[]}"#,
            stderr: "",
            exitCode: 0
        )
    }

    func waitUntilDescribeStarted() async {
        guard !describeStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func wasDescribeCancelled() -> Bool {
        describeCancelled
    }
}

private actor ReplacementDescribeRunner: InventoryProcessRunning {
    private var describeCount = 0
    private var firstStarted = false
    private var firstCancelled = false
    private var secondStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var secondRelease: CheckedContinuation<Void, Never>?

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        if Array(command.arguments.prefix(2)) == ["job", "get-grafana"] {
            return InventoryProcessOutput(
                stdout: #"{"grafana_url":"https://grafana.byted.org/d/rn3WCutvk/task"}"#,
                stderr: "",
                exitCode: 0
            )
        }
        if Array(command.arguments.prefix(2)) == ["grafana", "describe"] {
            describeCount += 1
            if describeCount == 1 {
                firstStarted = true
                firstStartWaiters.forEach { $0.resume() }
                firstStartWaiters.removeAll()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    firstCancelled = true
                    firstCancelWaiters.forEach { $0.resume() }
                    firstCancelWaiters.removeAll()
                    await withCheckedContinuation { continuation in
                        firstRelease = continuation
                    }
                    throw CancellationError()
                }
            } else {
                secondStarted = true
                secondStartWaiters.forEach { $0.resume() }
                secondStartWaiters.removeAll()
                await withCheckedContinuation { continuation in
                    secondRelease = continuation
                }
            }
            return InventoryProcessOutput(
                stdout: """
                {"dashboards":[{"dashboard_uid":"rn3WCutvk","dashboard_panels":[{"panels":[
                  {"id":71,"title":"GPU DutyCycle"},
                  {"id":42,"title":"Memory"}
                ]}]}]}
                """,
                stderr: "",
                exitCode: 0
            )
        }
        let panelID = try taskMetricPanelID(from: command)
        let stdout = panelID == 71
            ? #"{"total":[{"data":[{"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"gpu":"0"},"dps":{"100":50}}]}]}"#
            : #"{"total":[]}"#
        return InventoryProcessOutput(stdout: stdout, stderr: "", exitCode: 0)
    }

    func waitUntilFirstDescribeStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { firstStartWaiters.append($0) }
    }

    func waitUntilFirstDescribeCancelled() async {
        guard !firstCancelled else { return }
        await withCheckedContinuation { firstCancelWaiters.append($0) }
    }

    func waitUntilSecondDescribeStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { secondStartWaiters.append($0) }
    }

    func releaseFirstDescribe() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func releaseSecondDescribe() {
        secondRelease?.resume()
        secondRelease = nil
    }

    func describeCommandCount() -> Int {
        describeCount
    }
}
