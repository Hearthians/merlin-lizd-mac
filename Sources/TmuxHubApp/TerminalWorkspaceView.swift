import AppKit
import TmuxHubCore
import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var terminals: TerminalTabsModel

    var body: some View {
        ZStack {
            ForEach(terminals.tabs) { tab in
                if let session = terminals.sessionForRendering(tab.id) {
                    TerminalSessionContent(session: session) {
                        terminals.reconnect(tab.id)
                    }
                    .id(session.id)
                    .opacity(terminals.selectedTabID == tab.id ? 1 : 0)
                    .allowsHitTesting(terminals.selectedTabID == tab.id)
                    .accessibilityHidden(terminals.selectedTabID != tab.id)
                }
            }

            if terminals.selectedTabID == nil {
                unavailable
            } else if let selectedID = terminals.selectedTabID,
                terminals.sessionForRendering(selectedID) == nil
            {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "无法启动终端",
            systemImage: "terminal.fill",
            description: Text("请检查连接目标及终端是否仍然可用。")
        )
    }
}

private struct TerminalSessionContent: View {
    @ObservedObject var session: TerminalSession
    let onReconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            terminal
            TerminalAttachmentBar(model: session.attachmentModel)
        }
    }

    private var terminal: some View {
        ZStack(alignment: .top) {
            TerminalSessionHost(session: session)
                .background(Color.black)
                .overlay { AttachmentDropOverlay(model: session.attachmentModel) }

            if case let .exited(exitCode) = session.state {
                HStack(spacing: 10) {
                    Label(
                        exitCode.map { "连接已结束（\($0)）" } ?? "连接已结束",
                        systemImage: "network.slash"
                    )
                    Spacer()
                    Button(
                        "重新连接",
                        systemImage: "arrow.clockwise",
                        action: onReconnect
                    )
                    .buttonStyle(.borderedProminent)
                }
                .font(.callout)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            } else if let message = session.linkTransferMessage {
                HStack(spacing: 10) {
                    if session.isLinkTransferActive {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: message.hasPrefix("已下载")
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill")
                    }
                    Text(message).lineLimit(2)
                    Spacer()
                    if !session.isLinkTransferActive {
                        Button { session.dismissLinkTransferMessage() } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.callout)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
        }
    }
}

private struct AttachmentDropOverlay: View {
    @ObservedObject var model: TerminalAttachmentModel

    var body: some View {
        if model.isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.15))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                Label("松开添加附件 · 传输后插入路径，不自动发送", systemImage: "tray.and.arrow.down")
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(12)
            .allowsHitTesting(false)
        }
    }
}

struct TerminalTabBar: View {
    @ObservedObject var terminals: TerminalTabsModel
    let hosts: [SSHHost]
    let onRefresh: () -> Void

    @State private var pendingTerminationID: String?
    @State private var renameID: String?
    @State private var renameText = ""
    @State private var renameSessionID: String?
    @State private var renameSessionText = ""
    @State private var operationErrorMessage: String?
    @State private var terminatingSessionID: String?

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(terminals.tabs) { tab in
                            tabItem(tab)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minWidth: geometry.size.width, minHeight: 38, alignment: .leading)
                    .background(WindowHeaderDragArea())
                }
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("刷新（⌘R）")
            .accessibilityLabel("刷新")
            addTerminalMenu
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .padding(.horizontal, 4)
        }
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .confirmationDialog(
            "终止 tmux 会话？",
            isPresented: Binding(
                get: { pendingTerminationID != nil },
                set: { if !$0 { pendingTerminationID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if pendingTerminationTab?.sessionName != nil,
                pendingTerminationTab.map(terminals.allowsTmuxLifecycleMutation) == true
            {
                Button("终止会话并关闭标签", role: .destructive) {
                    guard let tab = pendingTerminationTab,
                        tab.sessionName != nil,
                        terminals.allowsTmuxLifecycleMutation(tab)
                    else {
                        pendingTerminationID = nil
                        return
                    }
                    let id = tab.id
                    pendingTerminationID = nil
                    terminatingSessionID = id
                    Task {
                        do {
                            try await terminals.terminateTmuxSessionAndClose(id)
                        } catch {
                            operationErrorMessage = operationErrorText(error)
                        }
                        terminatingSessionID = nil
                    }
                }
            }
            Button("取消", role: .cancel) { pendingTerminationID = nil }
        } message: {
            Text("将终止 tmux 会话“\(pendingTerminationTab?.sessionName ?? "")”及其中运行的进程，并关闭当前标签。")
        }
        .alert("重命名标签", isPresented: Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } }
        )) {
            TextField("标签名称", text: $renameText)
            Button("保存") {
                if let renameID { terminals.renameTab(renameID, to: renameText) }
                renameID = nil
            }
            Button("取消", role: .cancel) { renameID = nil }
        }
        .alert("重命名 tmux 会话", isPresented: Binding(
            get: { renameSessionID != nil },
            set: { if !$0 { renameSessionID = nil } }
        )) {
            TextField("tmux 会话名", text: $renameSessionText)
            Button("重命名") {
                guard let id = renameSessionID else { return }
                let newName = renameSessionText
                renameSessionID = nil
                Task {
                    do {
                        try await terminals.renameTmuxSession(id, to: newName)
                    } catch {
                        operationErrorMessage = operationErrorText(error)
                    }
                }
            }
            Button("取消", role: .cancel) { renameSessionID = nil }
        }
        .alert("终端操作失败", isPresented: Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(operationErrorMessage ?? "未知错误。")
        }
    }

    private func tabItem(_ tab: TerminalTabRecord) -> some View {
        let selected = terminals.selectedTabID == tab.id
        return HStack(spacing: 4) {
            Button {
                terminals.select(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.herdrReference != nil ? "square.stack.3d.up" : (tab.target == .local ? "macbook" : "server.rack"))
                    Text(tab.title)
                        .lineLimit(1)
                        .frame(maxWidth: 210)
                }
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.leading, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(tab.herdrReference.map { "Herdr: \($0.terminalID)" } ?? tab.sessionName.map { "tmux: \($0)" } ?? "本机登录 shell")

            if terminatingSessionID == tab.id {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 18, height: 18)
                    .padding(.trailing, 4)
            } else {
                Button {
                    closeTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .accessibilityLabel("关闭 \(tab.title)")
                .help(closeTabHelp(tab))
            }
        }
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contextMenu {
            Button("重命名标签") {
                renameText = tab.title
                renameID = tab.id
            }
            if let sessionName = tab.sessionName {
                if terminals.allowsTmuxLifecycleMutation(tab) {
                    Button("重命名 tmux 会话") {
                        renameSessionText = sessionName
                        renameSessionID = tab.id
                    }
                }
                Button("复制 tmux 会话名") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sessionName, forType: .string)
                }
            }
            Divider()
            Button("在 Terminal 中打开") {
                Task {
                    do {
                        try await terminals.openInTerminal(tab.id)
                    } catch {
                        operationErrorMessage = operationErrorText(error)
                    }
                }
            }
            Divider()
            Button("关闭标签") { terminals.close(tab.id) }
        }
    }

    private var addTerminalMenu: some View {
        Menu {
            Button("本机登录 Shell", systemImage: "macbook") {
                terminals.openLocalShell()
            }
            Button("本机 tmux", systemImage: "rectangle.stack") {
                terminals.openLocalTmux()
            }
            if !hosts.isEmpty {
                Divider()
                ForEach(hosts) { host in
                    Button(host.destination, systemImage: "server.rack") {
                        terminals.openSSH(host.destination)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 24, height: 24)
        }
        .help("新建终端")
    }

    private func closeTab(_ tab: TerminalTabRecord) {
        let event = NSApp.currentEvent
        let isLeftClick = event?.type == .leftMouseDown || event?.type == .leftMouseUp
        let isOptionClick = isLeftClick && event?.modifierFlags.contains(.option) == true
        if isOptionClick,
            tab.sessionName != nil,
            terminals.allowsTmuxLifecycleMutation(tab)
        {
            pendingTerminationID = tab.id
        } else {
            terminals.close(tab.id)
        }
    }

    private func closeTabHelp(_ tab: TerminalTabRecord) -> String {
        if tab.sessionName != nil, terminals.allowsTmuxLifecycleMutation(tab) {
            return "关闭标签并断开连接；按住 Option 点击 × 可终止 tmux 会话"
        }
        if tab.sessionName != nil || tab.herdrReference != nil {
            return "关闭标签并断开连接；会话和任务会继续运行"
        }
        return tab.target == .local ? "关闭标签并结束本机 shell" : "关闭标签并断开连接"
    }

    private var pendingTerminationTab: TerminalTabRecord? {
        guard let pendingTerminationID else { return nil }
        return terminals.tabs.first { $0.id == pendingTerminationID }
    }

    private func operationErrorText(_ error: Error) -> String {
        if let operationError = error as? TerminalTabOperationError {
            return operationError.localizedDescription
        }
        if let launcherError = error as? ExternalTerminalLauncherError,
            case let .commandFailed(exitCode) = launcherError
        {
            return "无法在 Terminal 中打开（退出码 \(exitCode)）。"
        }
        return "操作未完成：\(error.localizedDescription)"
    }
}
