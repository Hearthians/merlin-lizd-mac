import MerlinLizdCore
import SwiftUI

struct CodexApprovalCardView: View {
    let request: TerminalApprovalRequest
    let conversationKey: TerminalConversationKey
    let canAllowOnce: Bool
    let onAllowOnce: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            detail("Reason", CodexBoundedText.string(request.reason))
            detail("Proposed input", CodexTerminalPayloadFormatter.batch(request.batch))
            if let context = request.scope.context {
                detail(
                    "Endpoint / tmux surface",
                    "\(request.scope.endpointID.rawValue.uuidString) · session "
                        + context.surface.sessionIdentity.stableDisplayString
                        + " · window "
                        + "\(context.surface.windowID) · pane \(context.surface.paneID) · command "
                        + context.surface.currentCommand
                        + (context.surface.isCurrentCommandTruncated
                            ? "… [command context truncated]"
                            : "")
                )
                detail(
                    "Screen context",
                    "Revision \(context.screen.revision) · "
                        + "\(context.screen.columns)×\(context.screen.rows) · cursor "
                        + "\(context.screen.cursor.row):\(context.screen.cursor.column) "
                        + "(\(context.screen.cursor.isVisible ? "visible" : "hidden")) · "
                        + "\(context.screen.mode.isAlternateScreen ? "alternate" : "normal") screen · "
                        + "keyboard \(keyboardMode(context.screen.mode.keyboardMode))"
                )
                detail(
                    "Visible screen at approval",
                    CodexBoundedText.string(context.screen.text)
                        + (context.screen.isTextTruncated ? "\n… [screen context truncated]" : "")
                )
            } else {
                detail(
                    "Endpoint / surface",
                    "\(request.scope.endpointID.rawValue.uuidString) · tmux "
                        + conversationKey.tmux.stableDisplayString
                )
                detail(
                    "Screen context",
                    "Revision \(request.scope.screenRevision) · legacy approval context unavailable"
                )
            }
            detail(
                "Purpose",
                CodexBoundedText.string(
                    request.batch.purpose,
                    maximumCharacterCount: 500
                )
            )
            detail("Payload digest", request.scope.payloadDigest)

            HStack {
                Spacer()
                Button("Deny", role: .destructive, action: onDeny)
                    .buttonStyle(.bordered)
                Button("Allow Once", action: onAllowOnce)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAllowOnce)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyboardMode(_ mode: TerminalKeyboardMode) -> String {
        switch mode {
        case .normal: "normal"
        case .applicationCursor: "application-cursor"
        }
    }
}

enum CodexTerminalPayloadFormatter {
    static func batch(_ batch: TerminalInputBatch) -> String {
        CodexBoundedText.string(
            batch.events.map(event).joined(separator: "\n")
        )
    }

    static func event(_ event: TerminalInputEvent) -> String {
        switch event {
        case let .text(text):
            return "text(\(text.debugDescription))"
        case let .key(key, modifiers):
            return "key(\(keyName(key)), modifiers: \(modifierNames(modifiers)))"
        }
    }

    private static func keyName(_ key: TerminalKey) -> String {
        switch key {
        case let .character(value): "character(\(value.debugDescription))"
        case .enter: "enter"
        case .escape: "escape"
        case .backspace: "backspace"
        case .tab: "tab"
        case .up: "up"
        case .down: "down"
        case .right: "right"
        case .left: "left"
        case .home: "home"
        case .end: "end"
        case .insert: "insert"
        case .delete: "delete"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        case let .function(number): "function(\(number))"
        }
    }

    private static func modifierNames(_ modifiers: TerminalKeyModifiers) -> String {
        var names: [String] = []
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.control) { names.append("control") }
        if modifiers.contains(.option) { names.append("option") }
        if modifiers.contains(.command) { names.append("command") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }
}

enum CodexBoundedText {
    static let maximumCharacterCount = 4_096

    static func string(
        _ value: String,
        maximumCharacterCount: Int = maximumCharacterCount
    ) -> String {
        guard value.count > maximumCharacterCount else { return value }
        return String(value.prefix(maximumCharacterCount)) + "… [truncated]"
    }
}
