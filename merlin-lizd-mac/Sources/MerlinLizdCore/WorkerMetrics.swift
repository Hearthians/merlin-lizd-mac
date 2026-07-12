import Foundation

/// One GPU's point-in-time telemetry. Utilization values use the 0...100
/// percentage scale; byte counts are normalized from nvidia-smi's MiB values.
public struct WorkerGPUMetrics: Codable, Equatable, Hashable, Sendable {
    public let index: Int
    public let utilization: Double?
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    public let temperatureCelsius: Double?
    public let powerWatts: Double?
    public let powerLimitWatts: Double?

    public init(
        index: Int,
        utilization: Double?,
        memoryUsedBytes: UInt64?,
        memoryTotalBytes: UInt64?,
        temperatureCelsius: Double?,
        powerWatts: Double?,
        powerLimitWatts: Double?
    ) {
        self.index = index
        self.utilization = utilization
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.temperatureCelsius = temperatureCelsius
        self.powerWatts = powerWatts
        self.powerLimitWatts = powerLimitWatts
    }

    public var memoryUtilization: Double? {
        Self.percentage(used: memoryUsedBytes, total: memoryTotalBytes)
    }

    private static func percentage(used: UInt64?, total: UInt64?) -> Double? {
        guard let used, let total, total > 0, used <= total else { return nil }
        return Double(used) / Double(total) * 100
    }
}

/// A timestamped Worker sample suitable for an in-memory chart history.
/// It deliberately contains no Pod IP, port, ProxyCommand, or credentials.
public struct WorkerMetricsSample: Codable, Equatable, Hashable, Sendable {
    public let timestamp: Date
    public let cpuUtilization: Double?
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    public let gpus: [WorkerGPUMetrics]

    public init(
        timestamp: Date,
        cpuUtilization: Double?,
        memoryUsedBytes: UInt64?,
        memoryTotalBytes: UInt64?,
        gpus: [WorkerGPUMetrics]
    ) {
        self.timestamp = timestamp
        self.cpuUtilization = cpuUtilization
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.gpus = gpus.sorted { $0.index < $1.index }
    }

    public var memoryUtilization: Double? {
        guard
            let memoryUsedBytes,
            let memoryTotalBytes,
            memoryTotalBytes > 0,
            memoryUsedBytes <= memoryTotalBytes
        else { return nil }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100
    }

    /// Mean utilization across GPUs that reported a valid value.
    public var gpuUtilization: Double? {
        average(gpus.compactMap(\.utilization))
    }

    /// Aggregate VRAM is emitted only when every discovered GPU reported the
    /// value, avoiding deceptively low totals for partially supported output.
    public var gpuMemoryUsedBytes: UInt64? {
        completeSum(gpus.map(\.memoryUsedBytes))
    }

    public var gpuMemoryTotalBytes: UInt64? {
        completeSum(gpus.map(\.memoryTotalBytes))
    }

    public var gpuMemoryUtilization: Double? {
        guard
            let gpuMemoryUsedBytes,
            let gpuMemoryTotalBytes,
            gpuMemoryTotalBytes > 0,
            gpuMemoryUsedBytes <= gpuMemoryTotalBytes
        else { return nil }
        return Double(gpuMemoryUsedBytes) / Double(gpuMemoryTotalBytes) * 100
    }

    /// Highest reported device temperature is the most useful thermal signal.
    public var gpuTemperatureCelsius: Double? {
        gpus.compactMap(\.temperatureCelsius).max()
    }

    public var gpuPowerWatts: Double? {
        completeSum(gpus.map(\.powerWatts))
    }

    public var gpuPowerLimitWatts: Double? {
        completeSum(gpus.map(\.powerLimitWatts))
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func completeSum(_ values: [UInt64?]) -> UInt64? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        var sum: UInt64 = 0
        for value in values.compactMap({ $0 }) {
            let result = sum.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            sum = result.partialValue
        }
        return sum
    }

    private func completeSum(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        let sum = values.compactMap { $0 }.reduce(0, +)
        return sum.isFinite ? sum : nil
    }

    /// Combines two projections of the same instant. Values already present
    /// on the receiver win (for example a direct Worker observation), while
    /// the other sample fills fields supplied later by an incremental Merlin
    /// panel retry. GPU fields are merged independently by device ID.
    public func fillingMissingValues(
        from other: WorkerMetricsSample
    ) -> WorkerMetricsSample {
        guard timestamp == other.timestamp else { return self }
        let ownGPUs = Dictionary(uniqueKeysWithValues: gpus.map { ($0.index, $0) })
        let otherGPUs = Dictionary(
            uniqueKeysWithValues: other.gpus.map { ($0.index, $0) }
        )
        let gpuIDs = Set(ownGPUs.keys).union(otherGPUs.keys)
        let mergedGPUs = gpuIDs.sorted().compactMap { id -> WorkerGPUMetrics? in
            switch (ownGPUs[id], otherGPUs[id]) {
            case let (own?, supplement?):
                WorkerGPUMetrics(
                    index: id,
                    utilization: own.utilization ?? supplement.utilization,
                    memoryUsedBytes: own.memoryUsedBytes
                        ?? supplement.memoryUsedBytes,
                    memoryTotalBytes: own.memoryTotalBytes
                        ?? supplement.memoryTotalBytes,
                    temperatureCelsius: own.temperatureCelsius
                        ?? supplement.temperatureCelsius,
                    powerWatts: own.powerWatts ?? supplement.powerWatts,
                    powerLimitWatts: own.powerLimitWatts
                        ?? supplement.powerLimitWatts
                )
            case let (own?, nil):
                own
            case let (nil, supplement?):
                supplement
            case (nil, nil):
                nil
            }
        }
        return WorkerMetricsSample(
            timestamp: timestamp,
            cpuUtilization: cpuUtilization ?? other.cpuUtilization,
            memoryUsedBytes: memoryUsedBytes ?? other.memoryUsedBytes,
            memoryTotalBytes: memoryTotalBytes ?? other.memoryTotalBytes,
            gpus: mergedGPUs
        )
    }
}

enum WorkerMetricsWireFormat {
    static let beginMarker = "__MERLIN_LIZD_METRICS_V1_BEGIN__"
    static let uptimeBeforeMarker = "__MERLIN_LIZD_METRICS_UPTIME_BEFORE__"
    static let uptimeAfterMarker = "__MERLIN_LIZD_METRICS_UPTIME_AFTER__"
    static let cgroupV1CPUBeforeMarker = "__MERLIN_LIZD_METRICS_CGROUP_V1_CPU_BEFORE__"
    static let cgroupV1CPUAfterMarker = "__MERLIN_LIZD_METRICS_CGROUP_V1_CPU_AFTER__"
    static let cgroupV1CPUQuotaMarker = "__MERLIN_LIZD_METRICS_CGROUP_V1_CPU_QUOTA__"
    static let cgroupV1CPUPeriodMarker = "__MERLIN_LIZD_METRICS_CGROUP_V1_CPU_PERIOD__"
    static let cgroupV2CPUBeforeMarker = "__MERLIN_LIZD_METRICS_CGROUP_V2_CPU_BEFORE__"
    static let cgroupV2CPUAfterMarker = "__MERLIN_LIZD_METRICS_CGROUP_V2_CPU_AFTER__"
    static let cgroupV2CPUMaxMarker = "__MERLIN_LIZD_METRICS_CGROUP_V2_CPU_MAX__"
    static let cpuBeforeMarker = "__MERLIN_LIZD_METRICS_CPU_BEFORE__"
    static let cpuAfterMarker = "__MERLIN_LIZD_METRICS_CPU_AFTER__"
    static let cgroupV1MemoryUsageMarker = "__MERLIN_LIZD_METRICS_CGROUP_V1_MEMORY_USAGE__"
    static let cgroupV1MemoryLimitMarker = "__MERLIN_LIZD_METRICS_CGROUP_V1_MEMORY_LIMIT__"
    static let cgroupV2MemoryUsageMarker = "__MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_USAGE__"
    static let cgroupV2MemoryLimitMarker = "__MERLIN_LIZD_METRICS_CGROUP_V2_MEMORY_LIMIT__"
    static let memoryMarker = "__MERLIN_LIZD_METRICS_MEMORY__"
    static let gpuMarker = "__MERLIN_LIZD_METRICS_GPU__"
    static let endMarker = "__MERLIN_LIZD_METRICS_V1_END__"
}

public enum WorkerMetricsParseError: Error, Equatable, Sendable {
    case missingEnvelope
    case incompleteEnvelope
    case noMetrics
}

public enum WorkerMetricsParser {
    private enum Section {
        case none
        case uptimeBefore
        case uptimeAfter
        case cgroupV1CPUBefore
        case cgroupV1CPUAfter
        case cgroupV1CPUQuota
        case cgroupV1CPUPeriod
        case cgroupV2CPUBefore
        case cgroupV2CPUAfter
        case cgroupV2CPUMax
        case cpuBefore
        case cpuAfter
        case cgroupV1MemoryUsage
        case cgroupV1MemoryLimit
        case cgroupV2MemoryUsage
        case cgroupV2MemoryLimit
        case memory
        case gpu
    }

    /// Parses the last complete metrics envelope, ignoring SSH/mlx banners and
    /// unrelated output before or after it. Invalid individual device fields
    /// become nil so supported CPU or memory data remains usable.
    public static func parse(
        _ output: String,
        timestamp: Date = Date()
    ) throws -> WorkerMetricsSample {
        let lines = output
            .split(whereSeparator: \Character.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard lines.contains(WorkerMetricsWireFormat.beginMarker) else {
            throw WorkerMetricsParseError.missingEnvelope
        }

        var completed: WorkerMetricsSample?
        var insideEnvelope = false
        var section = Section.none
        var uptimeBefore: Double?
        var uptimeAfter: Double?
        var cgroupV1CPUBefore: UInt64?
        var cgroupV1CPUAfter: UInt64?
        var cgroupV1CPUQuota: Int64?
        var cgroupV1CPUPeriod: UInt64?
        var cgroupV2CPUBefore: UInt64?
        var cgroupV2CPUAfter: UInt64?
        var cgroupV2CPUMax: CgroupV2CPUMax?
        var cpuBefore: CPUCounters?
        var cpuAfter: CPUCounters?
        var cgroupV1MemoryUsage: UInt64?
        var cgroupV1MemoryLimit: UInt64?
        var cgroupV2MemoryUsage: UInt64?
        var cgroupV2MemoryLimit: UInt64?
        var memory: [String: UInt64] = [:]
        var gpus: [Int: WorkerGPUMetrics] = [:]

        for line in lines {
            switch line {
            case WorkerMetricsWireFormat.beginMarker:
                insideEnvelope = true
                section = .none
                uptimeBefore = nil
                uptimeAfter = nil
                cgroupV1CPUBefore = nil
                cgroupV1CPUAfter = nil
                cgroupV1CPUQuota = nil
                cgroupV1CPUPeriod = nil
                cgroupV2CPUBefore = nil
                cgroupV2CPUAfter = nil
                cgroupV2CPUMax = nil
                cpuBefore = nil
                cpuAfter = nil
                cgroupV1MemoryUsage = nil
                cgroupV1MemoryLimit = nil
                cgroupV2MemoryUsage = nil
                cgroupV2MemoryLimit = nil
                memory = [:]
                gpus = [:]
            case WorkerMetricsWireFormat.uptimeBeforeMarker where insideEnvelope:
                section = .uptimeBefore
            case WorkerMetricsWireFormat.uptimeAfterMarker where insideEnvelope:
                section = .uptimeAfter
            case WorkerMetricsWireFormat.cgroupV1CPUBeforeMarker where insideEnvelope:
                section = .cgroupV1CPUBefore
            case WorkerMetricsWireFormat.cgroupV1CPUAfterMarker where insideEnvelope:
                section = .cgroupV1CPUAfter
            case WorkerMetricsWireFormat.cgroupV1CPUQuotaMarker where insideEnvelope:
                section = .cgroupV1CPUQuota
            case WorkerMetricsWireFormat.cgroupV1CPUPeriodMarker where insideEnvelope:
                section = .cgroupV1CPUPeriod
            case WorkerMetricsWireFormat.cgroupV2CPUBeforeMarker where insideEnvelope:
                section = .cgroupV2CPUBefore
            case WorkerMetricsWireFormat.cgroupV2CPUAfterMarker where insideEnvelope:
                section = .cgroupV2CPUAfter
            case WorkerMetricsWireFormat.cgroupV2CPUMaxMarker where insideEnvelope:
                section = .cgroupV2CPUMax
            case WorkerMetricsWireFormat.cpuBeforeMarker where insideEnvelope:
                section = .cpuBefore
            case WorkerMetricsWireFormat.cpuAfterMarker where insideEnvelope:
                section = .cpuAfter
            case WorkerMetricsWireFormat.cgroupV1MemoryUsageMarker where insideEnvelope:
                section = .cgroupV1MemoryUsage
            case WorkerMetricsWireFormat.cgroupV1MemoryLimitMarker where insideEnvelope:
                section = .cgroupV1MemoryLimit
            case WorkerMetricsWireFormat.cgroupV2MemoryUsageMarker where insideEnvelope:
                section = .cgroupV2MemoryUsage
            case WorkerMetricsWireFormat.cgroupV2MemoryLimitMarker where insideEnvelope:
                section = .cgroupV2MemoryLimit
            case WorkerMetricsWireFormat.memoryMarker where insideEnvelope:
                section = .memory
            case WorkerMetricsWireFormat.gpuMarker where insideEnvelope:
                section = .gpu
            case WorkerMetricsWireFormat.endMarker where insideEnvelope:
                let sample = makeSample(
                    timestamp: timestamp,
                    uptimeBefore: uptimeBefore,
                    uptimeAfter: uptimeAfter,
                    cgroupV1CPUBefore: cgroupV1CPUBefore,
                    cgroupV1CPUAfter: cgroupV1CPUAfter,
                    cgroupV1CPUQuota: cgroupV1CPUQuota,
                    cgroupV1CPUPeriod: cgroupV1CPUPeriod,
                    cgroupV2CPUBefore: cgroupV2CPUBefore,
                    cgroupV2CPUAfter: cgroupV2CPUAfter,
                    cgroupV2CPUMax: cgroupV2CPUMax,
                    cpuBefore: cpuBefore,
                    cpuAfter: cpuAfter,
                    cgroupV1MemoryUsage: cgroupV1MemoryUsage,
                    cgroupV1MemoryLimit: cgroupV1MemoryLimit,
                    cgroupV2MemoryUsage: cgroupV2MemoryUsage,
                    cgroupV2MemoryLimit: cgroupV2MemoryLimit,
                    memory: memory,
                    gpus: Array(gpus.values)
                )
                if hasAnyMetric(sample) {
                    completed = sample
                }
                insideEnvelope = false
                section = .none
            default:
                guard insideEnvelope else { continue }
                switch section {
                case .uptimeBefore:
                    uptimeBefore = uptimeBefore ?? parseUptime(line)
                case .uptimeAfter:
                    uptimeAfter = uptimeAfter ?? parseUptime(line)
                case .cgroupV1CPUBefore:
                    cgroupV1CPUBefore = cgroupV1CPUBefore ?? parseUnsignedLine(line)
                case .cgroupV1CPUAfter:
                    cgroupV1CPUAfter = cgroupV1CPUAfter ?? parseUnsignedLine(line)
                case .cgroupV1CPUQuota:
                    cgroupV1CPUQuota = cgroupV1CPUQuota ?? parseSignedLine(line)
                case .cgroupV1CPUPeriod:
                    cgroupV1CPUPeriod = cgroupV1CPUPeriod ?? parseUnsignedLine(line)
                case .cgroupV2CPUBefore:
                    cgroupV2CPUBefore = cgroupV2CPUBefore ?? parseCgroupV2CPUUsage(line)
                case .cgroupV2CPUAfter:
                    cgroupV2CPUAfter = cgroupV2CPUAfter ?? parseCgroupV2CPUUsage(line)
                case .cgroupV2CPUMax:
                    cgroupV2CPUMax = cgroupV2CPUMax ?? parseCgroupV2CPUMax(line)
                case .cpuBefore:
                    cpuBefore = cpuBefore ?? parseCPUCounters(line)
                case .cpuAfter:
                    cpuAfter = cpuAfter ?? parseCPUCounters(line)
                case .cgroupV1MemoryUsage:
                    cgroupV1MemoryUsage = cgroupV1MemoryUsage ?? parseUnsignedLine(line)
                case .cgroupV1MemoryLimit:
                    cgroupV1MemoryLimit = cgroupV1MemoryLimit ?? parseUnsignedLine(line)
                case .cgroupV2MemoryUsage:
                    cgroupV2MemoryUsage = cgroupV2MemoryUsage ?? parseUnsignedLine(line)
                case .cgroupV2MemoryLimit:
                    cgroupV2MemoryLimit = cgroupV2MemoryLimit ?? parseUnsignedLine(line)
                case .memory:
                    if let (key, bytes) = parseMemoryLine(line) {
                        memory[key] = bytes
                    }
                case .gpu:
                    if let gpu = parseGPULine(line), gpus[gpu.index] == nil {
                        gpus[gpu.index] = gpu
                    }
                case .none:
                    continue
                }
            }
        }

        if let completed { return completed }
        if insideEnvelope || !lines.contains(WorkerMetricsWireFormat.endMarker) {
            throw WorkerMetricsParseError.incompleteEnvelope
        }
        throw WorkerMetricsParseError.noMetrics
    }

    private struct CPUCounters {
        let total: UInt64
        let idle: UInt64
    }

    private struct CgroupV2CPUMax {
        let quotaMicroseconds: UInt64
        let periodMicroseconds: UInt64
    }

    private static func parseUptime(_ line: String) -> Double? {
        guard
            let value = line.split(whereSeparator: \Character.isWhitespace).first,
            let seconds = Double(value),
            seconds.isFinite,
            seconds >= 0
        else { return nil }
        return seconds
    }

    private static func parseUnsignedLine(_ line: String) -> UInt64? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 1 else { return nil }
        return UInt64(fields[0])
    }

    private static func parseSignedLine(_ line: String) -> Int64? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 1 else { return nil }
        return Int64(fields[0])
    }

    private static func parseCgroupV2CPUUsage(_ line: String) -> UInt64? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 2, fields[0] == "usage_usec" else { return nil }
        return UInt64(fields[1])
    }

    private static func parseCgroupV2CPUMax(_ line: String) -> CgroupV2CPUMax? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard
            fields.count == 2,
            fields[0] != "max",
            let quota = UInt64(fields[0]),
            let period = UInt64(fields[1]),
            quota > 0,
            period > 0
        else { return nil }
        return CgroupV2CPUMax(
            quotaMicroseconds: quota,
            periodMicroseconds: period
        )
    }

    private static func parseCPUCounters(_ line: String) -> CPUCounters? {
        let columns = line.split(whereSeparator: \Character.isWhitespace)
        guard columns.first == "cpu", columns.count >= 6 else { return nil }
        let rawCounters = columns.dropFirst().prefix(8)
        guard
            rawCounters.count >= 5,
            rawCounters.allSatisfy({ UInt64($0) != nil })
        else { return nil }
        let counters = rawCounters.compactMap { UInt64($0) }

        var total: UInt64 = 0
        for value in counters {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        let idleResult = counters[3].addingReportingOverflow(counters[4])
        guard !idleResult.overflow else { return nil }
        return CPUCounters(total: total, idle: idleResult.partialValue)
    }

    private static func parseMemoryLine(_ line: String) -> (String, UInt64)? {
        let parts = line.split(whereSeparator: \Character.isWhitespace)
        guard parts.count >= 2 else { return nil }
        let key = String(parts[0].dropLast(parts[0].last == ":" ? 1 : 0))
        guard memoryKeys.contains(key), let kibibytes = UInt64(parts[1]) else {
            return nil
        }
        let bytes = kibibytes.multipliedReportingOverflow(by: 1_024)
        guard !bytes.overflow else { return nil }
        return (key, bytes.partialValue)
    }

    private static let memoryKeys: Set<String> = [
        "MemTotal", "MemAvailable", "MemFree", "Buffers", "Cached",
        "SReclaimable", "Shmem",
    ]

    private static func parseGPULine(_ line: String) -> WorkerGPUMetrics? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 7, let index = Int(fields[0]), index >= 0 else {
            return nil
        }
        return WorkerGPUMetrics(
            index: index,
            utilization: percentage(fields[1]),
            memoryUsedBytes: mebibytes(fields[2]),
            memoryTotalBytes: mebibytes(fields[3]),
            temperatureCelsius: finiteNonnegative(fields[4]),
            powerWatts: finiteNonnegative(fields[5]),
            powerLimitWatts: finiteNonnegative(fields[6])
        )
    }

    private static func percentage(_ value: String) -> Double? {
        guard let number = finiteNonnegative(value), number <= 100 else {
            return nil
        }
        return number
    }

    private static func finiteNonnegative(_ value: String) -> Double? {
        guard let number = Double(value), number.isFinite, number >= 0 else {
            return nil
        }
        return number
    }

    private static func mebibytes(_ value: String) -> UInt64? {
        guard let number = finiteNonnegative(value) else { return nil }
        let bytes = number * 1_048_576
        guard bytes.isFinite else { return nil }
        return UInt64(exactly: bytes.rounded())
    }

    private static func makeSample(
        timestamp: Date,
        uptimeBefore: Double?,
        uptimeAfter: Double?,
        cgroupV1CPUBefore: UInt64?,
        cgroupV1CPUAfter: UInt64?,
        cgroupV1CPUQuota: Int64?,
        cgroupV1CPUPeriod: UInt64?,
        cgroupV2CPUBefore: UInt64?,
        cgroupV2CPUAfter: UInt64?,
        cgroupV2CPUMax: CgroupV2CPUMax?,
        cpuBefore: CPUCounters?,
        cpuAfter: CPUCounters?,
        cgroupV1MemoryUsage: UInt64?,
        cgroupV1MemoryLimit: UInt64?,
        cgroupV2MemoryUsage: UInt64?,
        cgroupV2MemoryLimit: UInt64?,
        memory: [String: UInt64],
        gpus: [WorkerGPUMetrics]
    ) -> WorkerMetricsSample {
        let measuredElapsedSeconds = elapsedSeconds(
            before: uptimeBefore,
            after: uptimeAfter
        )
        let cgroupV1CPU = cgroupCPUUtilization(
            usageBefore: cgroupV1CPUBefore,
            usageAfter: cgroupV1CPUAfter,
            usageUnitsPerSecond: 1_000_000_000,
            elapsedSeconds: measuredElapsedSeconds,
            quotaMicroseconds: cgroupV1CPUQuota.flatMap {
                $0 > 0 ? UInt64($0) : nil
            },
            periodMicroseconds: cgroupV1CPUPeriod
        )
        let cgroupV2CPU = cgroupCPUUtilization(
            usageBefore: cgroupV2CPUBefore,
            usageAfter: cgroupV2CPUAfter,
            usageUnitsPerSecond: 1_000_000,
            elapsedSeconds: measuredElapsedSeconds,
            quotaMicroseconds: cgroupV2CPUMax?.quotaMicroseconds,
            periodMicroseconds: cgroupV2CPUMax?.periodMicroseconds
        )
        let cpuUtilization = cgroupV1CPU
            ?? cgroupV2CPU
            ?? procCPUUtilization(before: cpuBefore, after: cpuAfter)

        let cgroupV1Memory = cgroupMemory(
            used: cgroupV1MemoryUsage,
            total: cgroupV1MemoryLimit
        )
        let cgroupV2Memory = cgroupMemory(
            used: cgroupV2MemoryUsage,
            total: cgroupV2MemoryLimit
        )
        let fallbackMemory = procMemory(memory)
        let selectedMemory = cgroupV1Memory ?? cgroupV2Memory ?? fallbackMemory

        return WorkerMetricsSample(
            timestamp: timestamp,
            cpuUtilization: cpuUtilization,
            memoryUsedBytes: selectedMemory?.used,
            memoryTotalBytes: selectedMemory?.total,
            gpus: gpus
        )
    }

    private static func elapsedSeconds(
        before: Double?,
        after: Double?
    ) -> Double? {
        guard
            let before,
            let after,
            after > before,
            after - before <= 60
        else { return nil }
        return after - before
    }

    private static func cgroupCPUUtilization(
        usageBefore: UInt64?,
        usageAfter: UInt64?,
        usageUnitsPerSecond: Double,
        elapsedSeconds: Double?,
        quotaMicroseconds: UInt64?,
        periodMicroseconds: UInt64?
    ) -> Double? {
        guard
            let usageBefore,
            let usageAfter,
            usageAfter >= usageBefore,
            let elapsedSeconds,
            elapsedSeconds > 0,
            let quotaMicroseconds,
            let periodMicroseconds,
            quotaMicroseconds > 0,
            periodMicroseconds > 0
        else { return nil }
        let quotaCores = Double(quotaMicroseconds) / Double(periodMicroseconds)
        guard quotaCores.isFinite, quotaCores > 0 else { return nil }
        let usageDelta = Double(usageAfter - usageBefore) / usageUnitsPerSecond
        let utilization = usageDelta / elapsedSeconds / quotaCores * 100
        guard utilization.isFinite, utilization >= 0 else { return nil }
        return min(utilization, 100)
    }

    private static func procCPUUtilization(
        before: CPUCounters?,
        after: CPUCounters?
    ) -> Double? {
        guard
            let before,
            let after,
            after.total > before.total,
            after.idle >= before.idle
        else { return nil }
        let totalDelta = after.total - before.total
        let idleDelta = after.idle - before.idle
        guard idleDelta <= totalDelta else { return nil }
        return Double(totalDelta - idleDelta) / Double(totalDelta) * 100
    }

    private static func cgroupMemory(
        used: UInt64?,
        total: UInt64?
    ) -> (used: UInt64, total: UInt64)? {
        // cgroup v1 represents an unlimited hierarchy with a value near
        // Int64.max. Treat it as absent rather than drawing a near-zero line.
        let unlimitedThreshold = UInt64(1) << 60
        guard
            let used,
            let total,
            total > 0,
            total < unlimitedThreshold,
            used <= total
        else { return nil }
        return (used, total)
    }

    private static func procMemory(
        _ memory: [String: UInt64]
    ) -> (used: UInt64, total: UInt64)? {
        guard let total = memory["MemTotal"], total > 0 else { return nil }
        let available = memory["MemAvailable"]
            ?? fallbackAvailableMemory(memory)
        guard let available, available <= total else { return nil }
        return (total - available, total)
    }

    private static func fallbackAvailableMemory(
        _ memory: [String: UInt64]
    ) -> UInt64? {
        guard let free = memory["MemFree"] else { return nil }
        let additive = ["Buffers", "Cached", "SReclaimable"]
            .compactMap { memory[$0] }
        var available = free
        for value in additive {
            let result = available.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            available = result.partialValue
        }
        let shared = memory["Shmem"] ?? 0
        guard shared <= available else { return nil }
        return available - shared
    }

    private static func hasAnyMetric(_ sample: WorkerMetricsSample) -> Bool {
        sample.cpuUtilization != nil
            || sample.memoryTotalBytes != nil
            || !sample.gpus.isEmpty
    }
}

public enum WorkerMetricsSamplingError: Error, Equatable, Sendable {
    case workerNotReady
    case commandFailed(exitCode: Int32)
}

/// Executes bounded, cancellation-aware snapshots through the approved
/// Devbox-alias -> mlx Worker route. History and persistence are left to the
/// caller; this actor retains no network coordinates or samples.
public actor WorkerMetricsSampler {
    private let processRunner: any InventoryProcessRunning
    private let now: @Sendable () -> Date

    public init(maxConcurrentProcesses: Int = 2) {
        processRunner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(1, maxConcurrentProcesses),
            underlying: TimedInventoryProcessRunner(
                timeout: .seconds(45),
                underlying: FoundationInventoryProcessRunner()
            )
        )
        now = Date.init
    }

    init(
        processRunner: any InventoryProcessRunning,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.now = now
    }

    public func sample(target: TerminalTarget) async throws -> WorkerMetricsSample {
        let command = try MerlinCommands.sampleWorkerMetrics(target: target)
        let output = try await processRunner.run(command)
        let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()
        if diagnostic.contains("worker has not been ready")
            || diagnostic.contains("worker is not ready")
        {
            throw WorkerMetricsSamplingError.workerNotReady
        }
        guard output.exitCode == 0 else {
            throw WorkerMetricsSamplingError.commandFailed(exitCode: output.exitCode)
        }
        return try WorkerMetricsParser.parse(output.stdout, timestamp: now())
    }
}
