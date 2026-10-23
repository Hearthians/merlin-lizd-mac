import SwiftUI
import TmuxHubCore

struct RemoteEditorConfigurationCard: View {
    let destination: String
    @ObservedObject var terminals: TerminalTabsModel

    var body: some View {
        SurfaceCard("本机 VS Code") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("在远端输入 code .，用本机 VS Code 打开当前目录。")
                        .font(.callout)
                    Text("支持文件和绝对路径；文件保留在服务器。需要本机 VS Code 和 Remote - SSH。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(terminals.remoteEditorInstalling.contains(destination) ? "正在配置…" : "启用 code 命令") {
                    Task { await terminals.installRemoteEditor(on: destination) }
                }
                .buttonStyle(.bordered)
                .disabled(terminals.remoteEditorInstalling.contains(destination))
                .accessibilityIdentifier("enable-remote-code")
            }
            if let message = terminals.remoteEditorMessages[destination] {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("启用后重新连接标签页。新终端会自动加载；已有 shell 可运行下面这行：")
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
