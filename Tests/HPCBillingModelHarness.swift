import Foundation
import Combine
@testable import TmuxHubCore

/// Tests the real platform model against isolated preferences and in-memory
/// Slurm responses. No SSH connection, remote command, or job is created.
@main
struct HPCBillingModelHarness {
    @MainActor
    static func main() async throws {
        try await freshDefaults()
        try await legacyPlaceholderMigratesAndPersists()
        try await customRatesSurviveReload()
        try await explicitZeroRatesRemainZero()
        try await clusterPreferencesStayIsolated()
        try await invalidPreferencesFallBackSafely()
        try await currentAndHistoricalCostsUseTheSavedRates()
        print("HPC billing model: 7 persistence and integration checks passed.")
    }

    @MainActor
    private static func freshDefaults() async throws {
        try await withDefaults { defaults, runner in
            let hpc3 = model(.hpc3, defaults: defaults, runner: runner)
            let hpc4 = model(.hpc4, defaults: defaults, runner: runner)
            try expect(hpc3.costConfiguration == .hkustHPC3, "Fresh HPC3 settings must use its reference rates.")
            try expect(hpc4.costConfiguration == .hkustHPC4, "Fresh HPC4 settings must use its reference rates.")
            try expect([hpc3.costConfiguration.low.otherPerGPUHour,
                        hpc3.costConfiguration.medium.otherPerGPUHour,
                        hpc3.costConfiguration.high.otherPerGPUHour] == [2.4, 3.75, 6],
                       "HPC3 reference prices must match the confirmed source.")
            try expect([hpc4.costConfiguration.low.cpuPerCoreHour,
                        hpc4.costConfiguration.medium.cpuPerCoreHour,
                        hpc4.costConfiguration.high.cpuPerCoreHour] == [0.01, 0.02, 0.03],
                       "HPC4 CPU reference prices must match the confirmed source.")
            try expect([hpc4.costConfiguration.low.npuPerCardHour,
                        hpc4.costConfiguration.medium.npuPerCardHour,
                        hpc4.costConfiguration.high.npuPerCardHour] == [0.84, 1.3, 2.1],
                       "HPC4 NPU reference prices must match the confirmed source.")
            try expect(hpc4.costConfiguration.npuUnitsPerCard == 2,
                       "HPC4 must convert two scheduler NPU units to one physical card.")
            try expect(hpc4.costConfiguration.isPricingAvailable, "HPC4 pricing must be enabled.")
            try expect(await runner.recordedCalls().isEmpty, "Loading settings must not contact a cluster.")
        }
    }

    @MainActor
    private static func legacyPlaceholderMigratesAndPersists() async throws {
        try await withDefaults { defaults, runner in
            let legacy = try legacyPlaceholder()
            try expect(legacy.low.npuPerCardHour == nil, "Legacy fixtures must omit the new NPU price field.")
            defaults.set(legacyPlaceholderData, forKey: key(.hpc4))
            let restored = model(.hpc4, defaults: defaults, runner: runner)
            try expect(restored.costConfiguration == .hkustHPC4,
                       "The exact old HPC4 zero placeholder must migrate to reference rates.")
            let migratedData = try require(defaults.data(forKey: key(.hpc4)), "Migration must persist its result.")
            let persisted = try JSONDecoder().decode(SlurmCostConfiguration.self, from: migratedData)
            try expect(persisted == .hkustHPC4 && persisted.low.npuPerCardHour != nil,
                       "Persisted migration must include explicit NPU prices.")
            let second = model(.hpc4, defaults: defaults, runner: runner)
            try expect(second.costConfiguration == restored.costConfiguration,
                       "Repeated restoration must be idempotent.")
            try expect(defaults.data(forKey: key(.hpc4)) == migratedData,
                       "Already migrated settings must not be rewritten on every load.")
            try expect(await runner.recordedCalls().isEmpty, "Migration must not execute remote commands.")
        }
    }

    @MainActor
    private static func customRatesSurviveReload() async throws {
        try await withDefaults { defaults, runner in
            var oldCustom = try legacyPlaceholder()
            oldCustom.medium.cpuPerCoreHour = 0.07
            let originalData = try JSONEncoder().encode(oldCustom)
            defaults.set(originalData, forKey: key(.hpc4))
            let restored = model(.hpc4, defaults: defaults, runner: runner)
            try expect(restored.costConfiguration == oldCustom,
                       "Custom legacy rates must not be replaced merely because NPU pricing is missing.")
            try expect(defaults.data(forKey: key(.hpc4)) == originalData,
                       "Loading custom legacy rates must preserve their saved data.")

            var custom = SlurmCostConfiguration.hkustHPC4
            custom.low.cpuPerCoreHour = 0.123
            custom.medium.npuPerCardHour = 1.75
            try restored.saveCostConfiguration(custom)
            let reloaded = model(.hpc4, defaults: defaults, runner: runner)
            try expect(reloaded.costConfiguration == custom, "Saved CPU and NPU overrides must survive restart.")

            var hpc3Custom = SlurmCostConfiguration.hkustHPC3
            hpc3Custom.high.otherPerGPUHour = 7.25
            let hpc3 = model(.hpc3, defaults: defaults, runner: runner)
            try hpc3.saveCostConfiguration(hpc3Custom)
            try expect(model(.hpc3, defaults: defaults, runner: runner).costConfiguration == hpc3Custom,
                       "HPC3 custom rates must also survive restart.")
        }
    }

    @MainActor
    private static func explicitZeroRatesRemainZero() async throws {
        try await withDefaults { defaults, runner in
            let zero = SlurmCostTierRates(
                cpuPerCoreHour: 0, a800PerGPUHour: 0, otherPerGPUHour: 0, npuPerCardHour: 0
            )
            let explicitZero = SlurmCostConfiguration(low: zero, medium: zero, high: zero, cluster: .hpc4)
            let initial = model(.hpc4, defaults: defaults, runner: runner)
            try initial.saveCostConfiguration(explicitZero)
            let savedData = defaults.data(forKey: key(.hpc4))
            for _ in 0..<2 {
                let restored = model(.hpc4, defaults: defaults, runner: runner)
                try expect(restored.costConfiguration == explicitZero,
                           "Explicit new zero rates must not be mistaken for the legacy placeholder.")
                try expect(restored.costConfiguration.low.npuPerCardHour == 0,
                           "The explicit zero NPU field must survive decoding.")
            }
            try expect(defaults.data(forKey: key(.hpc4)) == savedData,
                       "Restoring intentional zero rates must not alter preferences.")
        }
    }

    @MainActor
    private static func clusterPreferencesStayIsolated() async throws {
        try await withDefaults { defaults, runner in
            var hpc2Custom = SlurmCostConfiguration.hkustHPC2
            hpc2Custom.low.a800PerGPUHour = 1.75
            var hpc3Custom = SlurmCostConfiguration.hkustHPC3
            hpc3Custom.medium.otherPerGPUHour = 4.25
            let hpc2Data = try JSONEncoder().encode(hpc2Custom)
            let hpc3Data = try JSONEncoder().encode(hpc3Custom)
            defaults.set(hpc2Data, forKey: key(.hpc2))
            defaults.set(hpc3Data, forKey: key(.hpc3))
            defaults.set(legacyPlaceholderData, forKey: key(.hpc4))
            _ = model(.hpc4, defaults: defaults, runner: runner)
            try expect(defaults.data(forKey: key(.hpc2)) == hpc2Data
                       && defaults.data(forKey: key(.hpc3)) == hpc3Data,
                       "HPC4 migration must not modify HPC2 or HPC3 settings.")
            let hpc4Data = defaults.data(forKey: key(.hpc4))
            let hpc3 = model(.hpc3, defaults: defaults, runner: runner)
            hpc3Custom.low.otherPerGPUHour = 2.65
            try hpc3.saveCostConfiguration(hpc3Custom)
            try expect(defaults.data(forKey: key(.hpc2)) == hpc2Data
                       && defaults.data(forKey: key(.hpc4)) == hpc4Data,
                       "Saving HPC3 prices must not modify another cluster.")
            try expect(model(.hpc2, defaults: defaults, runner: runner).costConfiguration == hpc2Custom,
                       "Legacy HPC2 settings without a cluster field must retain HPC2 behavior.")
        }
    }

    @MainActor
    private static func invalidPreferencesFallBackSafely() async throws {
        try await withDefaults { defaults, runner in
            for cluster in [HKUSTSlurmCluster.hpc3, .hpc4] {
                var negative = cluster.defaultCostConfiguration
                negative.low.cpuPerCoreHour = -1
                let invalidData = [
                    Data("not JSON".utf8),
                    Data("{}".utf8),
                    try JSONEncoder().encode(negative),
                    try JSONEncoder().encode(SlurmCostConfiguration.hkustHPC2),
                ]
                for data in invalidData {
                    defaults.set(data, forKey: key(cluster))
                    let restored = model(cluster, defaults: defaults, runner: runner)
                    try expect(restored.costConfiguration == cluster.defaultCostConfiguration,
                               "Malformed, invalid, or wrong-cluster rates must fall back to this cluster's defaults.")
                }
                let restored = model(cluster, defaults: defaults, runner: runner)
                do {
                    try restored.saveCostConfiguration(negative)
                    throw BillingHarnessFailure.failed("Saving invalid rates must fail.")
                } catch HPC2ConfigurationError.invalidCostRates {}
                try expect(restored.costConfiguration == cluster.defaultCostConfiguration,
                           "Rejected changes must not replace the working configuration.")
            }
            try expect(await runner.recordedCalls().isEmpty, "Validating preferences must not contact a cluster.")
        }
    }

    @MainActor
    private static func currentAndHistoricalCostsUseTheSavedRates() async throws {
        try await withDefaults { defaults, runner in
            let platform = model(.hpc4, defaults: defaults, runner: runner)
            await platform.refresh(force: true)
            let active = try require(platform.jobs.first, "The fake current job must load.")
            let current = try require(platform.costEstimate(for: active), "The current CPU-only allocation must be priced.")
            let finished = try require(
                try SlurmParser.queue(BillingHarnessRunner.queueRow(state: "COMPLETED")).first,
                "The fake historical job must parse."
            )
            let history = SlurmJobHistoryRecord(
                snapshot: finished, endTime: "2026-10-21T11:00:00", exitCode: "0:0",
                allocatedResources: BillingHarnessRunner.allocatedResources
            )
            let historical = try require(platform.costEstimate(for: history), "The historical allocation must be priced.")
            try expect(abs(current.amount - 0.32) < 0.000_001,
                       "HPC4 low-priority CPU cost must be 32 cores × one hour × 0.01.")
            try expect(current == historical, "Current and history paths must price the same allocation identically.")
            var custom = platform.costConfiguration
            custom.low.cpuPerCoreHour = 0.125
            try platform.saveCostConfiguration(custom)
            let updatedCurrent = try require(platform.costEstimate(for: active), "Current estimate must remain available.")
            let updatedHistory = try require(platform.costEstimate(for: history), "History estimate must remain available.")
            try expect(updatedCurrent == updatedHistory && abs(updatedCurrent.amount - 4) < 0.000_001,
                       "Saving custom rates must immediately recalculate both paths.")
            let calls = await runner.recordedCalls()
            try expect(!calls.isEmpty && calls.allSatisfy { !$0.contains("nvidia-smi") && !$0.contains("scancel") },
                       "The integration fixture must never request GPU sampling or job cancellation.")
        }
    }

    private static let legacyPlaceholderData = Data(#"""
    {"cluster":"hpc4",
     "low":{"cpuPerCoreHour":0,"a800PerGPUHour":0,"otherPerGPUHour":0},
     "medium":{"cpuPerCoreHour":0,"a800PerGPUHour":0,"otherPerGPUHour":0},
     "high":{"cpuPerCoreHour":0,"a800PerGPUHour":0,"otherPerGPUHour":0}}
    """#.utf8)

    private static func legacyPlaceholder() throws -> SlurmCostConfiguration {
        try JSONDecoder().decode(SlurmCostConfiguration.self, from: legacyPlaceholderData)
    }

    private static func key(_ cluster: HKUSTSlurmCluster) -> String {
        "\(cluster.storagePrefix)-cost-configuration-v1"
    }

    @MainActor
    private static func model(
        _ cluster: HKUSTSlurmCluster, defaults: UserDefaults, runner: BillingHarnessRunner
    ) -> HPC2PlatformModel {
        HPC2PlatformModel(service: SlurmService(remoteRunner: runner), cluster: cluster, defaults: defaults)
    }

    @MainActor
    private static func withDefaults(
        _ body: @MainActor (UserDefaults, BillingHarnessRunner) async throws -> Void
    ) async throws {
        let suite = "tmuxhub-hpc-billing-harness-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "Cannot create isolated preferences.")
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults, BillingHarnessRunner())
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw BillingHarnessFailure.failed(message) }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw BillingHarnessFailure.failed(message) }
    }
}

private enum BillingHarnessFailure: Error {
    case failed(String)
    case unexpectedCommand
}

private actor BillingHarnessRunner: SlurmRemoteCommandRunning {
    static let allocatedResources = "cpu=32,mem=64000M,node=2"
    private var commands: [String] = []

    static func queueRow(state: String = "RUNNING") -> String {
        ["42", "billing-fixture", "zli760", state, "cpu[01-02]", "a128m512u", "2",
         "01:00:00", "1-00:00:00", "2026-10-21T10:00:00", "2026-10-21T09:59:00",
         "cpu[01-02]", ""].joined(separator: SlurmCommands.fieldDelimiter) + "\n"
    }

    func run(_ command: CommandSpec, alias: String, replay: SSHReplayPolicy) async throws -> InventoryProcessOutput {
        guard alias == "hpc4", case .readOnly = replay else { throw BillingHarnessFailure.unexpectedCommand }
        let remote = command.arguments.last ?? ""
        commands.append(remote)
        let output: String
        if remote.contains(SlurmCommands.monitoringAllocationsMarker) {
            output = """
            @@TMUXHUB_ALLOCATIONS@@
            JobId=42 UserId=zli760(10001) JobState=RUNNING NumCPUs=32 NodeList=cpu[01-02] RunTime=01:00:00 AllocTRES=\(Self.allocatedResources)
            @@TMUXHUB_STATISTICS@@
            @@TMUXHUB_UNAVAILABLE@@
            @@TMUXHUB_END@@

            """
        } else if remote.contains(SlurmCommands.monitoringNodesMarker) {
            output = """
            @@TMUXHUB_NODES@@
            NodeName=cpu01 Partitions=a128m512u State=MIXED CPUTot=128 CPUAlloc=32 RealMemory=512000 AllocMem=64000 CfgTRES=cpu=128,mem=512000M AllocTRES=cpu=32,mem=64000M
            @@TMUXHUB_PARTITIONS@@
            PartitionName=a128m512u State=UP Nodes=cpu01
            @@TMUXHUB_QUEUE@@
            a128m512u|RUNNING
            @@TMUXHUB_END@@

            """
        } else if remote.contains("squeue") {
            output = Self.queueRow()
        } else {
            throw BillingHarnessFailure.unexpectedCommand
        }
        return InventoryProcessOutput(stdout: output, stderr: "", exitCode: 0)
    }

    func recordedCalls() -> [String] { commands }
}
