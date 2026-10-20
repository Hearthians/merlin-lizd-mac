import AppKit
import TmuxHubCore
import SwiftUI

struct TmuxHubRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    @ObservedObject var hpc2: HPC2PlatformModel
    @ObservedObject var hpc3: HPC2PlatformModel
    @ObservedObject var hpc4: HPC2PlatformModel
    @ObservedObject var mesh: NetworkMeshModel
    @ObservedObject var forwardedLinks: ForwardedLinksModel
    var propertiesReader = SSHHostPropertiesReader()
    @State private var sessionBrowserTarget: TerminalTarget?
    @State private var herdrBrowserTarget: TerminalTarget?
    @State private var showsAddSSHHost = false
    @State private var fileBrowserDestination: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var propertiesTarget: PropertiesTarget?

    private enum PropertiesTarget: Identifiable {
        case host(SSHHost)
        case platform(String)

        var id: String {
            switch self {
            case let .host(host): "ssh:\(host.destination)"
            case let .platform(id): "platform:\(id)"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                sidebarHeader
                SidebarView(
                    model: model,
                    terminals: terminals,
                    platforms: [hpc2.profile, hpc3.profile, hpc4.profile],
                    onAddHost: { showsAddSSHHost = true },
                    onShowProperties: showProperties,
                    onBrowseSessions: browseSessions,
                    onBrowseHerdr: browseHerdr
                )
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 360)
            .ignoresSafeArea(.container, edges: .top)
        } detail: {
            VStack(spacing: 0) {
                if !terminals.tabs.isEmpty {
                    HStack(spacing: 0) {
                        if isSidebarHidden {
                            showSidebarControl
                        }
                        TerminalTabBar(
                            terminals: terminals,
                            hosts: model.quickAccessHosts,
                            onRefresh: refresh
                        )
                    }
                } else if isSidebarHidden {
                    HStack(spacing: 0) {
                        showSidebarControl
                        Spacer(minLength: 0)
                    }
                    .background(WindowHeaderDragArea())
                }
                Group {
                    if terminals.selectedTabID != nil {
                        TerminalWorkspaceView(terminals: terminals)
                    } else {
                        selectedContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Scroll views must stop at the tab bar, even when the window
                // content extends into the native title-bar area.
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(removing: .sidebarToggle)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: Binding(
            get: { fileBrowserDestination != nil },
            set: { if !$0 { fileBrowserDestination = nil } }
        )) {
            if let destination = fileBrowserDestination {
                RemoteFileBrowser(alias: destination, service: terminals.remoteFileService)
            }
        }
        .task { await mesh.startMonitoring(sshHosts: model.hosts) }
        .focusedSceneValue(\.addSSHHost, { showsAddSSHHost = true })
        .focusedSceneValue(\.refreshHub, refresh)
        .focusedSceneValue(\.toggleHubSidebar, toggleSidebar)
        .sheet(item: $propertiesTarget) { target in
            switch target {
            case let .host(host):
                SSHHostPropertiesSheet(host: host, reader: propertiesReader) { settings in
                    _ = try await model.updateConnection(settings)
                }
            case let .platform(id):
                if let platform = platformModel(for: id) {
                    HPC2PropertiesSheet(model: platform)
                }
            }
        }
        .sheet(isPresented: $showsAddSSHHost) {
            AddSSHHostSheet(
                onAddConfiguration: { configuration in
                    _ = try await model.add(configuration: configuration)
                    terminals.selectedTabID = nil
                },
                onAddDestination: { destination in
                    _ = try model.add(destination: destination)
                    terminals.selectedTabID = nil
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { sessionBrowserTarget != nil },
                set: { if !$0 { sessionBrowserTarget = nil } }
            )
        ) {
            if let sessionBrowserTarget {
                TmuxSessionBrowserView(
                    target: sessionBrowserTarget,
                    terminals: terminals
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { herdrBrowserTarget != nil },
                set: { if !$0 { herdrBrowserTarget = nil } }
            )
        ) {
            if let herdrBrowserTarget {
                HerdrBrowserView(
                    target: herdrBrowserTarget,
                    service: terminals.herdrService
                ) { pane, workspaceLabel in
                    terminals.openHerdr(
                        pane,
                        target: herdrBrowserTarget,
                        workspaceLabel: workspaceLabel
                    )
                    self.herdrBrowserTarget = nil
                }
            }
        }
    }

    private var isSidebarHidden: Bool {
        columnVisibility == .detailOnly
    }

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .frame(width: 20, height: 24)
            }
            .help("隐藏侧边栏")
            .accessibilityLabel("隐藏侧边栏")

            Text("TmuxHub")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .layoutPriority(-1)

            Spacer(minLength: 4)

            Menu {
                ForEach(model.hosts, id: \.destination) { host in
                    Button(host.destination) { fileBrowserDestination = host.destination }
                }
            } label: {
                Image(systemName: "folder")
                    .frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择 SSH 主机，浏览和下载文件")
            .accessibilityLabel("远程文件")
            .disabled(model.hosts.isEmpty)

            Button {
                showsAddSSHHost = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 24)
            }
            .help("添加 SSH 主机")
            .accessibilityLabel("添加 SSH 主机")

            if terminals.tabs.isEmpty {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 24)
                }
                .help("刷新（⌘R）")
                .accessibilityLabel("刷新")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, WindowHeaderDragArea.leadingControlsInset)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(WindowHeaderDragArea())
    }

    private var showSidebarControl: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
                .frame(width: 28, height: 38)
        }
        .buttonStyle(.plain)
        .help("显示侧边栏")
        .accessibilityLabel("显示侧边栏")
        .padding(.leading, WindowHeaderDragArea.leadingControlsInset)
        .background(WindowHeaderDragArea())
    }

    private func toggleSidebar() {
        columnVisibility = isSidebarHidden ? .all : .detailOnly
    }

    private func refresh() {
        if model.selection == .mesh {
            Task { await mesh.refresh(sshHosts: model.hosts) }
        } else if model.selection == .portForwarding {
            Task { await forwardedLinks.refreshAll() }
        } else if case let .platform(id) = model.selection,
            let platform = platformModel(for: id) {
            Task { await platform.refresh(force: true) }
        } else {
            model.refresh()
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch model.selection {
        case .overview:
            HostOverviewView(
                model: model,
                onAddHost: { showsAddSSHHost = true },
                onShowProperties: { showProperties(.host($0)) }
            ) { destination in
                model.selection = .host(destination)
            }
        case .mesh:
            NetworkMeshView(
                model: mesh,
                sshHosts: model.hosts,
                onConnect: terminals.openOrResumeSSH,
                onHostsChanged: model.refresh
            )
        case .portForwarding:
            ForwardedLinksView(model: forwardedLinks)
        case .local:
            LocalTerminalLandingView(
                terminals: terminals,
                onOpenShell: terminals.openLocalShell,
                onNewTmux: { terminals.openLocalTmux() },
                onBrowseSessions: { sessionBrowserTarget = .local },
                onBrowseHerdr: { browseHerdr(.local) }
            )
        case let .platform(platformID):
            if let platform = platformModel(for: platformID) {
                HPC2PlatformView(
                    model: platform,
                    onConnect: { receipt in
                        terminals.openAttachOnlyRemoteTmux(
                            destination: receipt.loginDestination,
                            sessionName: receipt.tmuxSessionName,
                            title: "\(platform.profile.name) · \(receipt.jobName)"
                        )
                    },
                    onOpenLoginShell: {
                        terminals.openOrResumeSSH(platform.profile.loginDestination)
                    }
                )
                .id(platformID)
            } else {
                ContentUnavailableView(
                    "平台不可用",
                    systemImage: "cpu",
                    description: Text("没有找到这个计算平台。")
                )
            }
        case let .host(destination):
            if let host = model.host(destination: destination) {
                SSHHostDetailView(
                    host: host,
                    terminals: terminals,
                    onConnect: { terminals.openOrResumeSSH(destination) },
                    onNewSession: { terminals.openSSH(destination) },
                    onBrowseSessions: {
                        browseSessions(.ssh(destination: destination))
                    },
                    onBrowseHerdr: {
                        browseHerdr(.ssh(destination: destination))
                    },
                    hasSavedPassword: {
                        try await terminals.hasSavedPassword(for: destination)
                    },
                    onSavePassword: {
                        try await terminals.savePassword($0, for: destination)
                    },
                    onAuthorizePassword: {
                        try await terminals.authorizeSavedPassword(for: destination)
                    },
                    onRemovePassword: {
                        try await terminals.removePassword(for: destination)
                    }
                )
                .id(destination)
            } else {
                ContentUnavailableView(
                    "SSH 目标已移除",
                    systemImage: "network.slash",
                    description: Text("刷新 SSH 配置或重新添加这个目标。")
                )
            }
        }
    }

    private func platformModel(for id: String) -> HPC2PlatformModel? {
        [hpc2, hpc3, hpc4].first { $0.cluster.id == id }
    }

    private func browseSessions(_ target: TerminalTarget) {
        sessionBrowserTarget = target
    }

    private func showProperties(_ selection: SidebarSelection) {
        switch selection {
        case let .host(destination):
            if let host = model.host(destination: destination) {
                propertiesTarget = .host(host)
            }
        case let .platform(id):
            if platformModel(for: id) != nil { propertiesTarget = .platform(id) }
        default:
            break
        }
    }

    private func browseHerdr(_ target: TerminalTarget) {
        herdrBrowserTarget = target
    }
}
