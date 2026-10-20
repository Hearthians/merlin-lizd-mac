import SwiftUI
import TmuxHubCore

struct NetworkMeshHostSheet: View {
    let hosts: [NetworkMeshHost]
    let onSave: @MainActor (NetworkMeshHost, UUID?, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NetworkMeshHost
    @State private var mergingInto: UUID?
    @State private var configureSSH = false
    @State private var errorMessage: String?
    private let isNew: Bool

    init(
        host: NetworkMeshHost? = nil,
        hosts: [NetworkMeshHost],
        onSave: @escaping @MainActor (NetworkMeshHost, UUID?, Bool) throws -> Void
    ) {
        self.hosts = hosts
        self.onSave = onSave
        isNew = host == nil
        _configureSSH = State(initialValue: host == nil)
        _draft = State(initialValue: host ?? NetworkMeshHost(
            name: "", endpoints: [NetworkMeshEndpoint(label: "校园网", address: "", networkKind: .campus)]
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "添加互联主机" : "编辑主机与地址")
                        .font(.title2.bold())
                    Text("同一主机，多网络地址。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section("主机") {
                    TextField("主机名称", text: $draft.name, prompt: Text("例如 CIS Cube WSL"))
                    if draft.isLocal {
                        Text("自动发现本机接口。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("控制 SSH 入口", text: controlDestination, prompt: Text("例如 cis-cube-wsl-zerotier"))
                        Text("来源 IP 须属于实际网卡；域名可用作目标。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("归并到已有主机", selection: $mergingInto) {
                            Text("保留为独立主机").tag(UUID?.none)
                            ForEach(hosts.filter { $0.id != draft.id && !$0.isLocal }) { host in
                                Text(host.name).tag(Optional(host.id))
                            }
                        }
                        .help("请确认这些地址属于同一台物理主机。")
                    }
                }
                ForEach($draft.endpoints) { $endpoint in
                    Section {
                        HStack {
                            TextField("地址名称", text: $endpoint.label, prompt: Text("例如 校园网 / ZeroTier"))
                            Button(role: .destructive) {
                                draft.endpoints.removeAll { $0.id == endpoint.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("移除此地址")
                            .disabled(draft.isLocal)
                        }
                        Picker("网络类型", selection: $endpoint.networkKind) {
                            ForEach(NetworkMeshNetworkKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        HStack(spacing: 16) {
                            TextField("系统环境", text: $endpoint.environmentName, prompt: Text("Linux / Windows / WSL"))
                            Picker("系统类型", selection: $endpoint.platform) {
                                Text("Linux / macOS / WSL").tag(NetworkMeshPlatform.posix)
                                Text("Windows").tag(NetworkMeshPlatform.windows)
                            }.frame(width: 230)
                        }
                        TextField("环境标识", text: $endpoint.environmentID, prompt: Text("例如 main、windows、wsl"))
                        .help("同一系统环境沿用相同标识；Windows 和 WSL 分别设置。")
                        TextField("IP 或主机地址", text: $endpoint.address, prompt: Text("例如 10.4.129.108"))
                            .disabled(draft.isLocal)
                        HStack(spacing: 16) {
                            TextField("SSH 用户", text: $endpoint.username)
                            TextField("SSH 端口", value: $endpoint.port, format: .number.grouping(.never))
                                .frame(width: 160)
                        }
                        if !draft.isLocal {
                            TextField("SSH 别名", text: $endpoint.sshDestination, prompt: Text("例如 cis-cube-wsl-edu"))
                            .help("新入口填写唯一别名；留空自动生成。")
                        }
                        TextField("带宽测速端口", value: $endpoint.bandwidthPort, format: .number.grouping(.never))
                        .help("iperf3 监听端口，默认 5201。")
                    } header: {
                        Text(endpoint.label.isEmpty ? "网络地址" : endpoint.label)
                    }
                }
                if !draft.isLocal {
                    Button("添加网络地址", systemImage: "plus.circle") {
                        let previous = draft.endpoints.last
                        draft.endpoints.append(NetworkMeshEndpoint(
                            label: "ZeroTier", address: "", username: previous?.username ?? "", networkKind: .zeroTier,
                            environmentID: previous?.environmentID ?? "main",
                            environmentName: previous?.environmentName ?? "Linux", platform: previous?.platform ?? .posix
                        ))
                    }
                    Section {
                        Toggle("保存后配置 SSH 互联", isOn: $configureSSH)
                        Text("首次登录在终端完成。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            if let errorMessage {
                MessageBanner(text: errorMessage, kind: .error)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mergingInto == nil ? "保存" : "保存并归并", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.endpoints.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 660, height: 720)
    }

    private var controlDestination: Binding<String> {
        Binding(get: { draft.controlDestination ?? "" }, set: {
            draft.controlDestination = $0.isEmpty ? nil : $0
        })
    }

    private func save() {
        do {
            for index in draft.endpoints.indices {
                draft.endpoints[index].address = draft.endpoints[index].address.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.endpoints[index].sshDestination = draft.endpoints[index].sshDestination.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...65_535).contains(draft.endpoints[index].bandwidthPort) else {
                    errorMessage = "带宽测速端口需要是 1 到 65535 之间的整数。"
                    return
                }
            }
            if !draft.isLocal, draft.controlDestination == nil {
                draft.controlDestination = draft.endpoints.first(where: { !$0.sshDestination.isEmpty })?.sshDestination
            }
            try onSave(draft, mergingInto, configureSSH)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
