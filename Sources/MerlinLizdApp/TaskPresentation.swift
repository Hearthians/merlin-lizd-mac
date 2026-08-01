import MerlinLizdCore
import SwiftUI

enum TaskFormatting {
    static func startTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(
            .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
        )
    }

    static func runtime(
        _ seconds: TimeInterval?,
        run: MerlinTaskRun
    ) -> String {
        guard let seconds else {
            switch run.status {
            case .queued:
                return "等待启动"
            case .started:
                return "启动中"
            default:
                return "—"
            }
        }
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let remainingSeconds = whole % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .memory
        )
    }
}

struct TaskLifecyclePresentation {
    let title: String
    let emptyText: String
    let symbol: String
    let tint: Color
}

extension MerlinTaskLifecycle {
    var presentation: TaskLifecyclePresentation {
        switch self {
        case .active:
            TaskLifecyclePresentation(
                title: "进行中",
                emptyText: "暂无进行中的任务",
                symbol: "play.circle.fill",
                tint: .green
            )
        case .failed:
            TaskLifecyclePresentation(
                title: "失败",
                emptyText: "暂无失败任务",
                symbol: "xmark.circle.fill",
                tint: .red
            )
        case .finished:
            TaskLifecyclePresentation(
                title: "已结束",
                emptyText: "暂无已结束任务",
                symbol: "checkmark.circle.fill",
                tint: .secondary
            )
        }
    }
}

struct TaskStatusPresentation {
    let title: String
    let symbol: String
    let tint: Color
}

extension MerlinTaskStatus {
    var presentation: TaskStatusPresentation {
        switch self {
        case .queued:
            TaskStatusPresentation(
                title: "排队中",
                symbol: "clock.fill",
                tint: .orange
            )
        case .started:
            TaskStatusPresentation(
                title: "启动中",
                symbol: "hourglass",
                tint: .blue
            )
        case .running:
            TaskStatusPresentation(
                title: "运行中",
                symbol: "circle.fill",
                tint: .green
            )
        case .failed:
            TaskStatusPresentation(
                title: "失败",
                symbol: "xmark.circle.fill",
                tint: .red
            )
        case .done:
            TaskStatusPresentation(
                title: "已完成",
                symbol: "checkmark.circle.fill",
                tint: .secondary
            )
        case .stopped:
            TaskStatusPresentation(
                title: "已停止",
                symbol: "stop.circle.fill",
                tint: .secondary
            )
        case .disabled:
            TaskStatusPresentation(
                title: "已禁用",
                symbol: "minus.circle.fill",
                tint: .secondary
            )
        case .killed:
            TaskStatusPresentation(
                title: "已终止",
                symbol: "bolt.slash.fill",
                tint: .orange
            )
        }
    }
}
