import AppKit
import TmuxHubCore
import SwiftUI

struct TmuxHubRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    @State private var sessionBrowserTarget: TerminalTarget?
    @State private var herdrBrowserTarget: TerminalTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                model: model,
                terminals: terminals,
                onBrowseSessions: browseSessions,
                onBrowseHerdr: browseHerdr
            )
            .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if !terminals.tabs.isEmpty {
                    TerminalTabBar(
                        terminals: terminals,
                        hosts: model.quickAccessHosts
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

    @ViewBuilder
    private var selectedContent: some View {
        switch model.selection {
        case .overview:
            HostOverviewView(model: model) { destination in
                model.selection = .host(destination)
            }
        case .local:
            LocalTerminalLandingView(
                terminals: terminals,
                onOpenShell: terminals.openLocalShell,
                onNewTmux: { terminals.openLocalTmux() },
                onBrowseSessions: { sessionBrowserTarget = .local },
                onBrowseHerdr: { browseHerdr(.local) }
            )
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

    private func browseSessions(_ target: TerminalTarget) {
        sessionBrowserTarget = target
    }

    private func browseHerdr(_ target: TerminalTarget) {
        herdrBrowserTarget = target
    }
}
