import TmuxHubCore
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
    private let restoredSessions: [TmuxSessionRecord]
    private var refreshTask: Task<Void, Never>?

    init(
        target: TerminalTarget,
        discovery: TmuxSessionDiscovery,
        initialSessions: [TmuxSessionRecord]
    ) {
        self.target = target
        self.discovery = discovery
        restoredSessions = initialSessions
        sessions = initialSessions
        hasKnownEvidence = !initialSessions.isEmpty
    }

    func load(force: Bool = false) async {
        publish(await discovery.peekSnapshot(target: target))
        if !force, let snapshot = await discovery.peekSnapshot(target: target),
            snapshot.isFresh(at: Date())
        {
            return
        }
        startRefresh(force: force)
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
                await discovery.refresh(target: target, lane: .foreground)
            } else {
                await discovery.refreshIfStale(target: target, lane: .foreground)
            }
            guard !Task.isCancelled else { return }
            self?.publishRefresh(snapshot)
            self?.refreshTask = nil
        }
    }

    private func publish(_ snapshot: TmuxSessionSnapshot?) {
        guard let snapshot else {
            hasKnownEvidence = !restoredSessions.isEmpty
            isStale = true
            isVerifying = false
            errorMessage = nil
            return
        }
        hasKnownEvidence = true
        sessions = merged(snapshot.sessions, restoredSessions)
        fetchedAt = snapshot.fetchedAt
        isStale = !snapshot.isFresh(at: Date())
        isVerifying = snapshot.verification == .verifying
        errorMessage = Self.message(for: snapshot.lastError)
    }

    private func publishRefresh(_ snapshot: TmuxSessionSnapshot) {
        fetchedAt = snapshot.fetchedAt
        hasKnownEvidence = true
        isStale = !snapshot.isFresh(at: Date())
        isVerifying = snapshot.verification == .verifying
        errorMessage = Self.message(for: snapshot.lastError)
        if snapshot.readiness == .ready, snapshot.lastError == nil {
            sessions = snapshot.sessions
        }
    }

    private func merged(
        _ discovered: [TmuxSessionRecord],
        _ restored: [TmuxSessionRecord]
    ) -> [TmuxSessionRecord] {
        var seen: Set<String> = []
        return (discovered + restored).filter { seen.insert($0.name).inserted }
    }

    private static func message(for error: TmuxSessionDiscoveryError?) -> String? {
        switch error {
        case .localTmuxNotFound:
            "本机未找到 tmux。"
        case .commandFailed, .transport:
            "无法读取 tmux 会话。请检查 SSH 认证、网络和远端 tmux。"
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
    @State private var isCreatingSession = false
    @State private var newSessionName = ""
    @State private var creationErrorMessage: String?

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
                    verificationStatus
                }
                Spacer()
                if model.isVerifying || isTerminating {
                    ProgressView().controlSize(.small)
                }
                Button("新建", systemImage: "plus") {
                    newSessionName = ""
                    isCreatingSession = true
                }
                .disabled(isTerminating)
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load(force: true) }
                }
                .disabled(model.isVerifying || isTerminating)
                Button("完成") { dismiss() }
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
                Spacer()
            } else if model.sessions.isEmpty {
                if let errorMessage = model.errorMessage {
                    MessageBanner(text: errorMessage, kind: .warning)
                        .padding()
                }
                if !model.isVerifying {
                    ContentUnavailableView(
                        "没有 tmux 会话",
                        systemImage: "rectangle.stack",
                        description: Text("点“新建”会创建并接入一个可恢复会话。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    if let errorMessage = model.errorMessage {
                        MessageBanner(text: errorMessage, kind: .warning)
                            .padding()
                    }
                    List(model.sessions) { session in
                        let externallyManaged = terminals.isTmuxSessionManagedExternally(
                            sessionName: session.name,
                            target: model.target
                        )
                        HStack {
                            Button {
                                toggleSelection(session.name)
                            } label: {
                                Image(systemName: selectedSessionNames.contains(session.name)
                                    ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedSessionNames.contains(session.name)
                                ? Color.accentColor : Color.secondary)
                            .disabled(externallyManaged || isTerminating)
                            Image(systemName: "rectangle.stack.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name).font(.body.monospaced())
                                if externallyManaged {
                                    Label("由计算平台管理", systemImage: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let identity = session.identity {
                                    Text(identity.stableDisplayString)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("接入") {
                                terminals.attachExistingSession(
                                    session,
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
        .frame(minWidth: 560, minHeight: 400)
        .task { await model.load(force: false) }
        .onChange(of: model.sessions) { _, sessions in
            selectedSessionNames.formIntersection(Set(sessions.lazy
                .filter { session in
                    !terminals.isTmuxSessionManagedExternally(
                        sessionName: session.name,
                        target: model.target
                    )
                }
                .map(\.name)))
        }
        .alert("新建 tmux 会话", isPresented: $isCreatingSession) {
            TextField("留空自动命名", text: $newSessionName)
            Button("创建并接入") { createSession() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名称只能包含字母、数字、点、短横线和下划线。")
        }
        .alert("无法创建会话", isPresented: Binding(
            get: { creationErrorMessage != nil },
            set: { if !$0 { creationErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(creationErrorMessage ?? "会话名无效。")
        }
        .confirmationDialog(
            "终止 \(pendingTerminationNames.count) 个 tmux 会话？",
            isPresented: Binding(
                get: { !pendingTerminationNames.isEmpty },
                set: { if !$0 { pendingTerminationNames = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("终止所选会话", role: .destructive, action: terminatePending)
            Button("取消", role: .cancel) { pendingTerminationNames = [] }
        } message: {
            Text("会话内的进程会停止；引用这些会话的标签也会关闭。")
        }
        .alert("tmux 批量操作", isPresented: Binding(
            get: { terminationMessage != nil },
            set: { if !$0 { terminationMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(terminationMessage ?? "操作未完成。")
        }
    }

    @ViewBuilder
    private var verificationStatus: some View {
        if model.isVerifying {
            Text("正在连接并核对")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let fetchedAt = model.fetchedAt {
            Text(model.isStale ? "缓存 · \(fetchedAt.formatted(date: .omitted, time: .shortened))" : "刚刚更新")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var sessionManagementBar: some View {
        HStack(spacing: 10) {
            Button("选择 Hub 会话", systemImage: "wand.and.stars") {
                selectedSessionNames = Set(model.sessions.lazy
                    .filter {
                        $0.name.hasPrefix("hub-")
                            && !terminals.isTmuxSessionManagedExternally(
                                sessionName: $0.name,
                                target: model.target
                            )
                    }
                    .map(\.name))
            }
            Button(allSessionsSelected ? "取消全选" : "全选") {
                selectedSessionNames = allSessionsSelected
                    ? [] : selectableSessionNames
            }
            Spacer()
            Text("已选择 \(selectedSessionNames.count) 个")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("终止所选", systemImage: "trash", role: .destructive) {
                pendingTerminationNames = selectedSessionNames
            }
            .disabled(selectedSessionNames.isEmpty || isTerminating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var targetLabel: String {
        switch model.target {
        case .local: "本机"
        case let .ssh(destination): destination
        }
    }

    private var allSessionsSelected: Bool {
        !selectableSessionNames.isEmpty
            && selectedSessionNames == selectableSessionNames
    }

    private var selectableSessionNames: Set<String> {
        Set(model.sessions.lazy
            .filter {
                !terminals.isTmuxSessionManagedExternally(
                    sessionName: $0.name,
                    target: model.target
                )
            }
            .map(\.name))
    }

    private func toggleSelection(_ name: String) {
        guard !terminals.isTmuxSessionManagedExternally(
            sessionName: name,
            target: model.target
        ) else { return }
        if selectedSessionNames.contains(name) {
            selectedSessionNames.remove(name)
        } else {
            selectedSessionNames.insert(name)
        }
    }

    private func createSession() {
        let proposed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proposed.isEmpty, !TmuxSessionParser.isAttachable(proposed) {
            creationErrorMessage = "tmux 会话名无效。"
            return
        }
        switch model.target {
        case .local:
            terminals.openLocalTmux(sessionName: proposed.isEmpty ? nil : proposed)
        case let .ssh(destination):
            terminals.openSSH(destination, sessionName: proposed.isEmpty ? nil : proposed)
        }
        dismiss()
    }

    private func terminatePending() {
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
                let failed = result.failed.sorted().joined(separator: "、")
                terminationMessage = result.succeeded.isEmpty
                    ? "未能终止：\(failed)。"
                    : "已终止 \(result.succeeded.count) 个；失败：\(failed)。"
            }
        }
    }
}
