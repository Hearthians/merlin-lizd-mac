import AppKit
import SwiftUI
import TmuxHubCore

struct NetworkMeshView: View {
    @ObservedObject var model: NetworkMeshModel
    let sshHosts: [SSHHost]
    let onConnect: (String) -> Void
    var onHostsChanged: () -> Void = {}

    @State private var page: Page = .matrix
    @State private var networkKind: NetworkMeshNetworkKind?
    @State private var probeMode: NetworkMeshProbeMode = .speed
    @State private var selectedPair: Pair?
    @State private var selectedMembers: Set<UUID> = []
    @State private var membershipDirty = false
    @State private var editor: Editor?
    @State private var onboardingHost: NetworkMeshHost?
    @State private var pendingOnboardingID: UUID?
    @State private var searchText = ""
    @State private var showsAllHistory = false
    @State private var showsAllHosts = false
    @State private var diagnosticResult: NetworkMeshHealthResult?

    private enum Page: String, CaseIterable { case matrix = "矩阵", members = "成员", history = "历史" }
    private struct Pair: Equatable, Identifiable {
        let sourceID: UUID
        let targetID: UUID
        var id: String { "\(sourceID)→\(targetID)" }
    }
    private struct Editor: Identifiable {
        let id = UUID()
        let host: NetworkMeshHost?
    }

    private var matrixHosts: [NetworkMeshHost] { model.members }
    private var selectedRoutes: [NetworkMeshRoute] {
        guard let pair = selectedPair else { return [] }
        return model.routes(sourceHostID: pair.sourceID, targetHostID: pair.targetID, networkKind: networkKind)
    }
    private var allRoutes: [NetworkMeshRoute] { model.routes(networkKind: networkKind) }
    private var visibleHosts: [NetworkMeshHost] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.hosts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.endpoints.contains(where: {
            $0.address.localizedCaseInsensitiveContains(query) || $0.sshDestination.localizedCaseInsensitiveContains(query)
        }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                overview
                onlineStrip
                controls
                if let notice = model.notice {
                    MessageBanner(text: notice, kind: .warning)
                }
                if model.monitoringInterrupted {
                    MessageBanner(text: "监测中断，等待重新检查。", kind: .info)
                }
                if model.membershipNeedsReconcile && model.pendingTaskCount == 0 && !model.isReconciling {
                    MessageBanner(text: "等待联网配置。", kind: .info)
                }
                if model.isTesting || model.isPaused || model.isReconciling { progress }
                switch page {
                case .matrix: matrixPage
                case .members: membersPage
                case .history: historyPage
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.startMonitoring(sshHosts: sshHosts)
            selectedMembers = Set(model.members.map(\.id))
        }
        .onChange(of: sshHosts) { _, value in
            Task { await model.refresh(sshHosts: value) }
        }
        .onChange(of: model.hosts) { _, _ in
            if !membershipDirty { selectedMembers = Set(model.members.map(\.id)) }
        }
        .sheet(item: $selectedPair) { pair in
            VStack(spacing: 0) {
                HStack {
                    Text("网络路径").font(.headline)
                    Spacer()
                    Button("完成") { selectedPair = nil }.keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
                if model.isTesting || model.isPaused { progress.padding(16) }
                ScrollView {
                    if let source = model.host(id: pair.sourceID), let target = model.host(id: pair.targetID) {
                        pairDetails(source: source, target: target).padding(16)
                    }
                }
            }.frame(width: 720, height: 560)
        }
        .sheet(item: $editor, onDismiss: {
            if let id = pendingOnboardingID {
                pendingOnboardingID = nil
                if let host = model.host(id: id) { showOnboarding(host) }
            }
        }) { editor in
            NetworkMeshHostSheet(host: editor.host, hosts: model.hosts) { host, mergeID, configure in
                try model.save(host, mergingInto: mergeID)
                if configure { pendingOnboardingID = mergeID ?? host.id }
            }
        }
        .sheet(item: $onboardingHost, onDismiss: { model.setOnboardingPresented(false) }) { host in
            NetworkOnboardingSheet(
                host: host, peers: model.hosts, journal: model.membershipJournal,
                onReconciled: { result in
                    model.markForOnboarding(hostID: host.id)
                    model.acceptReconciliation(result)
                },
                onSaved: {
                    onHostsChanged()
                    await model.refresh(sshHosts: sshHosts)
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("主机互联").font(.largeTitle.bold())
                Text("在线状态 · 按方向测速")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("接入主机", systemImage: "plus") { editor = Editor(host: nil) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isBusy)
        }
    }

    private var overview: some View {
        HStack(spacing: 12) {
            summary(title: "登记主机", value: "\(model.hosts.count)", symbol: "server.rack", tint: .blue)
            summary(title: "本机可管理", value: "\(model.onlineCount)", symbol: "checkmark.circle", tint: .green)
            summary(title: "互联成员", value: "\(model.members.count)", symbol: "point.3.connected.trianglepath.dotted", tint: .purple)
            summary(title: "待配置 / 撤销", value: "\(model.pendingTaskCount)", symbol: "clock", tint: .orange)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("页面", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Spacer()
            if model.isCheckingOnline { ProgressView().controlSize(.small) }
            Text("状态 30 秒 · 互通 5 分钟")
                .font(.caption).foregroundStyle(.secondary)
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await model.refresh(sshHosts: sshHosts) }
            }.disabled(model.isBusy || model.isCheckingOnline)
                .contextMenu {
                    Button("重新导入已移除的主机") {
                        model.restoreRemovedCandidates()
                        Task { await model.refresh(sshHosts: sshHosts) }
                    }
                }
        }
    }

    private var progress: some View {
        SurfaceCard {
            HStack(spacing: 12) {
                if model.isTesting || model.isReconciling { ProgressView().controlSize(.small) }
                if model.isReconciling {
                    Text("正在配置成员互联…").font(.callout.weight(.medium))
                } else {
                    Text(model.isPaused ? "测试已暂停" : (model.isAutomaticTesting ? "正在检查成员互通" : "正在\(model.activeMode?.displayName ?? "测试")"))
                        .font(.callout.weight(.medium))
                    Text("\(model.completedCount) / \(model.plannedCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if model.isPaused {
                        Button("继续", systemImage: "play") { model.resume() }.disabled(model.isTesting)
                    } else if !model.isAutomaticTesting {
                        Button("暂停", systemImage: "pause") { model.pause() }
                    }
                    Button("停止", systemImage: "stop") { model.cancel() }
                }
            }
            if !model.isReconciling {
                ProgressView(value: Double(model.completedCount), total: Double(max(1, model.plannedCount)))
            } else if let step = model.membershipSteps.last {
                Text("\(step.title)：\(step.detail)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var matrixPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            testControls
            if matrixHosts.isEmpty {
                ContentUnavailableView {
                    Label("先选择互联成员", systemImage: "network")
                } description: {
                    Text("在成员中勾选主机并应用。")
                } actions: {
                    Button("选择成员") { page = .members }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, minHeight: 240)
            } else {
                SurfaceCard {
                    HStack {
                        Text("行＝来源 → 列＝目标").font(.callout.weight(.medium))
                        Spacer()
                        Text("Mbps · 点击展开路径").font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow {
                                Text("来源 ↓ / 目标 →").font(.caption).foregroundStyle(.secondary).frame(width: 130)
                                ForEach(matrixHosts) { host in
                                    Text(host.isLocal ? "\(host.name) · 本机" : host.name)
                                        .font(.caption.weight(.semibold)).lineLimit(2)
                                        .frame(width: 160, height: 42).help(host.name)
                                }
                            }
                            ForEach(matrixHosts) { source in
                                GridRow {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(source.name).font(.caption.weight(.semibold)).lineLimit(2)
                                        Text(model.hostState(source).title)
                                            .font(.caption2).foregroundStyle(color(model.hostState(source).tone))
                                    }.frame(width: 130, alignment: .leading)
                                    ForEach(matrixHosts) { target in
                                        matrixCell(source: source, target: target)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var testControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    networkPicker
                    modePicker
                    Spacer()
                    allTestButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    networkPicker
                    modePicker
                    allTestButton
                }
            }
            Text(testEstimate(routes: allRoutes, mode: probeMode))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var networkPicker: some View {
        Picker("目标网络", selection: $networkKind) {
            Text("全部网络").tag(NetworkMeshNetworkKind?.none)
            ForEach(NetworkMeshNetworkKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
        }.frame(width: 220)
    }

    private var modePicker: some View {
        Picker("测试类型", selection: $probeMode) {
            ForEach(NetworkMeshProbeMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }.frame(width: 250)
    }

    private var allTestButton: some View {
        Button("全网测试", systemImage: "speedometer") { model.start(routes: allRoutes, mode: probeMode) }
            .buttonStyle(.borderedProminent).disabled(model.isBusy || allRoutes.isEmpty)
    }

    private var onlineStrip: some View {
        SurfaceCard {
            HStack {
                Text("所有登记主机").font(.headline)
                Spacer()
                if model.hosts.count > 9 {
                    Button(showsAllHosts ? "收起" : "查看全部（\(model.hosts.count)）") { showsAllHosts.toggle() }
                        .controlSize(.small)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 10) {
                ForEach(showsAllHosts ? model.hosts : Array(model.hosts.prefix(9))) { host in
                    let state = model.hostState(host)
                    Button {
                        page = .members
                        searchText = host.name
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(color(state.tone)).frame(width: 7, height: 7)
                            Text(host.name).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(state.title).font(.caption2).foregroundStyle(color(state.tone))
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help(state.detail)
                }
            }
            if model.hosts.isEmpty { Text("正在发现本机与导入 SSH 配置…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func showOnboarding(_ host: NetworkMeshHost) {
        model.setOnboardingPresented(true)
        onboardingHost = host
    }

    private func matrixCell(source: NetworkMeshHost, target: NetworkMeshHost) -> some View {
        let routes = model.routes(sourceHostID: source.id, targetHostID: target.id, networkKind: networkKind)
        let fresh = routes.compactMap { model.freshConnection(for: $0) }
        let successes = fresh.filter { $0.status == .reachable }.count
        let isSelected = selectedPair == Pair(sourceID: source.id, targetID: target.id)
        let representative = representativeRoute(routes)
        let isRunning = routes.contains { model.activeRouteIDs.contains($0.id) }
        let tint: Color = successes == routes.count && !routes.isEmpty ? .green : (successes > 0 ? .orange : (fresh.isEmpty ? .secondary : .red))
        return Button {
            selectedPair = Pair(sourceID: source.id, targetID: target.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    if isRunning { ProgressView().controlSize(.mini) }
                    Text(routes.isEmpty ? (source.id == target.id ? "自身" : "无匹配路径") : (fresh.isEmpty ? "未验证" : "\(successes)/\(routes.count) 路径可达"))
                        .font(.caption.weight(.medium)).foregroundStyle(tint)
                    Spacer(minLength: 0)
                }
                if let route = representative {
                    HStack(spacing: 8) {
                        Text("SSH \(speedValue(model.latestResult(for: route, mode: .speed)))")
                        Text("网 \(speedValue(model.latestResult(for: route, mode: .bandwidth)))")
                    }.font(.caption2.monospacedDigit()).foregroundStyle(.primary).lineLimit(1)
                    let endpoint = model.endpoint(hostID: target.id, endpointID: route.targetEndpointID)
                    Text(endpoint?.label ?? "—").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let measured = [model.latestResult(for: route, mode: .speed)?.measuredAt, model.latestResult(for: route, mode: .bandwidth)?.measuredAt].compactMap({ $0 }).max() {
                        Text("测于 \(measured.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .padding(10).frame(width: 160, height: 108, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelected ? Color.accentColor : tint.opacity(0.15), lineWidth: isSelected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .disabled(routes.isEmpty)
        .accessibilityLabel("\(source.name)到\(target.name)，\(successes)条路径可达，共\(routes.count)条")
        .help("来源：\(source.name) → 目标：\(target.name)；速度单位 Mbps，点击查看具体路径和测试时间。")
    }

    private func pairDetails(source: NetworkMeshHost, target: NetworkMeshHost) -> some View {
        SurfaceCard {
            HStack {
                Text("\(source.name) → \(target.name)").font(.headline)
                Spacer()
                Button("反向") { selectedPair = Pair(sourceID: target.id, targetID: source.id) }
                Button("测试这些路径") { model.start(routes: selectedRoutes, mode: probeMode) }
                    .disabled(model.isBusy || selectedRoutes.isEmpty)
            }
            if selectedRoutes.isEmpty {
                Text("此网络筛选下没有路径。").foregroundStyle(.secondary)
            }
            ForEach(selectedRoutes) { route in
                if let sourceEndpoint = model.endpoint(hostID: source.id, endpointID: route.sourceEndpointID),
                   let targetEndpoint = model.endpoint(hostID: target.id, endpointID: route.targetEndpointID) {
                    routeRow(route, source: sourceEndpoint, target: targetEndpoint)
                    if route.id != selectedRoutes.last?.id { Divider() }
                }
            }
        }
    }

    private func routeRow(_ route: NetworkMeshRoute, source: NetworkMeshEndpoint, target: NetworkMeshEndpoint) -> some View {
        let connection = model.freshConnection(for: route)
        let previousConnection = model.latestResult(for: route, mode: .connectivity)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(source.environmentName) / \(source.label) → \(target.environmentName) / \(target.label)")
                        .font(.callout.weight(.semibold))
                    Text("\(source.username.isEmpty ? "" : source.username + "@")\(source.address) → \(target.username.isEmpty ? "" : target.username + "@")\(target.address):\(String(target.port))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                StatusPill(label: connection?.status.displayName ?? (previousConnection == nil ? "未测" : "历史 / 未知"),
                           color: connection.map { statusColor($0.status) } ?? .secondary)
                Button("检查") { model.start(routes: [route], mode: .connectivity) }.disabled(model.isBusy)
            }
            HStack(alignment: .top, spacing: 24) {
                speedMetric(title: "SSH 吞吐", result: model.latestResult(for: route, mode: .speed), route: route, mode: .speed)
                speedMetric(title: "网络带宽", result: model.latestResult(for: route, mode: .bandwidth), route: route, mode: .bandwidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接延迟").font(.caption).foregroundStyle(.secondary)
                    Text(connection?.latencyMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                        .font(.headline.monospacedDigit())
                    Text("来源地址的 ICMP 平均 RTT").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = connection ?? previousConnection, result.status != .reachable {
                Text(result.message).font(.caption).foregroundStyle(statusColor(result.status)).textSelection(.enabled)
            }
            DisclosureGroup("历史与详细结果（\(model.results(for: route).count)）") {
                ForEach(Array(model.results(for: route).prefix(12))) { historyRow($0) }
            }.font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func speedMetric(title: String, result: NetworkMeshProbeResult?, route: NetworkMeshRoute, mode: NetworkMeshProbeMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Button("测速") { model.start(routes: [route], mode: mode) }
                    .controlSize(.small).disabled(model.isBusy)
            }
            Text(result?.throughputMbps.map { String(format: "%.1f Mbps", $0) } ?? "未测")
                .font(.headline.monospacedDigit())
            if let result {
                Text("最近测试 \(time(result.measuredAt))").font(.caption2).foregroundStyle(.secondary)
                if result.status != .reachable {
                    Text(result.message).font(.caption2).foregroundStyle(statusColor(result.status)).lineLimit(3)
                }
            } else {
                Text(mode == .speed ? "固定 32 MiB，含 SSH 开销" : "iperf3，独立网络带宽")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var membersPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("互联成员").font(.headline)
                        Text("勾选并应用；加入自动互联，退出撤销授权。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("全选") { selectedMembers = Set(model.hosts.map(\.id)); membershipDirty = true }.disabled(model.isBusy)
                    Button("应用") {
                        let selected = selectedMembers
                        membershipDirty = false
                        Task { await model.applyMembership(selected) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || selectedMembers == Set(model.members.map(\.id)))
                }
                TextField("搜索主机、别名或地址", text: $searchText).textFieldStyle(.roundedBorder)
            }
            if model.hosts.isEmpty {
                ContentUnavailableView("尚无主机", systemImage: "server.rack", description: Text("接入新主机，或刷新导入已有 SSH 配置。"))
            }
            ForEach(visibleHosts) { host in hostCard(host) }
            if model.pendingTaskCount > 0 || !model.membershipSteps.isEmpty { membershipStatus }
        }
    }

    @ViewBuilder
    private func defaultSSHControl(_ host: NetworkMeshHost) -> some View {
        if !host.isLocal {
            let environments = model.connectionEnvironments(for: host)
            if environments.count == 1, let environment = environments.first {
                Button(model.isConnecting(host: host, environment: environment) ? "连接中…" : "SSH", systemImage: "terminal") { connectDefault(host: host, environment: environment) }
                    .disabled(model.isConnecting(host: host, environment: environment))
                    .help("校园网优先；仅网络失败时使用同一环境的备用入口。")
            } else if !environments.isEmpty {
                Menu {
                    ForEach(environments) { environment in
                        Button("\(environment.environmentName) · \(environment.username)") {
                            connectDefault(host: host, environment: environment)
                        }.disabled(model.isConnecting(host: host, environment: environment))
                    }
                } label: { Label("SSH", systemImage: "terminal") }
                .help("选择系统环境；校园网优先，ZeroTier 备用。")
            }
        }
    }

    private func connectDefault(host: NetworkMeshHost, environment: NetworkMeshEndpoint) {
        Task {
            if let destination = await model.preferredSSHDestination(host: host, environment: environment) {
                onConnect(destination)
            }
        }
    }

    private func hostCard(_ host: NetworkMeshHost) -> some View {
        let state = model.hostState(host)
        return SurfaceCard {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { selectedMembers.contains(host.id) }, set: { value in
                    if value { selectedMembers.insert(host.id) } else { selectedMembers.remove(host.id) }
                    membershipDirty = true
                })) { Text(host.name).font(.headline) }
                    .toggleStyle(.checkbox).disabled(model.isBusy)
                if host.isLocal { Text("本机").font(.caption).foregroundStyle(.secondary) }
                if selectedMembers.contains(host.id) != host.isMember { Text("待应用").font(.caption).foregroundStyle(.orange) }
                Spacer()
                StatusPill(label: state.title, color: color(state.tone))
                defaultSSHControl(host)
                Button("编辑") { editor = Editor(host: host) }.disabled(model.isBusy)
                Button("接入向导") { showOnboarding(host) }.disabled(model.isBusy)
            }
            Text(state.detail).font(.caption).foregroundStyle(.secondary)
            ForEach(host.endpoints) { endpoint in
                endpointRow(host: host, endpoint: endpoint)
            }
            if !host.isLocal && !host.isMember {
                HStack {
                    Spacer()
                    Button("移除登记", role: .destructive) { model.remove(hostID: host.id) }.controlSize(.small).disabled(model.isBusy)
                }
            }
        }
    }

    private func endpointRow(host: NetworkMeshHost, endpoint: NetworkMeshEndpoint) -> some View {
        let current = model.freshHealth(endpointID: endpoint.id)
        let previous = model.latestHealth(endpointID: endpoint.id)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: endpoint.networkKind == .zeroTier ? "point.3.filled.connected.trianglepath.dotted" : "network")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(endpoint.environmentName) · \(endpoint.label) · \(endpoint.username)")
                    .font(.caption.weight(.medium))
                Text("\(endpoint.address):\(String(endpoint.port))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let previous {
                    Text("\(current == nil ? "上次" : "检查") \(time(previous.checkedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(current?.status.displayName ?? "未知").font(.caption)
                .foregroundStyle(healthColor(current?.status))
            if let previous {
                Button { diagnosticResult = previous } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).help("查看完整诊断")
                    .popover(isPresented: Binding(
                        get: { diagnosticResult?.endpointID == endpoint.id },
                        set: { if !$0 { diagnosticResult = nil } }
                    )) {
                        if let result = diagnosticResult {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(result.status.displayName).font(.headline)
                                    Spacer()
                                    Button("复制") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(result.message, forType: .string)
                                    }
                                }
                                Text(time(result.checkedAt)).font(.caption).foregroundStyle(.secondary)
                                ScrollView { Text(result.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            .padding(16).frame(width: 440, height: 300)
                        }
                    }
            }
            if !host.isLocal && !endpoint.sshDestination.isEmpty {
                Button("SSH", systemImage: "terminal") { onConnect(endpoint.sshDestination) }.controlSize(.small)
            }
        }.padding(.vertical, 4)
    }

    private var membershipStatus: some View {
        SurfaceCard {
            HStack {
                Text("配置与撤销").font(.headline)
                Spacer()
                Button("重试待处理") { Task { await model.reconcileMembership() } }
                    .disabled(model.isBusy || model.pendingTaskCount == 0)
            }
            if model.pendingTaskCount > 0 {
                DisclosureGroup("\(String(model.pendingTaskCount)) 项待处理") {
                    ForEach(model.membershipJournal.pendingTasks) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(task.sourceName) → \(task.targetName) · \(task.kind == .revoke ? "待撤销" : (task.kind == .prepare ? "待准备" : "待配置"))", systemImage: "clock")
                                .font(.callout).foregroundStyle(.orange)
                            if let error = task.lastError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(.vertical, 4)
                    }
                }.font(.caption)
            }
            if !model.membershipSteps.isEmpty {
                DisclosureGroup("最近执行记录") {
                    ForEach(model.membershipSteps) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(step.title, systemImage: step.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(step.succeeded ? Color.green : Color.orange)
                            Text(step.detail).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.caption).padding(.vertical, 4)
                    }
                }.font(.caption)
            }
        }
    }

    private var historyPage: some View {
        SurfaceCard {
            HStack {
                Text("测试历史（\(model.history.count)）").font(.headline)
                Spacer()
                Toggle("全部", isOn: $showsAllHistory).toggleStyle(.checkbox)
                Button("清空", role: .destructive) { model.clearHistory() }.disabled(model.isTesting || model.history.isEmpty)
            }
            if model.history.isEmpty {
                Text("尚未进行测试。轻量状态检查与测速记录分别保存。").foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(showsAllHistory ? model.history : Array(model.history.prefix(100))) { result in historyRow(result) }
        }
    }

    private func historyRow(_ result: NetworkMeshProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(result.mode.displayName).font(.caption.weight(.medium))
                Text("\(model.host(id: result.route.sourceHostID)?.name ?? "已移除主机") → \(model.host(id: result.route.targetHostID)?.name ?? "已移除主机")")
                    .font(.caption).lineLimit(1)
                Spacer()
                if let speed = result.throughputMbps { Text(String(format: "%.1f Mbps", speed)).font(.caption.monospacedDigit()) }
                Text(result.status.displayName).font(.caption).foregroundStyle(statusColor(result.status))
                Text(time(result.measuredAt)).font(.caption2).foregroundStyle(.secondary)
            }
            if let context = model.measurementContexts[result.id.uuidString] {
                Text("\(context.sourceEnvironmentName) \(context.sourceAddress) → \(context.targetEnvironmentName) \(context.targetAddress):\(String(context.targetPort))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(result.message).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(.vertical, 7)
    }

    private func summary(title: String, value: String, symbol: String, tint: Color) -> some View {
        SurfaceCard {
            HStack {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(tint)
                Spacer()
                Text(value).font(.title2.bold().monospacedDigit())
            }
        }
    }

    private func representativeRoute(_ routes: [NetworkMeshRoute]) -> NetworkMeshRoute? {
        routes.first { model.freshConnection(for: $0)?.status == .reachable }
            ?? routes.first { model.latestResult(for: $0, mode: .speed) != nil || model.latestResult(for: $0, mode: .bandwidth) != nil }
            ?? routes.first
    }

    private func testEstimate(routes: [NetworkMeshRoute], mode: NetworkMeshProbeMode) -> String {
        switch mode {
        case .connectivity: "\(routes.count) 条有向路径；仅轻量连接检查，不传输测速数据。"
        case .speed: "\(routes.count) 条路径依次测试，预计发送 \(String(format: "%.2f", Double(routes.count * 32) / 1024)) GiB。速度包含 SSH 加密与处理开销。"
        case .bandwidth: "\(routes.count) 条路径依次测试，每条约 3 秒；流量随带宽变化，需要双方准备 iperf3。"
        }
    }

    private func speedValue(_ result: NetworkMeshProbeResult?) -> String {
        result?.throughputMbps.map { String(format: "%.1f", $0) } ?? "—"
    }
    private func time(_ date: Date) -> String { date.formatted(.dateTime.month().day().hour().minute().second()) }
    private func color(_ tone: NetworkMeshStateTone) -> Color {
        switch tone { case .good: .green; case .partial: .orange; case .bad: .red; case .unknown: .secondary }
    }
    private func statusColor(_ status: NetworkMeshProbeStatus) -> Color {
        switch status {
        case .reachable: .green
        case .unreachable: .red
        case .authenticationRequired, .hostKeyFailure, .unsupported: .orange
        case .cancelled: .secondary
        }
    }
    private func healthColor(_ status: NetworkMeshHealthStatus?) -> Color {
        switch status {
        case .online: .green
        case .networkOnly, .authenticationRequired, .hostKeyFailure, .unsupported: .orange
        case .unreachable: .red
        case .cancelled, nil: .secondary
        }
    }
}
