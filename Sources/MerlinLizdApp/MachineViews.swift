import MerlinLizdCore
import SwiftUI

struct OverviewView: View {
    let snapshot: InventorySnapshot?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onConnectDevbox: (DevboxInventory) -> Void

    private var devboxes: [DevboxInventory] { snapshot?.devboxes ?? [] }
    private var workers: [WorkerInventoryRecord] { devboxes.flatMap(\.workers) }

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
                        detail: "\(devboxes.filter { $0.devbox.status == "running" }.count) 台运行中",
                        symbol: "server.rack",
                        tint: .blue
                    )
                    SummaryTile(
                        title: "工作机",
                        value: "\(workers.count)",
                        detail: "跨开发机汇总",
                        symbol: "cpu",
                        tint: .purple
                    )
                    SummaryTile(
                        title: "GPU",
                        value: "\(workers.reduce(0) { $0 + $1.gpuCount })",
                        detail: "当前已列出的卡数",
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
                MetricPill(symbol: "shippingbox", value: "\(machine.workers.count) Workers")
            }

            HStack {
                Text(machine.devbox.sid)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("连接", systemImage: "terminal", action: onConnect)
                    .buttonStyle(.bordered)
                    .disabled(machine.devbox.status != "running" || machine.sshAlias == nil)
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
                    if machine.devbox.status == "running" {
                        Button("打开终端", systemImage: "terminal", action: onConnect)
                            .buttonStyle(.borderedProminent)
                            .disabled(machine.sshAlias == nil)
                        Button("tmux 会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                            .buttonStyle(.bordered)
                            .disabled(machine.sshAlias == nil)
                    } else if machine.devbox.status == "stopped" {
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
                    Text(workerStatusText(machine.workerStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if machine.workers.isEmpty {
                    SurfaceCard {
                        Text("当前没有可显示的工作机")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(machine.workers) { worker in
                            WorkerRow(worker: worker) {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("全部工作机")
                    .font(.largeTitle.bold())
                Text("跨开发机查看 GPU 与资源配置")
                    .foregroundStyle(.secondary)

                if rows.isEmpty {
                    ContentUnavailableView(
                        "暂无工作机",
                        systemImage: "cpu",
                        description: Text("运行中的开发机刷新成功后，工作机会显示在这里。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(rows, id: \.1.id) { devbox, worker in
                        WorkerRow(worker: worker, parentLabel: devbox.sshAlias ?? devbox.devbox.name) {
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
                        Text(worker.gpuType ?? "CPU Worker")
                            .font(.largeTitle.bold())
                        Text("\(machine.sshAlias ?? machine.devbox.name) · \(worker.id)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ReadinessPill(readiness: worker.readiness)
                }

                HStack {
                    Button("打开 tmux 终端", systemImage: "terminal", action: onConnect)
                        .buttonStyle(.borderedProminent)
                    Button("现有会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                        .buttonStyle(.bordered)
                }
                .disabled(machine.sshAlias == nil || machine.devbox.status != "running")

                if worker.readiness == .listed {
                    MessageBanner(
                        text: "Worker 列表不提供就绪状态；真正连接时会由 mlx worker login 验证。",
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

                SurfaceCard("会话行为") {
                    Label("每个标签对应一个独立 tmux 会话", systemImage: "rectangle.stack")
                    Label("关闭 App 或 SSH 断开后，远端任务继续运行", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    Label("重新打开标签时会恢复原会话", systemImage: "clock.arrow.circlepath")
                }
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct WorkerRow: View {
    let worker: WorkerInventoryRecord
    var parentLabel: String?
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: worker.gpuCount > 0 ? "square.stack.3d.up.fill" : "cpu")
                .font(.title3)
                .foregroundStyle(worker.gpuCount > 0 ? .green : .blue)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(worker.gpuType ?? "CPU Worker")
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
            ReadinessPill(readiness: worker.readiness)
            Button("连接", systemImage: "terminal", action: onConnect)
                .buttonStyle(.bordered)
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
    let status: String

    var body: some View {
        switch status {
        case "running": StatusPill(label: "运行中", color: .green)
        case "stopped": StatusPill(label: "已停止", color: .secondary, symbol: "stop.circle.fill")
        case "starting": StatusPill(label: "启动中", color: .orange, symbol: "clock.fill")
        case "stopping": StatusPill(label: "停止中", color: .orange, symbol: "clock.fill")
        default: StatusPill(label: status, color: .secondary, symbol: "questionmark.circle.fill")
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

private func formatGiB(_ bytes: Int64) -> String {
    let gibibytes = Double(bytes) / 1_073_741_824
    return gibibytes.rounded() == gibibytes
        ? "\(Int(gibibytes)) GiB"
        : String(format: "%.1f GiB", gibibytes)
}

private func workerStatusText(_ status: WorkerInventoryStatus) -> String {
    switch status {
    case .notQueried: "尚未查询"
    case .loaded: "已刷新"
    case .failed: "查询失败"
    }
}
