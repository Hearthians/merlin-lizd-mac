import SwiftUI
import TmuxHubCore

struct TmuxConfigurationCard: View {
    let target: TerminalTarget
    @ObservedObject var terminals: TerminalTabsModel

    private var state: TmuxConfigurationState? {
        terminals.tmuxConfigurationStates[target]
    }

    var body: some View {
        SurfaceCard("tmux 快捷配置") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    description
                    Spacer(minLength: 8)
                    applyButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    description
                    applyButton
                }
            }
            Text("自动备份原配置并保留其他设置；重复应用会更新同一配置段。")
                .font(.caption)
                .foregroundStyle(.secondary)
            status
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Ctrl+A 前缀 · 鼠标选择与滚动")
                .font(.callout.weight(.medium))
            Text("黑底白字状态栏 · 绿/红面板边框 · 从 1 编号 · 256 色")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var applyButton: some View {
        Button {
            let selectedTarget = target
            Task { await terminals.applyTmuxConfiguration(to: selectedTarget) }
        } label: {
            HStack(spacing: 6) {
                if state == .applying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "slider.horizontal.3")
                }
                Text(state == .applying ? "正在配置…" : "一键配置 tmux")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(state == .applying)
        .accessibilityIdentifier("apply-tmux-configuration")
        .help("为 \(target.sshDestination ?? "本机") 应用以上 tmux 设置")
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case let .applied(result):
            Label(
                result.activation == .reloadFailed ? "配置已保存，暂未应用到当前会话" : "tmux 配置已就绪",
                systemImage: result.activation == .reloadFailed ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .foregroundStyle(result.activation == .reloadFailed ? Color.orange : Color.green)
            Text(activationMessage(result.activation))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("配置文件：\(result.configurationPath)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let backup = result.backupPath {
                Text("原配置备份：\(backup)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else if !result.changed {
                Text("配置内容已相同，无需重复备份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .applying:
            Text("正在为 \(target.sshDestination ?? "本机") 保存并应用配置…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func activationMessage(_ activation: TmuxConfigurationResult.Activation) -> String {
        switch activation {
        case .reloaded:
            "已应用到正在运行的 tmux；编号与终端颜色能力设置用于新建窗口或会话。"
        case .nextSession:
            "下次启动 tmux 时自动生效。"
        case .reloadFailed:
            "当前 tmux 未能加载配置；可重试应用，或在下次启动 tmux 时加载。"
        }
    }
}
