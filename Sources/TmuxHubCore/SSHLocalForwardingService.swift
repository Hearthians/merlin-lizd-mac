import Darwin
import Foundation

// Chromium/WebKit refuse navigation to these well-known unsafe ports. Keep a
// forwarded service usable by selecting an ephemeral local port instead.
private let browserRestrictedPorts: Set<Int> = [
    1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69,
    77, 79, 87, 95, 101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119,
    123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515,
    526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990,
    993, 995, 1_719, 1_720, 1_723, 2_049, 3_659, 4_045, 5_060, 5_061,
    6_000, 6_566, 6_665, 6_666, 6_667, 6_668, 6_669, 6_697, 10_080,
]

public enum SSHLocalForwardingError: Error, Equatable, LocalizedError, Sendable {
    case localPortUnavailable(Int)
    case invalidLocalPort(Int)
    case unableToAllocateLocalPort
    case unableToOpenForward
    case invalidLoopbackHost
    case invalidRewrittenURL
    case shuttingDown

    public var errorDescription: String? {
        switch self {
        case let .localPortUnavailable(port):
            return "本机端口 \(port) 已被占用。"
        case let .invalidLocalPort(port):
            return "本机端口 \(port) 无效或被浏览器限制。"
        case .unableToAllocateLocalPort:
            return "无法为远端服务分配可用的本机端口。"
        case .unableToOpenForward:
            return "无法建立 SSH 端口转发，请检查连接后重试。"
        case .invalidLoopbackHost:
            return "这个链接不是受支持的回环地址。"
        case .invalidRewrittenURL:
            return "无法生成本机访问链接。"
        case .shuttingDown:
            return "端口转发服务正在关闭。"
        }
    }
}

protocol SSHLocalForwardingTransport: Sendable {
    func openLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async throws

    func cancelLocalForward(
        alias: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) async

    func isMasterRunning(alias: String) async -> Bool
}

extension SSHMasterPool: SSHLocalForwardingTransport {}

protocol SSHLocalPortAllocating: Sendable {
    func availablePort(
        preferredPort: Int?,
        excluding excludedPorts: Set<Int>
    ) throws -> Int
}

protocol SSHLocalListenerProbing: Sendable {
    func isListening(port: Int) -> Bool
}

/// Owns local forwards opened through an SSH control master.
///
/// Routes are shared by destination and remote endpoint. Each saved link
/// registers an owner, and the exact OpenSSH forwarding tuple is cancelled only
/// after the final owner releases it. An in-flight creation also retains its
/// owner set, so removing a link while OpenSSH is responding cannot leak a listener.
public actor SSHLocalForwardingService {
    private struct RouteKey: Hashable, Sendable {
        let destination: String
        let remoteHost: String
        let remotePort: Int
    }

    private struct Route: Sendable {
        let id: UUID
        let key: RouteKey
        let localPort: Int
        var isEstablished = true
    }

    private struct PendingRoute: Sendable {
        let id: UUID
        let previousRouteID: UUID?
        let task: Task<Route, any Error>
    }

    private struct PendingCancellation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let transport: any SSHLocalForwardingTransport
    private let portAllocator: any SSHLocalPortAllocating
    private let listenerProbe: any SSHLocalListenerProbing
    private let maximumOpenAttempts: Int

    private var routes: [RouteKey: Route] = [:]
    private var pendingRoutes: [RouteKey: PendingRoute] = [:]
    private var ownersByRoute: [RouteKey: Set<UUID>] = [:]
    private var routesByOwner: [UUID: Set<RouteKey>] = [:]
    private var inFlightCancellations: [RouteKey: PendingCancellation] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false

    public init(sshMasterPool: SSHMasterPool) {
        transport = sshMasterPool
        portAllocator = IPv4LoopbackPortAllocator()
        listenerProbe = IPv4LoopbackListenerProbe()
        maximumOpenAttempts = 6
    }

    init(
        transport: any SSHLocalForwardingTransport,
        portAllocator: any SSHLocalPortAllocating,
        listenerProbe: any SSHLocalListenerProbing,
        maximumOpenAttempts: Int = 6
    ) {
        precondition(maximumOpenAttempts > 0)
        self.transport = transport
        self.portAllocator = portAllocator
        self.listenerProbe = listenerProbe
        self.maximumOpenAttempts = maximumOpenAttempts
    }

    /// A supplied local port is strict, so saved browser URLs survive restart.
    /// Existing routes always repair on their assigned port; conflicts stay visible.
    public func acquire(
        owner: UUID,
        destination: String,
        endpoint: LoopbackURL,
        localPort requestedLocalPort: Int? = nil
    ) async throws -> URL {
        guard !isShuttingDown else {
            throw SSHLocalForwardingError.shuttingDown
        }

        if let requestedLocalPort,
            !(1...65_535).contains(requestedLocalPort) || browserRestrictedPorts.contains(requestedLocalPort) {
            throw SSHLocalForwardingError.invalidLocalPort(requestedLocalPort)
        }
        let remoteHost = try canonicalRemoteHost(endpoint.remoteHost)
        let key = RouteKey(
            destination: destination,
            remoteHost: remoteHost,
            remotePort: endpoint.remotePort
        )
        if let requestedLocalPort, let existing = routes[key],
            requestedLocalPort != existing.localPort {
            throw SSHLocalForwardingError.localPortUnavailable(requestedLocalPort)
        }
        let wasOwner = ownersByRoute[key]?.contains(owner) == true
        register(owner: owner, for: key)

        if let cancellation = inFlightCancellations[key] {
            await cancellation.task.value
            if inFlightCancellations[key]?.id == cancellation.id {
                inFlightCancellations.removeValue(forKey: key)
            }
            guard !isShuttingDown else {
                remove(owner: owner, from: key)
                throw SSHLocalForwardingError.shuttingDown
            }
            guard ownersByRoute[key]?.contains(owner) == true,
                !Task.isCancelled
            else {
                remove(owner: owner, from: key)
                throw CancellationError()
            }
        }

        let pending: PendingRoute
        if let existing = pendingRoutes[key] {
            pending = existing
        } else {
            let existingRoute = routes[key]
            let task = makeRouteTask(
                key: key, existingRoute: existingRoute, requestedLocalPort: requestedLocalPort
            )
            let created = PendingRoute(
                id: UUID(),
                previousRouteID: existingRoute?.id,
                task: task
            )
            pendingRoutes[key] = created
            pending = created
        }

        var establishedRoute = false
        do {
            let route = try await pending.task.value
            establishedRoute = true
            try await settleSuccessfulRoute(
                route,
                pendingID: pending.id,
                owner: owner,
                key: key
            )
            // A concurrent caller may have allocated this route before a saved
            // link asked for its remembered port. Never silently rewrite that link.
            if let requestedLocalPort, requestedLocalPort != route.localPort {
                throw SSHLocalForwardingError.localPortUnavailable(requestedLocalPort)
            }
            guard let url = endpoint.rewrittenURL(localPort: route.localPort) else {
                remove(owner: owner, from: key)
                await cancelIfUnowned(key: key)
                throw SSHLocalForwardingError.invalidRewrittenURL
            }
            return url
        } catch {
            await settleFailedRoute(
                pendingID: pending.id,
                previousRouteID: establishedRoute ? nil : pending.previousRouteID,
                owner: owner,
                key: key,
                preserveOwnership: wasOwner && !Task.isCancelled
            )
            throw error
        }
    }

    public func release(owner: UUID) async {
        guard let keys = routesByOwner.removeValue(forKey: owner) else { return }
        for key in keys {
            ownersByRoute[key]?.remove(owner)
            if ownersByRoute[key]?.isEmpty == true {
                ownersByRoute.removeValue(forKey: key)
            }
        }
        guard !isShuttingDown else { return }
        for key in keys where pendingRoutes[key] == nil {
            await cancelIfUnowned(key: key)
        }
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        isShuttingDown = true
        ownersByRoute.removeAll()
        routesByOwner.removeAll()

        let activeRoutes = Array(routes.values)
        let pending = Array(pendingRoutes.values)
        let cancellations = inFlightCancellations.values.map(\.task)
        routes.removeAll()
        pendingRoutes.removeAll()
        let transport = self.transport

        let task = Task.detached {
            for cancellation in cancellations {
                await cancellation.value
            }
            var cancelledRouteIDs: Set<UUID> = []
            for route in activeRoutes where cancelledRouteIDs.insert(route.id).inserted {
                await Self.cancel(route, using: transport)
            }
            for item in pending {
                guard case let .success(route) = await item.task.result,
                    cancelledRouteIDs.insert(route.id).inserted
                else { continue }
                await Self.cancel(route, using: transport)
            }
        }
        shutdownTask = task
        await task.value
    }

    private func register(owner: UUID, for key: RouteKey) {
        ownersByRoute[key, default: []].insert(owner)
        routesByOwner[owner, default: []].insert(key)
    }

    private func remove(owner: UUID, from key: RouteKey) {
        ownersByRoute[key]?.remove(owner)
        if ownersByRoute[key]?.isEmpty == true {
            ownersByRoute.removeValue(forKey: key)
        }
        routesByOwner[owner]?.remove(key)
        if routesByOwner[owner]?.isEmpty == true {
            routesByOwner.removeValue(forKey: owner)
        }
    }

    private func makeRouteTask(
        key: RouteKey,
        existingRoute: Route?,
        requestedLocalPort: Int?
    ) -> Task<Route, any Error> {
        let transport = self.transport
        let portAllocator = self.portAllocator
        let listenerProbe = self.listenerProbe
        let maximumOpenAttempts = self.maximumOpenAttempts
        return Task.detached {
            if let existingRoute, existingRoute.isEstablished {
                let masterIsRunning = await transport.isMasterRunning(
                    alias: key.destination
                )
                if masterIsRunning,
                    listenerProbe.isListening(port: existingRoute.localPort)
                {
                    return existingRoute
                }
                await Self.cancel(existingRoute, using: transport)
            }

            return try await Self.establishRoute(
                key: key,
                transport: transport,
                portAllocator: portAllocator,
                maximumOpenAttempts: maximumOpenAttempts,
                requestedLocalPort: existingRoute?.localPort ?? requestedLocalPort
            )
        }
    }

    private func settleSuccessfulRoute(
        _ route: Route,
        pendingID: UUID,
        owner: UUID,
        key: RouteKey
    ) async throws {
        if pendingRoutes[key]?.id == pendingID {
            pendingRoutes.removeValue(forKey: key)
            routes[key] = route
        }

        guard !isShuttingDown else {
            throw SSHLocalForwardingError.shuttingDown
        }
        guard ownersByRoute[key]?.contains(owner) == true, !Task.isCancelled else {
            remove(owner: owner, from: key)
            await cancelIfUnowned(key: key)
            throw CancellationError()
        }
    }

    private func settleFailedRoute(
        pendingID: UUID,
        previousRouteID: UUID?,
        owner: UUID,
        key: RouteKey,
        preserveOwnership: Bool
    ) async {
        if pendingRoutes[key]?.id == pendingID {
            pendingRoutes.removeValue(forKey: key)
            if let previousRouteID, routes[key]?.id == previousRouteID {
                // Keep the desired port for existing owners after failed repair.
                // A listener at that port may belong to another process now.
                routes[key]?.isEstablished = false
            }
        }
        if !preserveOwnership { remove(owner: owner, from: key) }
        guard !isShuttingDown, pendingRoutes[key] == nil else { return }
        await cancelIfUnowned(key: key)
    }

    private func cancelIfUnowned(key: RouteKey) async {
        guard ownersByRoute[key]?.isEmpty != false,
            pendingRoutes[key] == nil,
            inFlightCancellations[key] == nil,
            let route = routes.removeValue(forKey: key)
        else { return }
        let cancellationID = UUID()
        let transport = self.transport
        let task = Task.detached {
            await Self.cancel(route, using: transport)
        }
        inFlightCancellations[key] = PendingCancellation(
            id: cancellationID,
            task: task
        )
        await task.value
        if inFlightCancellations[key]?.id == cancellationID {
            inFlightCancellations.removeValue(forKey: key)
        }
    }

    func isShuttingDownForTesting() -> Bool {
        isShuttingDown
    }

    private func canonicalRemoteHost(_ host: String) throws -> String {
        switch host.lowercased() {
        case "localhost":
            return "localhost"
        case "127.0.0.1", "0.0.0.0":
            return "127.0.0.1"
        case "::1":
            return "::1"
        default:
            throw SSHLocalForwardingError.invalidLoopbackHost
        }
    }

    private static func establishRoute(
        key: RouteKey,
        transport: any SSHLocalForwardingTransport,
        portAllocator: any SSHLocalPortAllocating,
        maximumOpenAttempts: Int,
        requestedLocalPort: Int?
    ) async throws -> Route {
        var attemptedPorts: Set<Int> = []
        for attempt in 0..<maximumOpenAttempts {
            let localPort: Int
            do {
                // Binding a remembered port must be atomic at SSH; a separate
                // availability check could substitute a different browser URL.
                localPort = try requestedLocalPort ?? portAllocator.availablePort(
                    preferredPort: attempt == 0
                        && !browserRestrictedPorts.contains(key.remotePort)
                        ? key.remotePort
                        : nil,
                    excluding: attemptedPorts
                )
            } catch {
                throw SSHLocalForwardingError.unableToAllocateLocalPort
            }
            guard (1...65_535).contains(localPort),
                attemptedPorts.insert(localPort).inserted
            else { continue }

            do {
                try await transport.openLocalForward(
                    alias: key.destination,
                    localPort: localPort,
                    remoteHost: key.remoteHost,
                    remotePort: key.remotePort
                )
                return Route(id: UUID(), key: key, localPort: localPort)
            } catch SSHLocalForwardingError.localPortUnavailable {
                if let requestedLocalPort {
                    throw SSHLocalForwardingError.localPortUnavailable(requestedLocalPort)
                }
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SSHLocalForwardingError {
                throw error
            } catch SSHMasterPoolError.shuttingDown {
                throw SSHLocalForwardingError.shuttingDown
            } catch {
                throw SSHLocalForwardingError.unableToOpenForward
            }
        }
        throw SSHLocalForwardingError.unableToAllocateLocalPort
    }

    private static func cancel(
        _ route: Route,
        using transport: any SSHLocalForwardingTransport
    ) async {
        await transport.cancelLocalForward(
            alias: route.key.destination,
            localPort: route.localPort,
            remoteHost: route.key.remoteHost,
            remotePort: route.key.remotePort
        )
    }
}

private struct IPv4LoopbackPortAllocator: SSHLocalPortAllocating {
    func availablePort(
        preferredPort: Int?,
        excluding excludedPorts: Set<Int>
    ) throws -> Int {
        if let preferredPort,
            !excludedPorts.contains(preferredPort),
            Self.canBind(port: preferredPort)
        {
            return preferredPort
        }

        for _ in 0..<32 {
            guard let port = Self.ephemeralPort() else { continue }
            if !excludedPorts.contains(port) { return port }
        }
        throw SSHLocalForwardingError.unableToAllocateLocalPort
    }

    private static func canBind(port: Int) -> Bool {
        guard (1...65_535).contains(port), let descriptor = socketDescriptor() else {
            return false
        }
        defer { Darwin.close(descriptor) }
        var address = loopbackAddress(port: port)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }

    private static func ephemeralPort() -> Int? {
        guard let descriptor = socketDescriptor() else { return nil }
        defer { Darwin.close(descriptor) }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
        guard bound else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length) == 0
            }
        }
        guard read else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func socketDescriptor() -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        return descriptor >= 0 ? descriptor : nil
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }
}

private struct IPv4LoopbackListenerProbe: SSHLocalListenerProbing {
    func isListening(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        // A zero-payload TCP handshake verifies that a listener still accepts
        // connections. It may create a short connection at the remote service,
        // but sends no application data.
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        guard Darwin.poll(&pollDescriptor, 1, 200) > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0 else { return false }
        return socketError == 0
    }
}
