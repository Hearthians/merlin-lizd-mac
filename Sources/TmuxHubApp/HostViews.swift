import AppKit
import TmuxHubCore
import SwiftUI

struct HostOverviewView: View {
    let sections: [SSHHostRecencySection]
    let onSelect: (String) -> Void

    private var hosts: [SSHHost] {
        sections.flatMap(\.hosts)
    }

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
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.bucket.displayTitle)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(
                                    columns: [GridItem(
                                        .adaptive(minimum: 230),
                                        spacing: 12
                                    )],
                                    spacing: 12
                                ) {
                                    ForEach(section.hosts) { host in
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
    let hasSavedPassword: () throws -> Bool
    let onSavePassword: (String) throws -> Void
    let onRemovePassword: () throws -> Void
    @State private var password = ""
    @State private var passwordIsSaved = false
    @State private var passwordStatusMessage: String?
    @State private var passwordErrorMessage: String?

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
                        "优先使用 ~/.ssh/config 和 SSH Agent；需要时再启用密码回退。",
                        systemImage: "key"
                    )
                }
                .foregroundStyle(.secondary)

                SurfaceCard("密码回退（可选）") {
                    Text(
                        "仅当密钥认证不可用时使用。密码保存在 macOS 钥匙串，"
                            + "不会写入 SSH 配置、命令行或日志。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        SecureField(
                            passwordIsSaved ? "输入新密码以替换" : "SSH 密码",
                            text: $password
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePassword)

                        Button(passwordIsSaved ? "更新" : "保存并启用") {
                            savePassword()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)

                        if passwordIsSaved {
                            Button("移除", role: .destructive) {
                                removePassword()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if passwordIsSaved {
                        Label("已为此主机启用钥匙串密码回退", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    } else {
                        Label("未保存密码，继续使用密钥或终端交互认证", systemImage: "key")
                            .foregroundStyle(.secondary)
                    }
                    if let passwordStatusMessage {
                        Text(passwordStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let passwordErrorMessage {
                        Text(passwordErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
        }
        .task(id: host.destination) {
            refreshPasswordStatus()
        }
    }

    private func refreshPasswordStatus() {
        do {
            passwordIsSaved = try hasSavedPassword()
            passwordErrorMessage = nil
        } catch {
            passwordIsSaved = false
            passwordErrorMessage = error.localizedDescription
        }
    }

    private func savePassword() {
        do {
            try onSavePassword(password)
            password = ""
            passwordIsSaved = true
            passwordStatusMessage = "密码已保存；后续连接会先尝试密钥，再回退到密码。"
            passwordErrorMessage = nil
        } catch {
            passwordErrorMessage = error.localizedDescription
        }
    }

    private func removePassword() {
        do {
            try onRemovePassword()
            password = ""
            passwordIsSaved = false
            passwordStatusMessage = "已移除密码；现有 SSH 连接不会被中断。"
            passwordErrorMessage = nil
        } catch {
            passwordErrorMessage = error.localizedDescription
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
