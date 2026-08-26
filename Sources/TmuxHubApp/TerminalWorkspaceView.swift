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
            description: Text("SSH 目标、tmux 会话名或本地 shell 无效。")
        )
    }
}

private struct TerminalSessionContent: View {
    @ObservedObject var session: TerminalSession
    let onReconnect: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            TerminalSessionHost(session: session)
                .background(Color.black)

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
            }
        }
    }
}

struct TerminalTabBar: View {
    @ObservedObject var terminals: TerminalTabsModel
    let hosts: [SSHHost]

    @State private var pendingCloseID: String?
    @State private var renameID: String?
    @State private var renameText = ""
    @State private var renameSessionID: String?
    @State private var renameSessionText = ""
    @State private var operationErrorMessage: String?
    @State private var terminatingSessionID: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminals.tabs) { tab in
                        tabItem(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider().frame(height: 22)
            addTerminalMenu
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .padding(.horizontal, 4)
        }
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .confirmationDialog(
            "关闭终端标签？",
            isPresented: Binding(
                get: { pendingCloseID != nil },
                set: { if !$0 { pendingCloseID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingCloseTab?.sessionName == nil ? "关闭标签" : "仅关闭标签") {
                if let pendingCloseID { terminals.close(pendingCloseID) }
                pendingCloseID = nil
            }
            if pendingCloseTab?.sessionName != nil {
                Button("关闭标签并终止 tmux", role: .destructive) {
                    guard let id = pendingCloseID else { return }
                    pendingCloseID = nil
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
            Button("取消", role: .cancel) { pendingCloseID = nil }
        } message: {
            if pendingCloseTab?.sessionName != nil {
                Text("默认仅断开当前标签；远程 tmux 和任务会继续运行。")
            } else {
                Text("将结束本机登录 shell。")
            }
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
                    Image(systemName: tab.target == .local ? "macbook" : "server.rack")
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

            if terminatingSessionID == tab.id {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 18, height: 18)
                    .padding(.trailing, 4)
            } else {
                Button {
                    pendingCloseID = tab.id
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
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
                Button("重命名 tmux 会话") {
                    renameSessionText = sessionName
                    renameSessionID = tab.id
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
            Button("关闭…", role: .destructive) { pendingCloseID = tab.id }
        }
        .help(tab.sessionName.map { "tmux: \($0)" } ?? "本机登录 shell")
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

    private var pendingCloseTab: TerminalTabRecord? {
        guard let pendingCloseID else { return nil }
        return terminals.tabs.first { $0.id == pendingCloseID }
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
