import SwiftUI
import TmuxHubCore

struct HPC2QueueMonitoringView: View {
    let queues: [SlurmQueueSnapshot]
    let error: String?
    let updatedAt: Date?
    let isRefreshing: Bool
    let preferredPartition: String
    let platformPartitions: [String]

    @State private var showsAllQueues = false

    private var preferredPartitions: [String] {
        var result: [String] = []
        for partition in [preferredPartition] + platformPartitions {
            if !result.contains(partition) { result.append(partition) }
        }
        return result
    }

    private var displayedQueues: [SlurmQueueSnapshot] {
        let order = preferredPartitions
        let hasPreferredQueue = queues.contains { order.contains($0.partition) }
        return queues.filter { showsAllQueues || !hasPreferredQueue || order.contains($0.partition) }.sorted {
            let left = order.firstIndex(of: $0.partition) ?? Int.max
            let right = order.firstIndex(of: $1.partition) ?? Int.max
            return left == right ? $0.partition < $1.partition : left < right
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("队列资源", systemImage: "server.rack")
                    .font(.title3.bold())
                if isRefreshing { ProgressView().controlSize(.small) }
                Spacer()
                if queues.contains(where: { !preferredPartitions.contains($0.partition) }) {
                    Toggle("全部队列", isOn: $showsAllQueues)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if let error {
                MessageBanner(
                    text: updatedAt.map {
                        "队列资源暂时无法刷新，保留 \(HPC2MonitoringFormat.time($0)) 的数据。\n\(error)"
                    } ?? "暂时无法读取队列资源。\n\(error)",
                    kind: .warning
                )
            }

            if displayedQueues.isEmpty {
                SurfaceCard {
                    HStack(spacing: 10) {
                        if isRefreshing { ProgressView().controlSize(.small) }
                        Text(isRefreshing ? "正在读取队列资源…" : "暂无队列资源数据")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(minHeight: 48)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                    ForEach(displayedQueues) { queue in
                        HPC2QueueResourceCard(queue: queue)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Text("未分配数量是资源空位；GPU 的 4 / 8 卡空位按单台机器统计，NPU 数量按 Slurm 资源单位显示。能否启动仍取决于 CPU、内存、优先级和配额。队列可能共享节点，请勿相加。")
                Spacer(minLength: 0)
                if let updatedAt {
                    Text("更新于 \(HPC2MonitoringFormat.time(updatedAt))")
                        .fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct HPC2QueueResourceCard: View {
    let queue: SlurmQueueSnapshot

    private var isNPUQueue: Bool { (queue.totalNPU ?? 0) > 0 }
    private var isGPUQueue: Bool { !isNPUQueue && (queue.totalGPU ?? 0) > 0 }
    private var isCPUOnlyQueue: Bool { queue.totalGPU == 0 && queue.totalNPU == 0 }
    private var resourceName: String {
        if isNPUQueue { return "NPU" }
        if isCPUOnlyQueue { return "CPU 核" }
        return isGPUQueue ? "GPU" : "加速器"
    }
    private var totalResource: Int? {
        if isNPUQueue { return queue.totalNPU }
        if isCPUOnlyQueue { return queue.totalCPU }
        return isGPUQueue ? queue.totalGPU : nil
    }
    private var allocatedResource: Int? {
        if isNPUQueue { return queue.allocatedNPU }
        if isCPUOnlyQueue { return queue.allocatedCPU }
        return isGPUQueue ? queue.allocatedGPU : nil
    }
    private var unallocatedResource: Int? {
        if isNPUQueue { return queue.unallocatedNPU }
        if isGPUQueue { return queue.unallocatedGPU }
        guard isCPUOnlyQueue, let total = queue.totalCPU, let allocated = queue.allocatedCPU else { return nil }
        return max(0, total - allocated)
    }

    private var title: String {
        if queue.partition.localizedCaseInsensitiveContains("a800") { return "A800" }
        if queue.partition.localizedCaseInsensitiveContains("a40") { return "A40" }
        return queue.partition == "debug" ? "调试队列" : queue.partition
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(queue.state)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(queue.partition)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(HPC2MonitoringFormat.count(unallocatedResource))
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.blue)
                    Text("/ \(HPC2MonitoringFormat.count(totalResource)) \(resourceName) 未分配")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let total = totalResource, let allocated = allocatedResource, total > 0 {
                    ProgressView(value: Double(min(total, max(0, allocated))), total: Double(total))
                        .tint(.blue)
                        .accessibilityLabel("\(resourceName) 已分配 \(allocated)，共 \(total)")
                }
                Text("\(resourceName) 已分配 \(HPC2MonitoringFormat.count(allocatedResource)) · 运行 \(HPC2MonitoringFormat.count(queue.runningJobCount)) · 排队 \(HPC2MonitoringFormat.count(queue.pendingJobCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isGPUQueue {
                    HStack(spacing: 12) {
                        candidateCount("4 卡空位", count: queue.schedulableFourGPUNodeCount)
                        candidateCount("8 卡空位", count: queue.schedulableEightGPUNodeCount)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    resourceLine("CPU 已分配", value: "\(HPC2MonitoringFormat.count(queue.allocatedCPU)) / \(HPC2MonitoringFormat.count(queue.totalCPU)) 核")
                    resourceLine("内存已分配", value: "\(HPC2MonitoringFormat.memory(queue.allocatedMemoryMiB)) / \(HPC2MonitoringFormat.memory(queue.totalMemoryMiB))")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(queue.nodes) { node in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(node.name).font(.caption.monospaced().bold())
                                    Spacer()
                                    Text(node.state).font(.caption.monospaced())
                                }
                                Text(nodeResourceDescription(node))
                                    .font(.caption)
                                Text("内存已分配 \(HPC2MonitoringFormat.memory(node.allocatedMemoryMiB)) / \(HPC2MonitoringFormat.memory(node.totalMemoryMiB))\(node.isSchedulable ? "" : " · 节点暂不可调度")")
                                    .font(.caption)
                            }
                            .foregroundStyle(node.isSchedulable ? Color.secondary : Color.orange)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("节点详情 · \(queue.nodeCount) 台\(queue.unavailableNodeCount > 0 ? "（\(queue.unavailableNodeCount) 台不可用）" : "")")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nodeResourceDescription(_ node: SlurmNodeSnapshot) -> String {
        var resources: [String] = []
        if (node.totalNPU ?? 0) > 0 {
            resources.append("NPU 空位 \(HPC2MonitoringFormat.count(node.unallocatedNPU)) / \(HPC2MonitoringFormat.count(node.totalNPU)) 资源单位")
        }
        if (node.totalGPU ?? 0) > 0 {
            resources.append("GPU 空位 \(HPC2MonitoringFormat.count(node.unallocatedGPU)) / \(HPC2MonitoringFormat.count(node.totalGPU))")
        }
        if node.totalNPU == nil && node.totalGPU == nil {
            resources.append("加速器空位 — / —")
        } else if node.totalNPU == nil {
            resources.append("NPU 空位 — / —")
        } else if node.totalGPU == nil {
            resources.append("GPU 空位 — / —")
        }
        resources.append("CPU 已分配 \(HPC2MonitoringFormat.count(node.allocatedCPU)) / \(HPC2MonitoringFormat.count(node.totalCPU))")
        return resources.joined(separator: " · ")
    }

    private func candidateCount(_ title: String, count: Int?) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text("\(HPC2MonitoringFormat.count(count)) 台").fontWeight(.semibold)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resourceLine(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

struct HPC2JobUtilizationView: View {
    let job: SlurmJobSnapshot
    let snapshot: SlurmJobUtilizationSnapshot?
    let isRefreshing: Bool

    private var isNPUOnlyJob: Bool {
        (snapshot?.allocation?.allocatedNPU ?? 0) > 0 && (snapshot?.allocation?.allocatedGPU ?? 0) == 0
    }

    private var npuUnavailableReason: String {
        if let reason = snapshot?.unavailableReason, !reason.isEmpty { return reason }
        return "NPU 已分配；暂不支持 NPU 利用率、显存和功率采样。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Text("任务资源").font(.caption.bold())
                if let snapshot {
                    Text("采样于 \(HPC2MonitoringFormat.time(snapshot.sampledAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isRefreshing { ProgressView().controlSize(.mini) }
            }
            if let allocation = snapshot?.allocation, job.state != .pending {
                Text(allocationDescription(allocation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if job.state == .pending {
                Text("等待资源分配，尚未开始采样利用率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if isNPUOnlyJob {
                    Text(npuUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if let gpus = snapshot?.gpus {
                    if gpus.isEmpty {
                        Text("未分配 GPU")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                            ForEach(gpus) { gpu in
                                HPC2GPUUtilizationCard(gpu: gpu)
                            }
                        }
                    }
                } else {
                    Text("GPU 利用率 — · \(isRefreshing && snapshot == nil ? "正在采样…" : "暂不可用")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !isNPUOnlyJob, let reason = snapshot?.unavailableReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if snapshot == nil, !isRefreshing {
                    Text("尚未取得任务资源采样；下次刷新后重试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 24) {
                    statistic("CPU 平均（估算）", value: HPC2MonitoringFormat.percent(snapshot?.statistics?.averageCPUPercent))
                    statistic("单 task 内存峰值", value: HPC2MonitoringFormat.memory(snapshot?.statistics?.peakTaskMemoryMiB))
                }
                .help("CPU 按当前活动 step 的累计 CPU 时间、作业运行时长和已分配核数估算；已结束的 step 可能未计入。内存是 Slurm 记录的单个 task 的 RSS 峰值，不代表整个作业的当前内存。一个 task 可能包含多个子进程。")
                if snapshot != nil,
                    snapshot?.statistics?.averageCPUPercent == nil
                        || snapshot?.statistics?.peakTaskMemoryMiB == nil {
                    Text("Slurm 尚未提供完整的 CPU / 内存采样，缺失指标显示 —。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func allocationDescription(_ allocation: SlurmJobAllocation) -> String {
        var resources: [String] = []
        if (allocation.allocatedNPU ?? 0) > 0 {
            resources.append("NPU \(HPC2MonitoringFormat.count(allocation.allocatedNPU)) 资源单位")
        }
        if (allocation.allocatedGPU ?? 0) > 0 {
            resources.append("GPU \(HPC2MonitoringFormat.count(allocation.allocatedGPU)) 张")
        }
        resources.append("CPU \(HPC2MonitoringFormat.count(allocation.allocatedCPU)) 核")
        resources.append("内存 \(HPC2MonitoringFormat.memory(allocation.allocatedMemoryMiB))")
        return "已分配：" + resources.joined(separator: " · ")
    }

    private func statistic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct HPC2GPUUtilizationCard: View {
    let gpu: SlurmGPUUtilization

    private var memoryPercent: Double? {
        guard let used = gpu.memoryUsedMiB, let total = gpu.memoryTotalMiB,
            used.isFinite, total.isFinite, used >= 0, total > 0
        else { return nil }
        return min(100, max(0, used / total * 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let node = gpu.nodeName, !node.isEmpty {
                Text(node)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(node)
            }
            HStack {
                Text("GPU \(gpu.index)")
                    .font(.caption.bold())
                    .help("此节点上任务内可见的 GPU 编号；可能与节点上的物理编号不同。")
                Spacer(minLength: 8)
                Text("利用率 \(HPC2MonitoringFormat.percent(gpu.utilizationPercent))")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Text(gpu.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let percent = gpu.utilizationPercent, percent.isFinite {
                ProgressView(value: min(100, max(0, percent)), total: 100)
                    .tint(.green)
            }
            HStack {
                Text("显存")
                Spacer(minLength: 4)
                Text(HPC2MonitoringFormat.percent(memoryPercent))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Text("\(HPC2MonitoringFormat.memory(gpu.memoryUsedMiB)) / \(HPC2MonitoringFormat.memory(gpu.memoryTotalMiB))")
                .font(.caption.monospacedDigit())
            if let percent = memoryPercent {
                ProgressView(value: percent, total: 100)
                    .tint(.blue)
            }
            HStack {
                Text("功耗").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(HPC2MonitoringFormat.power(gpu.powerDrawWatts)) / \(HPC2MonitoringFormat.power(gpu.powerLimitWatts))")
            }
            .font(.caption.monospacedDigit())
            .help("当前功耗 / 功率上限；GPU 或驱动未提供的读数显示 —。")
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum HPC2MonitoringFormat {
    static func count(_ value: Int?) -> String { value.map(String.init) ?? "—" }

    static func memory(_ value: Int64?) -> String {
        memory(value.map(Double.init))
    }

    static func memory(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let amount: Double
        let unit: String
        if value >= 1_048_576 {
            amount = value / 1_048_576
            unit = "TiB"
        } else if value >= 1_024 {
            amount = value / 1_024
            unit = "GiB"
        } else {
            amount = value
            unit = "MiB"
        }
        return "\(amount.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    static func power(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) W"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .standard)
    }
}
