import MerlinLizdCore
import SwiftUI

@MainActor
final class TmuxSessionBrowserModel: ObservableObject {
    @Published private(set) var sessions: [TmuxSessionRecord] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isStale = true
    @Published private(set) var isVerifying = false
    @Published private(set) var hasKnownEvidence = false
    @Published private(set) var errorMessage: String?

    let target: TerminalTarget
    private let discovery: TmuxSessionDiscovery
    private var knownSessions: [TmuxSessionRecord]
    private var refreshTask: Task<Void, Never>?

    init(
        target: TerminalTarget,
        discovery: TmuxSessionDiscovery,
        initialSessions: [TmuxSessionRecord]
    ) {
        self.target = target
        self.discovery = discovery
        knownSessions = initialSessions
        sessions = initialSessions
        hasKnownEvidence = !initialSessions.isEmpty
    }

    func load(force: Bool = false) async {
        let snapshot = await discovery.peekSnapshot(target: target)
        publish(snapshot)
        if !force, let snapshot, snapshot.isFresh(at: Date()) {
            return
        }
        startRefresh(force: force)
    }

    /// Publishes newer in-memory evidence without starting remote work.
    func synchronizeCachedSnapshot(
        knownSessions: [TmuxSessionRecord]
    ) async {
        self.knownSessions = knownSessions
        guard let snapshot = await discovery.peekSnapshot(target: target) else {
            sessions = knownSessions
            hasKnownEvidence = !knownSessions.isEmpty
            return
        }
        publish(snapshot)
    }

    func removeSessions(named names: Set<String>) {
        sessions.removeAll { names.contains($0.name) }
    }

    private func startRefresh(force: Bool) {
        guard refreshTask == nil else { return }
        isVerifying = true
        let discovery = discovery
        let target = target
        refreshTask = Task { [weak self] in
            let snapshot = if force {
                await discovery.retryRefresh(
                    target: target,
                    lane: .foreground
                )
            } else {
                await discovery.refreshIfStale(
                    target: target,
                    lane: .foreground
                )
            }
            guard !Task.isCancelled else { return }
            self?.publishRefresh(snapshot)
            self?.refreshTask = nil
        }
    }

    private func publish(_ snapshot: TmuxSessionSnapshot?) {
        guard let snapshot else {
            hasKnownEvidence = !knownSessions.isEmpty
            isStale = true
            isVerifying = false
            errorMessage = nil
            return
        }
        hasKnownEvidence = true
        sessions = merged(snapshot.sessions, knownSessions)
        fetchedAt = snapshot.fetchedAt
        isStale = !snapshot.isFresh(at: Date())
        isVerifying = snapshot.verification == .verifying
        errorMessage = Self.message(for: snapshot.lastError)
    }

    private func publishRefresh(_ snapshot: TmuxSessionSnapshot) {
        let previousFetchedAt = fetchedAt
        fetchedAt = snapshot.fetchedAt
        hasKnownEvidence = true
        isStale = !snapshot.isFresh(at: Date())
        isVerifying = snapshot.verification == .verifying
        errorMessage = Self.message(for: snapshot.lastError)
        if
            snapshot.readiness == .ready,
            snapshot.lastError == nil,
            previousFetchedAt == nil || snapshot.fetchedAt > previousFetchedAt!
        {
            sessions = snapshot.sessions
        }
    }

    private func merged(
        _ snapshotSessions: [TmuxSessionRecord],
        _ knownSessions: [TmuxSessionRecord]
    ) -> [TmuxSessionRecord] {
        var seen: Set<String> = []
        return (snapshotSessions + knownSessions).filter {
            seen.insert($0.name).inserted
        }
    }

    private static func message(
        for error: TmuxSessionDiscoveryError?
    ) -> String? {
        switch error {
        case .workerNotReady:
            "Worker 尚未就绪。"
        case .localTmuxNotFound:
            "本机未找到 tmux。"
        case .commandFailed, .transport:
            "无法读取 tmux 会话，请检查连接状态。"
        case nil:
            nil
        }
    }
}

struct TmuxSessionBrowserView: View {
    @StateObject private var model: TmuxSessionBrowserModel
    @ObservedObject var terminals: TerminalTabsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSessionNames: Set<String> = []
    @State private var pendingTerminationNames: Set<String> = []
    @State private var isTerminating = false
    @State private var terminationMessage: String?

    init(target: TerminalTarget, terminals: TerminalTabsModel) {
        _model = StateObject(wrappedValue: TmuxSessionBrowserModel(
            target: target,
            discovery: terminals.tmuxSessionDiscovery,
            initialSessions: terminals.knownTmuxSessions(for: target)
        ))
        self.terminals = terminals
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("tmux 会话")
                        .font(.title2.bold())
                    Text(targetLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(targetLabel)
                    verificationStatus
                }
                Spacer()
                if model.isVerifying || isTerminating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load(force: true) }
                }
                .disabled(model.isVerifying || isTerminating)
                Button("新建", systemImage: "plus") {
                    requestNewSession()
                }
                .disabled(isTerminating)
                Button("完成") {
                    dismiss()
                }
                .disabled(isTerminating)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if let errorMessage = model.errorMessage,
                model.sessions.isEmpty,
                !model.hasKnownEvidence
            {
                MessageBanner(text: errorMessage, kind: .error)
                    .padding()
            } else if model.sessions.isEmpty {
                VStack(spacing: 0) {
                    if let errorMessage = model.errorMessage {
                        MessageBanner(text: errorMessage, kind: .warning)
                            .padding()
                    }
                    if !model.isVerifying {
                        ContentUnavailableView(
                            "没有 tmux 会话",
                            systemImage: "rectangle.stack",
                            description: Text(emptyStateDescription)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if let errorMessage = model.errorMessage {
                        MessageBanner(text: errorMessage, kind: .warning)
                            .padding()
                    }
                    List(model.sessions) { session in
                        HStack {
                            Button {
                                toggleSelection(session.name)
                            } label: {
                                Image(systemName: selectedSessionNames.contains(session.name)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedSessionNames.contains(session.name)
                                ? Color.accentColor
                                : Color.secondary)
                            .disabled(isTerminating)
                            .accessibilityLabel(
                                selectedSessionNames.contains(session.name)
                                    ? "取消选择 \(session.name)"
                                    : "选择 \(session.name)"
                            )
                            Image(systemName: "rectangle.stack.fill")
                                .foregroundStyle(.tint)
                            Text(session.name)
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .help("tmux: \(session.name)")
                            Spacer()
                            Button("接入") {
                                terminals.attachExistingSession(
                                    session.name,
                                    target: model.target
                                )
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isTerminating)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)

                    Divider()
                    sessionManagementBar
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .task {
            await model.load(force: false)
        }
        .onChange(of: model.sessions) { _, sessions in
            selectedSessionNames.formIntersection(Set(sessions.map(\.name)))
        }
        .confirmationDialog(
            "终止 \(pendingTerminationNames.count) 个 tmux 会话？",
            isPresented: Binding(
                get: { !pendingTerminationNames.isEmpty },
                set: { if !$0 { pendingTerminationNames = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                "终止所选会话",
                role: .destructive,
                action: terminatePendingSessions
            )
            Button("取消", role: .cancel) {
                pendingTerminationNames = []
            }
        } message: {
            Text("会话内正在运行的任务会停止；引用这些会话的本地标签也会关闭。此操作无法撤销。")
        }
        .alert("tmux 批量操作", isPresented: Binding(
            get: { terminationMessage != nil },
            set: { if !$0 { terminationMessage = nil } }
        )) {
            Button("好", role: .cancel) {
                terminationMessage = nil
            }
        } message: {
            Text(terminationMessage ?? "操作未完成。")
        }
    }

    @ViewBuilder
    private var verificationStatus: some View {
        if model.isVerifying {
            Text("后台核对中")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let fetchedAt = model.fetchedAt {
            if model.isStale {
                HStack(spacing: 2) {
                    Text("缓存 ·")
                    Text(fetchedAt, style: .time)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("刚刚更新")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sessionManagementBar: some View {
        HStack(spacing: 10) {
            Button("选择 App 会话", systemImage: "wand.and.stars") {
                selectedSessionNames = managedSessionNames
            }
            .disabled(managedSessionNames.isEmpty || isTerminating)

            Button(
                allSessionsSelected
                    ? "取消全选"
                    : "全选",
                systemImage: allSessionsSelected
                    ? "circle"
                    : "checkmark.circle"
            ) {
                if allSessionsSelected {
                    selectedSessionNames = []
                } else {
                    selectedSessionNames = Set(model.sessions.map(\.name))
                }
            }
            .disabled(model.sessions.isEmpty || isTerminating)

            Spacer()
            Text("已选择 \(selectedSessionNames.count) 个")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                pendingTerminationNames = selectedSessionNames
            } label: {
                Label("终止所选", systemImage: "trash")
            }
            .disabled(selectedSessionNames.isEmpty || isTerminating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var managedSessionNames: Set<String> {
        Set(model.sessions.lazy.filter { $0.name.hasPrefix("mlz-") }.map(\.name))
    }

    private var allSessionsSelected: Bool {
        !model.sessions.isEmpty
            && selectedSessionNames.count == model.sessions.count
    }

    private func toggleSelection(_ name: String) {
        if selectedSessionNames.contains(name) {
            selectedSessionNames.remove(name)
        } else {
            selectedSessionNames.insert(name)
        }
    }

    private func terminatePendingSessions() {
        let names = pendingTerminationNames
        pendingTerminationNames = []
        guard !names.isEmpty else { return }
        isTerminating = true

        Task { @MainActor in
            let result = await terminals.terminateTmuxSessions(
                names,
                target: model.target
            )
            model.removeSessions(named: result.succeeded)
            selectedSessionNames.subtract(result.succeeded)
            isTerminating = false

            if !result.failed.isEmpty {
                let failedNames = result.failed.sorted().joined(separator: "、")
                terminationMessage = result.succeeded.isEmpty
                    ? "未能终止：\(failedNames)。请刷新后重试。"
                    : "已终止 \(result.succeeded.count) 个；以下会话失败：\(failedNames)。"
            }
        }
    }

    private func requestNewSession() {
        let target = model.target
        dismiss()
        Task { @MainActor in
            await Task.yield()
            terminals.requestNewTmuxSession(on: target)
        }
    }

    private var targetLabel: String {
        switch model.target {
        case .local:
            "本机"
        case let .devbox(_, name, _):
            name
        case let .worker(_, devboxName, _, workerID):
            "\(devboxName) · Worker \(workerID)"
        case let .task(runID, name, _, _):
            "\(name) · \(runID)"
        }
    }

    private var emptyStateDescription: String {
        switch model.target {
        case .local:
            "本机尚无可接入的 tmux 会话；“打开终端”会启动普通登录 shell。"
        case .devbox, .worker:
            "打开新终端时，App 会自动创建一个可恢复的会话。"
        case .task:
            "可以新建一个由 MerlinHub 管理的任务实例 tmux 会话。"
        }
    }
}
