import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm monitoring collection")
struct SlurmMonitoringCollectionTests {
    private let platform = SlurmPlatformProfile(
        id: "hkust-hpc2", name: "HKUST HPC2", loginDestination: "hpc2", owner: "zli760"
    )

    @Test("the queue envelope rejects truncation and preserves unavailable queue counts")
    func queueEnvelope() async throws {
        let runner = MonitoringFixtureRunner(queue: """
            @@TMUXHUB_NODES@@
            NodeName=gpu1 Partitions=a800 State=IDLE CPUTot=64 CPUAlloc=0 RealMemory=1024 AllocMem=0 CfgTRES=cpu=64,mem=1024M,gres/gpu=8 AllocTRES=
            @@TMUXHUB_PARTITIONS@@
            PartitionName=a800 State=UP Nodes=gpu1
            @@TMUXHUB_QUEUE@@
            @@TMUXHUB_UNAVAILABLE@@
            @@TMUXHUB_END@@
            """)
        let service = SlurmService(remoteRunner: runner)
        let queues = try await service.queueResources(on: platform)
        #expect(queues.first?.totalGPU == 8)
        #expect(queues.first?.pendingJobCount == nil)
        #expect(await runner.policies() == ["readOnly"])

        let truncated = SlurmService(remoteRunner: MonitoringFixtureRunner(
            queue: "@@TMUXHUB_NODES@@\nNodeName=gpu1\n"
        ))
        await #expect(throws: SlurmServiceError.invalidMonitoringResponse) {
            try await truncated.queueResources(on: platform)
        }
    }

    @Test("GPU monitoring is never replayed and is capped at three own single-node jobs")
    func boundedOwnJobs() async throws {
        let own = try (1...4).map { try job(String($0)) }
        let runner = MonitoringFixtureRunner(allocations: (1...4).map {
            allocation(String($0))
        }.joined(separator: "\n"))
        let service = SlurmService(remoteRunner: runner)
        let result = try await service.jobUtilization(
            on: platform,
            jobs: own + [
                try job("5", owner: "someone-else"),
                try job("6", state: "PENDING"),
            ]
        )
        let policies = await runner.policies()
        #expect(policies.filter { $0 == "readOnly" }.count == 1)
        #expect(policies.filter { $0 == "never" }.count == 3)
        #expect(result[own[0].jobID]?.gpus?.count == 1)
        #expect(result[own[3].jobID]?.gpus == nil)
        #expect(result[own[3].jobID]?.unavailableReason?.contains("3") == true)
        let commands = await runner.commands()
        #expect(commands.allSatisfy { !$0.contains("'sbatch'") && !$0.contains("'scancel'") })
        let accounting = try #require(commands.first)
        #expect(!accounting.contains("'5'"))
        #expect(!accounting.contains("'6'"))
    }

    @Test("multi-node allocations keep accounting without a GPU monitor step")
    func multiNodeAccounting() async throws {
        let snapshot = try job("7", nodes: "2")
        let runner = MonitoringFixtureRunner(
            allocations: allocation("7"),
            statistics: "7.batch|1|00:00:20|100M|256M||||\n"
        )
        let result = try await SlurmService(remoteRunner: runner).jobUtilization(
            on: platform, jobs: [snapshot]
        )
        #expect(await runner.policies() == ["readOnly"])
        #expect(result[snapshot.jobID]?.statistics?.peakTaskMemoryMiB == 256)
        #expect(result[snapshot.jobID]?.gpus == nil)
        #expect(result[snapshot.jobID]?.unavailableReason?.contains("单节点") == true)
    }


    @Test("array identities never suppress ordinary job accounting")
    func unsupportedArrayIdentity() async throws {
        let ordinary = try job("42")
        let array = try job("36_1")
        let runner = MonitoringFixtureRunner(
            allocations: allocation("42"),
            statistics: "42.batch|1|00:00:20|100M|256M||||\n"
        )
        let result = try await SlurmService(remoteRunner: runner).jobUtilization(
            on: platform, jobs: [array, ordinary]
        )
        #expect(result[ordinary.jobID]?.statistics?.peakTaskMemoryMiB == 256)
        #expect(result[ordinary.jobID]?.statistics?.averageCPUPercent != nil)
        #expect(result[ordinary.jobID]?.gpus?.count == 1)
        #expect(result[array.jobID]?.allocation == nil)
        #expect(result[array.jobID]?.statistics == nil)
        #expect(result[array.jobID]?.gpus == nil)
        #expect(result[array.jobID]?.unavailableReason?.contains("数组") == true)
        let commands = await runner.commands()
        #expect(!commands.isEmpty)
        #expect(commands.allSatisfy { !$0.contains("36_1") })
        #expect(await runner.policies() == ["readOnly", "never"])
        #expect(throws: SlurmCommandError.invalidJobIdentity) {
            try SlurmCommands.jobStatistics(
                platform: platform, jobIDs: [ordinary.jobID, array.jobID]
            )
        }
        #expect(throws: SlurmCommandError.invalidJobIdentity) {
            try SlurmCommands.jobGPUUtilization(platform: platform, jobID: array.jobID)
        }
    }

    @Test("remote ownership and state are checked immediately before any monitor step")
    func remoteGuard() async throws {
        let fixture = try MonitoringShellFixture()
        defer { fixture.remove() }
        let command = try SlurmCommands.jobGPUUtilization(
            platform: platform, jobID: #require(SlurmJobID(rawValue: "42"))
        )
        for identity in [
            "42 another-user RUNNING 1", "42 zli760 PENDING 1",
            "43 zli760 RUNNING 1", "42 zli760 RUNNING 1\n42 zli760 RUNNING 1", "",
        ] {
            try fixture.write("identity", contents: identity)
            let output = try await fixture.run(command)
            #expect(output.exitCode == 74)
            #expect(!fixture.exists("srun-called"))
        }
        try fixture.write("identity", contents: "42 zli760 RUNNING 2")
        #expect(try await fixture.run(command).exitCode == 75)
        #expect(!fixture.exists("srun-called"))
    }

    @Test("GPU identifiers expand numeric ranges and fail closed for invalid allocations")
    func scopedGPUIdentifiers() async throws {
        let fixture = try MonitoringShellFixture()
        defer { fixture.remove() }
        let command = try SlurmCommands.jobGPUUtilization(
            platform: platform, jobID: #require(SlurmJobID(rawValue: "42"))
        )
        try fixture.write("identity", contents: " 42 zli760 RUNNING 1 ")
        try fixture.write("cuda-gpus", contents: "0,1,4")
        for ids in ["", "0,", "0,,1", "0;1", "0-9999", "2-1", "0,0", "0-1,1", "0\n1"] {
            try fixture.write("step-gpus", contents: ids)
            let output = try await fixture.run(command)
            #expect(output.exitCode == 78, "\(ids): \(output.stderr)")
            #expect(!fixture.exists("nvidia-arguments"))
        }
        try fixture.write("step-gpus", contents: "0-1,4")
        let output = try await fixture.run(command)
        #expect(output.exitCode == 0, "\(output.stderr)")
        let arguments = try String(
            contentsOf: fixture.directory.appendingPathComponent("nvidia-arguments"),
            encoding: .utf8
        )
        #expect(arguments.contains("--id=0,1,4\n"))
        #expect(try SlurmMonitoringParser.gpuUsage(output.stdout).map(\.index) == [0, 1, 4])
    }

    @Test("GPU monitoring uses the step-local device IDs when Slurm remaps global IDs")
    func remappedGPUIdentifiers() async throws {
        let fixture = try MonitoringShellFixture()
        defer { fixture.remove() }
        let command = try SlurmCommands.jobGPUUtilization(
            platform: platform, jobID: #require(SlurmJobID(rawValue: "42"))
        )
        try fixture.write("identity", contents: "42 zli760 RUNNING 1")
        try fixture.write("step-gpus", contents: "1,2,3,7")
        try fixture.write("cuda-gpus", contents: "0,1,2,3")
        let output = try await fixture.run(command)
        #expect(output.exitCode == 0, "\(output.stderr)")
        let arguments = try String(
            contentsOf: fixture.directory.appendingPathComponent("nvidia-arguments"),
            encoding: .utf8
        )
        #expect(arguments.contains("--id=0,1,2,3\n"))
        #expect(!arguments.contains("--id=1,2,3,7\n"))
        #expect(try SlurmMonitoringParser.gpuUsage(output.stdout).map(\.index) == [0, 1, 2, 3])
    }

    @Test("GPU monitoring preserves device IDs when the step does not remap them")
    func nonRemappedGPUIdentifiers() async throws {
        let fixture = try MonitoringShellFixture()
        defer { fixture.remove() }
        let command = try SlurmCommands.jobGPUUtilization(
            platform: platform, jobID: #require(SlurmJobID(rawValue: "42"))
        )
        try fixture.write("identity", contents: "42 zli760 RUNNING 1")
        try fixture.write("step-gpus", contents: "1,2,3,7")
        try fixture.write("cuda-gpus", contents: "1,2,3,7")
        let output = try await fixture.run(command)
        #expect(output.exitCode == 0, "\(output.stderr)")
        let arguments = try String(
            contentsOf: fixture.directory.appendingPathComponent("nvidia-arguments"),
            encoding: .utf8
        )
        #expect(arguments.contains("--id=1,2,3,7\n"))
        #expect(try SlurmMonitoringParser.gpuUsage(output.stdout).map(\.index) == [1, 2, 3, 7])
    }

    @Test("GPU monitoring accepts explicit step-local GPU UUIDs")
    func visibleGPUUUIDs() async throws {
        let fixture = try MonitoringShellFixture()
        defer { fixture.remove() }
        let command = try SlurmCommands.jobGPUUtilization(
            platform: platform, jobID: #require(SlurmJobID(rawValue: "42"))
        )
        let uuids = [
            "GPU-12345678-1234-1234-1234-123456789abc",
            "GPU-87654321-4321-4321-4321-cba987654321",
        ]
        try fixture.write("identity", contents: "42 zli760 RUNNING 1")
        try fixture.write("step-gpus", contents: "3,7")
        try fixture.write("cuda-gpus", contents: uuids.joined(separator: ","))
        let output = try await fixture.run(command)
        #expect(output.exitCode == 0, "\(output.stderr)")
        let arguments = try String(
            contentsOf: fixture.directory.appendingPathComponent("nvidia-arguments"),
            encoding: .utf8
        )
        #expect(arguments.contains("--id=\(uuids.joined(separator: ","))\n"))
        #expect(try SlurmMonitoringParser.gpuUsage(output.stdout).map(\.uuid) == uuids)
    }

    @Test("Missing or invalid step-local visibility never triggers an unfiltered GPU query")
    func invalidVisibleGPUIdentifiers() async throws {
        let command = try SlurmCommands.jobGPUUtilization(
            platform: platform, jobID: #require(SlurmJobID(rawValue: "42"))
        )
        let malformed: [String?] = [
            nil, "", "0,1,2", "0,1,2,3,4", "0,1,2,2", "0,1,2,", "0,,2,3",
            "0-3", "0;1;2;3", "0,1,2,3\n4", "0,1,2,3\r4", "-1,0,1,2",
            "0,00,1,2", "0,1,2,1024",
            "GPU-,GPU-,GPU-,GPU-", "GPU-not-a-uuid,0,1,2",
        ]
        for ids in malformed {
            let fixture = try MonitoringShellFixture()
            defer { fixture.remove() }
            try fixture.write("identity", contents: "42 zli760 RUNNING 1")
            try fixture.write("step-gpus", contents: "1,2,3,7")
            if let ids { try fixture.write("cuda-gpus", contents: ids) }
            let output = try await fixture.run(command)
            #expect(output.exitCode == 78, "\(ids ?? "<missing>"): \(output.stderr)")
            #expect(!fixture.exists("nvidia-arguments"))
        }
    }

    @Test("An incomplete GPU sample keeps valid readings and explains the allocation mismatch")
    func partialGPUSampleWarning() async throws {
        let snapshot = try job("42")
        let runner = MonitoringFixtureRunner(
            allocations: allocation("42", gpuCount: 4),
            gpuOutput: """
                0, GPU-first, NVIDIA A800, 95, 58000, 81920
                1, GPU-second, NVIDIA A800, 93, 55000, 81920
                2, GPU-third, NVIDIA A800, 94, 52000, 81920

                """
        )
        let result = try await SlurmService(remoteRunner: runner).jobUtilization(
            on: platform, jobs: [snapshot]
        )
        let sample = try #require(result[snapshot.jobID])
        #expect(sample.gpus?.count == 3)
        #expect(sample.gpus?.map(\.index) == [0, 1, 2])
        let warning = try #require(sample.unavailableReason)
        #expect(warning.contains("3"))
        #expect(warning.contains("4"))
    }

    private func job(
        _ id: String, owner: String = "zli760", state: String = "RUNNING",
        nodes: String = "1"
    ) throws -> SlurmJobSnapshot {
        try #require(SlurmParser.queue([
            id, "training", owner, state, "gpu1", "a800", nodes, "00:10:00",
            "01:00:00", "N/A", "N/A", "gpu1", "",
        ].joined(separator: "\u{001F}")).first)
    }

    private func allocation(_ id: String, gpuCount: Int = 1) -> String {
        "JobId=\(id) UserId=zli760(123) JobState=RUNNING NodeList=gpu1 NumCPUs=4 RunTime=00:10:00 AllocTRES=cpu=4,mem=64G,gres/gpu=\(gpuCount)"
    }
}

private actor MonitoringFixtureRunner: SlurmRemoteCommandRunning {
    let queue: String
    let allocations: String
    let statistics: String
    let gpuOutput: String
    private var history: [(command: String, policy: String)] = []

    init(
        queue: String = "", allocations: String = "", statistics: String = "",
        gpuOutput: String = "0, GPU-own, NVIDIA A800, 80, 1024, 81920\n"
    ) {
        self.queue = queue
        self.allocations = allocations
        self.statistics = statistics
        self.gpuOutput = gpuOutput
    }

    func run(
        _ command: CommandSpec, alias: String, replay: SSHReplayPolicy
    ) async throws -> InventoryProcessOutput {
        let remote = command.arguments.last ?? ""
        let policy: String
        switch replay {
        case .readOnly: policy = "readOnly"
        case .never: policy = "never"
        }
        history.append((remote, policy))
        let stdout: String
        if remote.contains("SLURM_STEP_GPUS") {
            stdout = gpuOutput
        } else if remote.contains(SlurmCommands.monitoringAllocationsMarker) {
            stdout = """
                @@TMUXHUB_ALLOCATIONS@@
                \(allocations)
                @@TMUXHUB_STATISTICS@@
                \(statistics)
                @@TMUXHUB_END@@

                """
        } else {
            stdout = queue
        }
        return InventoryProcessOutput(stdout: stdout, stderr: "", exitCode: 0)
    }

    func policies() -> [String] { history.map(\.policy) }
    func commands() -> [String] { history.map(\.command) }
}

private struct MonitoringShellFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmuxhub-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        try write(".bash_profile", contents: """
            export PATH="$TMUXHUB_FIXTURE_ROOT/bin:/usr/bin:/bin"
            """)
        try executable("timeout", script: "shift 3\nexec \"$@\"")
        try executable("squeue", script: "cat \"$TMUXHUB_FIXTURE_ROOT/identity\"")
        try executable("srun", script: """
            touch "$TMUXHUB_FIXTURE_ROOT/srun-called"
            export SLURM_STEP_GPUS=$(cat "$TMUXHUB_FIXTURE_ROOT/step-gpus")
            unset CUDA_VISIBLE_DEVICES
            if [ -f "$TMUXHUB_FIXTURE_ROOT/cuda-gpus" ]; then
                export CUDA_VISIBLE_DEVICES=$(cat "$TMUXHUB_FIXTURE_ROOT/cuda-gpus")
            fi
            while [ "$#" -gt 0 ]; do
                if [ "$1" = /bin/bash ]; then exec "$@"; fi
                shift
            done
            exit 97
            """)
        try executable("nvidia-smi", script: """
            printf '%s\\n' "$@" > "$TMUXHUB_FIXTURE_ROOT/nvidia-arguments"
            ids=
            for argument in "$@"; do
                case "$argument" in --id=*) ids=${argument#--id=} ;; esac
            done
            [ -n "$ids" ] || exit 96
            IFS=,
            local_index=0
            for id in $ids; do
                case "$id" in
                    GPU-*) index=$local_index; uuid=$id ;;
                    *) index=$id; uuid="GPU-fixture-$id" ;;
                esac
                printf '%s\\n' "$index, $uuid, NVIDIA A800, 80, 1024, 81920"
                local_index=$((local_index + 1))
            done
            """)
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        try await TimedInventoryProcessRunner(
            timeout: .seconds(15), underlying: FoundationInventoryProcessRunner()
        ).run(CommandSpec(
            executable: "/bin/sh", arguments: ["-c", try #require(command.arguments.last)],
            environment: [
                "HOME": directory.path, "PATH": "/usr/bin:/bin", "BASH_ENV": "/dev/null",
                "ENV": "/dev/null", "TMUXHUB_FIXTURE_ROOT": directory.path,
                "CUDA_VISIBLE_DEVICES": "0,1,2,3,4,5,6,7",
            ]
        ))
    }

    func write(_ name: String, contents: String) throws {
        try contents.write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private func executable(_ name: String, script: String) throws {
        try write("bin/" + name, contents: "#!/bin/sh\n" + script + "\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.appendingPathComponent("bin/" + name).path
        )
    }
}
