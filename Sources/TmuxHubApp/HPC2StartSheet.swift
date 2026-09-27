import SwiftUI
import TmuxHubCore

struct HPC2StartSheet: View {
    let initialProfile: SlurmPlatformProfile
    let initialPreset: SlurmInteractivePreset
    let onSubmit: @MainActor (
        SlurmPlatformProfile,
        SlurmInteractivePreset
    ) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var loginDestination: String
    @State private var owner: String
    @State private var environmentName: String
    @State private var partition: String
    @State private var cpusPerTask: Int
    @State private var memoryGiB: Int
    @State private var wallTime: String
    @State private var requestsGPU: Bool
    @State private var gpuCount: Int
    @State private var gpuType: GPUTypeChoice
    @State private var workingDirectory: String
    @State private var initializationScript: String
    @State private var showsAdvanced = false
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(
        initialProfile: SlurmPlatformProfile,
        initialPreset: SlurmInteractivePreset,
        onSubmit: @escaping @MainActor (
            SlurmPlatformProfile,
            SlurmInteractivePreset
        ) async -> Bool
    ) {
        self.initialProfile = initialProfile
        self.initialPreset = initialPreset
        self.onSubmit = onSubmit
        _loginDestination = State(initialValue: initialProfile.loginDestination)
        _owner = State(initialValue: initialProfile.owner)
        _environmentName = State(initialValue: initialPreset.name)
        _partition = State(initialValue: initialPreset.partition)
        _cpusPerTask = State(initialValue: initialPreset.cpusPerTask)
        _memoryGiB = State(initialValue: max(1, initialPreset.memoryMiB / 1_024))
        _wallTime = State(initialValue: initialPreset.wallTime.schedulerValue)
        _requestsGPU = State(initialValue: initialPreset.gpu != nil)
        _gpuCount = State(initialValue: initialPreset.gpu?.count ?? 1)
        _gpuType = State(initialValue: GPUTypeChoice(type: initialPreset.gpu?.type))
        _workingDirectory = State(initialValue: initialPreset.workingDirectory ?? "$HOME")
        _initializationScript = State(initialValue: initialPreset.initializationScript ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启动交互环境")
                        .font(.title2.bold())
                    Text("任务会在登录节点的 tmux 中排队和运行。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Form {
                Section("平台") {
                    TextField("SSH 主机别名", text: $loginDestination)
                        .textFieldStyle(.roundedBorder)
                    TextField("集群用户名", text: $owner)
                        .textFieldStyle(.roundedBorder)
                    Text("SSH 连接参数由 ~/.ssh/config 管理；默认别名为 hpc2。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("环境") {
                    TextField("环境名称", text: $environmentName)
                        .textFieldStyle(.roundedBorder)
                    TextField("分区", text: $partition)
                        .textFieldStyle(.roundedBorder)
                }

                Section("资源") {
                    Stepper(value: $cpusPerTask, in: 1...256) {
                        LabeledContent("CPU", value: "\(cpusPerTask) 核")
                    }
                    Stepper(value: $memoryGiB, in: 1...1_024) {
                        LabeledContent("内存", value: "\(memoryGiB) GiB")
                    }
                    Toggle("GPU", isOn: $requestsGPU)
                    if requestsGPU {
                        Stepper(value: $gpuCount, in: 1...16) {
                            LabeledContent("GPU 数量", value: "\(gpuCount)")
                        }
                        Picker("GPU 型号", selection: $gpuType) {
                            ForEach(GPUTypeChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                    }
                    TextField("时限（HH:MM:SS）", text: $wallTime)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                }

                DisclosureGroup("高级设置", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("工作目录", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                        Text("$HOME 表示登录后的默认目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("环境初始化命令")
                            .font(.callout.weight(.medium))
                        TextEditor(text: $initializationScript)
                            .font(.body.monospaced())
                            .frame(minHeight: 92)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.separator, lineWidth: 0.5)
                            }
                        Text("该命令会在获得计算资源后执行，然后进入 bash 登录 Shell。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                Section("等价命令") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(commandPreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                }

                if let validationMessage {
                    MessageBanner(text: validationMessage, kind: .warning)
                }
                if let submissionError {
                    MessageBanner(text: submissionError, kind: .error)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("启动后，关闭终端只会断开显示，不会取消 Slurm 任务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button("启动") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil || isSubmitting)
            }
            .padding(16)
        }
        .frame(width: 620)
        .frame(minHeight: 680)
    }

    private var validationMessage: String? {
        let destination = loginDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let queue = partition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IdentifierValidator.isSSHDestination(destination) else {
            return "请输入有效的 SSH 主机别名。"
        }
        guard isSafeIdentifier(username) else {
            return "集群用户名包含不支持的字符。"
        }
        guard !name.isEmpty, name.utf8.count <= 256 else {
            return "环境名称不能为空，且不能超过 256 字节。"
        }
        guard isSafeIdentifier(queue) else {
            return "分区名称包含不支持的字符。"
        }
        guard Self.parseWallTime(wallTime) != nil else {
            return "时限格式应为 HH:MM:SS，且必须大于 0。"
        }
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.isEmpty || directory == "$HOME" || (
            directory.hasPrefix("/")
                && !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        ) else {
            return "工作目录需要使用绝对路径，或填写 $HOME。"
        }
        guard initializationScript.utf8.count <= 64 * 1_024,
            !initializationScript.contains("\0")
        else {
            return "环境初始化命令过长或包含无效字符。"
        }
        return nil
    }

    private var commandPreview: String {
        var arguments = [
            "srun",
            "--partition", partitionOrPlaceholder,
            "--ntasks", "1",
            "--cpus-per-task", String(cpusPerTask),
            "--mem", "\(memoryGiB * 1_024)M",
            "--time", wallTime,
        ]
        if requestsGPU {
            let resource = ["gpu", gpuType.rawValue, String(gpuCount)]
                .filter { !$0.isEmpty }
                .joined(separator: ":")
            arguments += ["--gres", resource]
        }
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty, directory != "$HOME" {
            arguments += ["--chdir", directory]
        }
        arguments += ["--pty", "/bin/bash", "-l"]
        return arguments.map(Self.shellQuote).joined(separator: " ")
    }

    private var partitionOrPlaceholder: String {
        let value = partition.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "<分区>" : value
    }

    private func submit() {
        guard validationMessage == nil,
            let wallTimeSeconds = Self.parseWallTime(wallTime)
        else { return }

        let profile = SlurmPlatformProfile(
            id: initialProfile.id,
            name: initialProfile.name,
            loginDestination: loginDestination.trimmingCharacters(in: .whitespacesAndNewlines),
            owner: owner.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = initializationScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = SlurmInteractivePreset(
            id: initialPreset.id,
            name: environmentName.trimmingCharacters(in: .whitespacesAndNewlines),
            partition: partition.trimmingCharacters(in: .whitespacesAndNewlines),
            tasks: 1,
            cpusPerTask: cpusPerTask,
            memoryMiB: memoryGiB * 1_024,
            wallTime: SlurmWallTime(seconds: wallTimeSeconds),
            gpu: requestsGPU
                ? SlurmGPURequest(type: gpuType.value, count: gpuCount)
                : nil,
            workingDirectory: directory.isEmpty || directory == "$HOME" ? nil : directory,
            initializationScript: script.isEmpty ? nil : script
        )

        isSubmitting = true
        submissionError = nil
        Task {
            let accepted = await onSubmit(profile, preset)
            isSubmitting = false
            if accepted {
                dismiss()
            } else {
                submissionError = "启动失败。请检查页面上的错误信息后重试。"
            }
        }
    }

    private func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || "._:@+-".unicodeScalars.contains($0)
        }
    }

    private static func parseWallTime(_ value: String) -> Int? {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
            let hours = Int(components[0]), hours >= 0,
            let minutes = Int(components[1]), (0..<60).contains(minutes),
            let seconds = Int(components[2]), (0..<60).contains(seconds)
        else { return nil }
        let total = hours * 3_600 + minutes * 60 + seconds
        return (1...31_536_000).contains(total) ? total : nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private enum GPUTypeChoice: String, CaseIterable, Identifiable {
    case automatic = ""
    case a40 = "a40"
    case a800 = "a800"

    var id: String { rawValue }
    var value: String? { rawValue.isEmpty ? nil : rawValue }

    var title: String {
        switch self {
        case .automatic: "由分区决定"
        case .a40: "A40"
        case .a800: "A800"
        }
    }

    init(type: String?) {
        self = GPUTypeChoice(rawValue: type?.lowercased() ?? "") ?? .automatic
    }
}
