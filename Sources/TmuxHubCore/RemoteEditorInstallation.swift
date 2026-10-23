import Foundation

public enum RemoteEditorInstallation {
    public static func install(destination: String, pool: SSHMasterPool) async throws {
        let command = try RemoteEditorBridge.installCommand(destination: destination)
        let result = try await pool.run(command, alias: destination, replay: .never)
        guard result.exitCode == 0 else {
            throw NSError(domain: "TmuxHub.RemoteEditor", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "无法配置远端 code 命令。请确认远端有 Python 3，且主目录可写。"
            ])
        }
    }
}

public enum RemoteEditorLauncher {
    public static func launch(executable: String, destination: RemoteEditorDestination) async throws {
        let runner = TimedInventoryProcessRunner(timeout: .seconds(20), underlying: FoundationInventoryProcessRunner())
        let output = try await runner.run(CommandSpec(executable: executable, arguments: destination.cliArguments))
        guard output.exitCode == 0 else {
            throw NSError(domain: "TmuxHub.RemoteEditor", code: Int(output.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "VS Code 未能打开远端路径。请确认已安装 Remote - SSH 扩展，并能在 VS Code 中连接该主机。"
            ])
        }
    }
}
