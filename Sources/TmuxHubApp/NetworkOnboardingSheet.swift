import AppKit
import SwiftUI
import TmuxHubCore

@MainActor
private final class NetworkOnboardingProgress: ObservableObject {
    @Published var steps: [NetworkOnboardingStep] = []
    func append(_ step: NetworkOnboardingStep) { steps.append(step) }
}

struct NetworkOnboardingSheet: View {
    let host: NetworkMeshHost
    let peers: [NetworkMeshHost]
    let onReconciled: @MainActor (NetworkMembershipRunResult) async -> Void
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var progress = NetworkOnboardingProgress()
    @State private var journal: NetworkMembershipJournal
    @State private var step = 0
    @State private var isWorking = false
    @State private var workTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var preferredEndpoints: [String: UUID] = [:]
    @State private var verification: [UUID: NetworkOnboardingStep] = [:]
    @State private var tools: [String: NetworkOnboardingToolStatus] = [:]
    @State private var networkIDs: [String: String] = [:]
    @State private var zeroTierStates: [String: NetworkZeroTierStatus] = [:]
    @State private var result: NetworkMembershipRunResult?
    private let service = NetworkOnboardingService()
    private let terminal = ExternalTerminalLauncher()
    private let stepNames = ["登记主机", "首次登录", "准备网络与测速", "查看互联计划", "接入结果"]

    init(
        host: NetworkMeshHost, peers: [NetworkMeshHost], journal: NetworkMembershipJournal = NetworkMembershipJournal(),
        onReconciled: @escaping @MainActor (NetworkMembershipRunResult) async -> Void,
        onSaved: @escaping @MainActor () async -> Void
    ) {
        self.host = host
        self.peers = peers
        self.onReconciled = onReconciled
        self.onSaved = onSaved
        _journal = State(initialValue: journal)
    }

    private var environments: [NetworkOnboardingEnvironment] { NetworkOnboardingEnvironment.environments(for: host) }
    private var otherMembers: [NetworkMeshHost] { peers.filter { $0.isMember && $0.id != host.id } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("配置主机互联").font(.title2.bold())
                    Spacer()
                    Text(host.name).foregroundStyle(.secondary)
                }
                Label("自动双向互联 · 校园网优先 · ZeroTier 备用", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline)
                HStack(spacing: 12) {
                    ForEach(Array(stepNames.enumerated()), id: \.offset) { index, name in
                        Button {
                            step = index
                            message = nil
                            errorMessage = nil
                        } label: {
                            HStack(spacing: 5) {
                                Text("\(index + 1)").font(.caption.bold())
                                    .frame(width: 22, height: 22)
                                    .background(index == step ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                                    .foregroundStyle(index == step ? Color.white : Color.secondary)
                                Text(name).font(.caption).foregroundStyle(index == step ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking || (index == 4 && result == nil))
                    }
                }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: registration
                    case 1: authentication
                    case 2: preparation
                    case 3: authorizationPlan
                    default: executionResults
                    }
                    if let message { Label(message, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout) }
                    if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("正在检查与配置…").foregroundStyle(.secondary)
                    Button("停止") { workTask?.cancel() }
                }
                Spacer()
                Button(step == 4 ? "关闭" : "取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isWorking)
                if step > 0 && step < 4 {
                    Button("上一步") { step -= 1; errorMessage = nil; message = nil }.disabled(isWorking)
                }
                if step < 3 {
                    Button("下一步") { step += 1; errorMessage = nil; message = nil }
                        .buttonStyle(.borderedProminent).disabled(isWorking || environments.isEmpty)
                        .keyboardShortcut(.defaultAction)
                } else if step == 3 {
                    Button("开始双向配置", action: configure)
                        .buttonStyle(.borderedProminent).disabled(isWorking || environments.isEmpty)
                        .keyboardShortcut(.defaultAction)
                } else if !isWorking, let result, !result.journal.pendingTasks.isEmpty {
                    Button("重试待处理项", action: configure).buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 820, height: 750)
        .interactiveDismissDisabled(isWorking)
        .onDisappear { pollTask?.cancel() }
    }

    private var registration: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(environments) { environment in
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(environment.displayName).font(.headline)
                        ForEach(environment.endpoints) { endpoint in
                            HStack {
                                Text(endpoint.networkKind.displayName).frame(width: 80, alignment: .leading)
                                Text("\(endpoint.address):\(String(endpoint.port))").font(.system(.callout, design: .monospaced))
                                Spacer()
                                Text(endpoint.label).foregroundStyle(.secondary)
                            }
                        }
                        if environment.username.isEmpty {
                            Text("请在主机编辑中明确填写该环境的 SSH 用户名，避免把不同用户的授权合并。").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DisclosureGroup("连接策略") {
                Text("校园网优先，网络不可达时尝试 ZeroTier；各入口分别测速。Windows 与 WSL 独立配置。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在 Terminal 确认服务器指纹、登录并安装管理公钥，再返回验证。")
                .foregroundStyle(.secondary)
            ForEach(environments) { environment in
                GroupBox(environment.displayName) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(environment.endpoints) { endpoint in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: verification[endpoint.id]?.succeeded == true ? "checkmark.circle.fill" : "circle.dashed")
                                        .foregroundStyle(verification[endpoint.id]?.succeeded == true ? Color.green : Color.secondary)
                                    Text("\(endpoint.label) · \(endpoint.address):\(String(endpoint.port))")
                                    Spacer()
                                    Button("首次登录") { bootstrap(endpoint, environmentID: environment.id) }.disabled(isWorking)
                                    Button("验证") { verify(endpoint, environmentID: environment.id) }.disabled(isWorking)
                                }
                                Text(verification[endpoint.id]?.detail ?? "待首次信任与管理登录验证")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        DisclosureGroup("新主机尚未启用 SSH 服务") {
                            let instructions = NetworkMembershipCommands.serverSetupInstructions(platform: environment.platform, environmentName: environment.environmentName)
                            Text("请在新主机本机执行以下准备步骤，再回到此处登录。").font(.caption).foregroundStyle(.secondary)
                            Text(instructions).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            Button("复制准备步骤") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(instructions, forType: .string) }
                        }
                        if environment.platform == .windows {
                            Text("Windows 管理员账户共用系统授权文件；需要管理员权限。多个管理员账户同时纳管会显示待处理。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            Text("离线或未认证入口保留待补配。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(environments) { environment in
                GroupBox(environment.displayName) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let endpoint = selectedEndpoint(environment) {
                            Picker("管理入口", selection: endpointBinding(environment)) {
                                ForEach(environment.endpoints) { endpoint in Text(endpoint.label).tag(endpoint.id) }
                            }
                            HStack {
                                Label(tools[environment.id].map { $0.hasIperf3 ? "iperf3 已检测到" : "缺少 iperf3" } ?? "测速工具尚未检查", systemImage: "speedometer")
                                Spacer()
                                Button("检查组件") { checkTools(endpoint, environmentID: environment.id) }.disabled(isWorking)
                                Button("准备测速工具") { openCommand { try NetworkMembershipCommands.prepareToolsCommand(endpoint: endpoint) } }.disabled(isWorking)
                            }
                            Text("iperf3 仅在测速时临时监听。").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            TextField("ZeroTier 网络 ID（可选）", text: networkBinding(environment.id), prompt: Text("16 位十六进制网络 ID"))
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Label(tools[environment.id].map { $0.hasZeroTier ? "ZeroTier 已检测到" : "缺少 ZeroTier" } ?? "ZeroTier 尚未检查", systemImage: "network")
                                Spacer()
                                Link("官方下载", destination: URL(string: "https://www.zerotier.com/download/")!)
                                Button("加入网络") { openCommand { try NetworkMembershipCommands.joinZeroTierCommand(endpoint: endpoint, networkID: networkIDs[environment.id] ?? "") } }
                                    .disabled(isWorking || (networkIDs[environment.id] ?? "").isEmpty)
                                Button("检查授权") { checkZeroTier(endpoint, environmentID: environment.id, poll: true) }
                                    .disabled(isWorking || (networkIDs[environment.id] ?? "").isEmpty)
                            }
                            if let status = zeroTierStates[environment.id] {
                                Label(status.detail, systemImage: status.isReady ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(status.isReady ? Color.green : Color.orange)
                                if !status.addresses.isEmpty { Text(status.addresses.joined(separator: "、")).font(.system(.caption, design: .monospaced)) }
                                if status.awaitsAuthorization {
                                    Link("打开 ZeroTier 控制台授权", destination: URL(string: "https://central.zerotier.com/")!)
                                    Text("等待网络管理员批准；授权后请将新 IP 登记为入口。").font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("网络授权并获得 IP 后显示就绪。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
        }
    }

    private var authorizationPlan: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("与 \(otherMembers.count) 台成员双向互联").font(.headline)
            Text("仅分发公钥；离线成员自动补配。").foregroundStyle(.secondary)
            ForEach(otherMembers) { peer in
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("\(host.name) ↔ \(peer.name)")
                    Spacer()
                    Text("执行时检查").font(.caption).foregroundStyle(.secondary)
                }.padding(10).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            if otherMembers.isEmpty { Text("当前没有其他成员；先完成该主机准备，新成员加入后会自动建立双向互联。").foregroundStyle(.secondary) }
            DisclosureGroup("配置与退出说明") {
                Text("维护受管理授权、别名与指纹，并验证各入口。退出时撤销互联授权，保留管理登录、原配置和当前会话。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var executionResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isWorking { Text("正在配置并验证各条连接").font(.headline) }
            else if let result {
                Text(result.isComplete ? "互联配置已完成" : "主机已登记，部分互联仍待处理").font(.headline)
                Text(result.journal.pendingTasks.isEmpty ? "所有要求的配置与验证均已完成。" : "\(result.journal.pendingTasks.count) 项待补配或撤销；任务已保存，恢复连接后自动重试。")
                    .foregroundStyle(.secondary)
            }
            if let result {
                ForEach(result.journal.pendingTasks) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.sourceName) → \(item.targetName)").font(.callout.bold())
                        Text(item.lastError ?? "等待补配").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else if let latest = progress.steps.last {
                Text(latest.title).font(.callout)
            }
            DisclosureGroup("查看详细过程") {
            ForEach(progress.steps) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.succeeded ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                        .foregroundStyle(item.succeeded ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.callout.bold())
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            }
        }
    }

    private func selectedEndpoint(_ environment: NetworkOnboardingEnvironment) -> NetworkMeshEndpoint? {
        environment.endpoints.first { $0.id == preferredEndpoints[environment.id] } ?? environment.endpoints.first
    }

    private func endpointBinding(_ environment: NetworkOnboardingEnvironment) -> Binding<UUID> {
        Binding(get: { selectedEndpoint(environment)?.id ?? UUID() }, set: { preferredEndpoints[environment.id] = $0 })
    }

    private func networkBinding(_ id: String) -> Binding<String> {
        Binding(get: { networkIDs[id] ?? "" }, set: { networkIDs[id] = $0; zeroTierStates[id] = nil })
    }

    private func bootstrap(_ endpoint: NetworkMeshEndpoint, environmentID: String) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        workTask = Task { @MainActor in
            defer { isWorking = false }
            let saved = await service.saveEndpoints(host.endpoints)
            if !saved.savedAliases.isEmpty { await onSaved() }
            if !saved.failures.isEmpty { errorMessage = saved.failures.map(\.detail).joined(separator: "\n") }
            do {
                try await terminal.open(NetworkMembershipCommands.bootstrapCommand(endpoint: endpoint, managerID: journal.managerID))
                preferredEndpoints[environmentID] = endpoint.id
                message = "Terminal 已打开。请完成指纹确认和公钥安装，再点击验证；目前尚未确认登录成功。"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func verify(_ endpoint: NetworkMeshEndpoint, environmentID: String) {
        guard !isWorking else { return }
        isWorking = true
        workTask = Task { @MainActor in
            defer { isWorking = false }
            let checked = await service.verifyEndpoint(endpoint)
            verification[endpoint.id] = checked
            if checked.succeeded { preferredEndpoints[environmentID] = endpoint.id }
        }
    }

    private func openCommand(_ command: @escaping () throws -> CommandSpec) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        workTask = Task { @MainActor in
            defer { isWorking = false }
            do {
                try await terminal.open(command())
                message = "Terminal 已打开。完成操作后请重新检查组件或网络状态。"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func checkTools(_ endpoint: NetworkMeshEndpoint, environmentID: String) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        workTask = Task { @MainActor in
            defer { isWorking = false }
            do { tools[environmentID] = try await service.toolStatus(endpoint: endpoint) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func checkZeroTier(_ endpoint: NetworkMeshEndpoint, environmentID: String, poll: Bool) {
        pollTask?.cancel()
        let networkID = networkIDs[environmentID] ?? ""
        pollTask = Task { @MainActor in
            for _ in 0..<(poll ? 30 : 1) {
                guard !Task.isCancelled else { return }
                do {
                    let status = try await service.zeroTierStatus(endpoint: endpoint, networkID: networkID)
                    zeroTierStates[environmentID] = status
                    if status.isReady || (!status.awaitsAuthorization && status.status != "REQUESTING_CONFIGURATION") { return }
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func configure() {
        guard !isWorking else { return }
        isWorking = true
        step = 4
        progress.steps = []
        errorMessage = nil
        message = nil
        var member = host
        member.isMember = true
        var desired = peers.filter { $0.id != host.id }
        desired.append(member)
        workTask = Task { @MainActor in
            defer { isWorking = false }
            let outcome = await service.reconcile(hosts: desired, journal: journal, forceRepair: true) { [progress] item in
                await progress.append(item)
            }
            journal = outcome.journal
            result = outcome
            await onReconciled(outcome)
            await onSaved()
        }
    }
}
