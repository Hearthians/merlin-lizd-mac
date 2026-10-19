import AppKit
import TmuxHubCore
import SwiftUI

struct HostOverviewView: View {
    @ObservedObject var model: AppModel
    let onAddHost: () -> Void
    let onShowProperties: (String) -> Void
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
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("主机库")
                            .font(.largeTitle.bold())
                        Text("侧边栏只保留已固定和最近使用的主机；其余 SSH 配置按需搜索。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加 SSH 主机", systemImage: "plus") {
                        onAddHost()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
                        Text("添加服务器地址和登录信息，即可开始连接。已有的 SSH 配置也会自动显示在这里。")
                    } actions: {
                        Button("添加 SSH 主机", systemImage: "plus") {
                            onAddHost()
                        }
                        .buttonStyle(.borderedProminent)
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
                        Divider()
                        Button("属性", systemImage: "slider.horizontal.3") {
                            onShowProperties(host.destination)
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
    @State private var showsPasswordSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hostHeader
                connectionActions
                Divider()
                workspaceRow
                Divider()
                TmuxConfigurationCard(
                    target: .ssh(destination: host.destination),
                    terminals: terminals
                )
                Divider()
                passwordSettings
                connectionDetails
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: host.destination) {
            await refreshPasswordStatus()
        }
        .onChange(of: passwordErrorMessage) { _, message in
            if message != nil { showsPasswordSettings = true }
        }
    }

    private var hostHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(host.destination)
                    .font(.system(size: 24, weight: .semibold))
                    .textSelection(.enabled)
                Text(host.source == .configuration
                    ? "来自 ~/.ssh/config（含 Include）"
                    : "手动添加的 SSH 目标")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label("OpenSSH", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var connectionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                connectButton
                sessionActions
            }
            VStack(alignment: .leading, spacing: 10) {
                connectButton
                sessionActions
            }
        }
        .controlSize(.regular)
    }

    private var connectButton: some View {
        Button("连接或继续", systemImage: "terminal", action: onConnect)
            .buttonStyle(.borderedProminent)
    }

    private var sessionActions: some View {
        HStack(spacing: 10) {
            Button("新建会话", systemImage: "plus", action: onNewSession)
            Button("现有会话", systemImage: "rectangle.stack", action: onBrowseSessions)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ssh \(host.destination)", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("复制 SSH 命令")
            .accessibilityLabel("复制 SSH 命令")
        }
        .buttonStyle(.borderless)
    }

    private var workspaceRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Herdr 工作区")
                    .font(.callout.weight(.medium))
                Text("按工作区查看 Agent 和终端")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("浏览工作区", action: onBrowseHerdr)
                .buttonStyle(.borderless)
        }
    }

    private var connectionDetails: some View {
        DisclosureGroup("连接说明") {
            VStack(alignment: .leading, spacing: 8) {
                Text("tmux 与 Herdr 标签均可恢复；关闭标签只断开连接，不终止远程任务。")
                Text("会话查询复用 App 自己的 OpenSSH ControlMaster，切换主机更快。")
                Text("优先使用 ~/.ssh/config 和 SSH Agent；需要时再启用密码回退。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var passwordSettings: some View {
        DisclosureGroup(isExpanded: $showsPasswordSettings) {
            VStack(alignment: .leading, spacing: 12) {
                Text("仅在密钥认证不可用时使用。密码保存在 macOS 钥匙串，不会写入 SSH 配置、命令行或日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        passwordField
                        passwordActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        passwordField
                        passwordActions
                    }
                }
                .disabled(isManagingPassword)

                if passwordIsSaved || passwordErrorMessage != nil {
                    HStack(spacing: 8) {
                        Button("授权使用已存密码", systemImage: "lock.open", action: authorizePassword)
                            .buttonStyle(.borderless)
                            .disabled(isManagingPassword)
                            .accessibilityIdentifier("authorize-saved-ssh-password")
                        if isManagingPassword {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text("需要系统许可时，使用 Mac 登录钥匙串密码授权；后台不会自动弹窗。")
                        .font(.caption)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Text("密码与认证")
                    .font(.callout.weight(.medium))
                if passwordIsSaved {
                    Label("已保存密码", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                } else if passwordErrorMessage != nil {
                    Label("需要处理", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else {
                    Text("使用密钥或终端认证")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private var passwordField: some View {
        SecureField(passwordIsSaved ? "输入新密码以替换" : "SSH 密码", text: $password)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, maxWidth: 320)
            .onSubmit(savePassword)
    }

    private var passwordActions: some View {
        HStack(spacing: 8) {
            Button(passwordIsSaved ? "更新" : "保存并启用", action: savePassword)
                .buttonStyle(.bordered)
                .disabled(password.isEmpty)
            if passwordIsSaved {
                Button("移除", role: .destructive, action: removePassword)
                    .buttonStyle(.borderless)
            }
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
