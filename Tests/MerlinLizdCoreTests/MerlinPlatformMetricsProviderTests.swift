import Testing
@testable import MerlinLizdCore

@Suite("Merlin platform metrics provider")
struct MerlinPlatformMetricsProviderTests {
    @Test("validates safe platform targets")
    func validatesTargets() {
        #expect(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ) != nil)
        #expect(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762; touch /tmp/pwned"
        ) == nil)
        #expect(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679\nother",
            workerID: "3966762"
        ) == nil)
    }

    @Test("uses Worker-list Grafana URL, caches describe, and merges nearby samples")
    func loadsAndMergesOfficialMetrics() async throws {
        let runner = PlatformMetricsScriptedRunner(
            panelBehaviors: Self.fullPanelBehaviors
        )
        let boundedPanels = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: 2,
            underlying: runner
        )
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: boundedPanels,
            alignmentTolerance: 5
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        let first = try await provider.fetch(target)
        let second = try await provider.fetch(target)

        #expect(first == second)
        #expect(first.samples.count == 2)
        #expect(first.samples.map(\.timestamp.timeIntervalSince1970) == [
            1_700_000_004, 1_700_000_034,
        ])
        #expect(first.samples.map(\.cpuUtilization) == [30, 40])
        #expect(first.samples.map(\.memoryUsedBytes) == [1_500, 1_800])
        #expect(first.samples.allSatisfy { $0.memoryTotalBytes == 10_000 })

        let firstGPU = try #require(first.samples[0].gpus.first {
            $0.index == 0
        })
        #expect(first.samples[0].gpus.map(\.index) == [0])
        #expect(firstGPU.utilization == 50)
        #expect(firstGPU.memoryUsedBytes == 100)
        #expect(firstGPU.memoryTotalBytes == 1_000)
        #expect(firstGPU.temperatureCelsius == 40)
        #expect(first.samples[0].gpuMemoryUsedBytes == 100)
        #expect(first.samples[1].gpus.first { $0.index == 0 }?.utilization == 70)

        let commands = await runner.commands()
        let workerLists = commands.filter {
            $0.arguments.starts(with: ["cpu-devbox", "workers", "list"])
        }
        #expect(workerLists.count == 1)
        #expect(workerLists.allSatisfy { command in
            command.executable == Self.cliPath
                && command.arguments == [
                    "cpu-devbox", "workers", "list",
                    "--control-plane", "cn",
                    "--json", #"{"filter":{"instance_sid":"dbx_135679"},"page_size":100}"#,
                ]
        })
        #expect(!commands.contains {
            $0.arguments.starts(with: ["cpu-devbox", "workers", "get"])
        })
        #expect(commands.filter {
            $0.arguments.starts(with: ["grafana", "describe"])
        }.count == 1)
        let panelCommands = commands.filter {
            $0.arguments.starts(with: ["grafana", "panel-data"])
        }
        #expect(panelCommands.count == 10)
        for command in panelCommands {
            let request = try platformMetricsRequestBody(command)
            let url = try #require(request["url"] as? String)
            #expect(url.contains("/d/list-dashboard-uid/"))
            #expect(url.contains("from=now-5m"))
            #expect(url.contains("to=now"))
            #expect(!url.contains("from=now-30m"))
            #expect(!url.contains("get-dashboard-must-not-win"))
        }
        #expect(await runner.maximumConcurrentPanelCommands() == 2)

        let publicDescription = String(reflecting: first)
        #expect(!publicDescription.contains("grafana.byted.org"))
        #expect(!publicDescription.contains("sensitive-pod-name"))
        #expect(!publicDescription.contains("list-dashboard-uid"))
    }

    @Test("returns partial data when sibling panels time out")
    func returnsPartialData() async throws {
        let duty = try #require(Self.fullPanelBehaviors[7])
        let runner = PlatformMetricsScriptedRunner(panelBehaviors: [
            7: duty,
            112: .timedOut,
            90: .timedOut,
            119: .timedOut,
            122: .timedOut,
        ])
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner,
            alignmentTolerance: 5
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        let batch = try await provider.fetch(target)

        #expect(batch.samples.count == 2)
        #expect(batch.samples.map(\.gpuUtilization) == [50, 70])
        #expect(batch.samples.allSatisfy { $0.cpuUtilization == nil })
        #expect(batch.samples.allSatisfy { $0.memoryUsedBytes == nil })
        #expect(batch.missingMetrics == [
            .cpu, .memory, .gpuMemory, .temperature,
        ])
    }

    @Test("skips every GPU panel for a CPU-only Worker")
    func skipsGPUPanelsForCPUWorker() async throws {
        let cpu = try #require(Self.fullPanelBehaviors[90])
        let memory = try #require(Self.fullPanelBehaviors[119])
        let runner = PlatformMetricsScriptedRunner(
            panelBehaviors: [90: cpu, 119: memory],
            gpuCount: 0
        )
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner,
            alignmentTolerance: 5
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        let batch = try await provider.fetch(target)

        #expect(batch.samples.count == 2)
        #expect(batch.samples.allSatisfy { $0.gpus.isEmpty })
        let commands = await runner.commands()
        let panelIDs = try commands
            .filter { $0.arguments.starts(with: ["grafana", "panel-data"]) }
            .map { command in
                let request = try platformMetricsRequestBody(command)
                return try #require(request["panel_id"] as? Int)
            }
            .sorted()
        #expect(panelIDs == [90, 119])
    }

    @Test("incremental retries fetch only the missing Merlin panels")
    func fetchesOnlyRequestedMetrics() async throws {
        let memory = try #require(Self.fullPanelBehaviors[112])
        let temperature = try #require(Self.fullPanelBehaviors[122])
        let runner = PlatformMetricsScriptedRunner(panelBehaviors: [
            112: memory,
            122: temperature,
        ])
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner,
            alignmentTolerance: 5
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        let batch = try await provider.fetch(
            target,
            metrics: [.gpuMemory, .temperature]
        )

        #expect(batch.missingMetrics.isEmpty)
        #expect(batch.samples.count == 2)
        let commands = await runner.commands()
        let panelIDs = try commands
            .filter { $0.arguments.starts(with: ["grafana", "panel-data"]) }
            .map { command in
                let request = try platformMetricsRequestBody(command)
                return try #require(request["panel_id"] as? Int)
            }
            .sorted()
        #expect(panelIDs == [112, 122])
    }

    @Test("keeps GPU memory incomplete until both used and total arrive")
    func detectsIncompleteGPUMemoryPanel() async throws {
        let runner = PlatformMetricsScriptedRunner(panelBehaviors: [
            112: .output("""
                {"total":[{"data":[{
                  "metric":"lab.arnold.instance_monitor.gpu_mem_used",
                  "tags":{"gpu_id":"2"},
                  "dps":{"1700000002":100}
                }]}]}
                """),
        ])
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner,
            alignmentTolerance: 5
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        let batch = try await provider.fetch(target, metrics: [.gpuMemory])

        #expect(batch.samples.count == 1)
        #expect(batch.samples[0].gpuMemoryUsedBytes == 100)
        #expect(batch.samples[0].gpuMemoryTotalBytes == nil)
        #expect(batch.missingMetrics == [.gpuMemory])
    }

    @Test("normalizes sparse physical GPU IDs once for the whole fetch")
    func normalizesSparsePhysicalGPUTimeSeries() async throws {
        let runner = PlatformMetricsScriptedRunner(
            panelBehaviors: [
                7: .output("""
                    {"total":[{"data":[{
                      "metric":"lab.arnold.instance_monitor.gpu_duty_cycle",
                      "tags":{"gpu_id":"2"},
                      "dps":{"1700000001":50,"1700000031":60}
                    },{
                      "metric":"lab.arnold.instance_monitor.gpu_duty_cycle",
                      "tags":{"gpu_id":"5"},
                      "dps":{"1700000031":70}
                    }]}]}
                    """),
            ],
            gpuCount: 2
        )
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner,
            alignmentTolerance: 5
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        let batch = try await provider.fetch(
            target,
            metrics: [.gpuUtilization]
        )

        #expect(batch.missingMetrics.isEmpty)
        #expect(batch.samples.count == 2)
        #expect(batch.samples.allSatisfy { $0.gpus.map(\.index) == [0, 1] })
        #expect(batch.samples[0].gpus[0].utilization == 50)
        #expect(batch.samples[0].gpus[1].utilization == nil)
        #expect(batch.samples[1].gpus[0].utilization == 60)
        #expect(batch.samples[1].gpus[1].utilization == 70)
    }

    @Test("maps successful empty panels to noData")
    func mapsEmptyPanels() async throws {
        let runner = PlatformMetricsScriptedRunner(panelBehaviors: Dictionary(
            uniqueKeysWithValues: [7, 112, 90, 119, 122].map {
                ($0, .output(#"{"total":[]}"#))
            }
        ))
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        await #expect(throws: MerlinPlatformMetricsError.noData) {
            try await provider.fetch(target)
        }
    }

    @Test("maps an all-panel timeout without leaking diagnostics")
    func mapsPanelTimeout() async throws {
        let runner = PlatformMetricsScriptedRunner(panelBehaviors: Dictionary(
            uniqueKeysWithValues: [7, 112, 90, 119, 122].map {
                ($0, .timedOut)
            }
        ))
        let provider = try MerlinPlatformMetricsProvider(
            merlinCLIPath: Self.cliPath,
            discoveryProcessRunner: runner,
            panelProcessRunner: runner
        )
        let target = try #require(MerlinPlatformMetricsTarget(
            devboxSID: "dbx_135679",
            workerID: "3966762"
        ))

        await #expect(throws: MerlinPlatformMetricsError.timedOut) {
            try await provider.fetch(target)
        }
    }

    private static let cliPath = "/Users/test/.merlin-cli/bin/merlin-cli"

    private static let fullPanelBehaviors: [Int: PanelBehavior] = [
        90: .output(#"""
            {"total":[
              {"payload":"{\"queries\":[{\"metric\":\"tce.container.cpu_usage.mt\",\"multiFieldExpr\":\"limit\",\"filters\":[{\"filter\":\"sensitive-pod-name\"}]}]}","data":[{
                "metric":"tce.container.cpu_usage.mt",
                "tags":{"container_name":"worker"},
                "query":{"index":0},
                "dps":{"1700000000":20,"1700000030":20}
              }]},
              {"payload":"{\"queries\":[{\"metric\":\"tce.container.cpu_usage.mt\",\"multiFieldExpr\":\"usage\"}]}","data":[{
                "metric":"tce.container.cpu_usage.mt",
                "tags":{"container_name":"worker"},
                "query":{"index":0},
                "dps":{"1700000030":6,"1700000000":4}
              },{
                "metric":"tce.container.cpu_usage.mt",
                "tags":{"container_name":"sidecar"},
                "query":{"index":0},
                "dps":{"1700000032":2,"1700000002":2}
              }]}
            ]}
            """#),
        119: .output(#"""
            {"total":[
              {"payload":"{\"queries\":[{\"metric\":\"tce.container.mem_usage.mt\",\"multiFieldExpr\":\"limit\"}]}","data":[{
                "metric":"tce.container.mem_usage.mt",
                "tags":{"container_name":"worker"},
                "query":{"index":0},
                "dps":{"1700000001":10000}
              }]},
              {"payload":"{\"queries\":[{\"metric\":\"tce.container.mem_usage.mt\",\"multiFieldExpr\":\"used\"}]}","data":[{
                "metric":"tce.container.mem_usage.mt",
                "tags":{"container_name":"worker"},
                "query":{"index":0},
                "dps":{"1700000031":1200,"1700000001":1000}
              },{
                "metric":"tce.container.mem_usage.mt",
                "tags":{"container_name":"sidecar"},
                "query":{"index":0},
                "dps":{"1700000033":600,"1700000003":500}
              }]}
            ]}
            """#),
        7: .output("""
            {"total":[{"query":{"index":0},"data":[{
              "metric":"lab.arnold.instance_monitor.gpu_duty_cycle",
              "tags":{"gpu_id":"2"},
              "dps":{"1700000031":70,"1700000001":50}
            }]}]}
            """),
        112: .output("""
            {"total":[{"data":[{
              "metric":"lab.arnold.instance_monitor.gpu_mem_used",
              "tags":{"gpu_id":"2"},
              "dps":{"1700000032":200,"1700000002":100}
            },{
              "metric":"lab.arnold.instance_monitor.gpu_mem_total",
              "tags":{"gpu_id":"2"},
              "dps":{"1700000032":1000,"1700000002":1000}
            }]}]}
            """),
        122: .output("""
            {"total":[{"data":[{
              "metric":"lab.arnold.instance_monitor.gpu_temperature",
              "tags":{"gpu_id":"2"},
              "dps":{"1700000034":45,"1700000004":40}
            }]}]}
            """),
    ]

}
