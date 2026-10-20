import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm resource monitoring")
struct SlurmMonitoringTests {
    private let sampledAt = Date(timeIntervalSince1970: 1_792_448_000)

    @Test("generic and typed GPU TRES describe the same devices")
    func gpuCountsDoNotDoubleCountTypes() throws {
        let output = """
        NodeName=gpu1-01 CPUTot=128 CPUAlloc=64 RealMemory=1048576 AllocMem=262144 State=MIXED Partitions=a800 CfgTRES=cpu=128,mem=1T,gres/gpu=8,gres/gpu:a800=8 AllocTRES=cpu=64,mem=256G,gres/gpu=4,gres/gpu:a800=4
        NodeName=gpu1-02 CPUTot=128 CPUAlloc=32 RealMemory=1048576 AllocMem=131072 State=MIXED Partitions=a800 CfgTRES=cpu=128,mem=1T,gres/gpu:a800=8 AllocTRES=cpu=32,mem=128G,gres/gpu:a800=8
        """
        let queues = try queues(output)
        let queue = try #require(queues.first)
        #expect(queue.totalGPU == 16)
        #expect(queue.allocatedGPU == 12)
        #expect(queue.unallocatedGPU == 4)
        #expect(queue.totalCPU == 256)
        #expect(queue.allocatedCPU == 96)
        #expect(queue.totalMemoryMiB == 2_097_152)
        #expect(queue.allocatedMemoryMiB == 393_216)
        #expect(queue.schedulableFourGPUNodeCount == 1)
        #expect(queue.schedulableEightGPUNodeCount == 0)
        #expect(queue.sampledAt == sampledAt)
    }

    @Test("explicit empty allocation is zero while missing allocation is unknown")
    func emptyAndMissingAllocations() throws {
        let output = """
        NodeName=idle CPUTot=128 CPUAlloc=0 RealMemory=1048576 AllocMem=0 State=IDLE Partitions=a800 CfgTRES=cpu=128,mem=1T,gres/gpu=8 AllocTRES=
        NodeName=unknown CPUTot=128 CPUAlloc=0 RealMemory=1048576 AllocMem=0 State=IDLE Partitions=a800 CfgTRES=cpu=128,mem=1T,gres/gpu=8
        """
        let queue = try #require(try queues(output).first)
        #expect(queue.totalGPU == 16)
        #expect(queue.nodes.first { $0.name == "idle" }?.allocatedGPU == 0)
        #expect(queue.nodes.first { $0.name == "idle" }?.unallocatedGPU == 8)
        #expect(queue.nodes.first { $0.name == "unknown" }?.allocatedGPU == nil)
        #expect(queue.allocatedGPU == nil)
        #expect(queue.unallocatedGPU == nil)
        #expect(queue.schedulableFourGPUNodeCount == nil)
    }

    @Test("CPU-only nodes report observed zero GPUs")
    func cpuOnlyNode() throws {
        let queue = try #require(try queues("""
        NodeName=cpu01 CPUTot=64 CPUAlloc=8 RealMemory=262144 AllocMem=16384 State=MIXED Partitions=a800 CfgTRES=cpu=64,mem=256G AllocTRES=cpu=8,mem=16G
        """).first)
        #expect(queue.totalGPU == 0)
        #expect(queue.allocatedGPU == 0)
        #expect(queue.unallocatedGPU == 0)
        #expect(queue.schedulableFourGPUNodeCount == 0)
    }

    @Test("unpartitioned drained nodes do not invalidate healthy partition snapshots")
    func unpartitionedNodes() throws {
        let retired = """
        NodeName=bigmem-1 Arch=x86_64 CoresPerSocket=48 CPUAlloc=0 CPUEfctv=96 CPUTot=96 CPULoad=28.91 AvailableFeatures=(null) ActiveFeatures=(null) Gres=(null) NodeAddr=bigmem-1 NodeHostName=bigmem-1 Version=23.02.3 OS=Linux 5.4.0-155-generic #172-Ubuntu SMP Fri Jul 7 16:10:02 UTC 2023 RealMemory=3072000 AllocMem=0 FreeMem=2461494 Sockets=2 Boards=1 State=DOWN+DRAIN ThreadsPerCore=1 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A BootTime=2026-06-23T17:33:22 SlurmdStartTime=2026-06-23T17:53:30 LastBusyTime=2026-08-22T00:09:05 ResumeAfterTime=None CfgTRES=cpu=96,mem=3000G,billing=96 AllocTRES= CapWatts=n/a CurrentWatts=0 AveWatts=0 ExtSensorsJoules=n/s ExtSensorsWatts=0 ExtSensorsTemp=n/s Reason=mgmt6 : Not responding [root@2026-06-23T13:33:47]
        """
        let detached = "NodeName=detached State=IDLE Partitions=(null) CfgTRES=cpu=8,mem=16G AllocTRES="
        let queue = try #require(try queues(retired + "\n" + detached + "\n" + node("gpu01")).first)
        #expect(queue.nodeCount == 1)
        #expect(queue.nodes.map(\.name) == ["gpu01"])
        #expect(queue.totalGPU == 8)
        #expect(queue.schedulableEightGPUNodeCount == 1)
    }

    @Test("offline and draining nodes cannot count as four or eight GPU candidates")
    func excludesUnavailableNodes() throws {
        let output = [
            node("down", state: "DOWN", allocated: 0),
            node("drained", state: "IDLE+DRAIN", allocated: 0),
            node("unreachable", state: "IDLE+NOT_RESPONDING", allocated: 0),
            node("partial", state: "MIXED", allocated: 4),
        ].joined(separator: "\n")
        let queue = try #require(try queues(output).first)
        #expect(queue.totalGPU == 32)
        #expect(queue.unallocatedGPU == 28)
        #expect(queue.unavailableNodeCount == 3)
        #expect(queue.schedulableFourGPUNodeCount == 1)
        #expect(queue.schedulableEightGPUNodeCount == 0)
        let inactive = try #require(try queues(output, partitions: "PartitionName=a800 State=DOWN").first)
        #expect(inactive.unavailableNodeCount == 4)
        #expect(inactive.schedulableFourGPUNodeCount == 0)
    }

    @Test("overlapping partitions retain the shared node identity")
    func sharedPartitionNodesAndQueueCounts() throws {
        let snapshots = try queues(
            node("shared", partitions: "a800,debug", allocated: 4),
            partitions: "PartitionName=a800 State=UP\nPartitionName=debug State=UP",
            queue: "a800|RUNNING\na800,debug|PENDING\ndebug|COMPLETING\na800|COMPLETED"
        )
        let a800 = try #require(snapshots.first { $0.partition == "a800" })
        let debug = try #require(snapshots.first { $0.partition == "debug" })
        #expect(a800.totalGPU == 8)
        #expect(debug.totalGPU == 8)
        #expect(a800.nodes.map(\.id) == debug.nodes.map(\.id))
        #expect(a800.runningJobCount == 1)
        #expect(debug.runningJobCount == 1)
        #expect(a800.pendingJobCount == 1)
        #expect(debug.pendingJobCount == 1)
        #expect(try queues(node("one"), queue: nil).first?.runningJobCount == nil)
        #expect(try queues(node("one"), queue: "").first?.runningJobCount == 0)
    }

    @Test("allocation fields exclude pending requests and retain numeric array task job IDs")
    func jobAllocations() throws {
        let allocations = try SlurmMonitoringParser.allocations("""
        JobId=13004279 ArrayJobId=13004272 ArrayTaskId=7 JobName=vae UserId=zli760(10001) JobState=RUNNING NumCPUs=32 NodeList=gpu1-36 RunTime=1-02:03:04 AllocTRES=cpu=32,mem=256G,node=1,billing=32,gres/gpu=4,gres/gpu:a800=4
        JobId=13004273 UserId=zli760(10001) JobState=PENDING NumCPUs=64 NodeList=(null) RunTime=00:00:00 ReqTRES=cpu=64,mem=512G,gres/gpu=8 AllocTRES=cpu=64,mem=512G,gres/gpu=8
        JobId=13004274 UserId=zli760(10001) JobState=RUNNING NumCPUs=8 NodeList=cpu01 RunTime=00:01:00
        """)
        let running = try #require(allocations[jobID("13004279")])
        #expect(running.owner == "zli760")
        #expect(running.allocatedGPU == 4)
        #expect(running.allocatedCPU == 32)
        #expect(running.allocatedMemoryMiB == 262_144)
        #expect(running.elapsedSeconds == 93_784)
        #expect(allocations[jobID("13004272_7")] == nil)
        let pending = try #require(allocations[jobID("13004273")])
        #expect(pending.state == .pending)
        #expect(pending.nodeList == nil)
        #expect(pending.allocatedGPU == nil)
        #expect(pending.allocatedCPU == nil)
        #expect(pending.allocatedMemoryMiB == nil)
        #expect(allocations[jobID("13004274")]?.allocatedCPU == 8)
        #expect(allocations[jobID("13004274")]?.allocatedGPU == nil)
    }

    @Test("sstat computes since-start CPU average and a per-task sampled RSS peak")
    func jobStatistics() throws {
        let allocations = try SlurmMonitoringParser.allocations("""
        JobId=1042 ArrayJobId=1042 ArrayTaskId=8 UserId=zli760(10001) JobState=RUNNING NumCPUs=4 RunTime=00:01:00 AllocTRES=cpu=4,mem=16G,gres/gpu=1
        JobId=1043 ArrayJobId=1042 ArrayTaskId=7 UserId=zli760(10001) JobState=RUNNING NumCPUs=2 RunTime=00:01:00 AllocTRES=cpu=2,mem=8G,gres/gpu=1
        """)
        let statistics = try SlurmMonitoringParser.statistics("""
        1042.batch|1|00:00:10|500M|1G|cpu=10|cpu=10|cpu=10
        1042.0|2|00:00:25|1G|2G|cpu=25|cpu=25|cpu=50
        1043.0|1|00:00:00|0K|0K||||
        9999.0|1|00:01:00|9G|9G|cpu=60|cpu=60|cpu=60
        """, allocations: allocations)
        let stats = try #require(statistics[jobID("1042")])
        #expect(stats.cpuTimeSeconds == 60)
        #expect(stats.averageCPUPercent == 25)
        #expect(stats.peakTaskMemoryMiB == 2_048)
        #expect(stats.source == "sstat")
        #expect(statistics[jobID("1043")]?.averageCPUPercent == 0)
        #expect(statistics[jobID("1043")]?.peakTaskMemoryMiB == 0)
        #expect(statistics[jobID("9999")] == nil)
    }

    @Test("sstat missing metrics remain unknown and trailing delimiters preserve eight columns")
    func missingStatistics() throws {
        let allocations = try SlurmMonitoringParser.allocations("""
        JobId=1042 UserId=zli760(10001) JobState=RUNNING NumCPUs=4 RunTime=00:01:00 AllocTRES=cpu=4,mem=16G
        JobId=1043 UserId=zli760(10001) JobState=RUNNING NumCPUs=4 RunTime=00:00:00 AllocTRES=cpu=4,mem=16G
        """)
        let missing = try SlurmMonitoringParser.statistics("1042.batch|||||||", allocations: allocations)
        #expect(missing[jobID("1042")]?.averageCPUPercent == nil)
        #expect(missing[jobID("1042")]?.cpuTimeSeconds == nil)
        #expect(missing[jobID("1042")]?.peakTaskMemoryMiB == nil)
        let partial = try SlurmMonitoringParser.statistics("""
        1042.batch|1|00:00:30|512K|1024K|||
        1042.0||00:00:30|1M|2M|||
        1043.batch|1|00:00:00|0|0|||
        """, allocations: allocations)
        #expect(partial[jobID("1042")]?.averageCPUPercent == nil)
        #expect(partial[jobID("1042")]?.peakTaskMemoryMiB == 2)
        #expect(partial[jobID("1043")]?.averageCPUPercent == nil)
    }

    @Test("GPU telemetry distinguishes unsupported metrics from observed zero usage")
    func gpuMetrics() throws {
        let devices = try SlurmMonitoringParser.gpuUsage("""
        0, GPU-0000-aaaa, NVIDIA A800-SXM4-80GB, 0, 0, 81920
        1, GPU-0000-bbbb, NVIDIA A800-SXM4-80GB, [N/A], N/A, 81920
        2, GPU-0000-cccc, NVIDIA A800-SXM4-80GB, 87, 40960.5, 81920
        3, GPU-0000-dddd, NVIDIA A800-SXM4-80GB, 101, -1, NaN
        """)
        #expect(devices[0].utilizationPercent == 0)
        #expect(devices[0].memoryUsedMiB == 0)
        #expect(devices[1].utilizationPercent == nil)
        #expect(devices[1].memoryUsedMiB == nil)
        #expect(devices[1].memoryTotalMiB == 81_920)
        #expect(devices[2].utilizationPercent == 87)
        #expect(devices[2].memoryUsedMiB == 40_960.5)
        #expect(devices[3].utilizationPercent == nil)
        #expect(devices[3].memoryUsedMiB == nil)
        #expect(devices[3].memoryTotalMiB == nil)
        #expect(devices.allSatisfy { $0.nodeName == nil && $0.powerDrawWatts == nil && $0.powerLimitWatts == nil })
        #expect(devices[0].id == devices[0].uuid)
    }

    @Test("Multi-node GPU metrics retain node identity when local GPU indexes or UUIDs repeat")
    func nodeScopedGPUMetrics() throws {
        let devices = try SlurmMonitoringParser.gpuUsage("""
        gpu01, 0, GPU-aaaa, NVIDIA A800, 95, 58000, 81920, 275.5, 400
        gpu02, 0, GPU-aaaa, NVIDIA A800, 92, 53000, 81920, 240, 400
        gpu02, 1, GPU-bbbb, NVIDIA A800, 89, 50000, 81920, 235, 400
        """)
        #expect(devices.map(\.nodeName) == ["gpu01", "gpu02", "gpu02"])
        #expect(devices.map(\.index) == [0, 0, 1])
        #expect(Set(devices.map(\.id)).count == 3)
        #expect(devices[0].id == "gpu01:GPU-aaaa")
        #expect(devices[1].id == "gpu02:GPU-aaaa")
        #expect(devices[0].memoryUsedMiB == 58_000)
        #expect(devices[0].powerDrawWatts == 275.5)
        #expect(devices[0].powerLimitWatts == 400)
        #expect(throws: SlurmMonitoringParserError.duplicateIdentifier("gpu01:GPU-aaaa")) {
            try SlurmMonitoringParser.gpuUsage("""
            gpu01, 0, GPU-aaaa, NVIDIA A800, 95, 58000, 81920, 275.5, 400
            gpu01, 1, GPU-aaaa, NVIDIA A800, 92, 53000, 81920, 240, 400
            """)
        }
    }

    @Test("GPU power metrics preserve observed zero and keep unsupported or invalid values unknown")
    func gpuPowerMetrics() throws {
        let devices = try SlurmMonitoringParser.gpuUsage("""
        gpu01, 0, GPU-aaaa, NVIDIA A800, 0, 0, 81920, 0, 0
        gpu01, 1, GPU-bbbb, NVIDIA A800, [N/A], N/A, UNKNOWN, [N/A], N/A
        gpu01, 2, GPU-cccc, NVIDIA A800, 87, 40960.5, 81920, 215.25, 400
        gpu01, 3, GPU-dddd, NVIDIA A800, 87, 40960.5, 81920, -1, inf
        gpu01, 4, GPU-eeee, NVIDIA A800, 87, 40960.5, 81920, NaN, -20
        """)
        #expect(devices[0].powerDrawWatts == 0)
        #expect(devices[0].powerLimitWatts == 0)
        #expect(devices[1].utilizationPercent == nil)
        #expect(devices[1].memoryUsedMiB == nil)
        #expect(devices[1].memoryTotalMiB == nil)
        #expect(devices[1].powerDrawWatts == nil)
        #expect(devices[1].powerLimitWatts == nil)
        #expect(devices[2].powerDrawWatts == 215.25)
        #expect(devices[2].powerLimitWatts == 400)
        #expect(devices[3].powerDrawWatts == nil)
        #expect(devices[3].powerLimitWatts == nil)
        #expect(devices[4].powerDrawWatts == nil)
        #expect(devices[4].powerLimitWatts == nil)
    }

    @Test("Legacy GPU snapshots decode without node or power metrics")
    func legacyGPUDecoding() throws {
        let data = Data(#"""
        {"index":0,"uuid":"GPU-aaaa","name":"NVIDIA A800","utilizationPercent":80,"memoryUsedMiB":1024,"memoryTotalMiB":81920}
        """#.utf8)
        let device = try JSONDecoder().decode(SlurmGPUUtilization.self, from: data)
        #expect(device.id == "GPU-aaaa")
        #expect(device.nodeName == nil)
        #expect(device.powerDrawWatts == nil)
        #expect(device.powerLimitWatts == nil)
        #expect(device.memoryUsedMiB == 1024)
    }

    @Test("Node-tagged GPU rows reject unsafe nodes and malformed CSV")
    func malformedNodeGPUMetrics() throws {
        for row in [
            ",0,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu 01,0,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu/01,0,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu[01-02],0,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu;whoami,0,GPU-aaaa,A800,80,1024,81920,200,400",
            "-gpu01,0,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu01,-1,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu01,N/A,GPU-aaaa,A800,80,1024,81920,200,400",
            "gpu01,0,GPU-aaaa,A800,80,1024,81920,200",
            "gpu01,0,GPU-aaaa,A800,80,1024,81920,200,400,extra",
            "\(String(repeating: "g", count: 256)),0,GPU-aaaa,A800,80,1024,81920,200,400",
        ] {
            #expect(throws: SlurmMonitoringParserError.malformedRow(section: "gpu", line: 1)) {
                try SlurmMonitoringParser.gpuUsage(row)
            }
        }
    }

    @Test("monitoring rejects ambiguous rows, duplicate identities, and schema changes")
    func rejectsAmbiguousTelemetry() throws {
        #expect(throws: SlurmMonitoringParserError.duplicateIdentifier("gpu01")) {
            try queues(node("gpu01") + "\n" + node("gpu01"))
        }
        #expect(throws: SlurmMonitoringParserError.duplicateIdentifier("a800")) {
            try queues(node("gpu01"), partitions: "PartitionName=a800 State=UP\nPartitionName=a800 State=UP")
        }
        #expect(throws: SlurmMonitoringParserError.duplicateIdentifier("1042")) {
            try SlurmMonitoringParser.allocations("JobId=1042 UserId=zli760(1) JobState=RUNNING\nJobId=1042 UserId=zli760(1) JobState=RUNNING")
        }
        #expect(throws: SlurmMonitoringParserError.duplicateIdentifier("1042.batch")) {
            try SlurmMonitoringParser.statistics("1042.batch|||||||\n1042.batch|||||||", allocations: [:])
        }
        #expect(throws: SlurmMonitoringParserError.duplicateIdentifier("GPU-aaa")) {
            try SlurmMonitoringParser.gpuUsage("0,GPU-aaa,A800,0,0,81920\n1,GPU-aaa,A800,0,0,81920")
        }
        #expect(throws: SlurmMonitoringParserError.malformedRow(section: "statistics", line: 1)) {
            try SlurmMonitoringParser.statistics("1042.batch|1|00:00:10", allocations: [:])
        }
        #expect(throws: SlurmMonitoringParserError.malformedRow(section: "gpu", line: 1)) {
            try SlurmMonitoringParser.gpuUsage("0,GPU-aaa,A800,0,0")
        }
    }

    private func queues(
        _ nodes: String,
        partitions: String = "PartitionName=a800 State=UP",
        queue: String? = ""
    ) throws -> [SlurmQueueSnapshot] {
        try SlurmMonitoringParser.queues(nodes: nodes, partitions: partitions, queue: queue, sampledAt: sampledAt)
    }

    private func node(_ name: String, state: String = "IDLE", partitions: String = "a800", allocated: Int = 0) -> String {
        "NodeName=\(name) CPUTot=128 CPUAlloc=0 RealMemory=1048576 AllocMem=0 State=\(state) Partitions=\(partitions) CfgTRES=cpu=128,mem=1T,gres/gpu=8 AllocTRES=cpu=0,mem=0,gres/gpu=\(allocated)"
    }

    private func jobID(_ value: String) -> SlurmJobID {
        SlurmJobID(rawValue: value)!
    }
}
