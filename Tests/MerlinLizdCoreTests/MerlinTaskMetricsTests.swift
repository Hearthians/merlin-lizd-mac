import Testing
@testable import MerlinLizdCore

@Suite("Merlin task metrics")
struct MerlinTaskMetricsTests {
    @Test("builds canonical role metric URLs with an absolute time range")
    func buildsRoleMetricURLs() throws {
        let source = "https://grafana.byted.org/d/rn3WCutvk/?orgId=1&var-task_id=arnold-trial-389685485-%&var-cluster=federationgpu-hl&var-dc=hl&var-job_psm=aml.merlin_job.example&var-target_arnold_trial_id=389685485&var-target_arnold_role=head&var-hostnum=n147-176-086&var-task_family=arnold-fuse&from=now-30m&to=now&editPanel=99"

        let url = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .gpu,
            endingAt: taskTestDate(1_000)
        ))
        let value = url.absoluteString
        #expect(url.host == "grafana.byted.org")
        #expect(url.path == "/d/JiidrBwGzrole/arnold-shi-li-jian-kong-kan-ban-roleji-bie")
        #expect(value.contains("var-cluster=federationgpu-hl"))
        #expect(value.contains("var-dc=hl"))
        #expect(value.contains("var-target_arnold_trial_id=389685485"))
        #expect(value.contains("var-target_arnold_role=worker"))
        #expect(value.contains("var-hostnum=All"))
        #expect(value.contains("var-task_family=arnold"))
        #expect(value.contains("from=100000"))
        #expect(value.contains("to=1000000"))
        #expect(value.contains("viewPanel=7"))
        #expect(!value.contains("editPanel="))
        #expect(!value.contains("var-task_id="))
    }

    @Test("rejects role metric URLs without exact routing variables")
    func rejectsIncompleteRoleMetricURLs() {
        #expect(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=All&var-dc=hl&var-target_arnold_trial_id=1",
            role: "worker",
            panel: .gpu
        ) == nil)
        #expect(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: "https://example.com/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1",
            role: "worker",
            panel: .gpu
        ) == nil)
    }

    @Test("uses the task start for the GPU average window")
    func buildsSinceStartGPUWindow() throws {
        let source = "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1"
        let url = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .gpu,
            startingAtMilliseconds: 250_000,
            endingAt: taskTestDate(1_000)
        ))

        #expect(url.absoluteString.contains("from=250000"))
        #expect(url.absoluteString.contains("to=1000000"))
    }

    @Test("builds one role panel URL for several task trials")
    func buildsGroupedRoleMetricURL() throws {
        let url = try #require(
            MerlinTaskGrafanaURLBuilder.rolePanelURL(
                cluster: "federationgpu-hl",
                dataCenter: "hl",
                trialIDs: ["389738351", "389738720"],
                role: "worker",
                panel: .gpu,
                startingAtMilliseconds: 250_000,
                endingAt: taskTestDate(1_000)
            )
        )

        #expect(grafanaQueryValue("var-cluster", in: url) == "federationgpu-hl")
        #expect(grafanaQueryValue("var-dc", in: url) == "hl")
        #expect(
            grafanaQueryValue("var-target_arnold_trial_id", in: url)
                == "389738351|389738720"
        )
        #expect(grafanaQueryValue("from", in: url) == "250000")
        #expect(grafanaQueryValue("viewPanel", in: url) == "7")
    }

    @Test("builds the CPU role panel with a since-start window")
    func buildsCPURoleMetricURL() throws {
        let url = try #require(
            MerlinTaskGrafanaURLBuilder.rolePanelURL(
                cluster: "federationgpu-hl",
                dataCenter: "hl",
                trialIDs: ["389738351", "389738720"],
                role: "worker",
                panel: .cpu,
                startingAtMilliseconds: 250_000,
                endingAt: taskTestDate(1_000)
            )
        )

        #expect(grafanaQueryValue("viewPanel", in: url) == "2")
        #expect(grafanaQueryValue("from", in: url) == "250000")
        #expect(grafanaQueryValue("to", in: url) == "1000000")
    }

    @Test("reads official panel screenshots through the JWT OpenAPI client")
    func loadsPanelsThroughOpenAPI() async throws {
        let runner = GrafanaJWTScriptedRunner()
        let http = GrafanaOpenAPIScriptedHTTP()
        let screenshotReader = GrafanaScreenshotScriptedReader(values: [
            .cpu: MerlinTaskMetricLegendValues(
                current: 11.1,
                average: 9.14,
                capacity: 46
            ),
            .gpu: MerlinTaskMetricLegendValues(
                current: 28.9,
                average: 26.2
            ),
            .memory: MerlinTaskMetricLegendValues(
                current: 267_361_714_176,
                average: nil
            ),
        ])
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            httpLoader: http,
            screenshotReader: screenshotReader,
            now: { taskTestDate(100) }
        )
        let source = "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1"
        let cpuURL = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .cpu,
            endingAt: taskTestDate(100)
        ))
        let gpuURL = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .gpu,
            endingAt: taskTestDate(100)
        ))
        let memoryURL = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .memory,
            endingAt: taskTestDate(100)
        ))

        let output = await client.load([
            .init(panel: .cpu, url: cpuURL),
            .init(panel: .gpu, url: gpuURL),
            .init(panel: .memory, url: memoryURL),
        ])

        let metrics = MerlinTaskMetricsParser.parse(
            cpuOutput: output[.cpu],
            gpuOutput: output[.gpu],
            memoryOutput: output[.memory],
            memoryTotalOverride: 382_250_795_008
        )
        #expect(metrics?.cpuUsedCores == 11.1)
        #expect(metrics?.cpuAverageCores == 9.14)
        #expect(metrics?.cpuQuotaCores == 46)
        #expect(metrics?.gpuUtilization == 28.9)
        #expect(metrics?.gpuAverageUtilization == 26.2)
        #expect(metrics?.memoryUsedBytes == 267_361_714_176)
        #expect(metrics?.gpu?.sampledAt == taskTestDate(100))
        let commands = await runner.commands()
        #expect(commands.count == 1)
        #expect(Array(commands[0].arguments.prefix(2)) == ["login", "get-jwt"])
        let requests = await http.requests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy {
            $0.endpoint == "https://cloud.bytedance.net/api/v1/grafana_open_api/screenshot"
                && $0.method == "POST"
                && $0.hasExpectedToken
                && !$0.bodyContainsOnlyData
                && !$0.bodyContainsEditPanel
                && $0.bodyContainsViewPanel
                && $0.bodyContainsScreenshotSize
        })
        #expect(Set(await screenshotReader.panels()) == [.cpu, .gpu, .memory])
    }

    @Test("normalizes every trial row from one grouped screenshot")
    func normalizesGroupedScreenshotRows() async throws {
        let runner = GrafanaJWTScriptedRunner()
        let http = GrafanaOpenAPIScriptedHTTP()
        let screenshotReader = GrafanaScreenshotScriptedReader(values: [
            .gpu: [
                "389738351": MerlinTaskMetricLegendValues(
                    current: 21.8,
                    average: 29.7
                ),
                "389738720": MerlinTaskMetricLegendValues(
                    current: 22.8,
                    average: 34.1
                ),
            ],
        ])
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            httpLoader: http,
            screenshotReader: screenshotReader,
            now: { taskTestDate(100) }
        )
        let url = try #require(
            MerlinTaskGrafanaURLBuilder.rolePanelURL(
                cluster: "federationgpu-hl",
                dataCenter: "hl",
                trialIDs: ["389738351", "389738720"],
                role: "worker",
                panel: .gpu
            )
        )

        let output = await client.load([
            .init(panel: .gpu, url: url, seriesCountHint: 2),
        ])
        let first = MerlinTaskMetricsParser.parse(
            gpuOutput: output[.gpu],
            memoryOutput: nil,
            trialID: "389738351"
        )
        let second = MerlinTaskMetricsParser.parse(
            gpuOutput: output[.gpu],
            memoryOutput: nil,
            trialID: "389738720"
        )

        #expect(first?.gpuUtilization == 21.8)
        #expect(first?.gpuAverageUtilization == 29.7)
        #expect(second?.gpuUtilization == 22.8)
        #expect(second?.gpuAverageUtilization == 34.1)
        #expect(await http.requests().count == 1)
    }

    @Test("normalizes CPU quota with grouped CPU legend rows")
    func normalizesGroupedCPUScreenshotRows() async throws {
        let http = GrafanaOpenAPIScriptedHTTP()
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: GrafanaJWTScriptedRunner(),
            httpLoader: http,
            screenshotReader: GrafanaScreenshotScriptedReader(values: [
                .cpu: [
                    "389738351": MerlinTaskMetricLegendValues(
                        current: 11.1,
                        average: 9.14,
                        capacity: 46
                    ),
                    "389738720": MerlinTaskMetricLegendValues(
                        current: 7.29,
                        average: 6.32,
                        capacity: 23
                    ),
                ],
            ]),
            now: { taskTestDate(100) }
        )
        let url = try #require(
            MerlinTaskGrafanaURLBuilder.rolePanelURL(
                cluster: "federationgpu-hl",
                dataCenter: "hl",
                trialIDs: ["389738351", "389738720"],
                role: "worker",
                panel: .cpu,
                endingAt: taskTestDate(100)
            )
        )

        let output = await client.load([
            .init(panel: .cpu, url: url, seriesCountHint: 2),
        ])
        let metrics = MerlinTaskMetricsParser.parse(
            cpuOutput: output[.cpu],
            gpuOutput: nil,
            memoryOutput: nil,
            trialID: "389738351"
        )

        #expect(metrics?.cpuUsedCores == 11.1)
        #expect(metrics?.cpuAverageCores == 9.14)
        #expect(metrics?.cpuQuotaCores == 46)
        #expect(await http.requests().count == 1)
    }

    @Test("does not invent an average when the screenshot legend omits it")
    func preservesMissingScreenshotAverage() async throws {
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: GrafanaJWTScriptedRunner(),
            httpLoader: GrafanaOpenAPIScriptedHTTP(),
            screenshotReader: GrafanaScreenshotScriptedReader(values: [
                .gpu: MerlinTaskMetricLegendValues(
                    current: 28.9,
                    average: nil
                ),
            ]),
            now: { taskTestDate(100) }
        )
        let source = "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1"
        let url = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .gpu,
            endingAt: taskTestDate(80)
        ))

        let output = await client.load([.init(panel: .gpu, url: url)])
        let metrics = MerlinTaskMetricsParser.parse(
            gpuOutput: output[.gpu],
            memoryOutput: nil
        )

        #expect(metrics?.gpuUtilization == 28.9)
        #expect(metrics?.gpuAverageUtilization == nil)
        #expect(metrics?.gpu?.sampledAt == taskTestDate(80))
    }

    @Test("coalesces concurrent JWT acquisition")
    func coalescesJWTLoads() async throws {
        let gate = AsyncStartGate()
        let runner = GatedGrafanaJWTRunner(gate: gate)
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            httpLoader: GrafanaOpenAPIScriptedHTTP(),
            screenshotReader: GrafanaScreenshotScriptedReader(values: [
                .gpu: MerlinTaskMetricLegendValues(current: 1, average: nil),
            ]),
            now: { taskTestDate(100) }
        )
        let source = "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1"
        let url = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .gpu
        ))

        async let first = client.load([.init(panel: .gpu, url: url)])
        async let second = client.load([.init(panel: .gpu, url: url)])
        await runner.waitUntilStarted()
        for _ in 0..<20 { await Task.yield() }
        let commandCountWhileBlocked = await runner.commandCount()
        await gate.open()
        _ = await (first, second)

        #expect(commandCountWhileBlocked == 1)
    }

    @Test("bounds screenshot work across concurrent panel loads")
    func boundsConcurrentScreenshots() async throws {
        let gate = AsyncStartGate()
        let http = ConcurrencyTrackingGrafanaHTTP(gate: gate)
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: GrafanaJWTScriptedRunner(),
            httpLoader: http,
            screenshotReader: GrafanaScreenshotScriptedReader(values: [
                .gpu: MerlinTaskMetricLegendValues(current: 1, average: nil),
                .memory: MerlinTaskMetricLegendValues(current: 1, average: nil),
            ]),
            now: { taskTestDate(100) },
            retryDelay: .zero
        )
        let source = "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1"
        let requests = try MerlinTaskMetricPanel.allCases.map { panel in
            MerlinTaskPanelDataRequest(
                panel: panel,
                url: try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
                    from: source,
                    role: "worker",
                    panel: panel
                ))
            )
        }

        async let first = client.load(requests)
        async let second = client.load(requests)
        async let third = client.load(requests)
        await http.waitUntilStarted(count: 4)
        for _ in 0..<20 { await Task.yield() }
        let maximum = await http.maximumActiveCount()
        await gate.open()
        _ = await (first, second, third)

        #expect(maximum == 4)
    }

    @Test("retries one transiently unreadable panel screenshot")
    func retriesUnreadableScreenshot() async throws {
        let runner = GrafanaJWTScriptedRunner()
        let http = GrafanaOpenAPIScriptedHTTP()
        let screenshotReader = FlakyGrafanaScreenshotReader(
            valueAfterRetry: 12.4
        )
        let client = MerlinGrafanaOpenAPIClient(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            httpLoader: http,
            screenshotReader: screenshotReader,
            now: { taskTestDate(100) },
            retryDelay: .zero
        )
        let source = "https://grafana.byted.org/d/rn3WCutvk/?var-cluster=soil&var-dc=hl&var-target_arnold_trial_id=1"
        let gpuURL = try #require(MerlinTaskGrafanaURLBuilder.rolePanelURL(
            from: source,
            role: "worker",
            panel: .gpu,
            endingAt: taskTestDate(1_000)
        ))

        let output = await client.load([
            .init(panel: .gpu, url: gpuURL),
        ])
        let metrics = MerlinTaskMetricsParser.parse(
            gpuOutput: output[.gpu],
            memoryOutput: nil
        )

        #expect(metrics?.gpuUtilization == 12.4)
        #expect(await screenshotReader.callCount() == 2)
        #expect(await http.requests().count == 2)
        #expect(await runner.commands().count == 1)
    }

    @Test("loads task CPU, GPU, and memory through role panel view URLs")
    func loadsMetricsThroughRolePanels() async throws {
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = TaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
            batchSize: 2,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1,
            startedAtMilliseconds: 2,
            metricRoleName: "worker",
            allocatedGPUCount: 8,
            allocatedMemoryBytes: 10_000
        )

        let refresh = await provider.refresh(runs: [run])

        #expect(refresh.attemptedRunIDs == ["job-run"])
        #expect(refresh.metricsByRunID["job-run"]?.cpuUsedCores == 4)
        #expect(refresh.metricsByRunID["job-run"]?.cpuAverageCores == 3)
        #expect(refresh.metricsByRunID["job-run"]?.cpuQuotaCores == 8)
        #expect(refresh.metricsByRunID["job-run"]?.cpuUtilization == 50)
        #expect(refresh.metricsByRunID["job-run"]?.gpuUtilization == 50)
        #expect(refresh.metricsByRunID["job-run"]?.memoryUsedBytes == 3_000)
        #expect(refresh.metricsByRunID["job-run"]?.memoryTotalBytes == 10_000)
        let commands = await runner.commands()
        #expect(commands.count == 1)
        #expect(commands.allSatisfy {
            commandContainsAdjacentArguments(
                ["--control-plane", "cn"],
                command: $0
            )
        })
        #expect(try taskMetricJobRunID(from: commands) == "job-run")
        let requests = await panelLoader.requests()
        #expect(Set(requests.map(\.panel)) == [.cpu, .gpu, .memory])
        #expect(requests.allSatisfy {
            $0.url.absoluteString.contains(
                "viewPanel=" + String($0.panel.rawValue)
            )
        })
        #expect(requests.allSatisfy {
            !$0.url.absoluteString.contains("editPanel=")
        })
        #expect(requests.allSatisfy {
            $0.url.absoluteString.contains("var-target_arnold_role=worker")
        })
        let cpuRequest = try #require(requests.first { $0.panel == .cpu })
        let gpuRequest = try #require(requests.first { $0.panel == .gpu })
        let memoryRequest = try #require(requests.first { $0.panel == .memory })
        #expect(grafanaQueryValue("from", in: cpuRequest.url) == "2")
        #expect(grafanaQueryValue("from", in: gpuRequest.url) == "2")
        #expect(grafanaQueryValue("from", in: memoryRequest.url) != "2")
    }

    @Test("reads current GPU and memory values from fixed Grafana legends")
    func parsesScreenshotLegends() {
        let gpu = MerlinTaskScreenshotLegendParser.values(
            for: .gpu,
            observations: [
                screenshotText("gpu_util_avg_trial-worker-0", 0.01, 0.016),
                screenshotText("30.8%", 0.908, 0.016),
                screenshotText("26.2%", 0.939, 0.018),
                screenshotText("28.9%", 0.969, 0.016),
            ]
        )
        let memory = MerlinTaskScreenshotLegendParser.value(
            for: .memory,
            observations: [
                screenshotText("mem_limit_trial-worker-0", 0.01, 0.103),
                screenshotText("mem_usage_trial-worker-0", 0.02, 0.072),
                screenshotText("mem_rss_trial-worker-0", 0.02, 0.044),
                screenshotText("303 GiB", 0.887, 0.074),
                screenshotText("277 GIB", 0.924, 0.075),
                screenshotText("249 GİB", 0.964, 0.072),
            ]
        )

        #expect(gpu?.current == 28.9)
        #expect(gpu?.average == 26.2)
        #expect(memory == 267_361_714_176.0)
    }

    @Test("maps grouped Grafana legend rows back to task trials")
    func parsesGroupedScreenshotLegends() {
        let readings = MerlinTaskScreenshotLegendParser.readings(
            for: .gpu,
            observations: [
                screenshotText(
                    "gpu_util_avg_trial-389738351-trialrun-389738351-worker-0",
                    0.01,
                    0.050
                ),
                screenshotText("40.6%", 0.908, 0.050),
                screenshotText("29.7%", 0.939, 0.050),
                screenshotText("21.8%", 0.969, 0.050),
                screenshotText(
                    "gpu_util_avg_trial-389738720-trialrun-389738720-worker-0",
                    0.01,
                    0.020
                ),
                screenshotText("46.8%", 0.908, 0.020),
                screenshotText("34.1%", 0.939, 0.020),
                screenshotText("22.8%", 0.969, 0.020),
            ]
        )

        #expect(readings["389738351"]?.current == 21.8)
        #expect(readings["389738351"]?.average == 29.7)
        #expect(readings["389738720"]?.current == 22.8)
        #expect(readings["389738720"]?.average == 34.1)
    }

    @Test("reads CPU cores, average cores, and quota from one legend")
    func parsesCPUScreenshotLegend() {
        let readings = MerlinTaskScreenshotLegendParser.readings(
            for: .cpu,
            observations: [
                screenshotText(
                    "cpu_util_trial-389884286-trialrun-389884286-worker-0",
                    0.01,
                    0.050
                ),
                screenshotText("14.0", 0.908, 0.050),
                screenshotText("9.14", 0.939, 0.050),
                screenshotText("11.1", 0.969, 0.050),
                screenshotText(
                    "cpu_quota_trial-389884286-trialrun-389884286-worker-0",
                    0.01,
                    0.020
                ),
                screenshotText("46", 0.908, 0.020),
                screenshotText("46", 0.939, 0.020),
                screenshotText("46", 0.969, 0.020),
            ]
        )

        #expect(readings["389884286"]?.current == 11.1)
        #expect(readings["389884286"]?.average == 9.14)
        #expect(readings["389884286"]?.capacity == 46)
    }

    @Test("aggregates CPU legend rows from every pod in a trial")
    func aggregatesCPULegendPods() {
        let readings = MerlinTaskScreenshotLegendParser.readings(
            for: .cpu,
            observations: [
                screenshotText(
                    "cpu_util_trial-389884286-trialrun-389884286-worker-0",
                    0.01,
                    0.110
                ),
                screenshotText("14.0", 0.908, 0.110),
                screenshotText("9.14", 0.939, 0.110),
                screenshotText("11.1", 0.969, 0.110),
                screenshotText(
                    "cpu_util_trial-389884286-trialrun-389884286-worker-1",
                    0.01,
                    0.080
                ),
                screenshotText("9.0", 0.908, 0.080),
                screenshotText("6.3", 0.939, 0.080),
                screenshotText("7.2", 0.969, 0.080),
                screenshotText(
                    "cpu_quota_trial-389884286-trialrun-389884286-worker-0",
                    0.01,
                    0.050
                ),
                screenshotText("46", 0.908, 0.050),
                screenshotText("46", 0.939, 0.050),
                screenshotText("46", 0.969, 0.050),
                screenshotText(
                    "cpu_quota_trial-389884286-trialrun-389884286-worker-1",
                    0.01,
                    0.020
                ),
                screenshotText("23", 0.908, 0.020),
                screenshotText("23", 0.939, 0.020),
                screenshotText("23", 0.969, 0.020),
            ]
        )

        #expect(readings["389884286"]?.current == 18.3)
        #expect(abs((readings["389884286"]?.average ?? 0) - 15.44) < 0.0001)
        #expect(readings["389884286"]?.capacity == 69)
    }

    @Test("loads compatible tasks through three grouped panel screenshots")
    func loadsGroupedTaskMetrics() async throws {
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = GroupedTaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
            batchSize: 2,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let runs = [
            MerlinTaskRun(
                id: "run-one",
                name: "one",
                status: .running,
                createdAtMilliseconds: 1,
                startedAtMilliseconds: 10,
                clusterName: "federationgpu-hl",
                trialID: "389738351",
                metricRoleName: "worker",
                allocatedGPUCount: 8,
                allocatedMemoryBytes: 10_000
            ),
            MerlinTaskRun(
                id: "run-two",
                name: "two",
                status: .running,
                createdAtMilliseconds: 2,
                startedAtMilliseconds: 20,
                clusterName: "federationgpu-hl",
                trialID: "389738720",
                metricRoleName: "worker",
                allocatedGPUCount: 8,
                allocatedMemoryBytes: 20_000
            ),
        ]

        let refresh = await provider.refresh(runs: runs)

        #expect(refresh.metricsByRunID["run-one"]?.cpuUsedCores == 11.1)
        #expect(refresh.metricsByRunID["run-one"]?.cpuQuotaCores == 46)
        #expect(refresh.metricsByRunID["run-one"]?.gpuUtilization == 21.8)
        #expect(refresh.metricsByRunID["run-one"]?.gpuAverageUtilization == 29.7)
        #expect(refresh.metricsByRunID["run-one"]?.memoryUsedBytes == 3_000)
        #expect(refresh.metricsByRunID["run-two"]?.gpuUtilization == 22.8)
        #expect(refresh.metricsByRunID["run-two"]?.gpuAverageUtilization == 34.1)
        #expect(refresh.metricsByRunID["run-two"]?.memoryUsedBytes == 4_000)
        #expect(await runner.commands().isEmpty)
        let requests = await panelLoader.requests()
        #expect(requests.count == 3)
        #expect(Set(requests.map(\.panel)) == [.cpu, .gpu, .memory])
        #expect(requests.allSatisfy { $0.seriesCountHint == 2 })
        #expect(requests.allSatisfy {
            grafanaQueryValue("var-target_arnold_trial_id", in: $0.url)
                == "389738351|389738720"
        })
    }

    @Test("loads the selected task batch concurrently")
    func loadsBatchConcurrently() async throws {
        let gate = AsyncStartGate()
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = GatedTaskMetricsPanelLoader(gate: gate)
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
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
        let commandCountWhileBlocked = await runner.commands().count
        let panelLoadCountWhileBlocked = await panelLoader.loadCount()
        await gate.open()
        _ = await refresh

        #expect(commandCountWhileBlocked == 2)
        #expect(panelLoadCountWhileBlocked == 2)
    }

    @Test("samples twelve untouched tasks in the default batch")
    func usesFasterDefaultBatch() async throws {
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: TaskMetricsScriptedRunner(),
            panelDataLoader: TaskMetricsPanelLoader(),
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let runs = (1...14).map { index in
            MerlinTaskRun(
                id: "run-\(index)",
                name: "run-\(index)",
                status: .running,
                createdAtMilliseconds: Int64(index)
            )
        }

        let batch = await provider.makeRefreshBatch(runs: runs)

        #expect(batch.runIDs == Set((3...14).map { "run-\($0)" }))
    }

    @Test("rotates through untouched tasks before retrying a recent sample")
    func rotatesMetricsBatch() async throws {
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = TaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
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

    @Test("a new trial for the same run bypasses the previous cooldown")
    func refreshesChangedTrialImmediately() async throws {
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: TaskMetricsScriptedRunner(),
            panelDataLoader: GroupedTaskMetricsPanelLoader(),
            batchSize: 1,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let original = groupedRun(id: "run", trialID: "389738351")
        let retried = groupedRun(id: "run", trialID: "389738720")

        _ = await provider.refresh(runs: [original])
        let next = await provider.makeRefreshBatch(runs: [retried])

        #expect(next.runIDs == ["run"])
    }

    @Test("rejects a completed sample after the run switches trials")
    func rejectsStaleTrialResult() {
        let original = groupedRun(id: "run", trialID: "389738351")
        let retried = groupedRun(id: "run", trialID: "389738720")
        let metrics = MerlinTaskMetrics(
            gpu: MerlinTaskGPUReading(
                currentUtilization: 20,
                averageUtilization: 10,
                sampledAt: taskTestDate(100)
            ),
            memory: nil
        )
        let refresh = MerlinTaskMetricsRefresh(
            metricsByRunID: [original.id: metrics],
            attemptedRoutesByRunID: [original.id: original.metricRoute],
            refreshedAt: taskTestDate(100)
        )

        #expect(refresh.metrics(for: original) == metrics)
        #expect(refresh.metrics(for: retried) == nil)
    }

    @Test("reuses a task dashboard URL across metric refreshes")
    func cachesTaskDashboardURL() async throws {
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = TaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
            batchSize: 1,
            minimumRefreshInterval: 0,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "run-1",
            name: "run-1",
            status: .running,
            createdAtMilliseconds: 1
        )

        _ = await provider.refresh(runs: [run])
        _ = await provider.refresh(runs: [run])

        #expect(await runner.commands().count == 1)
        #expect(await panelLoader.requests().count == 6)
    }

    @Test("exposes the exact batch before slow panel loading starts")
    func preparesMetricBatch() async throws {
        let clock = TaskMetricsTestClock(now: taskTestDate(100))
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = TaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
            batchSize: 2,
            minimumRefreshInterval: 60,
            now: { clock.now }
        )
        let runs = (1...3).map { index in
            MerlinTaskRun(
                id: "run-\(index)",
                name: "run-\(index)",
                status: .running,
                createdAtMilliseconds: Int64(index)
            )
        }

        let batch = await provider.makeRefreshBatch(runs: runs)

        #expect(batch.runIDs == ["run-2", "run-3"])
        #expect(batch.refreshedAt == taskTestDate(100))
        #expect(await runner.commands().isEmpty)
        #expect(await panelLoader.requests().isEmpty)
    }

    @Test("abandoning a reserved batch releases its cooldown")
    func abandonsReservedBatch() async throws {
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: TaskMetricsScriptedRunner(),
            panelDataLoader: TaskMetricsPanelLoader(),
            batchSize: 1,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "run",
            name: "run",
            status: .running,
            createdAtMilliseconds: 1
        )

        let reserved = await provider.makeRefreshBatch(runs: [run])
        await provider.abandon(batch: reserved)
        let replacement = await provider.makeRefreshBatch(runs: [run])

        #expect(replacement.runIDs == [run.id])
    }

    @Test("retries an empty sample sooner than a successful refresh")
    func retriesEmptySamplesSooner() async throws {
        let clock = TaskMetricsTestClock(now: taskTestDate(100))
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = EmptyTaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
            batchSize: 1,
            minimumRefreshInterval: 60,
            failedRefreshInterval: 15,
            now: { clock.now }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1
        )

        _ = await provider.refresh(runs: [run])
        clock.advance(by: 14)
        let early = await provider.makeRefreshBatch(runs: [run])
        clock.advance(by: 1)
        let retry = await provider.makeRefreshBatch(runs: [run])

        #expect(early.runs.isEmpty)
        #expect(retry.runIDs == [run.id])
    }

    @Test("retries a missing panel sooner than a complete refresh")
    func retriesPartialSamplesSooner() async throws {
        let clock = TaskMetricsTestClock(now: taskTestDate(100))
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: TaskMetricsScriptedRunner(),
            panelDataLoader: GPUOnlyTaskMetricsPanelLoader(),
            batchSize: 1,
            minimumRefreshInterval: 60,
            failedRefreshInterval: 15,
            now: { clock.now }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1,
            allocatedGPUCount: 8,
            allocatedMemoryBytes: 10_000
        )

        _ = await provider.refresh(runs: [run])
        clock.advance(by: 15)
        let retry = await provider.makeRefreshBatch(runs: [run])

        #expect(retry.runIDs == [run.id])
    }

    @Test("cancels an unobserved panel load")
    func cancelsPanelLoad() async throws {
        let runner = TaskMetricsScriptedRunner()
        let panelLoader = CancellableTaskMetricsPanelLoader()
        let provider = try MerlinTaskMetricsProvider(
            merlinCLIPath: "/opt/merlin-cli",
            processRunner: runner,
            panelDataLoader: panelLoader,
            batchSize: 1,
            minimumRefreshInterval: 60,
            now: { taskTestDate(100) }
        )
        let run = MerlinTaskRun(
            id: "job-run",
            name: "job",
            status: .running,
            createdAtMilliseconds: 1
        )
        let refresh = Task { await provider.refresh(runs: [run]) }
        await panelLoader.waitUntilStarted()
        refresh.cancel()
        _ = await refresh.value
        for _ in 0..<100 { await Task.yield() }

        let retry = await provider.makeRefreshBatch(runs: [run])

        #expect(await panelLoader.wasCancelled())
        #expect(retry.runIDs == [run.id])
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

    @Test("derives CPU utilization from used cores and quota")
    func derivesCPUUtilization() {
        let cpuOutput = """
        {"total":[{"data":[
          {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"stat":"current"},"dps":{"20":11.1}},
          {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"stat":"average"},"dps":{"20":9.14}},
          {"metric":"lab.arnold.instance_monitor.cpu_quota","tags":{"stat":"capacity"},"dps":{"20":46}}
        ]}]}
        """

        let metrics = MerlinTaskMetricsParser.parse(
            cpuOutput: cpuOutput,
            gpuOutput: nil,
            memoryOutput: nil
        )

        #expect(metrics?.cpuUsedCores == 11.1)
        #expect(metrics?.cpuAverageCores == 9.14)
        #expect(metrics?.cpuQuotaCores == 46)
        #expect(abs((metrics?.cpuUtilization ?? 0) - 24.1304) < 0.0001)
        #expect(abs((metrics?.cpuAverageUtilization ?? 0) - 19.8696) < 0.0001)
        #expect(metrics?.cpu?.sampledAt == taskTestDate(20))
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

private func groupedRun(id: String, trialID: String) -> MerlinTaskRun {
    MerlinTaskRun(
        id: id,
        name: id,
        status: .running,
        createdAtMilliseconds: 1,
        clusterName: "federationgpu-hl",
        trialID: trialID,
        metricRoleName: "worker",
        allocatedGPUCount: 8,
        allocatedMemoryBytes: 10_000
    )
}

private func screenshotText(
    _ text: String,
    _ minX: Double,
    _ minY: Double
) -> MerlinTaskMetricScreenshotText {
    MerlinTaskMetricScreenshotText(
        text: text,
        minX: minX,
        minY: minY,
        width: 0.03,
        height: 0.016
    )
}

private actor TaskMetricsScriptedRunner: InventoryProcessRunning {
    private var recordedCommands: [CommandSpec] = []

    func run(_ command: CommandSpec) -> InventoryProcessOutput {
        recordedCommands.append(command)
        return InventoryProcessOutput(
            stdout: #"{"grafana_url":"https://grafana.byted.org/d/rn3WCutvk/task?orgId=1&var-cluster=federationgpu-hl&var-dc=hl&var-job_psm=aml.merlin.job&var-target_arnold_trial_id=123&var-hostnum=head-host&from=now-30m&to=now"}"#,
            stderr: "",
            exitCode: Array(command.arguments.prefix(2)) == ["job", "get-grafana"]
                ? 0
                : 1
        )
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

private actor TaskMetricsPanelLoader: MerlinTaskPanelDataLoading {
    private var recordedRequests: [MerlinTaskPanelDataRequest] = []

    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) -> [MerlinTaskMetricPanel: String] {
        recordedRequests.append(contentsOf: requests)
        var output: [MerlinTaskMetricPanel: String] = [:]
        if requests.contains(where: { $0.panel == .cpu }) {
            output[.cpu] = """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"stat":"current"},"dps":{"90":4}},
              {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"stat":"average"},"dps":{"90":3}},
              {"metric":"lab.arnold.instance_monitor.cpu_quota","tags":{"stat":"capacity"},"dps":{"90":8}}
            ]}]}
            """
        }
        if requests.contains(where: { $0.panel == .gpu }) {
            output[.gpu] = """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"pod_name":"a"},"dps":{"90":40}},
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"pod_name":"b"},"dps":{"90":60}}
            ]}]}
            """
        }
        if requests.contains(where: { $0.panel == .memory }) {
            output[.memory] = """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"pod_name":"a"},"dps":{"90":1000}},
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"pod_name":"b"},"dps":{"90":2000}},
              {"metric":"lab.arnold.instance_monitor.mem_limit","tags":{"pod_name":"a"},"dps":{"90":4000}},
              {"metric":"lab.arnold.instance_monitor.mem_limit","tags":{"pod_name":"b"},"dps":{"90":4000}}
            ]}]}
            """
        }
        return output
    }

    func requests() -> [MerlinTaskPanelDataRequest] {
        recordedRequests
    }
}

private actor GroupedTaskMetricsPanelLoader: MerlinTaskPanelDataLoading {
    private var recordedRequests: [MerlinTaskPanelDataRequest] = []

    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) -> [MerlinTaskMetricPanel: String] {
        recordedRequests.append(contentsOf: requests)
        return [
            .cpu: """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"trial_id":"389738351","stat":"current"},"dps":{"90":11.1}},
              {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"trial_id":"389738351","stat":"average"},"dps":{"90":9.14}},
              {"metric":"lab.arnold.instance_monitor.cpu_quota","tags":{"trial_id":"389738351","stat":"capacity"},"dps":{"90":46}},
              {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"trial_id":"389738720","stat":"current"},"dps":{"90":7.29}},
              {"metric":"lab.arnold.instance_monitor.cpu_util","tags":{"trial_id":"389738720","stat":"average"},"dps":{"90":6.32}},
              {"metric":"lab.arnold.instance_monitor.cpu_quota","tags":{"trial_id":"389738720","stat":"capacity"},"dps":{"90":23}}
            ]}]}
            """,
            .gpu: """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"trial_id":"389738351","stat":"current"},"dps":{"90":21.8}},
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"trial_id":"389738351","stat":"average"},"dps":{"90":29.7}},
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"trial_id":"389738720","stat":"current"},"dps":{"90":22.8}},
              {"metric":"lab.arnold.instance_monitor.gpu_duty_cycle","tags":{"trial_id":"389738720","stat":"average"},"dps":{"90":34.1}}
            ]}]}
            """,
            .memory: """
            {"total":[{"data":[
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"trial_id":"389738351","stat":"current"},"dps":{"90":3000}},
              {"metric":"lab.arnold.instance_monitor.mem_usage","tags":{"trial_id":"389738720","stat":"current"},"dps":{"90":4000}}
            ]}]}
            """,
        ]
    }

    func requests() -> [MerlinTaskPanelDataRequest] {
        recordedRequests
    }
}

private actor GatedTaskMetricsPanelLoader: MerlinTaskPanelDataLoading {
    private let gate: AsyncStartGate
    private var count = 0

    init(gate: AsyncStartGate) {
        self.gate = gate
    }

    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) async -> [MerlinTaskMetricPanel: String] {
        count += 1
        await gate.wait()
        return [:]
    }

    func loadCount() -> Int {
        count
    }
}

private actor EmptyTaskMetricsPanelLoader: MerlinTaskPanelDataLoading {
    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) -> [MerlinTaskMetricPanel: String] {
        [:]
    }
}

private actor GPUOnlyTaskMetricsPanelLoader: MerlinTaskPanelDataLoading {
    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) -> [MerlinTaskMetricPanel: String] {
        [
            .gpu: """
            {"total":[{"data":[{
              "metric":"lab.arnold.instance_monitor.gpu_duty_cycle",
              "tags":{"pod_name":"worker-0"},
              "dps":{"90":50}
            }]}]}
            """,
        ]
    }
}

private actor CancellableTaskMetricsPanelLoader: MerlinTaskPanelDataLoading {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load(
        _ requests: [MerlinTaskPanelDataRequest]
    ) async -> [MerlinTaskMetricPanel: String] {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            cancelled = error is CancellationError
        }
        return [:]
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
