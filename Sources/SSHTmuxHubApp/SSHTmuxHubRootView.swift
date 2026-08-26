import AppKit
import SSHTmuxHubCore
import SwiftUI

struct SSHTmuxHubRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    @State private var sessionBrowserTarget: TerminalTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                model: model,
                terminals: terminals,
                onBrowseSessions: { sessionBrowserTarget = $0 }
            )
            .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if !terminals.tabs.isEmpty {
                    TerminalTabBar(
                        terminals: terminals,
                        hosts: model.hosts
                    )
                }
                if terminals.selectedTabID != nil {
                    TerminalWorkspaceView(terminals: terminals)
                } else {
                    selectedContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("重新读取 SSH 配置", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
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
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch model.selection {
        case .overview:
            HostOverviewView(hosts: model.hosts) { destination in
                model.selection = .host(destination)
            }
        case .local:
            LocalTerminalLandingView(
                onOpenShell: terminals.openLocalShell,
                onNewTmux: { terminals.openLocalTmux() },
                onBrowseSessions: { sessionBrowserTarget = .local }
            )
        case let .host(destination):
            if let host = model.host(destination: destination) {
                SSHHostDetailView(
                    host: host,
                    onNewSession: { terminals.openSSH(destination) },
                    onBrowseSessions: {
                        sessionBrowserTarget = .ssh(destination: destination)
                    }
                )
            } else {
                ContentUnavailableView(
                    "SSH 目标已移除",
                    systemImage: "network.slash",
                    description: Text("刷新 SSH 配置或重新添加这个目标。")
                )
            }
        }
    }
}
