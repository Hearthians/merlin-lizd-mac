import Testing
@testable import MerlinLizdCore

@Suite("Grafana metrics parsing")
struct GrafanaMetricsTests {
    @Test("discovers semantic panels by title and ignores more specific decoys")
    func discoversPanelsBySemanticTitle() throws {
        let catalog = try GrafanaDescribeParser.parse("""
            {
              "dashboards": [{
                "dashboard_uid": "workspace-v-next",
                "dashboard_panels": [{
                  "row_title": "Metrics",
                  "panels": [
                    {"id": 902, "title": "CPU Usage (Cloud IDE Filewatch)"},
                    {"id": 417, "title": "Ada Device Util 监控"},
                    {"id": 388, "title": "GPU Memory Bandwidth Utilization"},
                    {"id": 731, "title": "GPU DutyCycle (GPU 利用率)"},
                    {"id": 654, "title": "GPU Mem (GPU 显存)"},
                    {"id": 205, "title": "CPU Cores"},
                    {"id": 306, "title": "内存 Used / Limit"},
                    {"id": 819, "title": "GPU Temperature"}
                  ]
                }]
              }]
            }
            """)

        #expect(catalog.availableMetrics == [
            .gpuUtilization, .gpuMemory, .cpu, .memory, .temperature,
        ])
        #expect(catalog.panel(for: .gpuUtilization)?.id == 731)
        #expect(catalog.panel(for: .gpuMemory)?.id == 654)
        #expect(catalog.panel(for: .cpu)?.id == 205)
        #expect(catalog.panel(for: .memory)?.id == 306)
        #expect(catalog.panel(for: .temperature)?.id == 819)
        #expect(catalog.panel(for: .temperature)?.dashboardUID == "workspace-v-next")
    }

    @Test("uses deterministic scoring when dashboards contain duplicate semantics")
    func prefersCanonicalPanelTitles() throws {
        let catalog = try GrafanaDescribeParser.parse("""
            {
              "dashboards": [{
                "dashboard_uid": "two-dashboards",
                "dashboard_panels": [
                  {"panels": [{"id": 90, "title": "CPU Filewatch Usage"}]},
                  {"panels": [{"id": 12, "title": "CPU Usage"}]},
                  {"panels": [{"id": 44, "title": "Memory Usage (Cloud IDE Filewatch)"}]},
                  {"panels": [{"id": 14, "title": "Memory Usage"}]}
                ]
              }]
            }
            """)

        #expect(catalog.panel(for: .cpu)?.id == 12)
        #expect(catalog.panel(for: .memory)?.id == 14)
        #expect(catalog.panel(for: .gpuUtilization) == nil)
    }

    @Test("merges OpenTSDB series, filters lookups, and normalizes timestamps")
    func parsesOpenTSDBSeries() throws {
        let series = try GrafanaPanelDataParser.parse("""
            {
              "count": 4,
              "total": [
                {
                  "data": {
                    "results": [{"tags": {"dc": "hl"}}]
                  }
                },
                {
                  "data": [{
                    "metric": "docker.gpu.utilization",
                    "tags": {"dockerGPUId": "0", "pod": "worker-a"},
                    "dps": {
                      "1700000003": 30,
                      "1700000000": 10,
                      "1700000001": "NaN"
                    }
                  }, {
                    "metric": "docker.gpu.utilization",
                    "tags": {"dockerGPUId": "1", "pod": "worker-a"},
                    "dps": {
                      "1700000000000": 40,
                      "1700000003000": 60,
                      "1700000004000": "Infinity"
                    }
                  }]
                },
                {
                  "data": [{
                    "metric": "docker.gpu.utilization",
                    "tags": {"pod": "worker-a", "dockerGPUId": "0"},
                    "dps": {
                      "1700000003000": 35
                    }
                  }]
                },
                {"data": {"rows": 0, "meta": [], "data": []}}
              ]
            }
            """)

        #expect(series.count == 2)
        let gpu0 = try #require(series.first { $0.tags["dockerGPUId"] == "0" })
        let gpu1 = try #require(series.first { $0.tags["dockerGPUId"] == "1" })
        #expect(gpu0.metric == "docker.gpu.utilization")
        #expect(gpu0.legend == "GPU 0")
        #expect(gpu0.points.map(\.timestamp.timeIntervalSince1970) == [
            1_700_000_000, 1_700_000_003,
        ])
        #expect(gpu0.points.map(\.value) == [10, 35])
        #expect(gpu1.legend == "GPU 1")
        #expect(gpu1.points.map(\.timestamp.timeIntervalSince1970) == [
            1_700_000_000, 1_700_000_003,
        ])
        #expect(gpu1.points.map(\.value) == [40, 60])
    }

    @Test("parses compact ClickHouse rows into multiple GPU series")
    func parsesCompactClickHouseRows() throws {
        let series = try GrafanaPanelDataParser.parse("""
            {
              "count": 2,
              "total": [
                {"data": {"results": [{"tags": {"eth_name": "eth0"}}]}},
                {"data": {
                  "meta": [
                    {"name": "t", "type": "UInt64"},
                    {"name": "legend", "type": "String"},
                    {"name": "dockerGPUId", "type": "String"},
                    {"name": "gpu_usage", "type": "Float64"}
                  ],
                  "data": [
                    [1700000003000, "GPU 0", "0", 30],
                    [1700000000, "GPU 0", "0", 10],
                    [1700000003000, "GPU 0", "0", 32],
                    [1700000000, "GPU 1", "1", 40],
                    [1700000003000, "GPU 1", "1", 60],
                    [1700000004000, "GPU 1", "1", "NaN"]
                  ],
                  "rows": 6,
                  "statistics": {"elapsed": 0.01}
                }}
              ]
            }
            """)

        #expect(series.count == 2)
        let gpu0 = try #require(series.first { $0.tags["dockerGPUId"] == "0" })
        let gpu1 = try #require(series.first { $0.tags["dockerGPUId"] == "1" })
        #expect(gpu0.metric == "gpu_usage")
        #expect(gpu0.legend == "GPU 0")
        #expect(gpu0.points.map(\.value) == [10, 32])
        #expect(gpu1.points.map(\.value) == [40, 60])
    }

    @Test("keeps legacy Grafana targets distinct using their safe query index")
    func preservesQueryIndexWhenMergingSeries() throws {
        let series = try GrafanaPanelDataParser.parse("""
            {
              "total": [
                {
                  "query": {"index": 1, "raw_query": "must not escape"},
                  "data": [{
                    "metric": "container.cpu",
                    "tags": {"pod": "worker-a"},
                    "dps": {"1700000000": 4, "1700000003": 5}
                  }]
                },
                {
                  "query": {"index": 0},
                  "data": [{
                    "metric": "container.cpu",
                    "tags": {"pod": "worker-a"},
                    "dps": {"1700000000": 20, "1700000003": 20}
                  }]
                },
                {
                  "query": {"index": 99},
                  "data": [{
                    "metric": "container.cpu",
                    "tags": {"pod": "worker-a"},
                    "query": {"index": "1"},
                    "dps": {"1700000003": 6}
                  }]
                }
              ]
            }
            """)

        #expect(series.count == 2)
        #expect(series.map(\.queryIndex) == [0, 1])
        #expect(series[0].points.map(\.value) == [20, 20])
        #expect(series[1].points.map(\.value) == [4, 6])
        #expect(!String(reflecting: series).contains("must not escape"))
    }

    @Test("uses Merlin payload fields when every target query index resets to zero")
    func preservesTargetsFromMerlinPayload() throws {
        let series = try GrafanaPanelDataParser.parse(#"""
            {"total": [
              {"payload": "{\"queries\":[{\"multiFieldExpr\":\"used\",\"filters\":[{\"filter\":\"sensitive-pod-must-not-escape\"}]}]}", "data": [{"metric": "container.memory", "tags": {"pod": "worker-a"}, "query": {"index": 0}, "dps": {"1700000000": 50}}]},
              {"payload": "{\"queries\":[{\"multiFieldExpr\":\"limit\"}]}", "data": [{"metric": "container.memory", "tags": {"pod": "worker-a"}, "query": {"index": 0}, "dps": {"1700000000": 100}}]},
              {"payload": "{\"queries\":[{\"multiFieldExpr\":\"shmem\"}]}", "data": [{"metric": "container.memory", "tags": {"pod": "worker-a"}, "query": {"index": 0}, "dps": {"1700000000": 1}}]},
              {"payload": "{\"queries\":[{\"multiFieldExpr\":\"cache\"}]}", "data": [{"metric": "container.memory", "tags": {"pod": "worker-a"}, "query": {"index": 0}, "dps": {"1700000000": 20}}]},
              {"payload": "{\"queries\":[{\"multiFieldExpr\":\"rss\"}]}", "data": [{"metric": "container.memory", "tags": {"pod": "worker-a"}, "query": {"index": 0}, "dps": {"1700000000": 40}}]}
            ]}
            """#)

        #expect(series.map(\.targetField) == [
            "cache", "limit", "rss", "shmem", "used",
        ])
        #expect(series.allSatisfy { $0.queryIndex == 0 })
        #expect(series.map { $0.points.first?.value } == [20, 100, 40, 1, 50])
        #expect(!String(reflecting: series).contains(
            "sensitive-pod-must-not-escape"
        ))
    }

    @Test("parses object ClickHouse rows and emits one series per value column")
    func parsesObjectClickHouseRows() throws {
        let series = try GrafanaPanelDataParser.parse("""
            {
              "total": [{"data": {
                "meta": [
                  {"name": "timestamp", "type": "DateTime64"},
                  {"name": "legend", "type": "String"},
                  {"name": "cluster", "type": "String"},
                  {"name": "usage", "type": "Float64"},
                  {"name": "limit", "type": "Float64"}
                ],
                "data": [
                  {"timestamp": "2026-07-12T09:00:00Z", "legend": "worker", "cluster": "hl", "usage": 4, "limit": 20},
                  {"timestamp": "2026-07-12T09:00:05.000Z", "legend": "worker", "cluster": "hl", "usage": 5, "limit": 20}
                ],
                "rows": 2
              }}]
            }
            """)

        #expect(series.map(\.metric) == ["limit", "usage"])
        #expect(series.allSatisfy { $0.legend == "worker" })
        #expect(series.allSatisfy { $0.tags == ["cluster": "hl"] })
        #expect(series.first { $0.metric == "usage" }?.points.map(\.value) == [4, 5])
        #expect(series.first { $0.metric == "limit" }?.points.map(\.value) == [20, 20])
    }

    @Test("returns an empty result for lookup-only, empty, or absent panel data")
    func handlesEmptyPanelData() throws {
        #expect(try GrafanaPanelDataParser.parse("""
            {"total": [
              {"data": {"results": [{"tags": {"dc": "hl"}}]}},
              {"data": {"meta": [], "data": [], "rows": 0}}
            ]}
            """) == [])
        #expect(try GrafanaPanelDataParser.parse("{}") == [])
    }

    @Test("reports malformed JSON without exposing decoder details")
    func rejectsMalformedJSON() {
        #expect(throws: GrafanaMetricsParseError.invalidJSON) {
            try GrafanaDescribeParser.parse("not-json")
        }
        #expect(throws: GrafanaMetricsParseError.invalidJSON) {
            try GrafanaPanelDataParser.parse("{broken")
        }
    }
}
