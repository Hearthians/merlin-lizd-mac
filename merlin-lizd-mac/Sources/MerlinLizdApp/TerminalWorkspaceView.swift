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
                TerminalSessionHost(session: session)
                    .id(session.id)
                    .background(Color.black)
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

struct TerminalTabBar: View {
    @ObservedObject var terminals: TerminalTabsModel
    let devboxes: [DevboxInventory]

    @State private var pendingCloseID: String?
    @State private var renameID: String?
    @State private var renameText = ""

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
            "关闭终端标签？",
            isPresented: Binding(
                get: { pendingCloseID != nil },
                set: { if !$0 { pendingCloseID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("关闭标签", role: .destructive) {
                if let pendingCloseID {
                    terminals.close(pendingCloseID)
                }
                pendingCloseID = nil
            }
            Button("取消", role: .cancel) {
                pendingCloseID = nil
            }
        } message: {
            Text("远端 SSH 会断开，但 tmux 中的任务会继续运行；本机终端进程会结束。")
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
                    Text(tab.title)
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.leading, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

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
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
        }
        .contextMenu {
            Button("重命名") {
                renameText = tab.title
                renameID = tab.id
            }
            if let sessionName = tab.sessionName {
                Button("复制 tmux 会话名") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sessionName, forType: .string)
                }
            }
            Divider()
            Button("关闭", role: .destructive) {
                pendingCloseID = tab.id
            }
        }
        .help(tab.sessionName.map { "tmux: \($0)" } ?? "本机终端")
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
                        Button(machine.sshAlias ?? machine.devbox.name) {
                            terminals.openDevbox(machine)
                        }
                        .disabled(machine.devbox.status != "running" || machine.sshAlias == nil)
                    }
                }

                Menu("工作机", systemImage: "cpu") {
                    ForEach(devboxes) { machine in
                        if !machine.workers.isEmpty {
                            Menu(machine.sshAlias ?? machine.devbox.name) {
                                ForEach(machine.workers) { worker in
                                    Button("\(worker.gpuType ?? "CPU") · \(worker.id)") {
                                        terminals.openWorker(worker, on: machine)
                                    }
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

    private func tabSymbol(_ target: TerminalTarget) -> String {
        switch target {
        case .local: "macbook"
        case .devbox: "server.rack"
        case .worker: "cpu"
        }
    }
}
