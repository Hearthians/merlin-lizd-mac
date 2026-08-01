import Foundation

public struct MerlinTaskGPUReading: Equatable, Sendable {
    public let currentUtilization: Double
    public let averageUtilization: Double?
    public let sampledAt: Date

    public init(
        currentUtilization: Double,
        averageUtilization: Double?,
        sampledAt: Date
    ) {
        self.currentUtilization = currentUtilization
        self.averageUtilization = averageUtilization
        self.sampledAt = sampledAt
    }
}

public struct MerlinTaskMemoryReading: Equatable, Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64?
    public let sampledAt: Date

    public init(usedBytes: UInt64, totalBytes: UInt64?, sampledAt: Date) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.sampledAt = sampledAt
    }

    public var utilization: Double? {
        guard let totalBytes, totalBytes > 0, usedBytes <= totalBytes else {
            return nil
        }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

/// Persistence-safe task telemetry. Each metric carries its own timestamp so
/// a fresh memory point cannot make an older GPU reading appear current. Raw
/// Grafana URLs, queries, routing tags, and credentials never cross this
/// projection.
public struct MerlinTaskMetrics: Equatable, Sendable {
    public let gpu: MerlinTaskGPUReading?
    public let memory: MerlinTaskMemoryReading?

    public init(
        gpu: MerlinTaskGPUReading?,
        memory: MerlinTaskMemoryReading?
    ) {
        self.gpu = gpu
        self.memory = memory
    }

    public var gpuUtilization: Double? { gpu?.currentUtilization }
    public var gpuAverageUtilization: Double? { gpu?.averageUtilization }
    public var memoryUsedBytes: UInt64? { memory?.usedBytes }
    public var memoryTotalBytes: UInt64? { memory?.totalBytes }

    public var memoryUtilization: Double? {
        memory?.utilization
    }
}

/// Reduces dashboard-specific panel responses to one task-level reading.
public enum MerlinTaskMetricsParser {
    private static let aggregateFreshnessTolerance: TimeInterval = 30

    public static func parse(
        gpuOutput: String?,
        memoryOutput: String?,
        memoryTotalOverride: UInt64? = nil,
        trialID: String? = nil
    ) -> MerlinTaskMetrics? {
        let gpuSeries = series(
            parseSeries(gpuOutput),
            matchingTrialID: trialID
        )
        let gpuMetricSeries = gpuSeries.filter {
            metric($0.metric, hasSuffix: "gpu_duty_cycle")
        }
        let currentGPUSeries = gpuMetricSeries.filter {
            $0.tags["stat"]?.lowercased() != "average"
        }
        let latestGPUReadings = currentGPUSeries.compactMap {
            series -> GrafanaMetricPoint? in
            return series.points.last
        }
        let gpuReadings = coherentPoints(latestGPUReadings)
        let explicitAverageReadings = gpuMetricSeries.compactMap {
            series -> GrafanaMetricPoint? in
            guard series.tags["stat"]?.lowercased() == "average" else {
                return nil
            }
            return series.points.last
        }
        let memorySeries = series(
            parseSeries(memoryOutput),
            matchingTrialID: trialID
        )
        let allUsedReadings = latestMemoryReadings(
            memorySeries,
            metricSuffixes: ["mem_usage", "memory_usage"],
            targetField: "used"
        )
        let usedReadings = coherentReadings(allUsedReadings)
        let limitReadings = latestMemoryReadings(
            memorySeries,
            metricSuffixes: ["mem_limit", "memory_limit"],
            targetField: "limit"
        )
        let gpu: MerlinTaskGPUReading?
        if let gpuSampledAt = gpuReadings.map(\.timestamp).min() {
            let utilization = min(100, max(
                0,
                gpuReadings.map(\.value).reduce(0, +)
                    / Double(gpuReadings.count)
            ))
            let isLegendProjection = currentGPUSeries.contains {
                $0.tags["source"] == "grafana-panel-legend"
            }
            let averagePoints: [GrafanaMetricPoint] = if
                !explicitAverageReadings.isEmpty
            {
                explicitAverageReadings
            } else if isLegendProjection {
                []
            } else {
                currentGPUSeries.flatMap(\.points)
            }
            let average = averagePoints.isEmpty ? nil : min(100, max(
                0,
                averagePoints.map(\.value).reduce(0, +)
                    / Double(averagePoints.count)
            ))
            gpu = MerlinTaskGPUReading(
                currentUtilization: utilization,
                averageUtilization: average,
                sampledAt: gpuSampledAt
            )
        } else {
            gpu = nil
        }
        // Memory is a sum across pods. If any pod is outside the coherent
        // bucket, suppress the aggregate rather than under-reporting usage.
        let memoryUsed = usedReadings.count == allUsedReadings.count
            ? sumBytes(usedReadings.values.map(\.value))
            : nil
        let matchingLimits = usedReadings.reduce(
            into: [String: GrafanaMetricPoint]()
        ) { matches, reading in
            guard
                let limit = limitReadings[reading.key],
                abs(limit.timestamp.timeIntervalSince(
                    reading.value.timestamp
                )) <= aggregateFreshnessTolerance
            else { return }
            matches[reading.key] = limit
        }
        let sampledMemoryTotal: UInt64? = if
            !usedReadings.isEmpty,
            matchingLimits.count == usedReadings.count
        {
            sumBytes(usedReadings.keys.compactMap {
                matchingLimits[$0]?.value
            })
        } else {
            nil
        }
        let memoryTotal = memoryTotalOverride ?? sampledMemoryTotal
        let memory: MerlinTaskMemoryReading?
        if
            let memoryUsed,
            let memorySampledAt = (
                usedReadings.values.map(\.timestamp)
                    + (sampledMemoryTotal == nil
                        ? []
                        : matchingLimits.values.map(\.timestamp))
            ).min()
        {
            memory = MerlinTaskMemoryReading(
                usedBytes: memoryUsed,
                totalBytes: memoryTotal,
                sampledAt: memorySampledAt
            )
        } else {
            memory = nil
        }
        guard gpu != nil || memory != nil else { return nil }
        return MerlinTaskMetrics(gpu: gpu, memory: memory)
    }

    private static func parseSeries(_ output: String?) -> [GrafanaMetricSeries] {
        guard let output else { return [] }
        return (try? GrafanaPanelDataParser.parse(output)) ?? []
    }

    private static func series(
        _ values: [GrafanaMetricSeries],
        matchingTrialID trialID: String?
    ) -> [GrafanaMetricSeries] {
        guard let trialID else { return values }
        return values.filter { $0.tags["trial_id"] == trialID }
    }

    private static func coherentPoints(
        _ points: [GrafanaMetricPoint]
    ) -> [GrafanaMetricPoint] {
        guard let newest = points.map(\.timestamp).max() else { return [] }
        return points.filter {
            newest.timeIntervalSince($0.timestamp)
                <= aggregateFreshnessTolerance
        }
    }

    private static func coherentReadings(
        _ readings: [String: GrafanaMetricPoint]
    ) -> [String: GrafanaMetricPoint] {
        guard let newest = readings.values.map(\.timestamp).max() else {
            return [:]
        }
        return readings.filter {
            newest.timeIntervalSince($0.value.timestamp)
                <= aggregateFreshnessTolerance
        }
    }

    private static func metric(_ metric: String, hasSuffix suffix: String) -> Bool {
        metric.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .hasSuffix(suffix)
    }

    private static func latestMemoryReadings(
        _ seriesList: [GrafanaMetricSeries],
        metricSuffixes: [String],
        targetField: String
    ) -> [String: GrafanaMetricPoint] {
        seriesList.reduce(into: [:]) { readings, series in
            let isMatch = series.targetField == targetField
                || metricSuffixes.contains {
                    metric(series.metric, hasSuffix: $0)
                }
            guard isMatch, let point = series.points.last else { return }
            let identity = series.tags.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            let key = identity.isEmpty ? series.legend : identity
            if readings[key]?.timestamp ?? .distantPast <= point.timestamp {
                readings[key] = point
            }
        }
    }

    private static func sumBytes(_ values: [Double]) -> UInt64? {
        guard !values.isEmpty else { return nil }
        var total: UInt64 = 0
        for value in values {
            guard
                value.isFinite,
                value >= 0,
                value <= Double(UInt64.max)
            else { return nil }
            let result = total.addingReportingOverflow(UInt64(value.rounded()))
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}
