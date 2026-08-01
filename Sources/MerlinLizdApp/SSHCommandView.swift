import AppKit
import MerlinLizdCore
import SwiftUI

@MainActor
enum SSHCommandClipboard {
    static func command(for target: TerminalTarget) -> String? {
        try? MerlinCommands.manualSSHCommand(for: target)
    }

    @discardableResult
    static func copy(_ target: TerminalTarget) -> Bool {
        guard let command = command(for: target) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(command, forType: .string)
    }
}

@MainActor
enum TaskSSHCommandClipboard {
    static func command(runID: String) -> String? {
        try? MerlinCommands.manualTaskSSHCommand(runID: runID)
    }

    @discardableResult
    static func copy(runID: String) -> Bool {
        guard let command = command(runID: runID) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(command, forType: .string)
    }
}

struct TaskSSHCopyButton: View {
    let runID: String
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard TaskSSHCommandClipboard.copy(runID: runID) else { return }
            copyFeedbackTask?.cancel()
            didCopy = true
            copyFeedbackTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Label(
                didCopy ? "已复制" : "SSH",
                systemImage: didCopy ? "checkmark" : "terminal"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(didCopy ? Color.green : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(didCopy ? "SSH 命令已复制" : "复制 SSH 命令")
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private var helpText: String {
        guard let command = TaskSSHCommandClipboard.command(runID: runID) else {
            return "暂无可用的 SSH 命令"
        }
        return "复制由 merlin-cli 建立的 SSH 连接命令：\n\(command)"
    }
}

struct SSHCommandCard: View {
    let target: TerminalTarget?
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        SurfaceCard("SSH 自救指令") {
            if let target, let command = SSHCommandClipboard.command(for: target) {
                HStack(alignment: .top, spacing: 12) {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(
                        didCopy ? "已复制" : "复制",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    ) {
                        guard SSHCommandClipboard.copy(target) else { return }
                        copyFeedbackTask?.cancel()
                        didCopy = true
                        copyFeedbackTask = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            didCopy = false
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Text("MerlinHub 无法连接时，可将这条命令粘贴到本机终端运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无安全可用的 SSH 连接指令。")
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }
}
