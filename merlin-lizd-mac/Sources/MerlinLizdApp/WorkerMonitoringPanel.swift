import Charts
import MerlinLizdCore
import SwiftUI

/// App-facing state for the live Worker monitor. Sampling and retention stay
/// outside the view so switching machines does not couple UI lifetime to an
/// SSH process.
enum WorkerMonitoringPanelState {
    case unavailable(message: String)
    case loading(previous: WorkerMonitoringData? = nil)
    case loaded(WorkerMonitoringData)
    case failed(message: String, previous: WorkerMonitoringData? = nil)
}

struct WorkerMonitoringData {
    let samples: [WorkerMetricsSample]
    let updatedAt: Date

    init(samples: [WorkerMetricsSample], updatedAt: Date = .now) {
        self.samples = samples.sorted { $0.timestamp < $1.timestamp }
        self.updatedAt = updatedAt
    }
}

/// A five-minute monitoring surface designed to replace the unused lower
/// portion of `WorkerDetailView`.
struct WorkerMonitoringPanel: View {
    private let window: TimeInterval = 5 * 60

    let state: WorkerMonitoringPanelState
    let expectsGPU: Bool
    var onRetry: (() -> Void)?

    private var data: WorkerMonitoringData? {
        switch state {
        case .unavailable:
            nil
        case let .loading(previous):
            previous
        case let .loaded(data):
            data
        case let .failed(_, previous):
            previous
        }
    }

    private var visibleSamples: [WorkerMetricsSample] {
        guard let data else { return [] }
        let end = max(data.updatedAt, data.samples.last?.timestamp ?? data.updatedAt)
        let start = end.addingTimeInterval(-window)
        return data.samples.filter { $0.timestamp >= start && $0.timestamp <= end }
    }

    private var latest: WorkerMetricsSample? {
        visibleSamples.last
    }

    private var chartDomain: ClosedRange<Date> {
        let end = max(data?.updatedAt ?? .now, visibleSamples.last?.timestamp ?? .distantPast)
        return end.addingTimeInterval(-window)...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if case let .failed(message, _) = state {
                MessageBanner(text: message, kind: .error)
            }

            if let data, !data.samples.isEmpty {
                populatedContent
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("实时监控", systemImage: "chart.xyaxis.line")
                .font(.title2.bold())
            Text("最近 5 分钟")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.65), in: Capsule())
            Spacer()
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state {
        case .unavailable:
            StatusPill(label: "暂无数据", color: .secondary, symbol: "minus.circle.fill")
        case .loading:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("正在采样")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case let .loaded(data):
            HStack(spacing: 7) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: .green.opacity(0.35), radius: 3)
                Text("实时 · \(data.updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .failed:
            StatusPill(label: "采样中断", color: .orange, symbol: "exclamationmark.circle.fill")
        }
    }

    private var populatedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 135), spacing: 10),
                    count: expectsGPU ? 4 : 2
                ),
                spacing: 10
            ) {
                if expectsGPU {
                    MonitoringKPICard(
                        title: "GPU",
                        value: percent(latest?.gpuUtilization),
                        detail: gpuDetail(latest),
                        symbol: "square.stack.3d.up.fill",
                        tint: .green,
                        progress: normalized(latest?.gpuUtilization)
                    )
                    MonitoringKPICard(
                        title: "显存",
                        value: percent(latest?.gpuMemoryUtilization),
                        detail: bytePair(
                            used: latest?.gpuMemoryUsedBytes,
                            total: latest?.gpuMemoryTotalBytes
                        ),
                        symbol: "memorychip.fill",
                        tint: .mint,
                        progress: normalized(latest?.gpuMemoryUtilization)
                    )
                }
                MonitoringKPICard(
                    title: "CPU",
                    value: percent(latest?.cpuUtilization),
                    detail: "Worker 配额利用率",
                    symbol: "cpu.fill",
                    tint: .blue,
                    progress: normalized(latest?.cpuUtilization)
                )
                MonitoringKPICard(
                    title: "内存",
                    value: percent(latest?.memoryUtilization),
                    detail: bytePair(
                        used: latest?.memoryUsedBytes,
                        total: latest?.memoryTotalBytes
                    ),
                    symbol: "memorychip",
                    tint: .purple,
                    progress: normalized(latest?.memoryUtilization)
                )
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 280), spacing: 10),
                    count: 2
                ),
                spacing: 10
            ) {
                if expectsGPU {
                    MonitoringLineChartCard(
                        title: "GPU 利用率",
                        value: percent(latest?.gpuUtilization),
                        symbol: "square.stack.3d.up.fill",
                        tint: .green,
                        points: points(for: \WorkerMetricsSample.gpuUtilization),
                        domain: chartDomain
                    )
                }
                MonitoringLineChartCard(
                    title: "CPU 利用率",
                    value: percent(latest?.cpuUtilization),
                    symbol: "cpu.fill",
                    tint: .blue,
                    points: points(for: \WorkerMetricsSample.cpuUtilization),
                    domain: chartDomain
                )
                MonitoringMemoryChartCard(
                    samples: visibleSamples,
                    domain: chartDomain
                )
                if expectsGPU {
                    MonitoringLineChartCard(
                        title: "GPU 温度",
                        value: thermalValue(latest),
                        symbol: "thermometer.medium",
                        tint: .orange,
                        points: points(for: \WorkerMetricsSample.gpuTemperatureCelsius),
                        domain: chartDomain,
                        axisSuffix: "°"
                    )
                }
            }

            if visibleSamples.count == 1 {
                Label("已收到首个采样点，曲线将在下一次采样后出现", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch state {
        case let .unavailable(message):
            MonitoringPlaceholder(
                title: "暂无监控数据",
                description: message,
                symbol: "chart.xyaxis.line",
                showsProgress: false,
                actionTitle: nil,
                action: nil
            )
        case .loading, .loaded:
            MonitoringPlaceholder(
                title: "正在建立实时监控",
                description: "首次连接通常需要约 10 秒，建立后会持续更新。",
                symbol: "waveform.path.ecg",
                showsProgress: true,
                actionTitle: nil,
                action: nil
            )
        case let .failed(message, _):
            MonitoringPlaceholder(
                title: "无法读取监控数据",
                description: message,
                symbol: "exclamationmark.triangle",
                showsProgress: false,
                actionTitle: onRetry == nil ? nil : "重试",
                action: onRetry
            )
        }
    }

    private func points(
        for keyPath: KeyPath<WorkerMetricsSample, Double?>
    ) -> [MonitoringPoint] {
        visibleSamples.compactMap { sample in
            guard let value = sample[keyPath: keyPath] else { return nil }
            return MonitoringPoint(timestamp: sample.timestamp, value: clamped(value))
        }
    }
}

private struct MonitoringKPICard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    let progress: Double?

    var body: some View {
        SurfaceCard {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: proxy.size.width * (progress ?? 0))
                }
            }
            .frame(height: 5)

            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MonitoringLineChartCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    let points: [MonitoringPoint]
    let domain: ClosedRange<Date>
    var axisSuffix = "%"

    var body: some View {
        SurfaceCard {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }

            ZStack {
                Chart(points) { point in
                    AreaMark(
                        x: .value("时间", point.timestamp),
                        y: .value("利用率", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0.015)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("利用率", point.value)
                    )
                    .foregroundStyle(tint)
                    .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("时间", point.timestamp),
                        y: .value("利用率", point.value)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(points.count == 1 ? 24 : 0)
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: 0...100)
                .monitoringAxes(axisSuffix: axisSuffix)

                if points.isEmpty {
                    MonitoringChartEmptyLabel()
                }
            }
            .frame(height: 220)
        }
    }
}

private struct MonitoringMemoryChartCard: View {
    let samples: [WorkerMetricsSample]
    let domain: ClosedRange<Date>

    private var points: [MonitoringSeriesPoint] {
        samples.flatMap { sample -> [MonitoringSeriesPoint] in
            var points: [MonitoringSeriesPoint] = []
            if let value = sample.gpuMemoryUtilization {
                points.append(.init(
                    timestamp: sample.timestamp,
                    value: clamped(value),
                    series: "显存"
                ))
            }
            if let value = sample.memoryUtilization {
                points.append(.init(
                    timestamp: sample.timestamp,
                    value: clamped(value),
                    series: "内存"
                ))
            }
            return points
        }
    }

    var body: some View {
        SurfaceCard {
            HStack {
                Label("内存占用", systemImage: "memorychip.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    MonitoringLegend(color: .mint, label: "显存")
                    MonitoringLegend(color: .purple, label: "内存")
                }
            }

            ZStack {
                Chart(points) { point in
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("占用率", point.value)
                    )
                    .foregroundStyle(by: .value("类型", point.series))
                    .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("时间", point.timestamp),
                        y: .value("占用率", point.value)
                    )
                    .foregroundStyle(by: .value("类型", point.series))
                    .symbolSize(samples.count == 1 ? 24 : 0)
                }
                .chartForegroundStyleScale([
                    "显存": Color.mint,
                    "内存": Color.purple,
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: domain)
                .chartYScale(domain: 0...100)
                .monitoringAxes()

                if points.isEmpty {
                    MonitoringChartEmptyLabel()
                }
            }
            .frame(height: 220)
        }
    }
}

private struct MonitoringLegend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct MonitoringChartEmptyLabel: View {
    var body: some View {
        Label("暂无指标", systemImage: "minus.circle")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct MonitoringPlaceholder: View {
    let title: String
    let description: String
    let symbol: String
    let showsProgress: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        SurfaceCard {
            VStack(spacing: 12) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, systemImage: "arrow.clockwise", action: action)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 270)
        }
    }
}

private struct MonitoringPoint: Identifiable {
    let timestamp: Date
    let value: Double

    var id: Date { timestamp }
}

private struct MonitoringSeriesPoint: Identifiable {
    struct ID: Hashable {
        let timestamp: Date
        let series: String
    }

    let timestamp: Date
    let value: Double
    let series: String

    var id: ID { ID(timestamp: timestamp, series: series) }
}

private extension View {
    func monitoringAxes(axisSuffix: String = "%") -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text("\(number)\(axisSuffix)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(.quaternary.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private func normalized(_ value: Double?) -> Double? {
    value.map { clamped($0) / 100 }
}

private func clamped(_ value: Double) -> Double {
    min(max(value, 0), 100)
}

private func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value >= 10
        ? String(format: "%.0f%%", value)
        : String(format: "%.1f%%", value)
}

private func bytePair(used: UInt64?, total: UInt64?) -> String {
    guard let used, let total, total > 0 else { return "等待数据" }
    return "\(gibibytes(used)) / \(gibibytes(total)) GiB"
}

private func gibibytes(_ bytes: UInt64) -> String {
    let value = Double(bytes) / 1_073_741_824
    return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

private func gpuDetail(_ sample: WorkerMetricsSample?) -> String {
    guard let sample else { return "等待数据" }
    guard !sample.gpus.isEmpty else { return "未检测到 GPU" }
    var details: [String] = []
    if let temperature = sample.gpuTemperatureCelsius {
        details.append(String(format: "%.0f°C", temperature))
    }
    if let power = sample.gpuPowerWatts {
        details.append(String(format: "%.0f W", power))
    }
    return details.isEmpty ? "整卡平均利用率" : details.joined(separator: " · ")
}

private func thermalValue(_ sample: WorkerMetricsSample?) -> String {
    guard let temperature = sample?.gpuTemperatureCelsius else { return "—" }
    let temperatureText = String(format: "%.0f°C", temperature)
    guard let power = sample?.gpuPowerWatts else { return temperatureText }
    return "\(temperatureText) · \(String(format: "%.0f W", power))"
}
