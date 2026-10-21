import AppKit
import SwiftUI
import TmuxHubCore

struct CodexNotificationsView: View {
    @ObservedObject var model: CodexNotificationsModel
    let hosts: [SSHHost]

    @State private var setupLocation: SetupLocation = .local
    @State private var selectedDestination = ""
    @State private var isSettingUp = false
    @State private var setupNotice: String?
    @State private var setupFailed = false
    @State private var showUnreadOnly = false

    private enum SetupLocation: Hashable {
        case local, ssh
    }

    private var hostDestinations: [String] {
        Array(Set(hosts.map(\.destination))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var visibleEntries: [CodexNotificationEntry] {
        model.entries
            .filter { !showUnreadOnly || model.isUnread($0) }
            .sorted { $0.event.timestamp > $1.event.timestamp }
    }

    private var unreadCount: Int {
        model.unreadCount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading
                setupCard
                if let setupNotice {
                    MessageBanner(text: setupNotice, kind: setupFailed ? .error : .info)
                        .accessibilityIdentifier("codex-notifications-setup-notice")
                }
                if let notice = model.notice {
                    MessageBanner(text: notice, kind: .warning)
                }
                if !model.sources.isEmpty {
                    sourcesCard
                }
                history
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { updateSelectedDestination() }
        .onChange(of: hostDestinations) { _, _ in updateSelectedDestination() }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Codex 通知").font(.largeTitle.bold())
                Text("接收任务完成和审批提醒，直接返回对应终端。")
                    .foregroundStyle(.secondary)
                Text("事件保留在运行 Codex 的主机上，已读状态在设备间同步；每台设备独立接收，静音和系统提醒仅影响本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }
                .disabled(model.isRefreshing || !model.sources.contains(where: \.enabled))
            }
        }
    }

    private var setupCard: some View {
        SurfaceCard("添加通知来源") {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择运行 Codex 的位置，再配置通知。")
                    .foregroundStyle(.secondary)
                Picker("运行位置", selection: $setupLocation) {
                    Text("本机").tag(SetupLocation.local)
                    Text("SSH 主机").tag(SetupLocation.ssh)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                .disabled(isSettingUp)

                if setupLocation == .ssh {
                    if hostDestinations.isEmpty {
                        Text("还没有 SSH 主机，请先在主机库中添加。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("SSH 主机", selection: $selectedDestination) {
                            ForEach(hostDestinations, id: \.self) { destination in
                                Text(destination).tag(destination)
                            }
                        }
                        .frame(maxWidth: 440, alignment: .leading)
                        .disabled(isSettingUp)
                    }
                }

                HStack(spacing: 8) {
                    Button("配置并启用", systemImage: "bell.badge") { setup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSettingUp || (setupLocation == .ssh && selectedDestination.isEmpty))
                        .accessibilityIdentifier("codex-notifications-setup")
                    if isSettingUp {
                        ProgressView().controlSize(.small)
                        Text("正在配置…").foregroundStyle(.secondary)
                    }
                }

                Text("配置后，请在该位置的 Codex 中打开 /hooks，审查并允许 TmuxHub 的 hooks，然后新建会话。收到首条通知后，才能确认事件上报正常。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        systemNotificationDescription
                        Spacer()
                        systemNotificationButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        systemNotificationDescription
                        systemNotificationButtons
                    }
                }
            }
        }
    }

    private var systemNotificationDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("本机系统通知").font(.subheadline.weight(.medium))
            Text(model.systemNotificationStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemNotificationButtons: some View {
        HStack(spacing: 8) {
            if model.systemNotificationsEnabled {
                Button("关闭本机提醒", systemImage: "bell.slash") {
                    model.disableSystemNotifications()
                }
                .help("通知历史继续保留，其他设备不受影响。")
            } else {
                Button("开启系统通知", systemImage: "bell") {
                    Task { await model.enableSystemNotifications() }
                }
            }
            Button("系统通知设置…", systemImage: "gearshape") { openNotificationSettings() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var sourcesCard: some View {
        SurfaceCard("接收来源") {
            ForEach(model.sources) { source in
                sourceRow(source)
                if source.id != model.sources.last?.id { Divider() }
            }
            Text("暂停接收或移除来源只影响本机，主机上的事件和其他设备的通知保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceRow(_ source: CodexNotificationSource) -> some View {
        let status = model.statuses[source.id] ?? .idle
        let busy = model.busySourceIDs.contains(source.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(source.displayName, systemImage: source.destination == nil ? "desktopcomputer" : "server.rack")
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        sourceStatus(status)
                        if source.enabled {
                            Text(hasReceivedEvent(from: source) ? "已收到通知" : "暂无通知记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if case let .ready(date) = status {
                        Text("最近检查：\(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button("移除本机来源", systemImage: "trash", role: .destructive) {
                        Task { await model.removeSource(id: source.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("\(source.displayName) 的更多操作")
                .disabled(busy)
            }

            if case let .failed(message) = status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if source.enabled {
                    Button("检查通知", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(id: source.id) }
                    }
                }
                Button(source.enabled ? "暂停本机接收" : "在本机继续接收",
                       systemImage: source.enabled ? "pause.circle" : "play.circle") {
                    Task { await model.setSourceEnabled(id: source.id, enabled: !source.enabled) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sourceStatus(_ status: CodexNotificationSourceStatus) -> some View {
        switch status {
        case .idle:
            Label("等待连接", systemImage: "clock").foregroundStyle(.secondary)
        case .installing:
            Label("正在配置", systemImage: "gearshape").foregroundStyle(.secondary)
        case .syncing:
            Label("正在检查", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .ready:
            Label("已连接", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed:
            Label("连接失败", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .disabled:
            Label("本机已停用", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("通知历史").font(.title2.bold())
                if unreadCount > 0 {
                    Text("\(unreadCount) 条未读")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("当前记录全部标为已读", systemImage: "checkmark") { model.markAllRead() }
                    .disabled(!model.entries.contains(where: { !$0.isRead }))
                    .help("将当前通知历史全部标为已读，并同步到其他设备。")
            }
            if model.pendingReadCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(model.pendingReadCount) 条已读标记等待同步", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                    Text(model.readSyncError ?? "已保存在本机；来源恢复接收并连接后，会自动同步到其他设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("codex-notifications-pending-read-sync")
            }
            Text("首次添加来源时，已有通知会静默载入，未读状态沿用主机记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("通知范围", selection: $showUnreadOnly) {
                Text("全部").tag(false)
                Text("未读").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            SurfaceCard {
                if visibleEntries.isEmpty {
                    ContentUnavailableView(
                        showUnreadOnly ? "没有未读通知" : "还没有 Codex 通知",
                        systemImage: showUnreadOnly ? "checkmark.circle" : "bell",
                        description: Text(showUnreadOnly
                            ? "已读记录仍可在「全部」中查看。"
                            : "配置来源并完成 /hooks 审查后，新会话的任务完成和审批提醒会显示在这里。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleEntries) { entry in
                            notificationRow(entry)
                            if entry.id != visibleEntries.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func notificationRow(_ entry: CodexNotificationEntry) -> some View {
        let muted = model.isMuted(entry: entry)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(model.isUnread(entry) ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                    .accessibilityLabel("未读")
                    .accessibilityHidden(!model.isUnread(entry))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        eventLabel(entry.event.kind)
                            .font(.headline)
                        if entry.isResolved && entry.event.kind == .approvalRequested {
                            Text("已继续").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(entry.event.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(entry.event.timestamp.formatted(date: .abbreviated, time: .standard))
                    }
                    Text("\(entry.sourceLabel) · \(sessionLabel(entry))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if muted {
                        Label("此会话已在本机静音", systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { entryButtons(entry, muted: muted) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { entryButtons(entry, muted: muted) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func entryButtons(_ entry: CodexNotificationEntry, muted: Bool) -> some View {
        Button("打开终端", systemImage: "terminal") { model.open(entry: entry) }
        if !entry.isRead {
            Button("标为已读", systemImage: "checkmark") { model.markRead(id: entry.id) }
                .help("已读状态会同步到其他设备。")
        }
        Button(muted ? "取消会话静音" : "静音此会话", systemImage: muted ? "bell" : "bell.slash") {
            model.setMuted(entry: entry, muted: !muted)
        }
        .help("只改变本机对此会话的提醒，通知历史继续保留。")
    }

    @ViewBuilder
    private func eventLabel(_ kind: CodexNotificationKind) -> some View {
        switch kind {
        case .turnCompleted:
            Label("任务已完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .approvalRequested:
            Label("需要审批", systemImage: "hand.raised.fill").foregroundStyle(.orange)
        case .turnStarted:
            Label("任务已继续", systemImage: "play.circle").foregroundStyle(.secondary)
        }
    }

    private func sessionLabel(_ entry: CodexNotificationEntry) -> String {
        if let session = entry.event.tmuxSession, !session.isEmpty { return session }
        return "Codex 会话 \(entry.event.sessionID.prefix(8))"
    }

    private func hasReceivedEvent(from source: CodexNotificationSource) -> Bool {
        model.entries.contains { entry in
            if let sourceID = source.sourceID { return entry.event.sourceID == sourceID }
            return entry.destination == source.destination
        }
    }

    private func updateSelectedDestination() {
        if !hostDestinations.contains(selectedDestination) {
            selectedDestination = hostDestinations.first ?? ""
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        if !NSWorkspace.shared.open(url) {
            setupFailed = false
            setupNotice = "请在系统设置的「通知」中允许 TmuxHub 发送通知。"
        }
    }

    private func setup() {
        guard !isSettingUp else { return }
        let destination = setupLocation == .local ? nil : selectedDestination
        guard destination == nil || !(destination?.isEmpty ?? true) else { return }
        isSettingUp = true
        setupNotice = nil
        Task { @MainActor in
            defer { isSettingUp = false }
            do {
                _ = try await model.setup(destination: destination)
                setupFailed = false
                setupNotice = "已写入通知配置。请在 Codex 的 /hooks 中审查并允许，然后新建会话；收到首条通知后即可确认生效。"
            } catch is CancellationError {
            } catch {
                setupFailed = true
                setupNotice = error.localizedDescription
            }
        }
    }
}
