import AppKit
import TmuxHubCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    let platforms: [SlurmPlatformProfile]
    let onAddHost: () -> Void
    let onShowProperties: (SidebarSelection) -> Void
    let onBrowseSessions: (TerminalTarget) -> Void
    let onBrowseHerdr: (TerminalTarget) -> Void

    @State private var searchText = ""

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
                sidebarRow(
                    title: "主机互联",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: .orange,
                    selection: .mesh
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
                ForEach(platforms) { platform in
                    sidebarRow(
                        title: platform.name,
                        symbol: "cpu",
                        tint: .purple,
                        selection: .platform(platform.id)
                    )
                    .contextMenu {
                        Button("属性", systemImage: "slider.horizontal.3") {
                            onShowProperties(.platform(platform.id))
                        }
                    }
                }
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
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机库")
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
            Divider()
            Button("属性", systemImage: "slider.horizontal.3") {
                onShowProperties(.host(host.destination))
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
                    onAddHost()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("添加 SSH 主机")
                .accessibilityLabel("添加 SSH 主机")
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
