import AppKit
import SSHTmuxHubCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    let onBrowseSessions: (TerminalTarget) -> Void

    @State private var searchText = ""
    @State private var isAddingHost = false
    @State private var newDestination = ""
    @State private var errorMessage: String?

    private var filteredHosts: [SSHHost] {
        guard !searchText.isEmpty else { return model.hosts }
        return model.hosts.filter {
            $0.destination.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("工作区") {
                sidebarRow(
                    title: "主机总览",
                    symbol: "rectangle.grid.2x2.fill",
                    tint: .blue,
                    selection: .overview
                )
                sidebarRow(
                    title: "本机",
                    symbol: "macbook",
                    tint: .cyan,
                    selection: .local
                )
                .onTapGesture(count: 2) { terminals.openLocalShell() }
            }

            Section {
                ForEach(filteredHosts) { host in
                    let selection = SidebarSelection.host(host.destination)
                    HStack(spacing: 9) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.green)
                            .frame(width: 26, height: 26)
                            .background(
                                Color.green.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.destination)
                                .font(.callout.weight(
                                    model.selection == selection
                                        ? .semibold : .medium
                                ))
                                .lineLimit(1)
                            Text(host.source == .configuration
                                ? "SSH config" : "手动添加")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .tag(selection)
                    .onTapGesture { show(selection) }
                    .onTapGesture(count: 2) {
                        show(selection)
                        onBrowseSessions(.ssh(destination: host.destination))
                    }
                    .contextMenu {
                        Button("查看 tmux 会话") {
                            onBrowseSessions(.ssh(destination: host.destination))
                        }
                        Button("新建 tmux 会话") {
                            terminals.openSSH(host.destination)
                        }
                        Button("复制 SSH 目标") {
                            copy(host.destination)
                        }
                        if model.isCustom(host.destination) {
                            Divider()
                            Button("移除手动目标", role: .destructive) {
                                model.removeCustomHost(host.destination)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("SSH 主机")
                    Spacer()
                    Button {
                        newDestination = ""
                        isAddingHost = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("添加 SSH 目标")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SSH Tmux Hub")
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索 SSH 主机")
        .alert("添加 SSH 目标", isPresented: $isAddingHost) {
            TextField("alias 或 user@host", text: $newDestination)
            Button("添加") { addHost() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("使用现有 ~/.ssh/config 和 SSH Agent；不会保存密码或私钥。")
        }
        .alert("无法添加主机", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "SSH 目标格式无效。")
        }
    }

    private func sidebarRow(
        title: String,
        symbol: String,
        tint: Color,
        selection: SidebarSelection
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            Text(title)
                .font(.callout.weight(
                    model.selection == selection ? .semibold : .medium
                ))
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(selection)
        .onTapGesture { show(selection) }
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding(
            get: { model.selection },
            set: { if model.selection != $0 { show($0) } }
        )
    }

    private func show(_ selection: SidebarSelection) {
        model.selection = selection
        terminals.selectedTabID = nil
    }

    private func addHost() {
        do {
            _ = try model.add(destination: newDestination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
