import MerlinLizdCore
import SwiftUI

struct SidebarTmuxSessionList: View {
    @StateObject private var model: TmuxSessionBrowserModel
    @ObservedObject var terminals: TerminalTabsModel

    init(
        target: TerminalTarget,
        terminals: TerminalTabsModel
    ) {
        _model = StateObject(wrappedValue: TmuxSessionBrowserModel(
            target: target,
            discovery: terminals.tmuxSessionDiscovery,
            initialSessions: terminals.knownTmuxSessions(for: target)
        ))
        self.terminals = terminals
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.sessions.isEmpty {
                emptyState
            } else {
                if model.isVerifying {
                    statusRow(
                        text: "正在更新 tmux 会话…",
                        symbol: nil,
                        showsProgress: true
                    )
                } else if let errorMessage = model.errorMessage {
                    statusRow(
                        text: errorMessage,
                        symbol: "exclamationmark.triangle.fill"
                    )
                }

                ForEach(model.sessions) { session in
                    Button {
                        terminals.attachExistingSession(
                            session.name,
                            target: model.target
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.cyan)
                                .frame(width: 23, height: 23)
                                .background(
                                    Color.cyan.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            Text(session.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("接入 tmux 会话 \(session.name)")
                    .accessibilityLabel("接入 tmux 会话 \(session.name)")
                }
            }
        }
        .padding(.leading, 1)
        .padding(.vertical, 2)
        .task {
            await model.load(force: false)
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(5))
                } catch {
                    return
                }
                await synchronizeFromCache()
            }
        }
        .onChange(of: terminals.tabs) {
            Task { await synchronizeFromCache() }
        }
    }

    private func synchronizeFromCache() async {
        await model.synchronizeCachedSnapshot(
            knownSessions: terminals.knownTmuxSessions(for: model.target)
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isVerifying {
            statusRow(
                text: "正在读取 tmux 会话…",
                symbol: nil,
                showsProgress: true
            )
        } else if let errorMessage = model.errorMessage {
            statusRow(
                text: errorMessage,
                symbol: "exclamationmark.triangle.fill"
            )
        } else {
            statusRow(
                text: "没有 tmux 会话",
                symbol: "rectangle.stack"
            )
        }
    }

    private func statusRow(
        text: String,
        symbol: String?,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            if showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 13, height: 13)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 13)
            }
            Text(text)
                .lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}
