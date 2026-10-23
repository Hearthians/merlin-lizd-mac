import SwiftUI
import TmuxHubCore

struct RemoteEditorConfigurationCard: View {
    let destination: String
    @ObservedObject var terminals: TerminalTabsModel

    var body: some View {
        SurfaceCard("本机 VS Code") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("默认启用：在远端输入 code .，用本机 VS Code 打开当前目录。")
                        .font(.callout)
                    Text("支持文件和绝对路径；文件保留在服务器。需要本机 VS Code 和 Remote - SSH。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(terminals.remoteEditorInstalling.contains(destination) ? "正在修复…" : "修复 code 配置") {
                    Task { await terminals.installRemoteEditor(on: destination) }
                }
                .buttonStyle(.bordered)
                .disabled(terminals.remoteEditorInstalling.contains(destination))
                .accessibilityIdentifier("enable-remote-code")
            }
            if let message = terminals.remoteEditorMessages[destination] {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("每次连接自动检查配置，新 Bash/Zsh 终端直接可用。更新前已运行的 shell 可加载一次：")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("source ~/.local/share/tmuxhub/remote-editor/shell.sh").font(.caption.monospaced()).textSelection(.enabled)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("source ~/.local/share/tmuxhub/remote-editor/shell.sh", forType: .string)
                }.buttonStyle(.borderless)
            }
            Text("多个设备同时连接时，终端会让你选择在哪台设备打开。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
