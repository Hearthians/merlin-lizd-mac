import Testing
@testable import MerlinLizdCore

@Suite("Worker metrics")
struct WorkerMetricsTests {
    @Test("parses CPU, memory, and multiple GPU readings amid transport noise")
    func parsesCompleteSample() throws {
        let sample = try WorkerMetricsParser.parse(
            """
            Logging into worker\r
            __MERLIN_LIZD_METRICS_V1_BEGIN__\r
            __MERLIN_LIZD_METRICS_CPU_BEFORE__\r
            cpu  100 0 50 800 50 0 0 0 20 0\r
            __MERLIN_LIZD_METRICS_CPU_AFTER__\r
            cpu  140 0 70 860 50 0 0 0 25 0\r
            __MERLIN_LIZD_METRICS_MEMORY__\r
            MemTotal:       1000000 kB\r
            MemFree:         100000 kB\r
            MemAvailable:    250000 kB\r
            Buffers:          10000 kB\r
            Cached:          100000 kB\r
            __MERLIN_LIZD_METRICS_GPU__\r
            0, 80, 1024, 8192, 70, 250.5, 350\r
            1, N/A, 2048, 8192, 72, N/A, 350\r
            __MERLIN_LIZD_METRICS_V1_END__\r
            Connection closed.\r
            """,
            timestamp: .distantPast
        )

        #expect(sample.timestamp == .distantPast)
        #expect(sample.cpuUtilization == 50)
        #expect(sample.memoryUsedBytes == 768_000_000)
        #expect(sample.memoryTotalBytes == 1_024_000_000)
        #expect(sample.memoryUtilization == 75)
        #expect(sample.gpus.map(\.index) == [0, 1])
        #expect(sample.gpus[0].utilization == 80)
        #expect(sample.gpus[1].utilization == nil)
        #expect(sample.gpuUtilization == 80)
        #expect(sample.gpuMemoryUsedBytes == 3_221_225_472)
        #expect(sample.gpuMemoryTotalBytes == 17_179_869_184)
        #expect(sample.gpuTemperatureCelsius == 72)
        #expect(sample.gpuPowerWatts == nil)
        #expect(sample.gpuPowerLimitWatts == 700)
    }

    @Test("uses the Linux memory fallback when MemAvailable is unavailable")
    func parsesLegacyMemoryCounters() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal:       1000 kB
            MemFree:         100 kB
            Buffers:          50 kB
            Cached:          200 kB
            SReclaimable:     25 kB
            Shmem:            10 kB
            __MERLIN_LIZD_METRICS_GPU__
            __MERLIN_LIZD_METRICS_V1_END__
            """)

        #expect(sample.memoryTotalBytes == 1_024_000)
        #expect(sample.memoryUsedBytes == 650_240)
        #expect(sample.memoryUtilization == 63.5)
    }

    @Test("prefers cgroup v1 CPU quota and memory limits over host proc values")
    func prefersCgroupV1Metrics() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_UPTIME_BEFORE__
            100.00 500.00
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_BEFORE__
            10000000000
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_BEFORE__
            usage_usec 1000000
            __MERLIN_LIZD_METRICS_CPU_BEFORE__
            cpu 100 0 50 800 50
            __MERLIN_LIZD_METRICS_UPTIME_AFTER__
            100.20 500.10
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_AFTER__
            10320000000
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_AFTER__
            usage_usec 1000000
            __MERLIN_LIZD_METRICS_CPU_AFTER__
            cpu 140 0 70 860 50
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_QUOTA__
            1600000
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_PERIOD__
            100000
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_MAX__
            200000 100000
            __MERLIN_LIZD_METRICS_CGROUP_V1_MEMORY_USAGE__
            50
            __MERLIN_LIZD_METRICS_CGROUP_V1_MEMORY_LIMIT__
            200
            __MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_USAGE__
            1
            __MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_LIMIT__
            100
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 1000 kB
            MemAvailable: 250 kB
            __MERLIN_LIZD_METRICS_GPU__
            __MERLIN_LIZD_METRICS_V1_END__
            """)

        #expect(abs(try #require(sample.cpuUtilization) - 10) < 0.001)
        #expect(sample.memoryUsedBytes == 50)
        #expect(sample.memoryTotalBytes == 200)
        #expect(sample.memoryUtilization == 25)
    }

    @Test("parses unified cgroup v2 CPU and memory metrics")
    func parsesCgroupV2Metrics() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_UPTIME_BEFORE__
            200.00 1000.00
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_BEFORE__
            usage_usec 1000000
            user_usec 800000
            __MERLIN_LIZD_METRICS_UPTIME_AFTER__
            200.25 1000.10
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_AFTER__
            usage_usec 1500000
            user_usec 1200000
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_MAX__
            200000 100000
            __MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_USAGE__
            300
            __MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_LIMIT__
            1000
            __MERLIN_LIZD_METRICS_GPU__
            __MERLIN_LIZD_METRICS_V1_END__
            """)

        #expect(sample.cpuUtilization == 100)
        #expect(sample.memoryUsedBytes == 300)
        #expect(sample.memoryTotalBytes == 1_000)
        #expect(sample.memoryUtilization == 30)
    }

    @Test("falls back to proc when cgroup quota and limits are unlimited")
    func fallsBackFromUnlimitedCgroups() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_UPTIME_BEFORE__
            300.0 1000.0
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_BEFORE__
            1000
            __MERLIN_LIZD_METRICS_CPU_BEFORE__
            cpu 100 0 50 800 50
            __MERLIN_LIZD_METRICS_UPTIME_AFTER__
            300.2 1000.1
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_AFTER__
            9999999
            __MERLIN_LIZD_METRICS_CPU_AFTER__
            cpu 140 0 70 860 50
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_QUOTA__
            -1
            __MERLIN_LIZD_METRICS_CGROUP_V1_CPU_PERIOD__
            100000
            __MERLIN_LIZD_METRICS_CGROUP_V2_CPU_MAX__
            max 100000
            __MERLIN_LIZD_METRICS_CGROUP_V1_MEMORY_USAGE__
            50
            __MERLIN_LIZD_METRICS_CGROUP_V1_MEMORY_LIMIT__
            9223372036854771712
            __MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_USAGE__
            10
            __MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_LIMIT__
            max
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 1000 kB
            MemAvailable: 250 kB
            __MERLIN_LIZD_METRICS_GPU__
            __MERLIN_LIZD_METRICS_V1_END__
            """)

        #expect(sample.cpuUtilization == 50)
        #expect(sample.memoryTotalBytes == 1_024_000)
        #expect(sample.memoryUsedBytes == 768_000)
        #expect(sample.memoryUtilization == 75)
    }

    @Test("keeps supported fields when nvidia-smi reports unavailable values")
    func toleratesPartialGPUFields() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_CPU_BEFORE__
            cpu 10 0 10 80 0
            __MERLIN_LIZD_METRICS_CPU_AFTER__
            cpu 20 0 20 160 0
            __MERLIN_LIZD_METRICS_MEMORY__
            not memory
            __MERLIN_LIZD_METRICS_GPU__
            persistence mode is enabled
            0, 101, N/A, 4096, N/A, [Not Supported], 300.0
            malformed,row
            __MERLIN_LIZD_METRICS_V1_END__
            """)

        #expect(sample.cpuUtilization == 20)
        #expect(sample.memoryTotalBytes == nil)
        #expect(sample.gpus.count == 1)
        #expect(sample.gpus[0].utilization == nil)
        #expect(sample.gpus[0].memoryUsedBytes == nil)
        #expect(sample.gpus[0].memoryTotalBytes == 4_294_967_296)
        #expect(sample.gpus[0].powerWatts == nil)
        #expect(sample.gpus[0].powerLimitWatts == 300)
    }

    @Test("does not shift malformed CPU counters or overflow byte conversion")
    func rejectsMalformedNumericFields() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_CPU_BEFORE__
            cpu 10 invalid 10 80 0 0 0 0
            __MERLIN_LIZD_METRICS_CPU_AFTER__
            cpu 20 0 20 160 0 0 0 0
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 100 kB
            MemAvailable: 20 kB
            __MERLIN_LIZD_METRICS_GPU__
            0, 10, 18446744073709551616, 18446744073709551616, 40, 50, 100
            __MERLIN_LIZD_METRICS_V1_END__
            """)

        #expect(sample.cpuUtilization == nil)
        #expect(sample.memoryUtilization == 80)
        #expect(sample.gpus[0].memoryUsedBytes == nil)
        #expect(sample.gpus[0].memoryTotalBytes == nil)
    }

    @Test("rejects missing, incomplete, and empty envelopes")
    func rejectsInvalidEnvelopes() {
        #expect(throws: WorkerMetricsParseError.missingEnvelope) {
            try WorkerMetricsParser.parse("cpu 1 2 3 4 5")
        }
        #expect(throws: WorkerMetricsParseError.incompleteEnvelope) {
            try WorkerMetricsParser.parse("""
                __MERLIN_LIZD_METRICS_V1_BEGIN__
                __MERLIN_LIZD_METRICS_MEMORY__
                MemTotal: 100 kB
                """)
        }
        #expect(throws: WorkerMetricsParseError.noMetrics) {
            try WorkerMetricsParser.parse("""
                __MERLIN_LIZD_METRICS_V1_BEGIN__
                __MERLIN_LIZD_METRICS_GPU__
                diagnostic text only
                __MERLIN_LIZD_METRICS_V1_END__
                """)
        }
    }

    @Test("returns the last complete sample and ignores a trailing partial envelope")
    func parsesLastCompleteEnvelope() throws {
        let sample = try WorkerMetricsParser.parse("""
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 100 kB
            MemAvailable: 40 kB
            __MERLIN_LIZD_METRICS_V1_END__
            __MERLIN_LIZD_METRICS_V1_BEGIN__
            __MERLIN_LIZD_METRICS_MEMORY__
            MemTotal: 200 kB
            """)

        #expect(sample.memoryTotalBytes == 102_400)
        #expect(sample.memoryUsedBytes == 61_440)
    }

    @Test("sampler routes the safe command and timestamps parsed output")
    func samplerExecutesSafeCommand() async throws {
        let runner = MetricsScriptedRunner(output: InventoryProcessOutput(
            stdout: """
                __MERLIN_LIZD_METRICS_V1_BEGIN__
                __MERLIN_LIZD_METRICS_MEMORY__
                MemTotal: 100 kB
                MemAvailable: 25 kB
                __MERLIN_LIZD_METRICS_V1_END__
                """,
            stderr: "",
            exitCode: 0
        ))
        let sampler = WorkerMetricsSampler(
            processRunner: runner,
            now: { .distantFuture }
        )
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )

        let sample = try await sampler.sample(target: target)

        #expect(sample.timestamp == .distantFuture)
        #expect(sample.memoryUtilization == 75)
        let command = await runner.recordedCommand()
        #expect(command?.executable == "/usr/bin/ssh")
        #expect(command?.arguments.contains("hl_gpu_2") == true)
        #expect(command?.arguments.last?.contains("worker login 3966762") == true)
    }

    @Test("sampler distinguishes an unready Worker from a command failure")
    func samplerReportsTransportFailures() async {
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "3966762"
        )
        let notReady = WorkerMetricsSampler(processRunner: MetricsScriptedRunner(
            output: InventoryProcessOutput(
                stdout: "",
                stderr: "worker has not been ready yet",
                exitCode: 1
            )
        ))
        await #expect(throws: WorkerMetricsSamplingError.workerNotReady) {
            try await notReady.sample(target: target)
        }

        let failed = WorkerMetricsSampler(processRunner: MetricsScriptedRunner(
            output: InventoryProcessOutput(stdout: "", stderr: "lost", exitCode: 255)
        ))
        await #expect(throws: WorkerMetricsSamplingError.commandFailed(exitCode: 255)) {
            try await failed.sample(target: target)
        }
    }
}

private actor MetricsScriptedRunner: InventoryProcessRunning {
    let output: InventoryProcessOutput
    private var command: CommandSpec?

    init(output: InventoryProcessOutput) {
        self.output = output
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        self.command = command
        return output
    }

    func recordedCommand() -> CommandSpec? {
        command
    }
}
