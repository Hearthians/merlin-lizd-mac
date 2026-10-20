import SwiftUI
import TmuxHubCore

struct HPC2JobCostView: View {
    let estimate: SlurmCostEstimate?
    var showsHourlyRate = false
    var isPending = false

    var body: some View {
        if let estimate {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("计算费用估计").foregroundStyle(.secondary)
                    Text("≈ \(HPC2CostFormat.money(estimate.amount))")
                        .fontWeight(.semibold)
                    if showsHourlyRate {
                        Text("\(HPC2CostFormat.money(estimate.hourlyCost)) / 小时")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("GPU \(HPC2CostFormat.money(estimate.gpuAmount)) + CPU \(HPC2CostFormat.money(estimate.cpuAmount)) · \(estimate.tariffLabel)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .help("按已分配的 GPU、CPU 和 Slurm 已运行时长估算，不按 GPU 利用率折扣；以平台账单为准。")
        } else {
            Text(isPending
                 ? "排队中 · 暂未计入当前费用估计，已有运行记录可在历史中查看"
                 : "计算费用估计 — · 暂缺可计价的队列、资源或运行时长")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct HPC2CostSummaryView: View {
    let estimates: [SlurmCostEstimate]
    let jobCount: Int
    let isHistory: Bool

    private var amount: Double { estimates.reduce(0) { $0 + $1.amount } }
    private var hourlyCost: Double { estimates.reduce(0) { $0 + $1.hourlyCost } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(isHistory ? "所列历史任务估计" : "当前任务累计估计")
                Text(estimates.isEmpty ? "—" : "≈ \(HPC2CostFormat.money(amount))")
                    .fontWeight(.semibold)
                if !isHistory, !estimates.isEmpty {
                    Text("按当前分配 \(HPC2CostFormat.money(hourlyCost)) / 小时")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            if estimates.count < jobCount {
                Text("已估算 \(estimates.count) / \(jobCount) 项；缺失项未按零费用计入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(isHistory
                 ? "按所列任务的完整运行时长、当前单价回算 GPU + CPU 费用；不含存储，以平台账单为准。"
                 : "按已分配资源和已采样的运行时长估算 GPU + CPU 费用；不含存储，以平台账单为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HPC2CostRatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String]
    @State private var error: String?
    let onSave: (SlurmCostConfiguration) throws -> Void

    init(
        configuration: SlurmCostConfiguration,
        onSave: @escaping (SlurmCostConfiguration) throws -> Void
    ) {
        _fields = State(initialValue: Self.fields(for: configuration))
        self.onSave = onSave
    }

    private var configuration: SlurmCostConfiguration? {
        let values = fields.compactMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard values.count == 9 else { return nil }
        func tier(_ start: Int) -> SlurmCostTierRates {
            SlurmCostTierRates(
                cpuPerCoreHour: values[start],
                a800PerGPUHour: values[start + 1],
                otherPerGPUHour: values[start + 2]
            )
        }
        let configuration = SlurmCostConfiguration(
            low: tier(0), medium: tier(3), high: tier(6)
        )
        return configuration.isValid ? configuration : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("费用估计 · 计费标准").font(.title2.bold())
            Text("人民币（CNY） · GPU 按卡时，CPU 按核时；不足一小时按秒折算。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("优先级")
                    Text("CPU / 核时")
                    Text("A800 / 卡时")
                    Text("A30 / A40 / 昇腾 / 卡时")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                rateRow("低", offset: 0)
                rateRow("中", offset: 3)
                rateRow("高", offset: 6)
            }
            .textFieldStyle(.roundedBorder)
            Text("按已确认的 HPC2 队列匹配优先级；debug 计算免费。未知队列及 MIG 暂不估算。修改单价会重新计算当前和历史任务的估计金额，不会修改集群设置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Link("价格速查 · 2026-10-13", destination: URL(string: "https://mcnj47nsbq2m.feishu.cn/wiki/Rhr9wjK8FiK15DkjA33cruc5nWg")!)
                Link("官方队列说明", destination: URL(string: "https://docs.hpc.hkust-gz.edu.cn/docs/hpc12/slurm/queue/")!)
            }
            .font(.caption)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if configuration == nil {
                Text("请输入有效的非负单价，小数点使用「.」。")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("恢复参考单价") {
                    fields = Self.fields(for: .hkustHPC2)
                    error = nil
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let configuration else { return }
                    do {
                        try onSave(configuration)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(configuration == nil)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func rateRow(_ title: String, offset: Int) -> some View {
        GridRow {
            Text(title)
            TextField("CPU", text: $fields[offset])
                .accessibilityLabel("\(title)优先级 CPU 每核小时单价")
            TextField("A800", text: $fields[offset + 1])
                .accessibilityLabel("\(title)优先级 A800 每卡小时单价")
            TextField("A30 / A40 / 昇腾", text: $fields[offset + 2])
                .accessibilityLabel("\(title)优先级 A30 A40 昇腾每卡小时单价")
        }
    }

    private static func fields(for configuration: SlurmCostConfiguration) -> [String] {
        [configuration.low, configuration.medium, configuration.high].flatMap {
            [$0.cpuPerCoreHour, $0.a800PerGPUHour, $0.otherPerGPUHour].map { String($0) }
        }
    }
}

private enum HPC2CostFormat {
    static func money(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value > 0, value < 0.01 { return "< ¥0.01" }
        return "¥\(value.formatted(.number.precision(.fractionLength(2))))"
    }
}
