import AppKit
import TmuxHubCore
import SwiftUI

struct HostOverviewView: View {
    let hosts: [SSHHost]
    let onSelect: (String) -> Void

    private var configuredCount: Int {
        hosts.filter { $0.source == .configuration }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH 主机")
                        .font(.largeTitle.bold())
                    Text("从 OpenSSH 配置读取目标，集中管理远程 tmux 会话。")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    summaryTile(
                        title: "可选主机",
                        value: "\(hosts.count)",
                        symbol: "server.rack",
                        tint: .blue
                    )
                    summaryTile(
                        title: "SSH config",
                        value: "\(configuredCount)",
                        symbol: "doc.text",
                        tint: .green
                    )
                    summaryTile(
                        title: "手动添加",
                        value: "\(hosts.count - configuredCount)",
                        symbol: "plus.circle",
                        tint: .orange
                    )
                }

                if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("尚无 SSH 主机", systemImage: "server.rack")
                    } description: {
                        Text("在 ~/.ssh/config 添加具体 Host，或用侧边栏的 + 手动添加。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(hosts) { host in
                            Button {
                                onSelect(host.destination)
                            } label: {
                                SurfaceCard {
                                    HStack {
                                        Image(systemName: "server.rack")
                                            .font(.title2)
                                            .foregroundStyle(.green)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(host.destination)
                                        .font(.headline.monospaced())
                                        .lineLimit(1)
                                    Text(host.source == .configuration
                                        ? "来自 SSH config" : "手动目标")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func summaryTile(
        title: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        SurfaceCard {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(tint)
                Spacer()
                Text(value)
                    .font(.title2.bold().monospacedDigit())
            }
        }
    }
}

struct SSHHostDetailView: View {
    let host: SSHHost
    let onNewSession: () -> Void
    let onBrowseSessions: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(host.destination)
                            .font(.largeTitle.bold().monospaced())
                        Text(host.source == .configuration
                            ? "来自 ~/.ssh/config（含 Include）"
                            : "手动添加的 SSH 目标")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        label: "OpenSSH",
                        color: .green,
                        symbol: "lock.shield"
                    )
                }

                HStack(spacing: 10) {
                    Button("新建 tmux 会话", systemImage: "plus.rectangle.on.rectangle") {
                        onNewSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("浏览现有会话", systemImage: "rectangle.stack") {
                        onBrowseSessions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("复制 SSH 命令", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "ssh \(host.destination)",
                            forType: .string
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                SurfaceCard("连接行为") {
                    Label(
                        "每个远程标签都运行在 tmux 中；关闭标签只断开 SSH，不终止远程任务。",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    Label(
                        "会话查询复用 App 自己的 OpenSSH ControlMaster，切换主机更快。",
                        systemImage: "bolt.horizontal.circle"
                    )
                    Label(
                        "认证完全交给 ~/.ssh/config、SSH Agent 或交互式 SSH。",
                        systemImage: "key"
                    )
                }
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct LocalTerminalLandingView: View {
    let onOpenShell: () -> Void
    let onNewTmux: () -> Void
    let onBrowseSessions: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("本机终端")
                .font(.title.bold())
            Text("可以打开普通登录 shell，也可以统一管理本机 tmux。")
                .foregroundStyle(.secondary)
            HStack {
                Button("登录 Shell", systemImage: "terminal", action: onOpenShell)
                    .buttonStyle(.bordered)
                Button("新建 tmux", systemImage: "plus", action: onNewTmux)
                    .buttonStyle(.borderedProminent)
                Button("现有 tmux 会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
