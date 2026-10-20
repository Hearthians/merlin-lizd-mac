import AppKit
import Combine
import Darwin
import Foundation
import Network
import TmuxHubCore

enum NetworkMeshStateTone { case good, partial, bad, unknown }

struct NetworkMeshMeasurementContext: Codable, Equatable {
    let sourceHostName: String
    let targetHostName: String
    let sourceEnvironmentName: String
    let targetEnvironmentName: String
    let sourceAddress: String
    let targetAddress: String
    let targetPort: Int
}

@MainActor
final class NetworkMeshModel: ObservableObject {
    @Published private(set) var hosts: [NetworkMeshHost] = []
    @Published private(set) var history: [NetworkMeshProbeResult] = []
    @Published private(set) var measurementContexts: [String: NetworkMeshMeasurementContext] = [:]
    @Published private(set) var healthResults: [NetworkMeshHealthResult] = []
    @Published private(set) var membershipJournal = NetworkMembershipJournal()
    @Published private(set) var membershipSteps: [NetworkOnboardingStep] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isCheckingOnline = false
    @Published private(set) var isReconciling = false
    @Published private(set) var isTesting = false
    @Published private(set) var isPaused = false
    @Published private(set) var completedCount = 0
    @Published private(set) var plannedCount = 0
    @Published private(set) var activeRouteIDs: Set<String> = []
    @Published private(set) var connectingEnvironmentIDs: Set<String> = []
    @Published private(set) var activeMode: NetworkMeshProbeMode?
    @Published private(set) var clock = Date()
    @Published private(set) var monitoringInterrupted = false
    @Published var notice: String?

    private let defaults: UserDefaults
    private let reader: SSHHostPropertiesReader
    private let service: NetworkMeshProbeService
    private let healthService: NetworkMeshHealthService
    private let onboarding: NetworkOnboardingService
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var testTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var routeMonitorTask: Task<Void, Never>?
    private var monitoringStarted = false
    @Published private(set) var isAutomaticTesting = false
    private var remainingRoutes: [NetworkMeshRoute] = []
    private var pausedMode: NetworkMeshProbeMode?
    private var validAfter = Date()
    private var lastMonitorTick = Date()
    private var lastRouteCheck = Date.distantPast
    private var lastMembershipAttempt = Date.distantPast
    private var networkAvailable = true
    private var networkSignature: String?
    private var isSleeping = false
    private var onboardingPresented = false
    @Published private(set) var membershipNeedsReconcile = false
    private var onlineHostIDs: Set<UUID> = []
    private var ignoredDestinations: Set<String> = []
    private var ignoredEndpoints: Set<String> = []
    private let storageKey = "tmuxhub.network-mesh.v1"
    private let historyLimit = 3_000
    private let healthTTL: TimeInterval = 90
    private let routeTTL: TimeInterval = 15 * 60

    private struct Snapshot: Codable {
        var hosts: [NetworkMeshHost]
        var history: [NetworkMeshProbeResult]
        var healthResults: [NetworkMeshHealthResult]?
        var membershipJournal: NetworkMembershipJournal?
        var measurementContexts: [String: NetworkMeshMeasurementContext]?
        var ignoredDestinations: [String]?
        var ignoredEndpoints: [String]?
    }

    init(
        defaults: UserDefaults = .standard,
        reader: SSHHostPropertiesReader = SSHHostPropertiesReader(),
        service: NetworkMeshProbeService = NetworkMeshProbeService(),
        healthService: NetworkMeshHealthService = NetworkMeshHealthService(),
        onboarding: NetworkOnboardingService = NetworkOnboardingService()
    ) {
        self.defaults = defaults
        self.reader = reader
        self.service = service
        self.healthService = healthService
        self.onboarding = onboarding
        if let data = defaults.data(forKey: storageKey) {
            do {
                let saved = try JSONDecoder().decode(Snapshot.self, from: data)
                hosts = saved.hosts
                history = Array(saved.history.prefix(historyLimit))
                healthResults = saved.healthResults ?? []
                measurementContexts = saved.measurementContexts ?? [:]
                ignoredDestinations = Set(saved.ignoredDestinations ?? [])
                ignoredEndpoints = Set(saved.ignoredEndpoints ?? [])
                membershipJournal = saved.membershipJournal ?? NetworkMembershipJournal()
                membershipNeedsReconcile = !membershipJournal.pendingTasks.isEmpty || hosts.contains(where: \.isMember) || !membershipJournal.environments.isEmpty
            } catch { notice = "保存的互联数据无法读取：\(error.localizedDescription)" }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interruptMonitoring(sleeping: true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.interruptMonitoring(sleeping: false)
                self?.lastRouteCheck = .distantPast
                await self?.monitorCycle()
            }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let available = path.status == .satisfied
                let signature = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
                let changed = self.networkSignature != nil && self.networkSignature != signature
                self.networkSignature = signature
                if self.networkAvailable != available || changed {
                    self.networkAvailable = available
                    self.interruptMonitoring(sleeping: self.isSleeping)
                    if available { await self.monitorCycle() }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "tmuxhub.mesh.path"))
    }

    var members: [NetworkMeshHost] { hosts.filter(\.isMember) }
    var endpointCount: Int { hosts.reduce(0) { $0 + $1.endpoints.count } }
    var pendingTaskCount: Int { membershipJournal.pendingTasks.count }
    var lastMeasuredAt: Date? { history.first?.measuredAt }
    var onlineCount: Int { hosts.filter { host in host.endpoints.contains { freshHealth(endpointID: $0.id)?.status == .online } }.count }
    var isBusy: Bool { isTesting || isReconciling || isRefreshing || onboardingPresented }

    func setOnboardingPresented(_ presented: Bool) { onboardingPresented = presented }

    func host(id: UUID) -> NetworkMeshHost? { hosts.first { $0.id == id } }

    func endpoint(hostID: UUID, endpointID: UUID) -> NetworkMeshEndpoint? {
        host(id: hostID)?.endpoints.first { $0.id == endpointID }
    }

    func connectionEnvironments(for host: NetworkMeshHost) -> [NetworkMeshEndpoint] {
        var seen = Set<String>()
        return host.endpoints.filter { endpoint in
            let key = "\(endpoint.environmentID)|\(endpoint.username)|\(endpoint.platform.rawValue)"
            return seen.insert(key).inserted
        }
    }

    private func connectionIdentity(host: NetworkMeshHost, environment: NetworkMeshEndpoint) -> String {
        "\(host.id)|\(environment.environmentID)|\(environment.username)|\(environment.platform.rawValue)"
    }

    func isConnecting(host: NetworkMeshHost, environment: NetworkMeshEndpoint) -> Bool {
        connectingEnvironmentIDs.contains(connectionIdentity(host: host, environment: environment))
    }

    func preferredSSHDestination(host: NetworkMeshHost, environment: NetworkMeshEndpoint) async -> String? {
        let identity = connectionIdentity(host: host, environment: environment)
        guard connectingEnvironmentIDs.insert(identity).inserted else { return nil }
        defer { connectingEnvironmentIDs.remove(identity) }
        func priority(_ kind: NetworkMeshNetworkKind) -> Int {
            switch kind { case .campus: 0; case .zeroTier: 1; case .lan: 2; case .publicInternet: 3; case .other: 4 }
        }
        let candidates = host.endpoints.filter {
            $0.environmentID == environment.environmentID && $0.username == environment.username && $0.platform == environment.platform
        }.sorted { priority($0.networkKind) < priority($1.networkKind) }
        for endpoint in candidates {
            let result = await healthService.check(host: host, endpoint: endpoint)
            healthResults.removeAll { $0.endpointID == result.endpointID }
            healthResults.insert(result, at: 0)
            clock = Date()
            persist()
            if result.status == .unreachable { continue }
            if result.status == .cancelled { return nil }
            guard !endpoint.sshDestination.isEmpty else {
                notice = "此入口尚无 SSH 别名，请先在接入向导保存配置。"
                return nil
            }
            if result.status != .online { notice = result.message }
            return endpoint.sshDestination
        }
        notice = "\(host.name) / \(environment.environmentName)：所有入口本次未连通。"
        return nil
    }

    func latestHealth(endpointID: UUID) -> NetworkMeshHealthResult? {
        healthResults.first { $0.endpointID == endpointID }
    }

    func freshHealth(endpointID: UUID) -> NetworkMeshHealthResult? {
        guard !monitoringInterrupted, let result = latestHealth(endpointID: endpointID),
              result.checkedAt >= validAfter, clock.timeIntervalSince(result.checkedAt) <= healthTTL else { return nil }
        return result
    }

    func hostState(_ host: NetworkMeshHost) -> (title: String, detail: String, tone: NetworkMeshStateTone) {
        let fresh = host.endpoints.compactMap { freshHealth(endpointID: $0.id) }
        let online = fresh.filter { $0.status == .online }.count
        if online > 0 {
            let all = online == host.endpoints.count
            return (all ? "在线" : "部分可用", "\(online)/\(host.endpoints.count) 个入口可 SSH 管理", all ? .good : .partial)
        }
        if fresh.contains(where: { $0.status == .networkOnly }) { return ("网络可达", "SSH 登录尚未成功", .partial) }
        if fresh.contains(where: { $0.status == .authenticationRequired || $0.status == .hostKeyFailure }) {
            return ("待处理", "认证或服务器指纹需要处理", .partial)
        }
        if fresh.contains(where: { $0.status == .unsupported }) { return ("无法检查", "检查方式或配置需要处理", .partial) }
        if !fresh.isEmpty && fresh.count == host.endpoints.count { return ("无响应", "本次探测未成功", .bad) }
        return ("未知", monitoringInterrupted ? "监测中断，等待重新检查" : "等待检查或结果已过期", .unknown)
    }

    func routes(sourceHostID: UUID? = nil, targetHostID: UUID? = nil, networkKind: NetworkMeshNetworkKind? = nil) -> [NetworkMeshRoute] {
        members.filter { sourceHostID == nil || $0.id == sourceHostID }.flatMap { source in
            members.filter { targetHostID == nil || $0.id == targetHostID }.flatMap { target in
                source.endpoints.flatMap { sourceEndpoint in
                    target.endpoints.filter {
                        (networkKind == nil || $0.networkKind == networkKind) &&
                        Self.compatibleFamilies(sourceEndpoint.address, $0.address) &&
                        (source.id != target.id || $0.environmentID != sourceEndpoint.environmentID || $0.username != sourceEndpoint.username || $0.platform != sourceEndpoint.platform)
                    }.map { targetEndpoint in
                        NetworkMeshRoute(sourceHostID: source.id, sourceEndpointID: sourceEndpoint.id, targetHostID: target.id, targetEndpointID: targetEndpoint.id)
                    }
                }
            }
        }
    }

    func latestResult(for route: NetworkMeshRoute, mode: NetworkMeshProbeMode? = nil) -> NetworkMeshProbeResult? {
        history.first { $0.route.id == route.id && (mode == nil || $0.mode == mode) }
    }

    func freshConnection(for route: NetworkMeshRoute) -> NetworkMeshProbeResult? {
        guard !monitoringInterrupted, let result = latestResult(for: route, mode: .connectivity),
              result.measuredAt >= validAfter, clock.timeIntervalSince(result.measuredAt) <= routeTTL else { return nil }
        return result
    }

    func results(for route: NetworkMeshRoute) -> [NetworkMeshProbeResult] { history.filter { $0.route.id == route.id } }

    func startMonitoring(sshHosts: [SSHHost]) async {
        if !monitoringStarted {
            monitoringStarted = true
            await refresh(sshHosts: sshHosts)
            lastMonitorTick = Date()
            monitorTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.monitorCycle()
                }
            }
        }
    }

    func refresh(sshHosts: [SSHHost]) async {
        guard !isRefreshing, !isTesting, !isReconciling else { return }
        isRefreshing = true
        await discoverLocalHost()
        await importSSHHosts(sshHosts)
        sortHosts()
        persist()
        isRefreshing = false
        await checkOnline()
    }

    func importSSHHosts(_ sshHosts: [SSHHost]) async {
        let reader = reader
        let resolved = await withTaskGroup(of: (String, SSHHostProperties?, String?).self) { group in
            var iterator = sshHosts.makeIterator()
            func submit(_ host: SSHHost) {
                group.addTask {
                    do { return (host.destination, try await reader.load(destination: host.destination), nil) }
                    catch { return (host.destination, nil, error.localizedDescription) }
                }
            }
            for _ in 0..<3 { if let next = iterator.next() { submit(next) } }
            var values: [(String, SSHHostProperties?, String?)] = []
            while let value = await group.next() {
                values.append(value)
                if let next = iterator.next() { submit(next) }
            }
            return values.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        }
        var failures: [String] = []
        for (destination, properties, error) in resolved {
            if ignoredDestinations.contains(destination) { continue }
            guard let properties else { failures.append("\(destination)：\(error ?? "无法读取配置")"); continue }
            if ignoredEndpoints.contains("\(properties.hostname)|\(properties.username)|\(properties.port)") { continue }
            if hosts.contains(where: { !$0.isLocal && $0.endpoints.contains(where: { $0.sshDestination == destination }) }) { continue }
            if hosts.contains(where: { !$0.isLocal && $0.endpoints.contains(where: {
                $0.address == properties.hostname && $0.username == properties.username && $0.port == properties.port
            }) }) { continue }
            let kind = Self.suggestedKind(for: destination)
            let isWSL = destination.lowercased().contains("wsl")
            hosts.append(NetworkMeshHost(
                name: destination, controlDestination: destination,
                endpoints: [NetworkMeshEndpoint(
                    label: kind == .other ? "SSH 地址" : kind.displayName,
                    address: properties.hostname, username: properties.username, port: properties.port,
                    sshDestination: destination, networkKind: kind,
                    environmentID: isWSL ? "wsl" : "main", environmentName: isWSL ? "WSL" : "系统"
                )]
            ))
        }
        if !failures.isEmpty { notice = "\(failures.count) 个 SSH 配置未能导入。\n" + failures.prefix(5).joined(separator: "\n") }
        sortHosts()
        persist()
    }

    func save(_ supplied: NetworkMeshHost, mergingInto targetID: UUID? = nil) throws {
        guard !isBusy else { throw MeshEditingError.testing }
        var edited = supplied
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.name.isEmpty else { throw MeshEditingError.name }
        if let control = edited.controlDestination, !IdentifierValidator.isSSHDestination(control) { throw MeshEditingError.destination }
        for index in edited.endpoints.indices {
            let endpoint = edited.endpoints[index]
            _ = try SSHHostConfiguration(alias: "mesh-validation", hostname: endpoint.address, username: endpoint.username, port: endpoint.port)
            guard (1...65_535).contains(endpoint.bandwidthPort) else { throw MeshEditingError.port }
            guard endpoint.environmentID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { throw MeshEditingError.environment }
            if !endpoint.sshDestination.isEmpty && !IdentifierValidator.isSSHDestination(endpoint.sshDestination) { throw MeshEditingError.destination }
            if !edited.isLocal && endpoint.sshDestination.isEmpty {
                edited.endpoints[index].sshDestination = "mesh-\(endpoint.id.uuidString.lowercased().prefix(8))"
            }
        }
        if let targetID, targetID != edited.id, let targetIndex = hosts.firstIndex(where: { $0.id == targetID }),
           !edited.isLocal, !hosts[targetIndex].isLocal {
            var merged = hosts[targetIndex]
            for endpoint in edited.endpoints where !merged.endpoints.contains(where: { $0.id == endpoint.id }) { merged.endpoints.append(endpoint) }
            merged.isMember = merged.isMember || edited.isMember
            if merged.controlDestination == nil { merged.controlDestination = edited.controlDestination }
            hosts[targetIndex] = merged
            hosts.removeAll { $0.id == edited.id }
            for index in history.indices {
                if history[index].route.sourceHostID == edited.id { history[index].route.sourceHostID = targetID }
                if history[index].route.targetHostID == edited.id { history[index].route.targetHostID = targetID }
            }
        } else if let index = hosts.firstIndex(where: { $0.id == edited.id }) { hosts[index] = edited }
        else { hosts.append(edited) }
        for endpoint in edited.endpoints {
            ignoredDestinations.remove(endpoint.sshDestination)
            ignoredEndpoints.remove("\(endpoint.address)|\(endpoint.username)|\(endpoint.port)")
        }
        if edited.isMember || targetID.flatMap({ host(id: $0) })?.isMember == true {
            membershipNeedsReconcile = true
            validAfter = Date()
            clock = validAfter
            lastRouteCheck = .distantPast
        }
        sortHosts()
        persist()
    }

    func remove(hostID: UUID) {
        guard !isBusy, host(id: hostID)?.isLocal != true, host(id: hostID)?.isMember != true else { return }
        if let removed = host(id: hostID) {
            for endpoint in removed.endpoints {
                ignoredDestinations.insert(endpoint.sshDestination)
                ignoredEndpoints.insert("\(endpoint.address)|\(endpoint.username)|\(endpoint.port)")
            }
        }
        hosts.removeAll { $0.id == hostID }
        persist()
    }

    func restoreRemovedCandidates() {
        ignoredDestinations = []
        ignoredEndpoints = []
        persist()
    }

    func applyMembership(_ memberIDs: Set<UUID>) async {
        guard !isBusy else { return }
        for index in hosts.indices { hosts[index].isMember = memberIDs.contains(hosts[index].id) }
        validAfter = Date()
        clock = validAfter
        membershipNeedsReconcile = true
        lastRouteCheck = .distantPast
        persist()
        await reconcileMembership()
        await checkOnline()
    }

    func markForOnboarding(hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].isMember = true
        validAfter = Date()
        clock = validAfter
        lastRouteCheck = .distantPast
        membershipNeedsReconcile = true
        persist()
    }

    func acceptReconciliation(_ result: NetworkMembershipRunResult) {
        for hostIndex in hosts.indices {
            for endpointIndex in hosts[hostIndex].endpoints.indices {
                let endpointID = hosts[hostIndex].endpoints[endpointIndex].id
                if let alias = result.managementAliases[endpointID] {
                    hosts[hostIndex].endpoints[endpointIndex].sshDestination = alias
                }
            }
        }
        membershipJournal = result.journal
        membershipSteps = result.report.steps
        membershipNeedsReconcile = !result.journal.pendingTasks.isEmpty
        lastMembershipAttempt = Date()
        persist()
    }

    func reconcileMembership() async {
        guard !isReconciling, !isTesting, !isRefreshing, !onboardingPresented, networkAvailable, !isSleeping else { return }
        isReconciling = true
        membershipSteps = []
        let result = await onboarding.reconcile(hosts: hosts, journal: membershipJournal, onProgress: { [weak self] step in
            await MainActor.run { self?.membershipSteps.append(step) }
        })
        acceptReconciliation(result)
        isReconciling = false
    }

    func start(routes requestedRoutes: [NetworkMeshRoute], mode: NetworkMeshProbeMode) {
        guard !isBusy, !requestedRoutes.isEmpty else { return }
        let memberIDs = Set(members.map(\.id))
        let routes = requestedRoutes.filter { memberIDs.contains($0.sourceHostID) && memberIDs.contains($0.targetHostID) }
        guard !routes.isEmpty else { return }
        isPaused = false
        remainingRoutes = routes
        pausedMode = mode
        isTesting = true
        activeMode = mode
        completedCount = 0
        plannedCount = routes.count
        notice = nil
        let inventory = hosts
        let service = service
        testTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTesting = false; self.activeMode = nil; self.activeRouteIDs = []; self.testTask = nil; self.persist() }
            await withTaskGroup(of: NetworkMeshProbeResult?.self) { group in
                var iterator = routes.makeIterator()
                @MainActor func submit(_ route: NetworkMeshRoute) {
                    guard let source = inventory.first(where: { $0.id == route.sourceHostID }),
                          let target = inventory.first(where: { $0.id == route.targetHostID }),
                          let sourceEndpoint = source.endpoints.first(where: { $0.id == route.sourceEndpointID }),
                          let targetEndpoint = target.endpoints.first(where: { $0.id == route.targetEndpointID }) else { return }
                    self.activeRouteIDs.insert(route.id)
                    group.addTask { await service.probe(source: source, sourceEndpoint: sourceEndpoint, target: target, targetEndpoint: targetEndpoint, mode: mode) }
                }
                for _ in 0..<(mode == .connectivity ? 3 : 1) { if let route = iterator.next() { submit(route) } }
                while let result = await group.next() {
                    if let result {
                        self.activeRouteIDs.remove(result.route.id)
                        self.append(result, inventory: inventory)
                        if result.status != .cancelled {
                            self.remainingRoutes.removeAll { $0.id == result.route.id }
                            self.completedCount += 1
                        }
                    }
                    if Task.isCancelled { group.cancelAll() }
                    else if let next = iterator.next() { submit(next) }
                }
            }
            if !self.isPaused { self.remainingRoutes = [] }
        }
    }

    func pause() { guard !isAutomaticTesting else { return }; isPaused = true; testTask?.cancel() }
    func resume() {
        guard isPaused, !isTesting, let mode = pausedMode else { return }
        start(routes: remainingRoutes, mode: mode)
    }
    func cancel() { isPaused = false; remainingRoutes = []; testTask?.cancel() }
    func clearHistory() { guard !isTesting else { return }; history = []; measurementContexts = [:]; persist() }

    private func append(_ result: NetworkMeshProbeResult, inventory: [NetworkMeshHost]? = nil) {
        let snapshot = inventory ?? hosts
        if let source = snapshot.first(where: { $0.id == result.route.sourceHostID }),
           let target = snapshot.first(where: { $0.id == result.route.targetHostID }),
           let sourceEndpoint = source.endpoints.first(where: { $0.id == result.route.sourceEndpointID }),
           let targetEndpoint = target.endpoints.first(where: { $0.id == result.route.targetEndpointID }) {
            measurementContexts[result.id.uuidString] = NetworkMeshMeasurementContext(
                sourceHostName: source.name, targetHostName: target.name,
                sourceEnvironmentName: sourceEndpoint.environmentName, targetEnvironmentName: targetEndpoint.environmentName,
                sourceAddress: sourceEndpoint.address, targetAddress: targetEndpoint.address, targetPort: targetEndpoint.port
            )
        }
        history.insert(result, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        let retained = Set(history.map { $0.id.uuidString })
        measurementContexts = measurementContexts.filter { retained.contains($0.key) }
        persist()
    }

    private func checkOnline() async {
        guard !isCheckingOnline, networkAvailable, !isSleeping else { return }
        isCheckingOnline = true
        defer { isCheckingOnline = false }
        let checks = hosts.flatMap { host in host.endpoints.map { (host, $0) } }
        let service = healthService
        await withTaskGroup(of: NetworkMeshHealthResult.self) { group in
            var iterator = checks.makeIterator()
            func submit(_ check: (NetworkMeshHost, NetworkMeshEndpoint)) { group.addTask { await service.check(host: check.0, endpoint: check.1) } }
            for _ in 0..<4 { if let next = iterator.next() { submit(next) } }
            while let result = await group.next() {
                healthResults.removeAll { $0.endpointID == result.endpointID }
                healthResults.insert(result, at: 0)
                if !Task.isCancelled, let next = iterator.next() { submit(next) }
            }
        }
        clock = Date()
        monitoringInterrupted = !networkAvailable || isSleeping
        let recovered = Set(hosts.filter { hostState($0).tone == .good || hostState($0).tone == .partial }.map(\.id))
        if !recovered.subtracting(onlineHostIDs).isEmpty && !membershipJournal.pendingTasks.isEmpty { membershipNeedsReconcile = true }
        onlineHostIDs = recovered
        persist()
    }

    private func monitorCycle() async {
        clock = Date()
        if clock.timeIntervalSince(lastMonitorTick) > 75 { interruptMonitoring(sleeping: isSleeping) }
        defer { lastMonitorTick = Date() }
        guard networkAvailable, !isSleeping, !isRefreshing, !isReconciling, !onboardingPresented,
              (!isTesting || isAutomaticTesting), !isCheckingOnline else { return }
        await discoverLocalHost()
        await checkOnline()
        if membershipNeedsReconcile && !isTesting && Date().timeIntervalSince(lastMembershipAttempt) >= 60 { await reconcileMembership() }
        if !members.isEmpty && !isBusy && routeMonitorTask == nil && Date().timeIntervalSince(lastRouteCheck) >= 5 * 60 {
            let task = Task<Void, Never> { @MainActor [weak self] in
                guard let self else { return }
                await self.checkMemberRoutes()
                self.routeMonitorTask = nil
                self.testTask = nil
            }
            routeMonitorTask = task
            testTask = task
        }
    }

    private func checkMemberRoutes() async {
        guard !isTesting else { return }
        isTesting = true
        activeMode = .connectivity
        isAutomaticTesting = true
        defer { isTesting = false; isAutomaticTesting = false; activeMode = nil; activeRouteIDs = []; persist() }
        lastRouteCheck = Date()
        let allRoutes = routes()
        let grouped = Dictionary(grouping: allRoutes) { route in
            let source = endpoint(hostID: route.sourceHostID, endpointID: route.sourceEndpointID)
            let target = endpoint(hostID: route.targetHostID, endpointID: route.targetEndpointID)
            return "\(route.sourceHostID):\(source?.environmentID ?? ""):\(source?.username ?? ""):\(source?.platform.rawValue ?? "")→\(route.targetHostID):\(target?.environmentID ?? ""):\(target?.username ?? ""):\(target?.platform.rawValue ?? "")"
        }
        let groups = grouped.values.sorted { ($0.first?.id ?? "") < ($1.first?.id ?? "") }
        plannedCount = groups.count
        completedCount = 0
        for candidates in groups {
            guard !Task.isCancelled, networkAvailable, !isSleeping else { break }
            for route in candidates.sorted(by: { routePriority($0) < routePriority($1) }) {
                guard let source = host(id: route.sourceHostID), let target = host(id: route.targetHostID),
                      let sourceEndpoint = endpoint(hostID: source.id, endpointID: route.sourceEndpointID),
                      let targetEndpoint = endpoint(hostID: target.id, endpointID: route.targetEndpointID) else { continue }
                activeRouteIDs = [route.id]
                let result = await service.probe(source: source, sourceEndpoint: sourceEndpoint, target: target, targetEndpoint: targetEndpoint, mode: .connectivity)
                append(result)
                if Task.isCancelled || result.status != .unreachable { break }
            }
            completedCount += 1
        }
    }

    private func routePriority(_ route: NetworkMeshRoute) -> Int {
        func rank(_ kind: NetworkMeshNetworkKind?) -> Int {
            switch kind { case .campus: 0; case .lan: 1; case .publicInternet: 2; case .other: 3; case .zeroTier: 4; case nil: 5 }
        }
        let source = endpoint(hostID: route.sourceHostID, endpointID: route.sourceEndpointID)
        let target = endpoint(hostID: route.targetHostID, endpointID: route.targetEndpointID)
        let sourceRank = source?.networkKind == target?.networkKind ? 0 : rank(source?.networkKind) + 1
        let literalSourcePenalty = source.map { Self.isLiteralIP($0.address) } == true ? 0 : 10_000
        return literalSourcePenalty + rank(target?.networkKind) * 100 + sourceRank
    }

    private func interruptMonitoring(sleeping: Bool) {
        isSleeping = sleeping
        monitoringInterrupted = true
        validAfter = Date()
        clock = validAfter
        testTask?.cancel()
        lastRouteCheck = .distantPast
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(Snapshot(hosts: hosts, history: history, healthResults: healthResults, membershipJournal: membershipJournal, measurementContexts: measurementContexts, ignoredDestinations: ignoredDestinations.sorted(), ignoredEndpoints: ignoredEndpoints.sorted())), forKey: storageKey)
        } catch { notice = "保存互联数据失败：\(error.localizedDescription)" }
    }

    private func sortHosts() {
        hosts.sort {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func discoverLocalHost() async {
        let zeroTier = await Self.zeroTierAddresses()
        let existing = hosts.first { $0.isLocal }
        let discovered = Self.interfaceAddresses().map { interface, address in
            var endpoint = existing?.endpoints.first { $0.address == address }
                ?? NetworkMeshEndpoint(label: interface, address: address, username: NSUserName(), environmentID: "macos", environmentName: "macOS")
            endpoint.environmentID = "macos"
            endpoint.environmentName = "macOS"
            endpoint.platform = .posix
            endpoint.username = NSUserName()
            if zeroTier.contains(address) {
                endpoint.networkKind = .zeroTier
                if endpoint.label == interface { endpoint.label = "ZeroTier" }
            } else if endpoint.networkKind == .other { endpoint.networkKind = interface.hasPrefix("en") ? .lan : .other }
            return endpoint
        }
        if let existing, Set(existing.endpoints.map(\.address)) != Set(discovered.map(\.address)) {
            interruptMonitoring(sleeping: isSleeping)
        }
        var local = existing ?? NetworkMeshHost(name: Host.current().localizedName ?? "本机", isLocal: true)
        local.endpoints = discovered
        if let index = hosts.firstIndex(where: { $0.isLocal }) { hosts[index] = local }
        else { hosts.insert(local, at: 0) }
    }

    private static func isLiteralIP(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, address, &ipv6) == 1
    }

    private static func compatibleFamilies(_ source: String, _ target: String) -> Bool {
        func family(_ address: String) -> Int? {
            var ipv4 = in_addr()
            if inet_pton(AF_INET, address, &ipv4) == 1 { return 4 }
            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, address, &ipv6) == 1 { return 6 }
            return nil
        }
        guard let sourceFamily = family(source), let targetFamily = family(target) else { return true }
        return sourceFamily == targetFamily
    }

    private static func suggestedKind(for destination: String) -> NetworkMeshNetworkKind {
        let text = destination.lowercased()
        if text.contains("zerotier") || text.hasSuffix("-zt") { return .zeroTier }
        if text.hasSuffix("-edu") || text.hasSuffix("-campus") { return .campus }
        return .other
    }

    private static func interfaceAddresses() -> [(String, String)] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var values: [(String, String)] = []
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addressText = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !addressText.hasPrefix("169.254."), !addressText.hasPrefix("fe80:"), addressText != "::1" else { continue }
            let interface = String(cString: entry.pointee.ifa_name)
            if !values.contains(where: { $0.1 == addressText }) { values.append((interface, addressText)) }
        }
        return values.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
    }

    private static func zeroTierAddresses() async -> Set<String> {
        let paths = ["/usr/local/bin/zerotier-cli", "/opt/homebrew/bin/zerotier-cli", "/usr/local/ZeroTier/One/zerotier-cli"]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["-j", "listnetworks"]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: []); return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let networks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continuation.resume(returning: []); return }
                continuation.resume(returning: Set(networks.flatMap {
                    ($0["assignedAddresses"] as? [String] ?? []).compactMap { $0.split(separator: "/").first.map(String.init) }
                }))
            }
        }
    }
}

private enum MeshEditingError: LocalizedError {
    case testing, name, destination, port, environment
    var errorDescription: String? {
        switch self {
        case .testing: "请先等待当前操作完成，再修改主机。"
        case .name: "请填写主机名称。"
        case .destination: "SSH 入口需是有效的别名或 user@host。"
        case .port: "端口需要是 1 到 65535 之间的整数。"
        case .environment: "环境标识请使用英文字母、数字、点、横线或下划线，长度不超过 64。"
        }
    }
}
