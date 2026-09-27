import AppKit
import TmuxHubCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    let onBrowseSessions: (TerminalTarget) -> Void
    let onBrowseHerdr: (TerminalTarget) -> Void

    @State private var searchText = ""
    @State private var isAddingHost = false
    @State private var newDestination = ""
    @State private var errorMessage: String?

    private var quickSections: [SSHHostQuickAccessSection] {
        model.quickAccessSections()
    }

    private var searchResults: [SSHHost] {
        model.searchHosts(matching: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("工作区") {
                sidebarRow(
                    title: "主机库",
                    symbol: "rectangle.grid.2x2.fill",
                    tint: .blue,
                    selection: .overview
                )
                HStack {
                    sidebarRow(
                        title: "本机",
                        symbol: "macbook",
                        tint: .cyan,
                        selection: .local
                    )
                    .onTapGesture(count: 2) { terminals.openLocalShell() }
                    herdrButton(for: .local)
                }
                .tag(SidebarSelection.local)
                .contextMenu {
                    Button("Herdr 工作区") { onBrowseHerdr(.local) }
                    Button("查看 tmux 会话") { onBrowseSessions(.local) }
                    Button("登录 Shell") { terminals.openLocalShell() }
                }
            }

            Section("计算平台") {
                sidebarRow(
                    title: "HKUST HPC2",
                    symbol: "cpu",
                    tint: .purple,
                    selection: .platform("hkust-hpc2")
                )
            }

            if isSearching {
                Section {
                    if searchResults.isEmpty {
                        Text("没有匹配的 SSH 主机")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(searchResults) { host in
                            hostRow(host)
                        }
                    }
                } header: {
                    hostSectionHeader(title: "搜索结果", showsAddButton: true)
                }
            } else if quickSections.isEmpty {
                Section {
                    Text("固定常用主机后，它们会显示在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    hostSectionHeader(title: "快捷主机", showsAddButton: true)
                }
            } else {
                ForEach(quickSections) { section in
                    Section {
                        ForEach(section.hosts) { host in
                            hostRow(host)
                        }
                    } header: {
                        hostSectionHeader(
                            title: section.bucket.displayTitle,
                            showsAddButton: section.id == quickSections.first?.id
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("TmuxHub")
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机库")
        .alert("添加 SSH 目标", isPresented: $isAddingHost) {
            TextField("alias 或 user@host", text: $newDestination)
            Button("添加") { addHost() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("添加后会固定到侧边栏；连接参数仍由 ~/.ssh/config 和 SSH Agent 管理。")
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

    private func hostRow(_ host: SSHHost) -> some View {
        let selection = SidebarSelection.host(host.destination)
        return HStack(spacing: 9) {
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
                        model.selection == selection ? .semibold : .medium
                    ))
                    .lineLimit(1)
                Text(hostRowSubtitle(host))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                terminals.openOrResumeSSH(host.destination)
            } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.borderless)
            .help("连接或继续")
            .accessibilityLabel("连接或继续 \(host.destination)")
            herdrButton(for: .ssh(destination: host.destination))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(selection)
        .onTapGesture { show(selection) }
        .onTapGesture(count: 2) {
            show(selection)
            terminals.openOrResumeSSH(host.destination)
        }
        .contextMenu {
            Button("连接或继续", systemImage: "terminal") {
                terminals.openOrResumeSSH(host.destination)
            }
            Button("Herdr 工作区") {
                onBrowseHerdr(.ssh(destination: host.destination))
            }
            Button("查看 tmux 会话") {
                onBrowseSessions(.ssh(destination: host.destination))
            }
            Button("新建 tmux 会话") {
                terminals.openSSH(host.destination)
            }
            Button("复制 SSH 目标") {
                copy(host.destination)
            }
            Divider()
            if model.isPinned(host.destination) {
                Button("从侧边栏取消固定", systemImage: "pin.slash") {
                    model.setPinned(false, destination: host.destination)
                }
            } else {
                Button("固定到侧边栏", systemImage: "pin") {
                    model.setPinned(true, destination: host.destination)
                }
            }
            if model.isCustom(host.destination) {
                Button("移除手动目标", role: .destructive) {
                    model.removeCustomHost(host.destination)
                }
            }
        }
    }

    private func herdrButton(for target: TerminalTarget) -> some View {
        Button {
            onBrowseHerdr(target)
        } label: {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 26)
        }
        .buttonStyle(.borderless)
        .help("浏览 Herdr 工作区")
        .accessibilityLabel("浏览 Herdr 工作区")
    }

    private func hostSectionHeader(
        title: String,
        showsAddButton: Bool
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if showsAddButton {
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

    private func hostRowSubtitle(_ host: SSHHost) -> String {
        if model.isPinned(host.destination) {
            return "已固定"
        }
        return host.source == .configuration ? "SSH config" : "手动目标"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
