import MerlinLizdCore
import SwiftUI

struct TaskSectionHeader: View {
    let lifecycle: MerlinTaskLifecycle
    let count: Int

    var body: some View {
        let presentation = lifecycle.presentation
        HStack(spacing: 9) {
            Image(systemName: presentation.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .frame(width: 18)
            Text(presentation.title)
                .font(.title3.weight(.semibold))
            Text(count.formatted())
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.8), in: Capsule())
            Spacer()
        }
    }
}

struct TaskColumnHeader: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("任务")
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            Text("状态")
                .frame(width: 92, alignment: .leading)
            Text("启动时间")
                .frame(width: 126, alignment: .leading)
            Text("运行时长")
                .frame(width: 104, alignment: .leading)
            Text("CPU")
                .frame(width: 164, alignment: .leading)
            Text("GPU")
                .frame(width: 126, alignment: .leading)
            Text("内存")
                .frame(width: 164, alignment: .leading)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
    }
}

struct TaskWideRow: View {
    let run: MerlinTaskRun
    let metrics: MerlinTaskMetrics?
    let cpuMetricState: TaskMetricAvailability
    let gpuMetricState: TaskMetricAvailability
    let memoryMetricState: TaskMetricAvailability
    let now: Date

    var body: some View {
        HStack(spacing: 16) {
            TaskIdentity(run: run)
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            TaskStatusPill(status: run.status)
                .frame(width: 92, alignment: .leading)
            TaskTimeValue(run: run)
                .frame(width: 126, alignment: .leading)
            Text(TaskFormatting.runtime(run.runtimeSeconds(at: now), run: run))
                .font(.callout.monospacedDigit())
                .foregroundStyle(
                    run.startedAtMilliseconds == nil ? .secondary : .primary
                )
                .frame(width: 104, alignment: .leading)
            TaskMetricValue.cpu(
                metrics,
                state: cpuMetricState,
                isFinal: run.lifecycle != .active
            )
            .frame(width: 164, alignment: .leading)
            TaskMetricValue.gpu(
                metrics,
                state: gpuMetricState,
                isFinal: run.lifecycle != .active
            )
            .frame(width: 126, alignment: .leading)
            TaskMetricValue.memory(
                metrics,
                state: memoryMetricState,
                isFinal: run.lifecycle != .active
            )
            .frame(width: 164, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

struct TaskCompactRow: View {
    let run: MerlinTaskRun
    let metrics: MerlinTaskMetrics?
    let cpuMetricState: TaskMetricAvailability
    let gpuMetricState: TaskMetricAvailability
    let memoryMetricState: TaskMetricAvailability
    let now: Date

    private let columns = [
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.flexible(minimum: 120), alignment: .leading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TaskIdentity(run: run)
                Spacer(minLength: 8)
                TaskStatusPill(status: run.status)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                CompactField("启动时间") {
                    TaskTimeValue(run: run)
                }
                CompactField("运行时长") {
                    Text(TaskFormatting.runtime(
                        run.runtimeSeconds(at: now),
                        run: run
                    ))
                    .font(.callout.monospacedDigit())
                }
                CompactField("CPU") {
                    TaskMetricValue.cpu(
                        metrics,
                        state: cpuMetricState,
                        isFinal: run.lifecycle != .active
                    )
                }
                CompactField("GPU") {
                    TaskMetricValue.gpu(
                        metrics,
                        state: gpuMetricState,
                        isFinal: run.lifecycle != .active
                    )
                }
                CompactField("内存") {
                    TaskMetricValue.memory(
                        metrics,
                        state: memoryMetricState,
                        isFinal: run.lifecycle != .active
                    )
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

private struct TaskIdentity: View {
    let run: MerlinTaskRun

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(run.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(run.name)\n任务 ID：\(run.id)")

            HStack(spacing: 6) {
                if let presentation = run.clusterPresentation {
                    ClusterBadgeView(presentation: presentation)
                }
                if run.status == .running {
                    TaskSSHCopyButton(runID: run.id)
                }
            }
        }
    }
}

private struct TaskStatusPill: View {
    let status: MerlinTaskStatus

    var body: some View {
        let presentation = status.presentation
        StatusPill(
            label: presentation.title,
            color: presentation.tint,
            symbol: presentation.symbol
        )
        .fixedSize()
    }
}

private struct TaskTimeValue: View {
    let run: MerlinTaskRun

    var body: some View {
        if let milliseconds = run.startedAtMilliseconds {
            let date = Date(
                timeIntervalSince1970: Double(milliseconds) / 1_000
            )
            Text(TaskFormatting.startTime(date))
                .font(.callout.monospacedDigit())
                .help(date.formatted(
                    .dateTime.year().month().day().hour().minute().second()
                ))
        } else {
            Text(run.status == .queued ? "尚未启动" : "—")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CompactField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
