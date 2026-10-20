import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Slurm cluster isolation")
struct SlurmClusterTests {
    @Test("cluster profiles route queries to independent destinations and owners")
    func queryRouting() throws {
        #expect(Set(HKUSTSlurmCluster.allCases.map(\.id)).count == 3)
        #expect(Set(HKUSTSlurmCluster.allCases.map(\.storagePrefix)).count == 3)
        for cluster in HKUSTSlurmCluster.allCases {
            let profile = cluster.defaultProfile(owner: "researcher")
            let command = try SlurmCommands.listJobs(platform: profile)
            #expect(command.arguments.contains(cluster.sshDestination))
            #expect(command.arguments.last?.contains("researcher") == true)
            let history = try SlurmCommands.jobHistory(platform: profile, range: .week)
            #expect(history.arguments.contains(cluster.sshDestination))
            #expect(history.arguments.last?.contains("researcher") == true)
            for other in HKUSTSlurmCluster.allCases where other != cluster {
                #expect(!command.arguments.contains(other.sshDestination))
                #expect(!history.arguments.contains(other.sshDestination))
            }
        }
    }

    @Test("legacy HPC2 profile and GPU preset remain compatible")
    func legacySettings() throws {
        let profileJSON = Data(#"{"id":"hkust-hpc2","name":"My HPC2","loginDestination":"custom-hpc2","owner":"researcher"}"#.utf8)
        let profile = try JSONDecoder().decode(SlurmPlatformProfile.self, from: profileJSON)
        #expect(profile.name == "My HPC2")
        #expect(profile.loginDestination == "custom-hpc2")
        #expect(profile.owner == "researcher")
        #expect(HKUSTSlurmCluster.hpc2.storagePrefix == "hpc2")
        let gpu = try JSONDecoder().decode(
            SlurmGPURequest.self, from: Data(#"{"type":"a800","count":4}"#.utf8)
        )
        #expect(gpu.resource == nil)
        #expect(gpu.gresResource == .gpu)
        #expect(gpu.gresValue == "gpu:a800:4")
        #expect(gpu == SlurmGPURequest(type: "a800", count: 4))
    }

    @Test("new cluster presets use debug limits and HPC4 does not request NVIDIA GPUs")
    func defaultPresets() throws {
        for cluster in HKUSTSlurmCluster.allCases {
            let preset = cluster.defaultPreset
            #expect(preset.partition == "debug")
            #expect(preset.wallTime.seconds == 1_800)
            #expect(preset.cpusPerTask == 4)
            #expect(preset.memoryMiB == 16_384)
            #expect(preset.id == "\(cluster.storagePrefix)-default")
            try SlurmCommands.validate(preset)
            if cluster == .hpc4 {
                #expect(preset.gpu == nil)
            } else {
                #expect(preset.gpu?.gresValue == "gpu:1")
            }
        }
        #expect(HKUSTSlurmCluster.hpc3.preferredPartitions.contains("acd_u"))
        #expect(HKUSTSlurmCluster.hpc4.preferredPartitions.contains("a320m2tn910cu"))
    }

    @Test("launch receipts cannot be reused on a different cluster even with matching user")
    func receiptIsolation() throws {
        for cluster in HKUSTSlurmCluster.allCases {
            let profile = cluster.defaultProfile(owner: "researcher")
            let receipt = try SlurmCommands.launchReceipt(platform: profile)
            try SlurmCommands.validate(receipt, for: profile)
            for other in HKUSTSlurmCluster.allCases where other != cluster {
                #expect(throws: SlurmCommandError.invalidReceipt) {
                    try SlurmCommands.startInteractive(
                        platform: other.defaultProfile(owner: "researcher"),
                        preset: other.defaultPreset,
                        receipt: receipt
                    )
                }
            }
        }
    }

    @Test("NPU requests round-trip distinctly and use the scheduler NPU GRES")
    func npuRequest() throws {
        let npu = SlurmGPURequest(type: "910c", count: 2, resource: .npu)
        #expect(npu.gresResource == .npu)
        #expect(npu.gresValue == "npu:910c:2")
        #expect(try JSONDecoder().decode(
            SlurmGPURequest.self, from: JSONEncoder().encode(npu)
        ) == npu)
        let platform = HKUSTSlurmCluster.hpc4.defaultProfile()
        let preset = SlurmInteractivePreset(
            id: "hpc4-npu", name: "NPU", partition: "a320m2tn910cu",
            cpusPerTask: 4, memoryMiB: 16_384,
            wallTime: SlurmWallTime(seconds: 1_800), gpu: npu
        )
        let command = try SlurmCommands.startInteractive(
            platform: platform, preset: preset,
            receipt: SlurmCommands.launchReceipt(platform: platform)
        )
        #expect(command.arguments.last?.contains("npu:910c:2") == true)
        #expect(command.arguments.last?.contains("gpu:910c:2") == false)
    }

    @Test("old saved rates retain HPC2 behavior and new cluster policies persist")
    func costPolicyCompatibility() throws {
        let legacy = """
        {"low":{"cpuPerCoreHour":0.02,"a800PerGPUHour":1.6,"otherPerGPUHour":0.5},
         "medium":{"cpuPerCoreHour":0.04,"a800PerGPUHour":2.5,"otherPerGPUHour":1},
         "high":{"cpuPerCoreHour":0.06,"a800PerGPUHour":4,"otherPerGPUHour":1.5}}
        """
        let decoded = try JSONDecoder().decode(SlurmCostConfiguration.self, from: Data(legacy.utf8))
        #expect(decoded.cluster == nil)
        #expect(decoded.effectiveCluster == .hpc2)
        #expect(abs(try #require(SlurmCostEstimator.estimate(
            partition: "i64m1tga800u", allocatedCPU: 32, allocatedGPU: 4,
            elapsedSeconds: 3_600, configuration: decoded
        )).amount - 7.04) < 0.000_001)
        for cluster in HKUSTSlurmCluster.allCases {
            let restored = try JSONDecoder().decode(
                SlurmCostConfiguration.self,
                from: JSONEncoder().encode(cluster.defaultCostConfiguration)
            )
            #expect(restored.effectiveCluster == cluster)
        }
    }

    @Test("phase III prices only confirmed ACD queues and does not inherit HPC2 prices")
    func acdBilling() throws {
        for (partition, hourly) in [("acd_u", 2.4), ("acd_ue", 3.75), ("emergency_acd", 6.0)] {
            for resources in ["cpu=64,gres/gpu=2", "cpu=64,gres/gpu=2,gres/gpu:acd=2"] {
                let estimate = try #require(SlurmCostEstimator.estimate(
                    partition: partition, allocatedCPU: 64, allocatedGPU: 2,
                    elapsedSeconds: 1_800, configuration: .hkustHPC3,
                    allocatedResources: resources
                ))
                #expect(abs(estimate.amount - hourly) < 0.000_001)
                #expect(estimate.cpuAmount == 0)
                #expect(estimate.hourlyCost == hourly * 2)
            }
            #expect(SlurmCostEstimator.estimate(
                partition: partition, allocatedCPU: 64, allocatedGPU: 2,
                elapsedSeconds: 1_800, configuration: .hkustHPC2
            ) == nil)
        }
        for partition in ["i64m1tga800u", "gpu", "emergency_gpu", "debug", "a128m512u"] {
            #expect(SlurmCostEstimator.estimate(
                partition: partition, allocatedCPU: 64, allocatedGPU: 2,
                elapsedSeconds: 1_800, configuration: .hkustHPC3
            ) == nil)
        }
        for resources in [
            "cpu=64,gres/gpu=2,gres/gpu:a800=2",
            "cpu=64,gres/gpu=2,gres/gpu:unknown=2",
            "cpu=64,gres/gpu=2,gres/gpu:acd_1g.10gb=2",
            "cpu=64,gres/gpu=2,gres/mig=2",
        ] {
            #expect(SlurmCostEstimator.estimate(
                partition: "acd_u", allocatedCPU: 64, allocatedGPU: 2,
                elapsedSeconds: 1_800, configuration: .hkustHPC3,
                allocatedResources: resources
            ) == nil)
        }
    }

    @Test("unpriced phase IV and NPU allocations never appear free or CPU-only priced")
    func unpricedAccelerators() {
        #expect(!SlurmCostConfiguration.hkustHPC4.isPricingAvailable)
        for partition in ["debug", "a128m512u", "a128m512ue", "emergency", "a320m2tn910cu"] {
            #expect(SlurmCostEstimator.estimate(
                partition: partition, allocatedCPU: 32, allocatedGPU: 0,
                elapsedSeconds: 3_600, configuration: .hkustHPC4
            ) == nil)
        }
        for resources in ["cpu=32,gres/npu=2", "cpu=32,gres/npu:910c=2"] {
            for partition in ["normal", "debug", "a128m512u"] {
                #expect(SlurmCostEstimator.estimate(
                    partition: partition, allocatedCPU: 32, allocatedGPU: 0,
                    elapsedSeconds: 3_600, configuration: .hkustHPC2,
                    allocatedResources: resources
                ) == nil)
            }
        }
    }
}
