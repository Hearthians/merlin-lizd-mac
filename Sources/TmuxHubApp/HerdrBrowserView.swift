import TmuxHubCore
import SwiftUI

@MainActor
final class HerdrBrowserModel: ObservableObject {
    @Published private(set) var sessions: [HerdrSessionSnapshot] = []
    @Published private(set) var isLoading = false
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var errorMessage: String?

    let target: TerminalTarget
    private let service: HerdrService

    init(target: TerminalTarget, service: HerdrService) {
        self.target = target
        self.service = service
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let discovered = try await service.discover(target: target)
            try Task.checkCancellation()
            sessions = discovered
            fetchedAt = Date()
        } catch is CancellationError {
            return
        } catch HerdrError.noRunningSessions {
            guard !Task.isCancelled else { return }
            sessions = []
            fetchedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct HerdrBrowserView: View {
    @StateObject private var model: HerdrBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var refreshVersion = 0
    @State private var collapsedWorkspaces: Set<WorkspaceKey> = []
    private let onOpen: (HerdrPaneRecord, String) -> Void

    init(
        target: TerminalTarget,
        service: HerdrService,
        onOpen: @escaping (HerdrPaneRecord, String) -> Void
    ) {
        _model = StateObject(wrappedValue: HerdrBrowserModel(target: target, service: service))
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Herdr 工作区", systemImage: "square.stack.3d.up")
                        .font(.title2.bold())
                    Text(targetLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    refreshVersion += 1
                }
                .disabled(model.isLoading)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if model.sessions.isEmpty {
                emptyContent
            } else {
                if let errorMessage = model.errorMessage {
                    MessageBanner(
                        text: "刷新失败，以下为上次读取的工作区。\(errorMessage)",
                        kind: .warning
                    )
                    .padding([.horizontal, .top], 16)
                }
                workspaceList
            }

            Divider()

            HStack {
                if model.fetchedAt != nil {
                    Text("\(workspaceCount) 个工作区 · \(terminalCount) 个终端")
                }
                Spacer()
                if let fetchedAt = model.fetchedAt {
                    Text("上次读取 \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 480, idealHeight: 560)
        .task(id: refreshVersion) { await model.refresh() }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if model.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取 Herdr 工作区…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("无法读取 Herdr", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("没有运行中的 Herdr 会话", systemImage: "square.stack.3d.up")
            } description: {
                Text("在这台主机打开 Herdr 后，点击“刷新”查看工作区和终端。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workspaceList: some View {
        List {
            ForEach(model.sessions, id: \.name) { session in
                Section {
                    if session.workspaces.isEmpty {
                        Text("此会话暂无工作区")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.workspaces) { workspace in
                        DisclosureGroup(isExpanded: expandedBinding(
                            for: WorkspaceKey(sessionName: session.sessionName, workspaceID: workspace.id)
                        )) {
                            if workspace.panes.isEmpty {
                                Text("此工作区暂无终端")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            }
                            ForEach(workspace.panes) { pane in
                                Button {
                                    onOpen(pane, workspace.label)
                                } label: {
                                    HerdrPaneRow(
                                        pane: pane,
                                        showsPaneID: workspace.panes.filter { $0.label == pane.label }.count > 1
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("打开 \(workspace.label) · \(pane.label)\n\(pane.reference.terminalID)")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(workspace.label, systemImage: "folder")
                                    .font(.headline)
                                if let cwd = workspace.cwd {
                                    Text(cwd)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                } header: {
                    Label(
                        session.sessionName == nil ? "默认会话" : session.name,
                        systemImage: "rectangle.stack"
                    )
                }
            }
        }
        .listStyle(.inset)
    }

    private var targetLabel: String {
        switch model.target {
        case .local: "本机"
        case let .ssh(destination): destination
        }
    }

    private var workspaceCount: Int {
        model.sessions.reduce(0) { $0 + $1.workspaces.count }
    }

    private var terminalCount: Int {
        model.sessions.flatMap(\.workspaces).reduce(0) { $0 + $1.panes.count }
    }

    private func expandedBinding(for key: WorkspaceKey) -> Binding<Bool> {
        Binding(
            get: { !collapsedWorkspaces.contains(key) },
            set: { expanded in
                if expanded { collapsedWorkspaces.remove(key) }
                else { collapsedWorkspaces.insert(key) }
            }
        )
    }

    private struct WorkspaceKey: Hashable {
        let sessionName: String?
        let workspaceID: String
    }
}

private struct HerdrPaneRow: View {
    let pane: HerdrPaneRecord
    let showsPaneID: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.agent == nil ? "terminal" : "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pane.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let agent = pane.agent, agent.caseInsensitiveCompare(pane.label) != .orderedSame {
                        Text(agent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if showsPaneID {
                        Text(pane.paneID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(pane.workingDirectory ?? "目录未知")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if pane.agent != nil || pane.agentStatus != nil {
                StatusPill(label: statusLabel, color: statusColor, symbol: statusSymbol)
                    .help(pane.agentStatus ?? "Herdr 未报告状态")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var statusLabel: String {
        switch pane.agentStatus?.lowercased() {
        case "idle": "空闲"
        case "running", "working", "busy": "运行中"
        case "waiting": "等待"
        case "done": "待查看"
        case "blocked": "等待处理"
        case "error": "错误"
        case "stopped": "已停止"
        case "unknown", nil: "状态未知"
        default: pane.agentStatus ?? "状态未知"
        }
    }

    private var statusColor: Color {
        switch pane.agentStatus?.lowercased() {
        case "running", "working", "busy": .blue
        case "waiting": .orange
        case "done": .purple
        case "blocked": .orange
        case "error": .red
        default: .secondary
        }
    }

    private var statusSymbol: String {
        switch pane.agentStatus?.lowercased() {
        case "running", "working", "busy": "bolt.fill"
        case "waiting": "pause.circle"
        case "done": "eye"
        case "blocked", "error": "exclamationmark.circle"
        case "unknown", nil: "questionmark.circle"
        default: "circle"
        }
    }
}
