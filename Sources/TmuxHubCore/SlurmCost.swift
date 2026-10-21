import Foundation

public struct SlurmCostTierRates: Codable, Hashable, Sendable {
    public var cpuPerCoreHour: Double
    public var a800PerGPUHour: Double
    public var otherPerGPUHour: Double
    /// Missing from older saved tariffs. An unknown NPU price must not become zero.
    public var npuPerCardHour: Double?

    public init(
        cpuPerCoreHour: Double, a800PerGPUHour: Double, otherPerGPUHour: Double,
        npuPerCardHour: Double? = nil
    ) {
        self.cpuPerCoreHour = cpuPerCoreHour
        self.a800PerGPUHour = a800PerGPUHour
        self.otherPerGPUHour = otherPerGPUHour
        self.npuPerCardHour = npuPerCardHour
    }

    public var isValid: Bool {
        [cpuPerCoreHour, a800PerGPUHour, otherPerGPUHour].allSatisfy { $0.isFinite && $0 >= 0 }
            && (npuPerCardHour.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public struct SlurmCostConfiguration: Codable, Hashable, Sendable {
    public var low: SlurmCostTierRates
    public var medium: SlurmCostTierRates
    public var high: SlurmCostTierRates
    /// Missing in legacy saved configurations, which were always HPC2 tariffs.
    public var cluster: HKUSTSlurmCluster?
    /// Scheduler NPU resource units per physical card. Kept explicit because
    /// 910C cards expose two chips and a cluster may schedule either unit.
    public var npuUnitsPerCard: Double?
    public var effectiveCluster: HKUSTSlurmCluster { cluster ?? .hpc2 }
    public var isPricingAvailable: Bool { true }
    public var currencyCode: String { "CNY" }

    public init(
        low: SlurmCostTierRates,
        medium: SlurmCostTierRates,
        high: SlurmCostTierRates,
        cluster: HKUSTSlurmCluster? = nil,
        npuUnitsPerCard: Double? = nil
    ) {
        self.low = low
        self.medium = medium
        self.high = high
        self.cluster = cluster
        self.npuUnitsPerCard = npuUnitsPerCard
    }

    /// HKUST(GZ) HPC price reference, verified 2026-10-13. GPU prices exclude CPU and storage.
    public static let hkustHPC2 = SlurmCostConfiguration(
        low: .init(cpuPerCoreHour: 0.02, a800PerGPUHour: 1.60, otherPerGPUHour: 0.50),
        medium: .init(cpuPerCoreHour: 0.04, a800PerGPUHour: 2.50, otherPerGPUHour: 1.00),
        high: .init(cpuPerCoreHour: 0.06, a800PerGPUHour: 4.00, otherPerGPUHour: 1.50)
    )

    /// ACD rates from the user-provided HPC price reference (revision 83).
    /// No separate phase III CPU charge is listed; these rates apply only to ACD queues.
    public static let hkustHPC3 = SlurmCostConfiguration(
        low: .init(cpuPerCoreHour: 0, a800PerGPUHour: 0, otherPerGPUHour: 2.40),
        medium: .init(cpuPerCoreHour: 0, a800PerGPUHour: 0, otherPerGPUHour: 3.75),
        high: .init(cpuPerCoreHour: 0, a800PerGPUHour: 0, otherPerGPUHour: 6.00),
        cluster: .hpc3
    )

    /// ARM CPU and 910C rates from the user-provided HPC price reference (revision 83).
    /// The NPU price is per physical card, not per scheduler device or chip.
    /// Official HPC4 hardware has eight 910C cards per NPU node; Slurm reports
    /// sixteen NPU resources. The corresponding factor of two remains configurable.
    public static let hkustHPC4 = SlurmCostConfiguration(
        low: .init(cpuPerCoreHour: 0.01, a800PerGPUHour: 0, otherPerGPUHour: 0, npuPerCardHour: 0.84),
        medium: .init(cpuPerCoreHour: 0.02, a800PerGPUHour: 0, otherPerGPUHour: 0, npuPerCardHour: 1.30),
        high: .init(cpuPerCoreHour: 0.03, a800PerGPUHour: 0, otherPerGPUHour: 0, npuPerCardHour: 2.10),
        cluster: .hpc4,
        npuUnitsPerCard: 2
    )

    /// Replace only the old unpriced HPC4 placeholder. Explicit custom tariffs,
    /// including a new zero-price NPU tariff, must survive application updates.
    public var migratedToCurrentDefaults: SlurmCostConfiguration {
        guard effectiveCluster == .hpc4, npuUnitsPerCard == nil else { return self }
        let tiers: [SlurmCostTierRates] = [low, medium, high]
        for tier in tiers {
            guard tier.cpuPerCoreHour == 0, tier.a800PerGPUHour == 0,
                tier.otherPerGPUHour == 0, tier.npuPerCardHour == nil
            else { return self }
        }
        return .hkustHPC4
    }

    public var isValid: Bool {
        low.isValid && medium.isValid && high.isValid
            && (npuUnitsPerCard.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

public struct SlurmCostEstimate: Hashable, Sendable {
    public let amount: Double
    public let gpuAmount: Double
    public let npuAmount: Double
    public let cpuAmount: Double
    public let hourlyCost: Double
    public let gpuCount: Int
    /// The scheduler's allocated NPU resource units, which need not be physical cards.
    public let npuCount: Int
    public let npuCardCount: Double
    public let cpuCount: Int
    public let elapsedSeconds: TimeInterval
    public let tariffLabel: String
}

public enum SlurmCostEstimator {
    /// Estimates allocated compute time, not utilization or the number of nodes.
    /// Missing resources, unknown partitions and MIG allocations are deliberately not priced.
    public static func estimate(
        partition: String,
        allocatedCPU: Int?,
        allocatedGPU: Int?,
        elapsedSeconds: TimeInterval?,
        configuration: SlurmCostConfiguration = .hkustHPC2,
        allocatedResources: String? = nil,
        allocatedNPU: Int? = nil
    ) -> SlurmCostEstimate? {
        guard configuration.isValid, configuration.isPricingAvailable,
            let elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0,
            allocatedCPU.map({ $0 >= 0 }) ?? true,
            allocatedGPU.map({ $0 >= 0 }) ?? true,
            allocatedNPU.map({ $0 >= 0 }) ?? true,
            let tariff = tariff(for: partition, cluster: configuration.effectiveCluster)
        else { return nil }

        // Preserve the HPC2 debug exception without extending it to unknown NPU resources.
        if tariff.tier == .free {
            guard (allocatedNPU ?? 0) == 0,
                !containsNPUResource(allocatedResources ?? "")
            else { return nil }
            return SlurmCostEstimate(
                amount: 0, gpuAmount: 0, npuAmount: 0, cpuAmount: 0, hourlyCost: 0,
                gpuCount: allocatedGPU ?? 0, npuCount: 0, npuCardCount: 0,
                cpuCount: allocatedCPU ?? 0,
                elapsedSeconds: elapsedSeconds, tariffLabel: "调试队列 · 计算免费"
            )
        }

        var cpuCount = allocatedCPU
        var gpuCount = allocatedGPU
        var npuCount = allocatedNPU ?? (tariff.npu ? nil : 0)
        if let allocatedResources {
            guard let counts = resources(allocatedResources, tariff: tariff),
                cpuCount.map({ $0 == counts.cpu }) ?? true,
                gpuCount.map({ $0 == counts.gpu }) ?? true,
                allocatedNPU.map({ $0 == counts.npu }) ?? true
            else { return nil }
            cpuCount = counts.cpu
            gpuCount = counts.gpu
            npuCount = counts.npu
        }
        guard let cpuCount, let gpuCount, let npuCount,
            tariff.gpu != nil || gpuCount == 0,
            tariff.npu || npuCount == 0
        else { return nil }

        let rates: SlurmCostTierRates
        let label: String
        switch tariff.tier {
        case .low: rates = configuration.low; label = "低优先级"
        case .medium: rates = configuration.medium; label = "中优先级"
        case .high: rates = configuration.high; label = "高优先级"
        case .free: return nil
        }
        let gpuRate = tariff.gpu == .a800 ? rates.a800PerGPUHour : rates.otherPerGPUHour
        let gpuHourly = Double(gpuCount) * gpuRate
        let npuCards: Double
        let npuHourly: Double
        if npuCount > 0 {
            guard let rate = rates.npuPerCardHour,
                let unitsPerCard = configuration.npuUnitsPerCard
            else { return nil }
            npuCards = Double(npuCount) / unitsPerCard
            npuHourly = npuCards * rate
        } else {
            npuCards = 0
            npuHourly = 0
        }
        let cpuHourly = configuration.effectiveCluster == .hpc3
            ? 0 : Double(cpuCount) * rates.cpuPerCoreHour
        let hours = elapsedSeconds / 3_600
        let gpuAmount = gpuHourly * hours
        let npuAmount = npuHourly * hours
        let cpuAmount = cpuHourly * hours
        let amount = gpuAmount + npuAmount + cpuAmount
        let hourlyCost = gpuHourly + npuHourly + cpuHourly
        guard [npuCards, gpuAmount, npuAmount, cpuAmount, amount, hourlyCost].allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return nil }
        return SlurmCostEstimate(
            amount: amount, gpuAmount: gpuAmount, npuAmount: npuAmount, cpuAmount: cpuAmount,
            hourlyCost: hourlyCost, gpuCount: gpuCount, npuCount: npuCount,
            npuCardCount: npuCards, cpuCount: cpuCount,
            elapsedSeconds: elapsedSeconds, tariffLabel: label
        )
    }

    public static func estimate(
        history: SlurmJobHistoryRecord,
        configuration: SlurmCostConfiguration = .hkustHPC2
    ) -> SlurmCostEstimate? {
        estimate(
            partition: history.snapshot.partition,
            allocatedCPU: nil, allocatedGPU: nil,
            elapsedSeconds: duration(history.snapshot.elapsed),
            configuration: configuration, allocatedResources: history.allocatedResources
        )
    }

    private enum Tier { case free, low, medium, high }
    private enum GPU { case a800, a40, a30, ascend, acd }
    private struct Tariff {
        let tier: Tier
        let gpu: GPU?
        var npu: Bool = false
    }

    private static func tariff(for partition: String, cluster: HKUSTSlurmCluster) -> Tariff? {
        switch cluster {
        case .hpc3:
            switch partition {
            case "acd_u": return Tariff(tier: .low, gpu: .acd)
            case "acd_ue": return Tariff(tier: .medium, gpu: .acd)
            case "emergency_acd": return Tariff(tier: .high, gpu: .acd)
            default: return nil
            }
        case .hpc4:
            switch partition {
            case "a128m512u": return Tariff(tier: .low, gpu: nil)
            case "a128m512ue": return Tariff(tier: .medium, gpu: nil)
            case "emergency": return Tariff(tier: .high, gpu: nil)
            case "a320m2tn910cu": return Tariff(tier: .low, gpu: nil, npu: true)
            case "a320m2tn910cue": return Tariff(tier: .medium, gpu: nil, npu: true)
            case "emergency_a320m2tn910c": return Tariff(tier: .high, gpu: nil, npu: true)
            default: return nil
            }
        case .hpc2: break
        }
        switch partition {
        case "debug": return Tariff(tier: .free, gpu: nil)
        case "i64m1tga800u", "long_gpu": return Tariff(tier: .low, gpu: .a800)
        case "i64m1tga800ue": return Tariff(tier: .medium, gpu: .a800)
        case "emergency_gpu": return Tariff(tier: .high, gpu: .a800)
        case "i64m1tga40u": return Tariff(tier: .low, gpu: .a40)
        case "i64m1tga40ue": return Tariff(tier: .medium, gpu: .a40)
        case "emergency_gpua40": return Tariff(tier: .high, gpu: .a40)
        case "gpu": return Tariff(tier: .low, gpu: .a30)
        case "normal", "lmem", "i64m512u", "long_cpu", "i64m512r", "a128m512u", "i96m3tu":
            return Tariff(tier: .low, gpu: nil)
        case "i64m512ue", "i64m512re", "a128m512ue", "i96m3tue":
            return Tariff(tier: .medium, gpu: nil)
        case "emergency_cpu": return Tariff(tier: .high, gpu: nil)
        default: return nil
        }
    }

    private static func resources(_ value: String, tariff: Tariff) -> (cpu: Int, gpu: Int, npu: Int)? {
        guard !value.isEmpty, value.utf8.count <= 65_536 else { return nil }
        var fields: [String: String] = [:]
        for item in value.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            let key = String(pair[0])
            guard fields.updateValue(String(pair[1]), forKey: key) == nil else { return nil }
        }
        guard let rawCPU = fields["cpu"], let cpu = count(rawCPU) else { return nil }
        // Slices and shared accelerators are not full-card allocations.
        guard !fields.keys.contains(where: {
            let key = $0.lowercased()
            return key.contains("mig") || key == "gres/mps" || key == "gres/shard"
        }) else { return nil }

        guard let gpu = acceleratorCount(fields, resource: "gpu", acceptsType: { type in
            guard let expected = tariff.gpu else { return false }
            return gpuType(type) == expected
        }), let npu = acceleratorCount(fields, resource: "npu", acceptsType: { type in
            tariff.npu && ["910c", "ascend910c"].contains(type.lowercased())
        }), tariff.gpu != nil || gpu == 0, tariff.npu || npu == 0
        else { return nil }
        return (cpu, gpu, npu)
    }

    /// Aggregate and typed GRES describe the same resources; never add both.
    private static func acceleratorCount(
        _ fields: [String: String], resource: String, acceptsType: (String) -> Bool
    ) -> Int? {
        let key = "gres/\(resource)"
        let prefix = key + ":"
        let typed = fields.filter { $0.key.hasPrefix(prefix) }
        var typedCount = 0
        for (key, value) in typed {
            guard acceptsType(String(key.dropFirst(prefix.count))), let current = count(value)
            else { return nil }
            let sum = typedCount.addingReportingOverflow(current)
            guard !sum.overflow else { return nil }
            typedCount = sum.partialValue
        }
        if let raw = fields[key] {
            guard let total = count(raw), typed.isEmpty || typedCount == total else { return nil }
            return total
        }
        return typedCount
    }

    private static func containsNPUResource(_ value: String) -> Bool {
        value.split(separator: ",").contains {
            let key = $0.split(separator: "=", maxSplits: 1).first?.lowercased() ?? ""
            return key == "gres/npu" || key.hasPrefix("gres/npu:")
        }
    }

    private static func gpuType(_ value: String) -> GPU? {
        switch value.lowercased() {
        case "a800": return .a800
        case "a40": return .a40
        case "a30": return .a30
        case "acd": return .acd
        case "ascend", "ascend910", "ascend910b": return .ascend
        default: return nil
        }
    }

    private static func count(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }

    private static func duration(_ value: String) -> TimeInterval? {
        let dayParts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(dayParts.count) else { return nil }
        let days: Int
        if dayParts.count == 2 {
            guard let parsed = count(String(dayParts[0])) else { return nil }
            days = parsed
        } else { days = 0 }
        let parts = dayParts.last!.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), dayParts.count == 1 || parts.count == 3 else { return nil }
        let values = parts.compactMap { count(String($0)) }
        guard values.count == parts.count, values.last! < 60,
            parts.count == 2 || values[1] < 60,
            dayParts.count == 1 || values[0] < 24
        else { return nil }
        let seconds = values.reduce(0.0) { $0 * 60 + Double($1) } + Double(days) * 86_400
        return seconds.isFinite ? seconds : nil
    }
}
