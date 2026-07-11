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
}

struct TmuxSessionBrowserView: View {
    @StateObject private var model: TmuxSessionBrowserModel
    @ObservedObject var terminals: TerminalTabsModel
    @Environment(\.dismiss) private var dismiss

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
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .disabled(model.isLoading)
                Button("完成") {
                    dismiss()
                }
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
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .task {
            await model.load()
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
