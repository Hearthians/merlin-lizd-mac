import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm compute cost estimates")
struct SlurmCostTests {
    @Test("A800 compute adds GPU and CPU charges without rounding runtime to hours")
    func exactElapsedSeconds() throws {
        let result = try #require(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: 3_601
        ))
        #expect(result.gpuCount == 4)
        #expect(result.cpuCount == 32)
        #expect(result.elapsedSeconds == 3_601)
        #expect(abs(result.hourlyCost - 7.04) < 0.000_001)
        #expect(abs(result.gpuAmount - 6.4 * 3_601 / 3_600) < 0.000_001)
        #expect(abs(result.cpuAmount - 0.64 * 3_601 / 3_600) < 0.000_001)
        #expect(abs(result.amount - result.gpuAmount - result.cpuAmount) < 0.000_001)
    }

    @Test("published queues use the correct GPU family and priority tariff")
    func queueTariffs() throws {
        let cases: [(String, Double)] = [
            ("i64m1tga800u", 1.62), ("long_gpu", 1.62),
            ("i64m1tga800ue", 2.54), ("emergency_gpu", 4.06),
            ("i64m1tga40u", 0.52), ("i64m1tga40ue", 1.04),
            ("emergency_gpua40", 1.56), ("gpu", 0.52),
        ]
        for (partition, expected) in cases {
            let result = try #require(SlurmCostEstimator.estimate(
                partition: partition, allocatedCPU: 1, allocatedGPU: 1, elapsedSeconds: 3_600
            ))
            #expect(abs(result.amount - expected) < 0.000_001)
        }
        for partition in ["normal", "lmem", "i64m512u", "long_cpu", "i64m512r", "a128m512u", "i96m3tu"] {
            #expect(SlurmCostEstimator.estimate(
                partition: partition, allocatedCPU: 32, allocatedGPU: 0, elapsedSeconds: 3_600
            )?.amount == 0.64)
        }
        for partition in ["i64m512ue", "i64m512re", "a128m512ue", "i96m3tue"] {
            #expect(SlurmCostEstimator.estimate(
                partition: partition, allocatedCPU: 32, allocatedGPU: 0, elapsedSeconds: 3_600
            )?.amount == 1.28)
        }
        #expect(SlurmCostEstimator.estimate(
            partition: "emergency_cpu", allocatedCPU: 32, allocatedGPU: 0, elapsedSeconds: 3_600
        )?.amount == 1.92)
    }

    @Test("multi-node allocation uses its total GPU count and does not double-count typed TRES")
    func totalAllocation() throws {
        let raw = "cpu=32,mem=256G,node=4,billing=32,gres/gpu=4,gres/gpu:a800=4"
        let fourNodes = try #require(SlurmCostEstimator.estimate(history: history(resources: raw, nodes: 4)))
        let oneNode = try #require(SlurmCostEstimator.estimate(history: history(resources: raw, nodes: 1)))
        #expect(fourNodes.gpuCount == 4)
        #expect(fourNodes.amount == oneNode.amount)
        #expect(abs(fourNodes.amount - 7.04) < 0.000_001)
        #expect(SlurmCostEstimator.estimate(history: history(
            resources: "cpu=32,mem=256G,gres/gpu:a800=4"
        ))?.gpuCount == 4)
    }

    @Test("failed and cancelled jobs retain charges for allocated elapsed time")
    func failedAndCancelled() throws {
        for state in [SlurmJobState.failed, .cancelled, .timeout] {
            let result = try #require(SlurmCostEstimator.estimate(history: history(
                state: state, elapsed: "00:30:00"
            )))
            #expect(abs(result.amount - 3.52) < 0.000_001)
        }
    }

    @Test("history parses day-hour and minute-second durations without charging queue wait")
    func accountingDuration() throws {
        let durations: [(String, Double)] = [
            ("1-02:03:04", 93_784), ("26:03:04", 93_784), ("03:04", 184), ("00:00", 0),
        ]
        for (text, expected) in durations {
            #expect(SlurmCostEstimator.estimate(history: history(elapsed: text))?.elapsedSeconds == expected)
        }
        for invalid in ["Unknown", "", "1-02:03", "1-24:00:00", "00:60:00", "00:00:60", "-01:00", "nan", "1e2:00", "1:2:3:4"] {
            #expect(SlurmCostEstimator.estimate(history: history(elapsed: invalid)) == nil)
        }
    }

    @Test("debug compute is free even if allocation fields are unavailable")
    func debugException() throws {
        let result = try #require(SlurmCostEstimator.estimate(
            partition: "debug", allocatedCPU: nil, allocatedGPU: nil, elapsedSeconds: 123
        ))
        #expect(result.amount == 0)
        #expect(result.hourlyCost == 0)
        #expect(SlurmCostEstimator.estimate(history: history(partition: "debug", resources: ""))?.amount == 0)
    }

    @Test("missing or inconsistent billable resources do not produce a partial estimate")
    func missingResources() throws {
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: nil, allocatedGPU: 4, elapsedSeconds: 3_600
        ) == nil)
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: nil, elapsedSeconds: 3_600
        ) == nil)
        for raw in [
            "", "gres/gpu=4", "cpu=32,gres/gpu=4,gres/gpu:a800=3",
            "cpu=32,cpu=64,gres/gpu=4", "cpu=bad,gres/gpu=4",
            "cpu=32,gres/gpu=-4", "cpu=32,gres/gpu=1.5", "cpu=32,gres/gpu=4,",
            "cpu=32,gres/gpu=4,malformed", "cpu=32,gres/gpu=99999999999999999999999999999",
        ] {
            #expect(SlurmCostEstimator.estimate(history: history(resources: raw)) == nil)
        }
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: 3_600,
            allocatedResources: "cpu=64,gres/gpu=4"
        ) == nil)
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: 3_600,
            allocatedResources: "cpu=32,gres/gpu=2"
        ) == nil)
    }

    @Test("MIG slices, unknown device types and unpriced queues never use full-card prices")
    func unsupportedResources() throws {
        for partition in ["a800", "i64m1tga800mig", "custom_gpu", "unknown", "i64m1tga800u,debug"] {
            #expect(SlurmCostEstimator.estimate(history: history(partition: partition)) == nil)
        }
        for raw in [
            "cpu=32,gres/gpu=1,gres/gpu:a800_1g.10gb=1",
            "cpu=32,gres/gpu=1,gres/gpu:mig=1",
            "cpu=32,gres/gpu=1,gres/mig=1",
            "cpu=32,gres/gpu=1,gres/shard=1",
            "cpu=32,gres/gpu=1,gres/mps=10",
            "cpu=32,gres/gpu=1,gres/gpu:a40=1",
            "cpu=32,gres/gpu=1,gres/gpu:unknown=1",
        ] {
            #expect(SlurmCostEstimator.estimate(history: history(resources: raw)) == nil)
            #expect(SlurmCostEstimator.estimate(
                partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 1, elapsedSeconds: 3_600,
                allocatedResources: raw
            ) == nil)
        }
        #expect(SlurmCostEstimator.estimate(history: history(partition: "normal")) == nil)
    }

    @Test("CPU-only allocation has zero GPU charge and unknown counts stay unknown")
    func cpuOnly() throws {
        let result = try #require(SlurmCostEstimator.estimate(history: history(
            partition: "normal", resources: "cpu=32,mem=256G,node=2"
        )))
        #expect(result.gpuCount == 0)
        #expect(result.gpuAmount == 0)
        #expect(result.amount == 0.64)
        #expect(SlurmCostEstimator.estimate(history: history(
            resources: "mem=256G,node=2"
        )) == nil)
    }

    @Test("configured prices round-trip and reject invalid rates, durations, counts and overflow")
    func configurationValidation() throws {
        var custom = SlurmCostConfiguration.hkustHPC2
        custom.low.a800PerGPUHour = 2
        custom.low.cpuPerCoreHour = 0.1
        #expect(custom.isValid)
        #expect(custom.currencyCode == "CNY")
        #expect(try JSONDecoder().decode(SlurmCostConfiguration.self, from: JSONEncoder().encode(custom)) == custom)
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: 3_600,
            configuration: custom
        )?.amount == 11.2)
        for invalid in [-1.0, .infinity, -.infinity, .nan] {
            custom.low.a800PerGPUHour = invalid
            #expect(!custom.isValid)
            #expect(SlurmCostEstimator.estimate(
                partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: 3_600,
                configuration: custom
            ) == nil)
            #expect(SlurmCostEstimator.estimate(
                partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: invalid
            ) == nil)
        }
        custom = .hkustHPC2
        custom.low.a800PerGPUHour = .greatestFiniteMagnitude
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: 3_600,
            configuration: custom
        ) == nil)
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: -1, allocatedGPU: 4, elapsedSeconds: 3_600
        ) == nil)
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: -1, elapsedSeconds: 3_600
        ) == nil)
        #expect(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4, elapsedSeconds: nil
        ) == nil)
    }

    @Test("allocation retains raw TRES for MIG checks and decodes legacy snapshots")
    func rawAllocationCompatibility() throws {
        let jobID = try #require(SlurmJobID(rawValue: "123"))
        let raw = "cpu=32,mem=256G,gres/gpu=4,gres/gpu:a800=4"
        let output = "JobId=123 UserId=user(1) JobState=RUNNING NumCPUs=32 RunTime=01:00:00 AllocTRES=\(raw)"
        let allocation = try #require(SlurmMonitoringParser.allocations(output)[jobID])
        #expect(allocation.allocatedResources == raw)
        let encoded = try JSONEncoder().encode(allocation)
        var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "allocatedResources")
        let legacy = try JSONDecoder().decode(
            SlurmJobAllocation.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        #expect(legacy.allocatedResources == nil)
        #expect(legacy.allocatedGPU == 4)
    }

    @Test("real scontrol punctuation in field names does not contaminate allocation TRES")
    func scontrolFieldBoundaries() throws {
        let jobID = try #require(SlurmJobID(rawValue: "13232525"))
        let raw = "cpu=32,mem=256G,node=4,billing=32,gres/gpu=4,gres/gpu:a800=4"
        let output = """
        JobId=13232525 JobName=training UserId=user(1) JobState=RUNNING RunTime=01:00:00 TimeLimit=1-00:00:00 Partition=i64m1tga800ue NodeList=gpu1-[31,35,41,43] NumNodes=4 NumCPUs=32 NumTasks=4 CPUs/Task=8 ReqB:S:C:T=0:0:*:* TRES=cpu=32,mem=256G,node=4 AllocTRES=\(raw) Socks/Node=* NtasksPerN:B:S:C=1:0:*:* CoreSpec=* MinCPUsNode=8 MinMemoryNode=64G
        """
        let allocation = try #require(SlurmMonitoringParser.allocations(output)[jobID])
        #expect(allocation.allocatedResources == raw)
        #expect(allocation.allocatedGPU == 4)
        #expect(allocation.allocatedCPU == 32)
        let estimate = try #require(SlurmCostEstimator.estimate(
            partition: "i64m1tga800ue",
            allocatedCPU: allocation.allocatedCPU, allocatedGPU: allocation.allocatedGPU,
            elapsedSeconds: allocation.elapsedSeconds, allocatedResources: allocation.allocatedResources
        ))
        #expect(abs(estimate.hourlyCost - 11.28) < 0.000_001)
        #expect(abs(estimate.amount - 11.28) < 0.000_001)
    }

    private func history(
        partition: String = "i64m1tga800u",
        resources: String = "cpu=32,mem=256G,gres/gpu=4,gres/gpu:a800=4",
        state: SlurmJobState = .completed,
        elapsed: String = "01:00:00",
        nodes: Int = 1
    ) -> SlurmJobHistoryRecord {
        SlurmJobHistoryRecord(
            snapshot: SlurmJobSnapshot(
                jobID: SlurmJobID(rawValue: "123")!, name: "training", owner: "user",
                state: state, reasonOrNodeList: "gpu1-01", partition: partition, nodeCount: nodes,
                elapsed: elapsed, timeLimit: "1-00:00:00",
                startTime: "2026-10-20T10:00:00", submitTime: "2026-10-19T10:00:00",
                nodeList: "gpu1-01", comment: ""
            ),
            endTime: "2026-10-20T11:00:00", exitCode: "0:0", allocatedResources: resources
        )
    }
}
