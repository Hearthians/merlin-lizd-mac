import MerlinLizdCore
import SwiftUI

@MainActor
final class TmuxSessionBrowserModel: ObservableObject {
    @Published private(set) var sessions: [TmuxSessionRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let target: TerminalTarget
    private let discovery: TmuxSessionDiscovery

    init(
        target: TerminalTarget,
        discovery: TmuxSessionDiscovery,
        initialSessions: [TmuxSessionRecord]
    ) {
        self.target = target
        self.discovery = discovery
        sessions = initialSessions
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if let cached = await discovery.cached(target: target) {
                var seen: Set<String> = []
                sessions = (sessions + cached).filter {
                    seen.insert($0.name).inserted
                }
            }
            sessions = try await discovery.list(target: target)
            errorMessage = nil
        } catch TmuxSessionDiscoveryError.workerNotReady {
            errorMessage = "Worker 尚未就绪。"
        } catch TmuxSessionDiscoveryError.localTmuxNotFound {
            errorMessage = "本机未找到 tmux。"
        } catch {
            errorMessage = "无法读取 tmux 会话，请检查连接状态。"
        }
    }

    func removeSessions(named names: Set<String>) {
        sessions.removeAll { names.contains($0.name) }
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
                    if model.isLoading {
                        Text("正在核对远端；mlx 冷启动最长约 45 秒")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isLoading || isTerminating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .disabled(model.isLoading || isTerminating)
                Button("完成") {
                    dismiss()
                }
                .disabled(isTerminating)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if let errorMessage = model.errorMessage, model.sessions.isEmpty {
                MessageBanner(text: errorMessage, kind: .error)
                    .padding()
            } else if !model.isLoading && model.sessions.isEmpty {
                ContentUnavailableView(
                    "没有 tmux 会话",
                    systemImage: "rectangle.stack",
                    description: Text(emptyStateDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let errorMessage = model.errorMessage {
                        MessageBanner(text: errorMessage, kind: .error)
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
            await model.load()
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

    private var targetLabel: String {
        switch model.target {
        case .local:
            "本机"
        case let .devbox(_, name, alias):
            "\(alias) · \(name)"
        case let .worker(_, _, alias, workerID):
            "\(alias) · Worker \(workerID)"
        }
    }

    private var emptyStateDescription: String {
        switch model.target {
        case .local:
            "本机尚无可接入的 tmux 会话；“打开终端”会启动普通登录 shell。"
        case .devbox, .worker:
            "打开新终端时，App 会自动创建一个可恢复的会话。"
        }
    }
}
