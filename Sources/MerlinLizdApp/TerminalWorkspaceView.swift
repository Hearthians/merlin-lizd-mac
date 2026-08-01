import AppKit
import MerlinLizdCore
import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var terminals: TerminalTabsModel

    var body: some View {
        Group {
            if
                let selectedID = terminals.selectedTabID,
                let session = terminals.session(for: selectedID)
            {
                TerminalSessionContent(session: session) {
                    terminals.reconnect(selectedID)
                }
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "无法启动终端",
                    systemImage: "terminal.fill",
                    description: Text("目标信息无效，或本地 shell 不可用。")
                )
            }
        }
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
                    Button("重新连接", systemImage: "arrow.clockwise", action: onReconnect)
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
    let devboxes: [DevboxInventory]

    @State private var pendingTmuxTerminationID: String?
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

            Divider()
                .frame(height: 22)

            addTerminalMenu
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .padding(.horizontal, 4)
        }
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .confirmationDialog(
            "关闭并终止 tmux？",
            isPresented: Binding(
                get: { pendingTmuxTerminationID != nil },
                set: { if !$0 { pendingTmuxTerminationID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("关闭标签并终止 tmux", role: .destructive) {
                guard let id = pendingTmuxTerminationID else { return }
                pendingTmuxTerminationID = nil
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
            Button("取消", role: .cancel) {
                pendingTmuxTerminationID = nil
            }
        } message: {
            Text("这会终止远程 tmux 会话，其中运行的任务也会停止。此操作无法撤销。")
        }
        .alert("重命名标签", isPresented: Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } }
        )) {
            TextField("标签名称", text: $renameText)
            Button("保存") {
                if let renameID {
                    terminals.rename(renameID, to: renameText)
                }
                renameID = nil
            }
            Button("取消", role: .cancel) {
                renameID = nil
            }
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
            Button("取消", role: .cancel) {
                renameSessionID = nil
            }
        } message: {
            Text("会直接重命名目标机器上的 tmux 会话，并更新此标签的恢复信息。")
        }
        .alert("终端操作失败", isPresented: Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {
                operationErrorMessage = nil
            }
        } message: {
            Text(operationErrorMessage ?? "未知错误。")
        }
    }

    @ViewBuilder
    private func tabItem(_ tab: TerminalTabRecord) -> some View {
        let selected = terminals.selectedTabID == tab.id
        HStack(spacing: 4) {
            Button {
                terminals.select(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tabSymbol(tab.target))
                    HStack(spacing: 4) {
                        if let sessionName = tab.sessionName {
                            Text(sessionName)
                                .layoutPriority(1)
                            if let secondaryTitle = tab.sessionContextTitle {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(secondaryTitle)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text(tab.title)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.leading, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(tabHelp(for: tab))

            if terminatingSessionID == tab.id {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 18, height: 18)
                    .padding(.trailing, 4)
            } else {
                Button {
                    requestClose(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .help(closeHelp(for: tab))
            }
        }
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
        }
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
            Button("关闭标签", role: .destructive) {
                requestClose(tab)
            }
        }
    }

    private func tabHelp(for tab: TerminalTabRecord) -> String {
        guard let sessionName = tab.sessionName else { return tab.title }
        var lines = ["tmux: \(sessionName)"]
        if let contextTitle = tab.sessionContextTitle {
            lines.append("标签：\(contextTitle)")
        }
        if let workingDirectory = tab.workingDirectory, !workingDirectory.isEmpty {
            lines.append("创建目录：\(workingDirectory)")
        }
        return lines.joined(separator: "\n")
    }

    private func closeHelp(for tab: TerminalTabRecord) -> String {
        tab.sessionName == nil
            ? "关闭标签"
            : "关闭标签；按住 ⌥ 点击可终止 tmux 会话"
    }

    private var addTerminalMenu: some View {
        Menu {
            Button("本机终端", systemImage: "macbook") {
                terminals.openLocal()
            }

            if !devboxes.isEmpty {
                Divider()
                Menu("开发机", systemImage: "server.rack") {
                    ForEach(devboxes) { machine in
                        Button(machine.displayName) {
                            terminals.openDevbox(machine)
                        }
                        .disabled(
                            !machine.devbox.status.isRunning
                                || machine.sshConnectionTarget == nil
                        )
                    }
                }

                Menu("工作机", systemImage: "cpu") {
                    ForEach(devboxes) { machine in
                        if !machine.workers.isEmpty {
                            Menu(machine.displayName) {
                                ForEach(machine.workers) { worker in
                                    Button("\(worker.gpuType ?? "CPU") · \(worker.id)") {
                                        terminals.openWorker(worker, on: machine)
                                    }
                                    .disabled(
                                        machine.workerTerminalTarget(
                                            for: worker
                                        ) == nil
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 24, height: 24)
        }
        .help("新建终端")
    }

    private func requestClose(_ tab: TerminalTabRecord) {
        switch TerminalTabCloseDisposition.resolve(
            for: tab,
            optionPressed: NSEvent.modifierFlags.contains(.option)
        ) {
        case .closeTab:
            terminals.close(tab.id)
        case .confirmTmuxTermination:
            pendingTmuxTerminationID = tab.id
        }
    }

    private func tabSymbol(_ target: TerminalTarget) -> String {
        switch target {
        case .local: "macbook"
        case .devbox: "server.rack"
        case .worker: "cpu"
        }
    }

    private func operationErrorText(_ error: Error) -> String {
        if let operationError = error as? TerminalTabOperationError {
            return operationError.localizedDescription
        }
        if let launcherError = error as? ExternalTerminalLauncherError {
            switch launcherError {
            case let .commandFailed(exitCode):
                return "无法在 Terminal 中打开（退出码 \(exitCode)）。"
            }
        }
        return "操作未完成：\(error.localizedDescription)"
    }
}
