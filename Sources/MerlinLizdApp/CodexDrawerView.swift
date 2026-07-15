import MerlinLizdCore
import SwiftUI

struct CodexDrawerView: View {
    @ObservedObject var model: CodexDrawerModel
    let containerHeight: CGFloat

    @State private var dragStartFraction: Double?

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex conversation")
    }

    private var dragHandle: some View {
        ZStack {
            Capsule()
                .fill(.tertiary)
                .frame(width: 42, height: 4)
            HStack {
                Spacer()
                backgroundStatus
                Button {
                    model.setExpanded(!model.state.isExpanded)
                } label: {
                    Image(systemName: model.state.isExpanded
                        ? "chevron.down"
                        : "chevron.up")
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help(model.state.isExpanded ? "Collapse Codex" : "Expand Codex")
                .padding(.trailing, 8)
            }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard containerHeight > 0 else { return }
                    let start = dragStartFraction
                        ?? model.state.expandedFraction
                    dragStartFraction = start
                    model.resizeExpanded(
                        fraction: start
                            - Double(value.translation.height / containerHeight)
                    )
                }
                .onEnded { _ in dragStartFraction = nil }
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.state.isExpanded {
            expandedContent
        } else if model.state.isActive {
            compactContent
        } else {
            collapsedContent
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            eligibilityOrComposer
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var compactContent: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Label(
                    model.state.currentAction ?? "Codex is working",
                    systemImage: phaseSymbol
                )
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                Spacer()
                Button("Stop and Take Over") {
                    model.stopAndTakeOver()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canTakeOver)
            }
            HStack(spacing: 8) {
                composerField(prompt: "Steer the active Codex turn…")
                sendButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label(
                    model.state.currentAction ?? "Codex",
                    systemImage: phaseSymbol
                )
                .font(.headline)
                Spacer()
                if model.state.isActive {
                    Button("Stop and Take Over") {
                        model.stopAndTakeOver()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !model.canTakeOver
                    )
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let notice = model.state.terminalNotice {
                        noticeRow(notice, symbol: "terminal")
                    } else if let notice = model.state.availabilityNotice {
                        availabilityRow(notice)
                    }

                    conversationHistory

                    if let key = model.state.selectedConversationKey {
                        ForEach(model.state.selectedSession?.pendingApprovals ?? []) {
                            request in
                            CodexApprovalCardView(
                                request: request,
                                conversationKey: key,
                                canAllowOnce: terminalIsConnected
                                    && request.scope.context != nil,
                                onAllowOnce: { model.allowOnce(request.id) },
                                onDeny: { model.deny(request.id) }
                            )
                        }
                    }

                    if !model.operations.isEmpty {
                        Text("Terminal operations")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(model.operations) { operation in
                            CodexOperationView(operation: operation)
                        }
                    } else if let notice = model.journalNotice {
                        noticeRow(notice, symbol: "doc.text.magnifyingglass")
                    }
                    if let notice = model.journalHistoryNotice {
                        noticeRow(notice, symbol: "clock.arrow.circlepath")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            if case .connected = model.state.terminalContext {
                HStack(spacing: 8) {
                    composerField(
                        prompt: model.state.composerMode == .steer
                            ? "Steer the active Codex turn…"
                            : "Ask Codex to operate this tmux session…"
                    )
                    sendButton
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var eligibilityOrComposer: some View {
        if let notice = model.state.terminalNotice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        } else if let notice = model.state.availabilityNotice {
            Text(notice.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if notice.isRetryable {
                Button("Retry") { model.retryAvailability() }
                    .controlSize(.small)
            }
        } else {
            composerField(prompt: "Ask Codex to operate this tmux session…")
            sendButton
        }
    }

    private func composerField(prompt: String) -> some View {
        TextField(
            prompt,
            text: Binding(
                get: { model.composer },
                set: { model.editComposer($0) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit { model.sendComposer() }
    }

    private var sendButton: some View {
        Button {
            model.sendComposer()
        } label: {
            Image(systemName: model.state.composerMode == .steer
                ? "arrow.triangle.turn.up.right.diamond.fill"
                : "arrow.up.circle.fill")
                .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .opacity(model.state.canSend ? 1 : 0.45)
        .disabled(!model.state.canSend)
        .help(model.state.composerMode == .steer ? "Steer" : "Send")
    }

    @ViewBuilder
    private var conversationHistory: some View {
        let messages = model.state.selectedSession?.messages ?? []
        if !messages.isEmpty {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                HStack {
                    if message.role == .user { Spacer(minLength: 42) }
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            message.role == .user
                                ? Color.accentColor.opacity(0.14)
                                : Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    if message.role == .assistant { Spacer(minLength: 42) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func availabilityRow(
        _ notice: CodexDrawerAvailabilityNotice
    ) -> some View {
        HStack {
            noticeRow(notice.message, symbol: "exclamationmark.triangle")
            if notice.isRetryable {
                Button("Retry") { model.retryAvailability() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func noticeRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var backgroundStatus: some View {
        let activity = model.backgroundActivity
        if activity.pendingApprovalCount > 0 {
            Label(
                "\(activity.pendingApprovalCount) background approval",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
        } else if activity.runningConversationCount > 0 {
            Label(
                "\(activity.runningConversationCount) background",
                systemImage: "circle.dotted.circle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var phaseSymbol: String {
        guard let phase = model.state.selectedSession?.phase else {
            return "sparkles"
        }
        return switch phase {
        case .idle, .completed: "sparkles"
        case .thinking: "brain.head.profile"
        case .controlling: "terminal"
        case .awaitingApproval: "exclamationmark.shield"
        case .waitingForUser: "person.crop.circle.badge.questionmark"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "stop.circle"
        }
    }

    private var terminalIsConnected: Bool {
        if case .connected = model.state.terminalContext { return true }
        return false
    }
}
