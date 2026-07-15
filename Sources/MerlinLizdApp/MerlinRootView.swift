import AppKit
import MerlinLizdCore
import SwiftUI

struct MerlinRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel
    @ObservedObject var codexDrawer: CodexDrawerModel
    let metricsStreamer: WorkerMetricsStreamer
    @State private var sessionBrowserTarget: TerminalTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, terminals: terminals)
                .navigationSplitViewColumnWidth(min: 245, ideal: 285, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if !terminals.tabs.isEmpty {
                    TerminalTabBar(
                        terminals: terminals,
                        codexDrawer: codexDrawer,
                        devboxes: model.devboxes
                    )
                }

                if let message = model.message {
                    MessageBanner(text: message.text, kind: bannerKind(message.kind))
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }

                if terminals.selectedTabID != nil {
                    TerminalWorkspaceView(
                        terminals: terminals,
                        codexDrawer: codexDrawer
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    selectedContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRefreshing
                    || model.isStartingDevbox
                    || model.isRefreshingWorkers
                {
                    ProgressView()
                        .controlSize(.small)
                }
                if model.isRefreshingWorkers {
                    Text("同步 Worker")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("开发机列表已可使用，Worker 信息正在后台更新")
                }
                if let refreshedAt = model.snapshot?.refreshedAt {
                    Text(refreshedAt, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("最近刷新时间")
                }
                Button {
                    Task { await model.refresh(forceReadinessProbe: true) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
        .task {
            await model.runRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: sessionBrowserTarget) { _, target in
            if let target {
                terminals.prioritize(target)
            }
        }
        .confirmationDialog(
            "启动开发机？",
            isPresented: Binding(
                get: { model.pendingStartDevbox != nil },
                set: { if !$0 { model.pendingStartDevbox = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("启动") {
                Task { await model.startPendingDevbox() }
            }
            Button("取消", role: .cancel) {
                model.pendingStartDevbox = nil
            }
        } message: {
            if let machine = model.pendingStartDevbox {
                Text("将启动 \(machine.sshAlias ?? machine.devbox.name)（\(machine.devbox.sid)）。")
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
            OverviewView(
                snapshot: model.snapshot,
                isRefreshing: model.isRefreshing,
                onRefresh: {
                    Task { await model.refresh(forceReadinessProbe: true) }
                },
                onConnectDevbox: terminals.openDevbox
            )
        case .allWorkers:
            AllWorkersView(devboxes: model.devboxes) { machine, worker in
                terminals.openWorker(worker, on: machine)
            }
        case .local:
            LocalTerminalLandingView(
                onOpen: terminals.openLocal,
                onBrowseSessions: { sessionBrowserTarget = .local }
            )
        case let .devbox(sid):
            if let machine = model.devbox(sid: sid) {
                DevboxDetailView(
                    machine: machine,
                    onConnect: { terminals.openDevbox(machine) },
                    onBrowseSessions: {
                        guard let alias = machine.sshAlias else { return }
                        sessionBrowserTarget = .devbox(
                            sid: machine.devbox.sid,
                            name: machine.devbox.name,
                            alias: alias
                        )
                    },
                    onStart: { model.requestStart(machine) },
                    onConnectWorker: { terminals.openWorker($0, on: machine) }
                )
            } else {
                MissingSelectionView()
            }
        case let .worker(devboxSID, workerID):
            if let (machine, worker) = model.worker(devboxSID: devboxSID, workerID: workerID) {
                WorkerDetailView(
                    machine: machine,
                    worker: worker,
                    onConnect: { terminals.openWorker(worker, on: machine) },
                    onBrowseSessions: {
                        guard let alias = machine.sshAlias else { return }
                        sessionBrowserTarget = .worker(
                            devboxSID: machine.devbox.sid,
                            devboxName: machine.devbox.name,
                            alias: alias,
                            workerID: worker.id
                        )
                    },
                    metricsStreamer: metricsStreamer
                )
            } else {
                MissingSelectionView()
            }
        }
    }

    private func bannerKind(_ kind: AppMessage.Kind) -> MessageBanner.Kind {
        switch kind {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}

private struct LocalTerminalLandingView: View {
    let onOpen: () -> Void
    let onBrowseSessions: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("本机终端")
                .font(.title.bold())
            Text("使用当前登录 shell，并继承 SSH Agent 与系统环境。")
                .foregroundStyle(.secondary)
            HStack {
                Button("打开终端", systemImage: "plus", action: onOpen)
                    .buttonStyle(.borderedProminent)
                Button("现有 tmux 会话", systemImage: "rectangle.stack", action: onBrowseSessions)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MissingSelectionView: View {
    var body: some View {
        ContentUnavailableView(
            "目标已不可用",
            systemImage: "questionmark.folder",
            description: Text("它可能在最近一次刷新后被移除。")
        )
    }
}
