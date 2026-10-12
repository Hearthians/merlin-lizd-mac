import AppKit
import SwiftUI
import TmuxHubCore

struct SSHHostPropertiesSheet: View {
    let host: SSHHost
    var reader = SSHHostPropertiesReader()
    let onSave: @MainActor (SSHConnectionSettings) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var properties: SSHHostProperties?
    @State private var hostname = ""
    @State private var username = ""
    @State private var port = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH 主机属性")
                        .font(.title2.bold())
                    Text(host.destination)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Image(systemName: "server.rack")
                    .font(.title)
                    .foregroundStyle(.green)
            }
            .padding(20)
            Divider()

            if isLoading {
                ProgressView("正在读取连接属性…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let properties {
                Form {
                    Section("连接设置") {
                        LabeledContent("SSH 目标", value: host.destination)
                            .textSelection(.enabled)
                        TextField("主机地址", text: $hostname)
                        TextField("用户名", text: $username)
                        TextField("端口", text: $port)
                        Text("保存前自动备份 SSH 配置，保留其他设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("其他连接设置") {
                        if !properties.identityFiles.isEmpty {
                            LabeledContent("密钥文件") {
                                Text(properties.identityFiles.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if let proxyJump = properties.proxyJump {
                            LabeledContent("跳板主机", value: proxyJump)
                                .textSelection(.enabled)
                        }
                        if let proxyCommand = properties.proxyCommand {
                            LabeledContent("代理命令") {
                                Text(proxyCommand)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        Text("密钥和跳板信息来自当前 SSH 配置；高级选项可在配置文件中修改。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开 SSH 配置…", action: openConfiguration)
                    }
                }
                .formStyle(.grouped)
                .textFieldStyle(.roundedBorder)
                .disabled(isSaving)
            } else {
                ContentUnavailableView {
                    Label("无法读取连接属性", systemImage: "network.slash")
                } description: {
                    Text("检查 SSH 配置后重试。")
                } actions: {
                    Button("重试") { Task { await load() } }
                    Button("打开 SSH 配置…", action: openConfiguration)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorMessage {
                MessageBanner(text: errorMessage, kind: .error)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text("已建立的连接继续使用原设置。重启 TmuxHub 后，所有连接将使用新设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isSaving { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isSaving || !hasChanges)
            }
            .padding(16)
        }
        .frame(width: 600, height: 620)
        .interactiveDismissDisabled(isSaving)
        .task(id: host.destination) { await load() }
    }

    private var hasChanges: Bool {
        guard let properties else { return false }
        return hostname != properties.hostname || username != properties.username
            || port != String(properties.port)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        properties = nil
        defer { isLoading = false }
        do {
            let loaded = try await reader.load(destination: host.destination)
            try Task.checkCancellation()
            properties = loaded
            hostname = loaded.hostname
            username = loaded.username
            port = String(loaded.port)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard !isSaving, !isLoading else { return }
        errorMessage = nil
        do {
            guard let number = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SSHHostConfigurationError.invalidPort
            }
            let settings = try SSHConnectionSettings(
                destination: host.destination,
                hostname: hostname,
                username: username,
                port: number
            )
            isSaving = true
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    try await onSave(settings)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openConfiguration() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: file.path),
            let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        else {
            errorMessage = "未找到 SSH 配置文件。保存连接设置后会自动创建。"
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in errorMessage = error.localizedDescription }
            }
        }
    }
}
