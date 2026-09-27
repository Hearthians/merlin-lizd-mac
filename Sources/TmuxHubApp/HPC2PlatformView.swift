import SwiftUI
import TmuxHubCore

struct HPC2PlatformView: View {
    @ObservedObject var model: HPC2PlatformModel
    let onConnect: (SlurmLaunchReceipt) -> Void
    let onOpenLoginShell: () -> Void

    @State private var selectedList: JobList = .current
    @State private var showsStartSheet = false
    @State private var pendingCancellation: SlurmManagedJob?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                connectionBanner
                metrics
                listPicker
                if selectedList == .current {
                    currentJobs
                } else {
                    history
                }
            }
            .padding(24)
            .frame(maxWidth: 1_080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: model.profile.id) {
            await model.refreshContinuously()
        }
        .sheet(isPresented: $showsStartSheet) {
            HPC2StartSheet(
                initialProfile: model.profile,
                initialPreset: model.defaultPreset
            ) { profile, preset in
                await model.start(profile: profile, preset: preset)
            }
        }
        .alert(
            "取消 Slurm 任务？",
            isPresented: Binding(
                get: { pendingCancellation != nil },
                set: { if !$0 { pendingCancellation = nil } }
            ),
            presenting: pendingCancellation
        ) { job in
            Button("取消任务并释放资源", role: .destructive) {
                pendingCancellation = nil
                Task { await model.cancel(job) }
            }
            Button("保留任务", role: .cancel) {
                pendingCancellation = nil
            }
        } message: { job in
            Text("将取消作业 \(job.snapshot.jobID.rawValue)。关闭终端不会执行这个操作。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("HKUST HPC2")
                    .font(.largeTitle.bold())
                Text("通过 \(model.profile.loginDestination) 管理 Slurm 交互任务")
                    .foregroundStyle(.secondary)
                Text("集群用户：\(model.profile.owner)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("登录 Shell", systemImage: "terminal", action: onOpenLoginShell)
                .buttonStyle(.bordered)
                .controlSize(.large)
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await model.refresh(force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isRefreshing)
            Button("启动交互环境", systemImage: "play.fill") {
                showsStartSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isStarting)
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        switch model.connectionState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取 Slurm 任务…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .ready(date):
            HStack(spacing: 8) {
                StatusPill(label: "已连接", color: .green, symbol: "checkmark.circle.fill")
                Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
        case let .stale(date, message):
            VStack(alignment: .leading, spacing: 8) {
                MessageBanner(
                    text: date == nil
                        ? message
                        : "暂时无法刷新，仍显示上次成功读取的数据。\n\(message)",
                    kind: .warning
                )
                HStack {
                    Button("重试") { Task { await model.refresh(force: true) } }
                    Button("打开登录 Shell", action: onOpenLoginShell)
                }
                .buttonStyle(.bordered)
            }
        }

        if let notice = model.notice {
            HStack(alignment: .top, spacing: 8) {
                MessageBanner(text: notice, kind: .info)
                Button {
                    model.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metricCard(
                title: "运行中",
                value: model.runningJobCount,
                symbol: "play.circle.fill",
                tint: .green
            )
            metricCard(
                title: "排队中",
                value: model.pendingJobCount + model.unresolvedRuns.count,
                symbol: "clock.fill",
                tint: .orange
            )
            metricCard(
                title: "当前任务",
                value: model.activeJobs.count + model.unresolvedRuns.count,
                symbol: "square.stack.3d.up.fill",
                tint: .blue
            )
        }
    }

    private var listPicker: some View {
        Picker("任务范围", selection: $selectedList) {
            ForEach(JobList.allCases) { list in
                Text(list.title).tag(list)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var currentJobs: some View {
        let jobs = model.activeJobs
        let unresolved = model.unresolvedRuns
        if jobs.isEmpty, unresolved.isEmpty, !model.isRefreshing {
            ContentUnavailableView(
                "当前没有 Slurm 任务",
                systemImage: "cpu",
                description: Text("启动一个交互环境，或在登录节点提交任务后刷新。")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(unresolved) { run in
                    unresolvedRow(run)
                }
                ForEach(jobs) { job in
                    jobRow(job)
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        if model.historyRuns.isEmpty {
            ContentUnavailableView(
                "还没有 TmuxHub 任务记录",
                systemImage: "clock.arrow.circlepath",
                description: Text("任务离开活动队列后会保留最近一次状态。")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(model.historyRuns) { run in
                    historyRow(run)
                }
            }
        }
    }

    private func jobRow(_ job: SlurmJobSnapshot) -> some View {
        let run = model.run(for: job)
        return SurfaceCard {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(run?.preset.name ?? job.name)
                            .font(.headline)
                        StatusPill(
                            label: job.state.hpc2Title,
                            color: job.state.hpc2Color,
                            symbol: job.state.hpc2Symbol
                        )
                        if run == nil {
                            StatusPill(label: "外部任务 · 只读", color: .secondary, symbol: "eye")
                        }
                    }
                    Text("Job \(job.jobID.rawValue) · \(job.partition)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        MetricPill(symbol: "clock", value: "\(job.elapsed) / \(job.timeLimit)")
                        MetricPill(symbol: "square.stack.3d.up", value: "\(job.nodeCount) 节点")
                        if let nodeList = job.nodeList {
                            MetricPill(symbol: "server.rack", value: nodeList)
                        }
                    }
                    if job.state == .pending, !job.reasonOrNodeList.isEmpty {
                        Text("等待原因：\(job.reasonOrNodeList)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if let run {
                    Button("连接", systemImage: "terminal") {
                        onConnect(run.receipt)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("取消任务…", role: .destructive) {
                        pendingCancellation = SlurmManagedJob(
                            receipt: run.receipt,
                            snapshot: job
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCancelling(run.receipt))
                }
            }
        }
    }

    private func unresolvedRow(_ run: HPC2ManagedRunRecord) -> some View {
        SurfaceCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(run.preset.name).font(.headline)
                        StatusPill(
                            label: run.phase.hpc2Title,
                            color: run.phase.hpc2Color,
                            symbol: "clock.arrow.circlepath"
                        )
                    }
                    Text(run.receipt.jobName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(run.phase == .launchOutcomeUnknown
                        ? "启动结果仍在核对，TmuxHub 不会重复提交。"
                        : "正在等待 Slurm 分配 Job ID。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看终端", systemImage: "terminal") {
                    onConnect(run.receipt)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func historyRow(_ run: HPC2ManagedRunRecord) -> some View {
        SurfaceCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(run.preset.name).font(.headline)
                        StatusPill(
                            label: historyStatusTitle(run),
                            color: historyStatusColor(run),
                            symbol: "clock.arrow.circlepath"
                        )
                    }
                    Text(run.snapshot.map { "Job \($0.jobID.rawValue)" }
                        ?? run.receipt.jobName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(run.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if run.phase != .launchFailed, run.phase != .notFound {
                    Button("查看终端", systemImage: "terminal") {
                        onConnect(run.receipt)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func metricCard(
        title: String,
        value: Int,
        symbol: String,
        tint: Color
    ) -> some View {
        SurfaceCard {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(tint)
                Spacer()
                Text("\(value)")
                    .font(.title2.bold().monospacedDigit())
            }
        }
    }

    private func historyStatusTitle(_ run: HPC2ManagedRunRecord) -> String {
        switch run.phase {
        case .leftQueue, .launchFailed, .notFound, .cancellationRequested:
            run.phase.hpc2Title
        default:
            run.snapshot?.state.hpc2Title ?? run.phase.hpc2Title
        }
    }

    private func historyStatusColor(_ run: HPC2ManagedRunRecord) -> Color {
        switch run.phase {
        case .leftQueue, .launchFailed, .notFound, .cancellationRequested:
            run.phase.hpc2Color
        default:
            run.snapshot?.state.hpc2Color ?? run.phase.hpc2Color
        }
    }
}

private enum JobList: String, CaseIterable, Identifiable {
    case current
    case history

    var id: String { rawValue }
    var title: String { self == .current ? "当前任务" : "历史" }
}

private extension SlurmJobState {
    var hpc2Title: String {
        switch self {
        case .pending: "排队中"
        case .running: "运行中"
        case .completing: "结束中"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .failed: "失败"
        case .timeout: "超时"
        case .nodeFailure: "节点故障"
        case .outOfMemory: "内存不足"
        case .preempted: "被抢占"
        case .suspended: "已暂停"
        case let .unknown(value): value.isEmpty ? "未知" : value
        }
    }

    var hpc2Color: Color {
        switch self {
        case .running: .green
        case .pending, .suspended: .orange
        case .completing: .blue
        case .completed: .secondary
        case .cancelled: .secondary
        case .failed, .timeout, .nodeFailure, .outOfMemory, .preempted: .red
        case .unknown: .secondary
        }
    }

    var hpc2Symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .pending: "clock.fill"
        case .completing: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .suspended: "pause.circle.fill"
        case .failed, .timeout, .nodeFailure, .outOfMemory, .preempted:
            "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

private extension HPC2ManagedRunPhase {
    var hpc2Title: String {
        switch self {
        case .submitting: "正在提交"
        case .awaitingScheduler: "等待确认"
        case .active: "活动中"
        case .cancellationRequested: "取消中"
        case .leftQueue: "已离开队列"
        case .launchOutcomeUnknown: "结果待确认"
        case .launchFailed: "启动失败"
        case .notFound: "未找到任务"
        }
    }

    var hpc2Color: Color {
        switch self {
        case .submitting, .awaitingScheduler: .orange
        case .active: .green
        case .cancellationRequested: .blue
        case .leftQueue: .secondary
        case .launchOutcomeUnknown: .orange
        case .launchFailed, .notFound: .red
        }
    }
}
