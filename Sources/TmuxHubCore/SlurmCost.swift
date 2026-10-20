import Foundation

public struct SlurmCostTierRates: Codable, Hashable, Sendable {
    public var cpuPerCoreHour: Double
    public var a800PerGPUHour: Double
    public var otherPerGPUHour: Double

    public init(cpuPerCoreHour: Double, a800PerGPUHour: Double, otherPerGPUHour: Double) {
        self.cpuPerCoreHour = cpuPerCoreHour
        self.a800PerGPUHour = a800PerGPUHour
        self.otherPerGPUHour = otherPerGPUHour
    }

    public var isValid: Bool {
        [cpuPerCoreHour, a800PerGPUHour, otherPerGPUHour].allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

public struct SlurmCostConfiguration: Codable, Hashable, Sendable {
    public var low: SlurmCostTierRates
    public var medium: SlurmCostTierRates
    public var high: SlurmCostTierRates
    public var currencyCode: String { "CNY" }

    public init(low: SlurmCostTierRates, medium: SlurmCostTierRates, high: SlurmCostTierRates) {
        self.low = low
        self.medium = medium
        self.high = high
    }

    /// HKUST(GZ) HPC price reference, verified 2026-10-13. GPU prices exclude CPU and storage.
    public static let hkustHPC2 = SlurmCostConfiguration(
        low: .init(cpuPerCoreHour: 0.02, a800PerGPUHour: 1.60, otherPerGPUHour: 0.50),
        medium: .init(cpuPerCoreHour: 0.04, a800PerGPUHour: 2.50, otherPerGPUHour: 1.00),
        high: .init(cpuPerCoreHour: 0.06, a800PerGPUHour: 4.00, otherPerGPUHour: 1.50)
    )

    public var isValid: Bool { low.isValid && medium.isValid && high.isValid }
}

public struct SlurmCostEstimate: Hashable, Sendable {
    public let amount: Double
    public let gpuAmount: Double
    public let cpuAmount: Double
    public let hourlyCost: Double
    public let gpuCount: Int
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
        allocatedResources: String? = nil
    ) -> SlurmCostEstimate? {
        guard configuration.isValid,
            let elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0,
            allocatedCPU.map({ $0 >= 0 }) ?? true,
            allocatedGPU.map({ $0 >= 0 }) ?? true,
            let tariff = tariff(for: partition)
        else { return nil }

        // The published debug exception is free compute, even without allocation details.
        if tariff.tier == .free {
            return SlurmCostEstimate(
                amount: 0, gpuAmount: 0, cpuAmount: 0, hourlyCost: 0,
                gpuCount: allocatedGPU ?? 0, cpuCount: allocatedCPU ?? 0,
                elapsedSeconds: elapsedSeconds, tariffLabel: "调试队列 · 计算免费"
            )
        }

        var cpuCount = allocatedCPU
        var gpuCount = allocatedGPU
        if let allocatedResources {
            guard let counts = resources(allocatedResources, gpu: tariff.gpu),
                cpuCount.map({ $0 == counts.cpu }) ?? true,
                gpuCount.map({ $0 == counts.gpu }) ?? true
            else { return nil }
            cpuCount = counts.cpu
            gpuCount = counts.gpu
        }
        guard let cpuCount, let gpuCount, tariff.gpu != nil || gpuCount == 0 else { return nil }

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
        let cpuHourly = Double(cpuCount) * rates.cpuPerCoreHour
        let hours = elapsedSeconds / 3_600
        let gpuAmount = gpuHourly * hours
        let cpuAmount = cpuHourly * hours
        let amount = gpuAmount + cpuAmount
        let hourlyCost = gpuHourly + cpuHourly
        guard [gpuAmount, cpuAmount, amount, hourlyCost].allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return nil }
        return SlurmCostEstimate(
            amount: amount, gpuAmount: gpuAmount, cpuAmount: cpuAmount, hourlyCost: hourlyCost,
            gpuCount: gpuCount, cpuCount: cpuCount, elapsedSeconds: elapsedSeconds, tariffLabel: label
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
    private enum GPU { case a800, a40, a30, ascend }
    private struct Tariff { let tier: Tier; let gpu: GPU? }

    private static func tariff(for partition: String) -> Tariff? {
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

    private static func resources(_ value: String, gpu expectedGPU: GPU?) -> (cpu: Int, gpu: Int)? {
        guard !value.isEmpty, value.utf8.count <= 65_536 else { return nil }
        var fields: [String: String] = [:]
        for item in value.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            let key = String(pair[0])
            guard fields.updateValue(String(pair[1]), forKey: key) == nil else { return nil }
        }
        guard let rawCPU = fields["cpu"], let cpu = count(rawCPU) else { return nil }
        // Slices and shared GPU resources have separate pricing, not full-card pricing.
        guard !fields.keys.contains(where: {
            let key = $0.lowercased()
            return key.contains("mig") || key == "gres/mps" || key == "gres/shard"
        }) else { return nil }

        let typed = fields.filter { $0.key.hasPrefix("gres/gpu:") }
        var typedCount = 0
        for (key, value) in typed {
            guard let expectedGPU, gpuType(String(key.dropFirst("gres/gpu:".count))) == expectedGPU,
                let current = count(value)
            else { return nil }
            let sum = typedCount.addingReportingOverflow(current)
            guard !sum.overflow else { return nil }
            typedCount = sum.partialValue
        }
        if let rawGPU = fields["gres/gpu"] {
            guard let gpu = count(rawGPU), typed.isEmpty || typedCount == gpu else { return nil }
            return (cpu, gpu)
        }
        return (cpu, typedCount)
    }

    private static func gpuType(_ value: String) -> GPU? {
        switch value.lowercased() {
        case "a800": return .a800
        case "a40": return .a40
        case "a30": return .a30
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
