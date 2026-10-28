import AppKit
import Foundation
import TmuxHubCore

@MainActor
final class RemoteEditorController {
    let token = UUID().uuidString
    private let destination: String
    private let endpoint: CodexNotificationSSHEndpoint?
    private var requestIDs: [String] = []
    private var task: Task<Void, Never>?
    private var closed = false
    var showMessage: ((String?) -> Void)?

    init(destination: String, endpoint: CodexNotificationSSHEndpoint?) {
        self.destination = destination
        self.endpoint = endpoint
    }

    func wrap(_ command: CommandSpec) throws -> CommandSpec {
        try RemoteEditorBridge.wrap(command: command, token: token,
            deviceName: Host.current().localizedName ?? "Mac")
    }

    func receive(_ payload: String) {
        guard !closed, let request = RemoteEditorRequest.decode(payload, expectedToken: token),
            !requestIDs.contains(request.requestID) else { return }
        requestIDs.append(request.requestID)
        if requestIDs.count > 256 { requestIDs.removeFirst() }
        guard task == nil else {
            showMessage?("正在打开上一个 VS Code 请求，请稍后再试。")
            return
        }
        showMessage?("正在用本机 VS Code 打开远端路径…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
                    throw NSError(domain: "TmuxHub.RemoteEditor", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "请先在本机安装 Visual Studio Code；Remote - SSH 会自动配置。"
                    ])
                }
                let cli = app.appendingPathComponent("Contents/Resources/app/bin/code").path
                guard FileManager.default.isExecutableFile(atPath: cli) else {
                    throw NSError(domain: "TmuxHub.RemoteEditor", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "未找到 VS Code 自带的 code 命令，请检查本机 VS Code 安装。"
                    ])
                }
                let remote = try await RemoteEditorService.resolve(
                    sshDestination: destination, absolutePath: request.path,
                    kind: request.isDirectory ? .folder : .file,
                    hostname: request.hostname, serverAddress: request.serverAddress,
                    pinnedEndpoint: endpoint
                )
                try Task.checkCancellation()
                guard !closed else { return }
                try await RemoteEditorPreparation.prepare(application: app, destination: remote) { [weak self] message in
                    if let self, !self.closed { self.showMessage?(message) }
                }
                try Task.checkCancellation()
                guard !closed else { return }
                try await RemoteEditorLauncher.launch(executable: cli, destination: remote)
                if !closed { showMessage?(nil) }
            } catch is CancellationError {
                // Closing a terminal cancels pending local editor launches.
            } catch {
                if !closed { showMessage?(error.localizedDescription) }
            }
        }
    }

    func close() {
        closed = true
        task?.cancel()
        task = nil
        showMessage = nil
    }
}
