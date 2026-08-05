import MerlinLizdCore
import SwiftUI

struct TaskLifecycleView: View {
    let state: TaskPageState
    let onBrowseTmux: (TerminalTarget) -> Void

    @ViewBuilder
    var body: some View {
        switch state.content {
        case .loading:
            ProgressView("同步任务…")
        case .unavailable:
            ContentUnavailableView(
                "无法同步任务",
                systemImage: "exclamationmark.triangle",
                description: Text("请检查 Merlin CLI 登录状态与网络连接。")
            )
        case let .loaded(snapshot, refreshFailed):
            taskContent(snapshot: snapshot, refreshFailed: refreshFailed)
        }
    }

    private func taskContent(
        snapshot: MerlinTaskSnapshot,
        refreshFailed: Bool
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    pageHeader(snapshot: snapshot)

                    if refreshFailed {
                        MessageBanner(
                            text: "任务同步暂时失败，正在显示上一次成功结果。",
                            kind: .warning
                        )
                    }

                    lifecycleSection(
                        .active,
                        snapshot: snapshot,
                        now: context.date
                    )
                    lifecycleSection(
                        .failed,
                        snapshot: snapshot,
                        now: context.date
                    )
                    lifecycleSection(
                        .finished,
                        snapshot: snapshot,
                        now: context.date
                    )
                }
                .frame(maxWidth: 1_440, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func pageHeader(snapshot: MerlinTaskSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("任务")
                    .font(.largeTitle.bold())
                Text("当前账号创建的训练与数据处理任务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                if state.isRefreshingMetrics {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("更新指标")
                    }
                    .foregroundStyle(.secondary)
                }
                Label {
                    Text(
                        snapshot.refreshedAt,
                        format: .dateTime.hour().minute().second()
                    )
                    .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                .foregroundStyle(.secondary)
                .help("任务状态最近更新时间")
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func lifecycleSection(
        _ lifecycle: MerlinTaskLifecycle,
        snapshot: MerlinTaskSnapshot,
        now: Date
    ) -> some View {
        let runs = snapshot.runs(in: lifecycle)
        let presentation = lifecycle.presentation
        SurfaceCard {
            TaskSectionHeader(lifecycle: lifecycle, count: runs.count)

            if runs.isEmpty {
                Text(presentation.emptyText)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 42,
                        alignment: .leading
                    )
            } else {
                ViewThatFits(in: .horizontal) {
                    wideSection(runs: runs, now: now)
                        .frame(minWidth: 1_080)
                    compactSection(runs: runs, now: now)
                }
            }
        }
    }

    private func wideSection(
        runs: [MerlinTaskRun],
        now: Date
    ) -> some View {
        VStack(spacing: 0) {
            TaskColumnHeader()
                .padding(.bottom, 7)
            Divider()
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    Divider()
                }
                TaskWideRow(
                    run: run,
                    metrics: state.metricsByRunID[run.id],
                    cpuMetricState: state.cpuMetricAvailability(for: run),
                    gpuMetricState: state.gpuMetricAvailability(for: run),
                    memoryMetricState: state.memoryMetricAvailability(for: run),
                    now: now,
                    onBrowseTmux: onBrowseTmux
                )
            }
        }
    }

    private func compactSection(
        runs: [MerlinTaskRun],
        now: Date
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    Divider()
                }
                TaskCompactRow(
                    run: run,
                    metrics: state.metricsByRunID[run.id],
                    cpuMetricState: state.cpuMetricAvailability(for: run),
                    gpuMetricState: state.gpuMetricAvailability(for: run),
                    memoryMetricState: state.memoryMetricAvailability(for: run),
                    now: now,
                    onBrowseTmux: onBrowseTmux
                )
            }
        }
    }
}
