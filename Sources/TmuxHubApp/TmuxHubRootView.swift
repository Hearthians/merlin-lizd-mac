import AppKit
import TmuxHubCore
import SwiftUI

struct TmuxHubRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    @State private var sessionBrowserTarget: TerminalTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                model: model,
                terminals: terminals,
                onBrowseSessions: browseSessions
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
            HostOverviewView(sections: model.hostSections()) { destination in
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
                        browseSessions(.ssh(destination: destination))
                    },
                    hasSavedPassword: {
                        try terminals.hasSavedPassword(for: destination)
                    },
                    onSavePassword: {
                        try terminals.savePassword($0, for: destination)
                    },
                    onRemovePassword: {
                        try terminals.removePassword(for: destination)
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

    private func browseSessions(_ target: TerminalTarget) {
        if case let .ssh(destination) = target {
            terminals.noteHostUse(destination)
        }
        sessionBrowserTarget = target
    }
}
