import AppKit
import TmuxHubCore
import SwiftUI

struct HostOverviewView: View {
    @ObservedObject var model: AppModel
    let onSelect: (String) -> Void
    @State private var searchText = ""
    @State private var showsRawAddresses = false

    private var quickSections: [SSHHostQuickAccessSection] {
        model.quickAccessSections()
    }

    private var quickHosts: [SSHHost] {
        quickSections.flatMap(\.hosts)
    }

    private var libraryHosts: [SSHHost] {
        model.libraryHosts(
            matching: searchText,
            includeRawAddresses: showsRawAddresses
                || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var pinnedCount: Int {
        quickSections.first(where: { $0.bucket == .pinned })?.hosts.count ?? 0
    }

    private var recentCount: Int {
        quickSections.first(where: { $0.bucket == .recent })?.hosts.count ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("主机库")
                        .font(.largeTitle.bold())
                    Text("侧边栏只保留已固定和最近使用的主机；其余 SSH 配置按需搜索。")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    summaryTile(
                        title: "快捷入口",
                        value: "\(quickHosts.count)",
                        symbol: "server.rack",
                        tint: .blue
                    )
                    summaryTile(
                        title: "已固定",
                        value: "\(pinnedCount)",
                        symbol: "pin.fill",
                        tint: .green
                    )
                    summaryTile(
                        title: "最近使用",
                        value: "\(recentCount)",
                        symbol: "clock",
                        tint: .orange
                    )
                }

                HStack(spacing: 12) {
                    TextField("搜索 SSH alias、主机名或 IP", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    if model.hiddenRawAddressCount > 0 {
                        Toggle(
                            "显示原始地址（\(model.hiddenRawAddressCount)）",
                            isOn: $showsRawAddresses
                        )
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    }
                }

                if model.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("尚无 SSH 主机", systemImage: "server.rack")
                    } description: {
                        Text("在 ~/.ssh/config 添加具体 Host，或用侧边栏的 + 手动添加。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(quickSections) { section in
                            hostGrid(
                                title: section.bucket.displayTitle,
                                hosts: section.hosts
                            )
                        }
                        if !libraryHosts.isEmpty {
                            hostGrid(title: "SSH 配置中的其他主机", hosts: libraryHosts)
                        } else if !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func hostGrid(title: String, hosts: [SSHHost]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                spacing: 12
            ) {
                ForEach(hosts) { host in
                    SurfaceCard {
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.title2)
                                .foregroundStyle(.green)
                            Spacer()
                            Button {
                                togglePin(host)
                            } label: {
                                Image(systemName: model.isPinned(host.destination)
                                    ? "pin.fill" : "pin")
                            }
                            .buttonStyle(.plain)
                            .help(model.isPinned(host.destination)
                                ? "取消固定" : "固定到侧边栏")
                        }
                        Text(host.destination)
                            .font(.headline.monospaced())
                            .lineLimit(1)
                        Text(host.source == .configuration
                            ? "来自 SSH config" : "手动目标")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(host.destination) }
                    .contextMenu {
                        Button(model.isPinned(host.destination)
                            ? "取消固定" : "固定到侧边栏") {
                            togglePin(host)
                        }
                    }
                }
            }
        }
    }

    private func togglePin(_ host: SSHHost) {
        model.setPinned(
            !model.isPinned(host.destination),
            destination: host.destination
        )
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
    @ObservedObject var terminals: TerminalTabsModel
    let onConnect: () -> Void
    let onNewSession: () -> Void
    let onBrowseSessions: () -> Void
    let onBrowseHerdr: () -> Void
    let hasSavedPassword: () async throws -> Bool
    let onSavePassword: (String) async throws -> Void
    let onAuthorizePassword: () async throws -> Void
    let onRemovePassword: () async throws -> Void
    @State private var password = ""
    @State private var passwordIsSaved = false
    @State private var passwordStatusMessage: String?
    @State private var passwordErrorMessage: String?
    @State private var isManagingPassword = false

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
                    Button("连接或继续", systemImage: "terminal") {
                        onConnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("新建会话", systemImage: "plus.rectangle.on.rectangle") {
                        onNewSession()
                    }
                    .buttonStyle(.bordered)
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

                SurfaceCard {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Herdr 工作区", systemImage: "square.stack.3d.up")
                                .font(.headline)
                            Text("按工作区查看 Agent 和终端，选择后直接接入。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("浏览工作区", action: onBrowseHerdr)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }

                TmuxConfigurationCard(
                    target: .ssh(destination: host.destination),
                    terminals: terminals
                )

                SurfaceCard("连接行为") {
                    Label(
                        "tmux 与 Herdr 标签均可恢复；关闭标签只断开连接，不终止远程任务。",
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
                    .disabled(isManagingPassword)

                    if passwordIsSaved || passwordErrorMessage != nil {
                        HStack(spacing: 10) {
                            Button("授权使用已存密码", systemImage: "lock.open") {
                                authorizePassword()
                            }
                            .disabled(isManagingPassword)
                            .accessibilityIdentifier("authorize-saved-ssh-password")
                            if isManagingPassword {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Text("需要系统许可时，请点此授权。弹窗使用 Mac 登录钥匙串密码；后台不会自动弹窗。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if passwordIsSaved {
                        Label("已保存此主机的 SSH 密码", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    } else if passwordErrorMessage == nil {
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
            await refreshPasswordStatus()
        }
    }

    private func refreshPasswordStatus() async {
        isManagingPassword = true
        defer { isManagingPassword = false }
        do {
            let saved = try await hasSavedPassword()
            guard !Task.isCancelled else { return }
            passwordIsSaved = saved
            passwordErrorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            passwordIsSaved = false
            passwordErrorMessage = error.localizedDescription
        }
    }

    private func savePassword() {
        guard !isManagingPassword, !password.isEmpty else { return }
        isManagingPassword = true
        passwordStatusMessage = nil
        let submittedPassword = password
        Task {
            defer { isManagingPassword = false }
            do {
                try await onSavePassword(submittedPassword)
                password = ""
                passwordIsSaved = true
                passwordStatusMessage = "密码已保存；后续连接会先尝试密钥，再回退到密码。"
                passwordErrorMessage = nil
            } catch {
                passwordErrorMessage = error.localizedDescription
            }
        }
    }

    private func authorizePassword() {
        guard !isManagingPassword else { return }
        isManagingPassword = true
        passwordStatusMessage = nil
        Task {
            defer { isManagingPassword = false }
            do {
                try await onAuthorizePassword()
                passwordIsSaved = true
                passwordStatusMessage = "已授权使用已存密码；本次 App 运行中会复用授权。"
                passwordErrorMessage = nil
            } catch {
                passwordErrorMessage = error.localizedDescription
            }
        }
    }

    private func removePassword() {
        guard !isManagingPassword else { return }
        isManagingPassword = true
        passwordStatusMessage = nil
        Task {
            defer { isManagingPassword = false }
            do {
                try await onRemovePassword()
                password = ""
                passwordIsSaved = false
                passwordStatusMessage = "已移除密码；现有 SSH 连接不会被中断。"
                passwordErrorMessage = nil
            } catch {
                passwordErrorMessage = error.localizedDescription
            }
        }
    }
}

struct LocalTerminalLandingView: View {
    @ObservedObject var terminals: TerminalTabsModel
    let onOpenShell: () -> Void
    let onNewTmux: () -> Void
    let onBrowseSessions: () -> Void
    let onBrowseHerdr: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("本机终端")
                .font(.title.bold())
            Text("打开本机 Shell、管理 tmux 会话，或直接接入 Herdr 终端。")
                .foregroundStyle(.secondary)
            HStack {
                Button("登录 Shell", systemImage: "terminal", action: onOpenShell)
                    .buttonStyle(.bordered)
                Button("新建 tmux", systemImage: "plus", action: onNewTmux)
                    .buttonStyle(.borderedProminent)
                Button("现有 tmux 会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                    .buttonStyle(.bordered)
                Button("Herdr 工作区", systemImage: "square.stack.3d.up", action: onBrowseHerdr)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            TmuxConfigurationCard(target: .local, terminals: terminals)
                .frame(maxWidth: 720)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
