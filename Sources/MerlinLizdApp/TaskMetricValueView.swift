import MerlinLizdCore
import SwiftUI

struct TaskMetricValue: View {
    let value: String
    let detail: String?
    let fraction: Double?
    let tint: Color
    let isLoading: Bool
    let helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(value)
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(tint.opacity(0.8))
                            .frame(
                                width: proxy.size.width
                                    * min(1, max(0, fraction))
                            )
                    }
                }
                .frame(height: 3)
            }
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(helpText ?? "")
    }

    static func gpu(
        _ metrics: MerlinTaskMetrics?,
        state: TaskMetricAvailability,
        isFinal: Bool
    ) -> TaskMetricValue {
        guard let utilization = metrics?.gpuUtilization else {
            return placeholder(state: state, tint: .green)
        }
        let currentLabel = isFinal ? "最后采样" : "当前"
        let averageLabel = isFinal ? "截至采样均值" : "启动均值"
        let averageDetail = metrics?.gpuAverageUtilization.map {
            "\(averageLabel) \(Int($0.rounded()))%"
        }
        return TaskMetricValue(
            value: "\(currentLabel) \(Int(utilization.rounded()))%",
            detail: averageDetail,
            fraction: utilization / 100,
            tint: utilization >= 90 ? .orange : .green,
            isLoading: false,
            helpText: metrics?.gpu.map {
                let average = $0.averageUtilization.map {
                    "，\(averageLabel) \(Int($0.rounded()))%"
                } ?? ""
                return "GPU \(currentLabel)利用率 \(Int($0.currentUtilization.rounded()))%\(average)，采样于 \($0.sampledAt.formatted(.dateTime.hour().minute().second()))"
            }
        )
    }

    static func memory(
        _ metrics: MerlinTaskMetrics?,
        state: TaskMetricAvailability,
        isFinal: Bool
    ) -> TaskMetricValue {
        guard let used = metrics?.memoryUsedBytes else {
            return placeholder(state: state, tint: .blue)
        }
        let fraction = metrics?.memoryUtilization.map { $0 / 100 }
        let value = metrics?.memoryUtilization.map {
            "\(Int($0.rounded()))%"
        } ?? TaskFormatting.bytes(used)
        let detail: String
        if let total = metrics?.memoryTotalBytes {
            detail = "\(TaskFormatting.bytes(used)) / \(TaskFormatting.bytes(total))"
        } else {
            detail = TaskFormatting.bytes(used)
        }
        return TaskMetricValue(
            value: value,
            detail: detail,
            fraction: fraction,
            tint: (metrics?.memoryUtilization ?? 0) >= 90 ? .orange : .blue,
            isLoading: false,
            helpText: metrics?.memory.map {
                let prefix = isFinal ? "任务最后一次内存采样" : "任务内存占用"
                return "\(prefix)，采样于 \($0.sampledAt.formatted(.dateTime.hour().minute().second()))"
            }
        )
    }

    private static func placeholder(
        state: TaskMetricAvailability,
        tint: Color
    ) -> TaskMetricValue {
        let value: String
        switch state {
        case .loading:
            value = "读取中"
        case .pending:
            value = "待采样"
        case .available, .unavailable:
            value = "—"
        }
        return TaskMetricValue(
            value: value,
            detail: nil,
            fraction: nil,
            tint: tint,
            isLoading: state == .loading,
            helpText: state == .unavailable
                ? "平台暂未返回可用指标"
                : nil
        )
    }
}

enum TaskMetricAvailability: Equatable {
    case loading
    case pending
    case available
    case unavailable
}
