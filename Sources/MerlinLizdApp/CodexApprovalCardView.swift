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

            detail("Reason", request.reason)
            detail("Proposed input", CodexTerminalPayloadFormatter.batch(request.batch))
            detail(
                "Endpoint / surface",
                "\(request.scope.endpointID.rawValue.uuidString) · tmux "
                    + conversationKey.tmux.serverSessionID
            )
            detail(
                "Screen context",
                "Revision \(request.scope.screenRevision) · "
                    + "expected payload revision \(request.batch.expectedRevision) · "
                    + request.batch.purpose
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
}

enum CodexTerminalPayloadFormatter {
    static func batch(_ batch: TerminalInputBatch) -> String {
        batch.events.map(event).joined(separator: "\n")
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
