import AppKit
import SwiftUI
import TmuxHubCore

private struct AddSSHHostActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var addSSHHost: (() -> Void)? {
        get { self[AddSSHHostActionKey.self] }
        set { self[AddSSHHostActionKey.self] = newValue }
    }
}

struct AddSSHHostCommands: Commands {
    @FocusedValue(\.addSSHHost) private var addSSHHost

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加 SSH 主机") { addSSHHost?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(addSSHHost == nil)
        }
    }
}

struct AddSSHHostSheet: View {
    let onAddConfiguration: @MainActor (SSHHostConfiguration) async throws -> Void
    let onAddDestination: @MainActor (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .newHost
    @State private var alias = ""
    @State private var hostname = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var identityFile = ""
    @State private var destination = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var filePanel: NSOpenPanel?
    @FocusState private var focusedField: Field?

    private enum Mode: Hashable {
        case newHost, existingTarget
    }

    private enum Field: Hashable {
        case alias, destination
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加 SSH 主机")
                        .font(.title2.bold())
                    Text("保存后会固定到侧边栏，方便随时连接。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Picker("添加方式", selection: $mode) {
                    Text("新建主机配置").tag(Mode.newHost)
                    Text("已有 SSH 目标").tag(Mode.existingTarget)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if mode == .newHost {
                    Section("服务器") {
                        TextField("主机别名", text: $alias, prompt: Text("例如 my-server"))
                            .focused($focusedField, equals: .alias)
                        Text("别名用于主机列表和连接，请使用英文字母、数字、点、横线或下划线。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("主机地址", text: $hostname, prompt: Text("域名、IPv4 或 IPv6 地址"))
                        TextField("用户名", text: $username, prompt: Text("可选，使用默认用户名"))
                        TextField("端口", text: $port, prompt: Text("22"))
                    }

                    Section("登录密钥（可选）") {
                        HStack {
                            TextField("私钥文件", text: $identityFile, prompt: Text("默认使用 SSH Agent 和已有密钥"))
                            Button("选择…", action: chooseIdentityFile)
                        }
                        Text("也可填写 ~/.ssh/id_ed25519。使用密码登录时可留空，连接时会提示输入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("配置保存到 ~/.ssh/config，也可在终端中使用。已有配置会保留，并在保存前自动备份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Section("已有目标") {
                        TextField("SSH 目标", text: $destination, prompt: Text("alias、hostname 或 user@host"))
                            .focused($focusedField, equals: .destination)
                        Text("将已有目标固定到侧边栏，连接时使用现有 SSH 配置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .disabled(isSaving)

            if let errorMessage {
                MessageBanner(text: errorMessage, kind: .error)
                    .accessibilityIdentifier("add-ssh-host-error")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("正在保存…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("添加", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || requiredFieldsAreEmpty)
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
        .interactiveDismissDisabled(isSaving)
        .onAppear { focusedField = .alias }
        .onChange(of: mode) { _, newMode in
            errorMessage = nil
            focusedField = newMode == .newHost ? .alias : .destination
        }
    }

    private var requiredFieldsAreEmpty: Bool {
        if mode == .existingTarget {
            return destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard !isSaving else { return }
        errorMessage = nil
        if mode == .existingTarget {
            do {
                try onAddDestination(destination)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        do {
            let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let portNumber = Int(portText.isEmpty ? "22" : portText),
                  (1...65_535).contains(portNumber)
            else {
                errorMessage = "端口需要是 1 到 65535 之间的整数。"
                return
            }
            let configuration = try SSHHostConfiguration(
                alias: alias,
                hostname: hostname,
                username: username,
                port: portNumber,
                identityFile: identityFile
            )
            isSaving = true
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    try await onAddConfiguration(configuration)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseIdentityFile() {
        guard filePanel == nil else { return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                if response == .OK, let url = panel.url {
                    identityFile = url.path
                }
                filePanel = nil
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
