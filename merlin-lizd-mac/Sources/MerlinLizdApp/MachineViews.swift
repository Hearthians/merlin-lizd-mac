import MerlinLizdCore
import SwiftUI

struct OverviewView: View {
    let snapshot: InventorySnapshot?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onConnectDevbox: (DevboxInventory) -> Void

    private var devboxes: [DevboxInventory] { snapshot?.devboxes ?? [] }
    private var workers: [WorkerInventoryRecord] { devboxes.flatMap(\.workers) }
    private var hasPendingWorkerInventory: Bool {
        devboxes.contains(where: workerInventoryIsPending)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("机器总览")
                            .font(.largeTitle.bold())
                        Text("开发机、工作机与连接状态")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }

                HStack(spacing: 12) {
                    SummaryTile(
                        title: "开发机",
                        value: "\(devboxes.count)",
                        detail: "\(devboxes.filter { $0.devbox.status.isRunning }.count) 台运行中",
                        symbol: "server.rack",
                        tint: .blue
                    )
                    SummaryTile(
                        title: "工作机",
                        value: hasPendingWorkerInventory
                            ? (workers.isEmpty ? "…" : "\(workers.count)+")
                            : "\(workers.count)",
                        detail: hasPendingWorkerInventory ? "后台更新中" : "跨开发机汇总",
                        symbol: "cpu",
                        tint: .purple
                    )
                    SummaryTile(
                        title: "GPU",
                        value: hasPendingWorkerInventory
                            ? "…"
                            : "\(workers.reduce(0) { $0 + $1.gpuCount })",
                        detail: hasPendingWorkerInventory ? "后台更新中" : "当前已列出的卡数",
                        symbol: "square.stack.3d.up.fill",
                        tint: .green
                    )
                }

                if devboxes.isEmpty {
                    ContentUnavailableView {
                        Label("暂无机器数据", systemImage: "server.rack")
                    } description: {
                        Text(isRefreshing ? "正在从 Merlin 获取状态…" : "刷新后会在这里显示你的开发机。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    Text("开发机")
                        .font(.title2.bold())

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 290), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(devboxes) { machine in
                            DevboxCard(machine: machine) {
                                onConnectDevbox(machine)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        SurfaceCard {
            HStack {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Spacer()
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct DevboxCard: View {
    let machine: DevboxInventory
    let onConnect: () -> Void

    var body: some View {
        SurfaceCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine.sshAlias ?? machine.devbox.name)
                        .font(.headline)
                    if machine.sshAlias != nil {
                        Text(machine.devbox.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                LifecyclePill(status: machine.devbox.status)
            }

            HStack(spacing: 6) {
                if let cpu = machine.devbox.cpuCores {
                    MetricPill(symbol: "cpu", value: "\(cpu) CPU")
                }
                if let memory = machine.devbox.memoryBytes {
                    MetricPill(symbol: "memorychip", value: formatGiB(memory))
                }
                MetricPill(symbol: "shippingbox", value: workerCountLabel(machine))
            }

            HStack {
                Text(machine.devbox.sid)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("连接", systemImage: "terminal", action: onConnect)
                    .buttonStyle(.bordered)
                    .disabled(!machine.devbox.status.isRunning || machine.sshAlias == nil)
            }
        }
    }
}

struct DevboxDetailView: View {
    let machine: DevboxInventory
    let onConnect: () -> Void
    let onBrowseSessions: () -> Void
    let onStart: () -> Void
    let onConnectWorker: (WorkerInventoryRecord) -> Void

    var body: some View {
        let workerStatus = workerStatusPresentation(machine)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(machine.sshAlias ?? machine.devbox.name)
                            .font(.largeTitle.bold())
                        Text("\(machine.devbox.name) · \(machine.devbox.sid)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    LifecyclePill(status: machine.devbox.status)
                }

                HStack(spacing: 8) {
                    if machine.devbox.status.isRunning {
                        Button("打开终端", systemImage: "terminal", action: onConnect)
                            .buttonStyle(.borderedProminent)
                            .disabled(machine.sshAlias == nil)
                        Button("tmux 会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                            .buttonStyle(.bordered)
                            .disabled(machine.sshAlias == nil)
                    } else if machine.devbox.status.isStopped {
                        Button("启动开发机", systemImage: "play.fill", action: onStart)
                            .buttonStyle(.borderedProminent)
                    }
                    if machine.sshAlias == nil {
                        StatusPill(label: "未匹配 SSH alias", color: .orange, symbol: "link.badge.plus")
                    }
                }

                SurfaceCard("资源") {
                    HStack(spacing: 8) {
                        if let cpu = machine.devbox.cpuCores {
                            MetricPill(symbol: "cpu", value: "\(cpu) CPU", tint: .blue)
                        }
                        if let memory = machine.devbox.memoryBytes {
                            MetricPill(symbol: "memorychip", value: formatGiB(memory), tint: .purple)
                        }
                        if let disk = machine.devbox.diskBytes {
                            MetricPill(symbol: "internaldrive", value: formatGiB(disk), tint: .orange)
                        }
                    }
                }

                HStack {
                    Text("工作机")
                        .font(.title2.bold())
                    Spacer()
                    Text(workerStatus.summary)
                        .font(.caption)
                        .foregroundStyle(workerStatus.isFailure ? .red : .secondary)
                }

                if let detail = workerStatus.detail {
                    MessageBanner(text: detail, kind: .error)
                }

                if machine.workers.isEmpty {
                    SurfaceCard {
                        Text(emptyWorkerMessage(machine))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(machine.workers) { worker in
                            WorkerRow(
                                worker: worker,
                                isConnectable: machine.devbox.status.isRunning
                                    && machine.sshAlias != nil
                            ) {
                                onConnectWorker(worker)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct AllWorkersView: View {
    let devboxes: [DevboxInventory]
    let onConnect: (DevboxInventory, WorkerInventoryRecord) -> Void

    private var rows: [(DevboxInventory, WorkerInventoryRecord)] {
        devboxes.flatMap { devbox in devbox.workers.map { (devbox, $0) } }
    }

    private var pendingDevboxCount: Int {
        devboxes.filter(workerInventoryIsPending).count
    }

    private var failedDevboxCount: Int {
        devboxes.filter { workerStatusPresentation($0).isFailure }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("全部工作机")
                    .font(.largeTitle.bold())
                Text("跨开发机查看 GPU 与资源配置")
                    .foregroundStyle(.secondary)

                if pendingDevboxCount > 0 {
                    MessageBanner(
                        text: "还有 \(pendingDevboxCount) 台开发机正在后台查询 Worker；现有结果可先使用。",
                        kind: .info
                    )
                }

                if failedDevboxCount > 0 {
                    MessageBanner(
                        text: "\(failedDevboxCount) 台开发机的 Worker 查询失败；其他开发机的结果仍可使用。",
                        kind: .error
                    )
                }

                if rows.isEmpty {
                    ContentUnavailableView(
                        pendingDevboxCount > 0
                            ? "正在查询工作机"
                            : (failedDevboxCount > 0 ? "工作机查询失败" : "暂无工作机"),
                        systemImage: "cpu",
                        description: Text(
                            pendingDevboxCount > 0
                                ? "开发机已显示，Worker 列表正在后台更新。"
                                : (failedDevboxCount > 0
                                    ? "暂时没有可显示的结果；请检查对应开发机的连接状态后刷新。"
                                    : "运行中的开发机刷新成功后，工作机会显示在这里。")
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(rows, id: \.1.id) { devbox, worker in
                        WorkerRow(
                            worker: worker,
                            parentLabel: devbox.sshAlias ?? devbox.devbox.name,
                            isConnectable: devbox.devbox.status.isRunning
                                && devbox.sshAlias != nil
                        ) {
                            onConnect(devbox, worker)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct WorkerDetailView: View {
    let machine: DevboxInventory
    let worker: WorkerInventoryRecord
    let onConnect: () -> Void
    let onBrowseSessions: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workerDisplayName(worker))
                            .font(.largeTitle.bold())
                        Text("\(machine.sshAlias ?? machine.devbox.name) · \(worker.id)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        WorkerPlatformStatusPill(status: worker.platformStatus)
                        ReadinessPill(readiness: worker.readiness)
                    }
                }

                HStack {
                    Button("打开 tmux 终端", systemImage: "terminal", action: onConnect)
                        .buttonStyle(.borderedProminent)
                    Button("现有会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                        .buttonStyle(.bordered)
                }
                .disabled(machine.sshAlias == nil || !machine.devbox.status.isRunning)

                if machine.sshAlias == nil {
                    MessageBanner(
                        text: "Merlin 平台状态与监控仍可使用；未匹配 SSH alias，因此终端与 tmux 暂不可用。",
                        kind: .info
                    )
                }

                if worker.readiness == .listed {
                    MessageBanner(
                        text: "Worker 列表已显示；就绪状态会在后台探测，不会阻塞机器刷新。",
                        kind: .info
                    )
                } else if worker.readiness == .probing {
                    MessageBanner(
                        text: "正在后台验证 Worker 是否可连接；你仍可直接尝试打开终端。",
                        kind: .info
                    )
                }

                SurfaceCard("资源") {
                    HStack(spacing: 8) {
                        MetricPill(symbol: "cpu", value: "\(worker.cpuCores) CPU", tint: .blue)
                        MetricPill(symbol: "memorychip", value: "\(worker.memoryGiB) GiB", tint: .purple)
                        if worker.gpuCount > 0 {
                            MetricPill(
                                symbol: "square.stack.3d.up",
                                value: "\(worker.gpuCount) × \(worker.gpuType ?? "GPU")",
                                tint: .green
                            )
                        }
                    }
                }

                WorkerMonitoringContainer(
                    platformTarget: platformMonitoringTarget,
                    directTarget: directMonitoringTarget,
                    expectsGPU: worker.gpuCount > 0,
                    unavailableMessage: monitoringUnavailableMessage
                )
                .id(platformMonitoringTarget)
            }
            .padding(24)
        }
    }

    private var platformMonitoringTarget: MerlinPlatformMetricsTarget? {
        guard machine.devbox.status.isRunning else { return nil }
        return MerlinPlatformMetricsTarget(
            devboxSID: machine.devbox.sid,
            workerID: worker.id
        )
    }

    private var directMonitoringTarget: TerminalTarget? {
        guard
            machine.devbox.status.isRunning,
            let alias = machine.sshAlias,
            platformAllowsDirectMonitoring,
            worker.readiness != .notReady,
            worker.readiness != .unreachable
        else {
            return nil
        }
        return .worker(
            devboxSID: machine.devbox.sid,
            devboxName: machine.devbox.name,
            alias: alias,
            workerID: worker.id
        )
    }

    private var platformAllowsDirectMonitoring: Bool {
        guard let status = worker.platformStatus?.lowercased() else {
            return true
        }
        return status == "running" || status == "ready"
    }

    private var monitoringUnavailableMessage: String {
        if !machine.devbox.status.isRunning {
            return "开发机未运行，无法读取 Worker 指标。"
        }
        if platformMonitoringTarget == nil {
            return "Worker 标识无效，无法请求 Merlin 平台指标。"
        }
        return "Merlin 平台暂时无法读取该 Worker 的指标。"
    }
}

struct WorkerRow: View {
    let worker: WorkerInventoryRecord
    var parentLabel: String?
    var isConnectable = true
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: worker.gpuCount > 0 ? "square.stack.3d.up.fill" : "cpu")
                .font(.title3)
                .foregroundStyle(worker.gpuCount > 0 ? .green : .blue)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(workerDisplayName(worker))
                    .font(.headline)
                Text([parentLabel, worker.id].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            MetricPill(symbol: "cpu", value: "\(worker.cpuCores)")
            MetricPill(symbol: "memorychip", value: "\(worker.memoryGiB) GiB")
            if worker.gpuCount > 0 {
                MetricPill(symbol: "square.stack.3d.up", value: "\(worker.gpuCount) GPU", tint: .green)
            }
            WorkerPlatformStatusPill(status: worker.platformStatus)
            ReadinessPill(readiness: worker.readiness)
            Button("连接", systemImage: "terminal", action: onConnect)
                .buttonStyle(.bordered)
                .disabled(!isConnectable)
                .help(isConnectable ? "打开 Worker 终端" : "开发机未运行或未匹配 SSH alias")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}

struct LifecyclePill: View {
    let status: DevboxLifecycle

    var body: some View {
        if status == .running {
            StatusPill(label: "运行中", color: .green)
        } else if status == .stopped {
            StatusPill(label: "已停止", color: .secondary, symbol: "stop.circle.fill")
        } else if status == .starting {
            StatusPill(label: "启动中", color: .orange, symbol: "clock.fill")
        } else if status == .stopping {
            StatusPill(label: "停止中", color: .orange, symbol: "clock.fill")
        } else {
            StatusPill(
                label: status.rawValue,
                color: .secondary,
                symbol: "questionmark.circle.fill"
            )
        }
    }
}

struct ReadinessPill: View {
    let readiness: WorkerReadiness

    var body: some View {
        switch readiness {
        case .listed: StatusPill(label: "待探测", color: .secondary, symbol: "questionmark.circle.fill")
        case .probing: StatusPill(label: "探测中", color: .orange, symbol: "clock.fill")
        case .ready: StatusPill(label: "就绪", color: .green)
        case .notReady: StatusPill(label: "未就绪", color: .orange, symbol: "exclamationmark.circle.fill")
        case .unreachable: StatusPill(label: "不可达", color: .red, symbol: "xmark.circle.fill")
        }
    }
}

struct WorkerPlatformStatusPill: View {
    let status: String?

    @ViewBuilder
    var body: some View {
        if let status, !status.isEmpty {
            let normalized = status.lowercased()
            if normalized == "running" {
                StatusPill(label: "平台运行中", color: .green)
            } else if normalized == "pending" || normalized == "starting" {
                StatusPill(label: "平台准备中", color: .orange, symbol: "clock.fill")
            } else if normalized == "stopped" || normalized == "terminated" {
                StatusPill(label: "平台已停止", color: .secondary, symbol: "stop.circle.fill")
            } else {
                StatusPill(
                    label: "平台 \(status)",
                    color: .secondary,
                    symbol: "circle.fill"
                )
            }
        }
    }
}

private func workerDisplayName(_ worker: WorkerInventoryRecord) -> String {
    worker.gpuType ?? (worker.gpuCount > 0 ? "GPU Worker" : "CPU Worker")
}

private func formatGiB(_ bytes: Int64) -> String {
    let gibibytes = Double(bytes) / 1_073_741_824
    return gibibytes.rounded() == gibibytes
        ? "\(Int(gibibytes)) GiB"
        : String(format: "%.1f GiB", gibibytes)
}

private struct WorkerStatusPresentation {
    let summary: String
    let detail: String?
    let isFailure: Bool
}

private func workerStatusPresentation(
    _ machine: DevboxInventory
) -> WorkerStatusPresentation {
    guard machine.devbox.status.isRunning else {
        return WorkerStatusPresentation(
            summary: "开发机未运行",
            detail: nil,
            isFailure: false
        )
    }
    return switch machine.workerStatus {
    case .notQueried:
        WorkerStatusPresentation(summary: "后台查询中", detail: nil, isFailure: false)
    case .loaded:
        WorkerStatusPresentation(summary: "已刷新", detail: nil, isFailure: false)
    case .failed(.transport):
        WorkerStatusPresentation(
            summary: "Worker 查询不可用",
            detail: "Merlin CLI 与可用的 SSH 降级通道均未能刷新工作机；当前保留上次结果。",
            isFailure: true
        )
    case let .failed(.commandFailed(exitCode)):
        WorkerStatusPresentation(
            summary: "命令失败（退出码 \(exitCode)）",
            detail: "Merlin Worker 查询失败（退出码 \(exitCode)）；当前保留上次结果。",
            isFailure: true
        )
    case .failed(.malformedOutput):
        WorkerStatusPresentation(
            summary: "输出格式异常",
            detail: "无法识别 Merlin Worker 返回；为避免误报，当前未将结果显示为 0 台工作机。",
            isFailure: true
        )
    }
}

private func workerCountLabel(_ machine: DevboxInventory) -> String {
    if workerInventoryIsPending(machine) {
        "Worker 查询中"
    } else {
        "\(machine.workers.count) Workers"
    }
}

private func emptyWorkerMessage(_ machine: DevboxInventory) -> String {
    guard machine.devbox.status.isRunning else {
        return "开发机未运行，无法查询工作机。"
    }
    return switch machine.workerStatus {
    case .notQueried:
        "Worker 列表正在后台查询…"
    case .loaded:
        "当前没有工作机"
    case .failed:
        "Worker 列表查询失败，暂无可显示结果。"
    }
}

private func workerInventoryIsPending(_ machine: DevboxInventory) -> Bool {
    machine.devbox.status.isRunning
        && machine.workerStatus == .notQueried
}
