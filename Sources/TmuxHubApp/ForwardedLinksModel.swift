import AppKit
import Foundation
import TmuxHubCore

struct ForwardedLinkRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var destination: String
    var originalURL: String
    var localPort: Int?
    var enabled: Bool
    var lastUsed: Date

    var displayURL: String { ForwardedLinksModel.displayURL(originalURL) }
}

enum ForwardedLinkStatus: Equatable {
    case saved
    case connecting
    case ready(URL, Date)
    case stopped
    case failed(String)
}

enum ForwardedLinksError: LocalizedError {
    case shuttingDown
    case missingRecord
    case disabled
    case invalidLink
    case capacityReached

    var errorDescription: String? {
        switch self {
        case .shuttingDown: return "应用正在关闭，无法建立端口转发。"
        case .missingRecord: return "这条链接已移除。"
        case .disabled: return "端口转发已停止。"
        case .invalidLink: return "链接或 SSH 目标无效。"
        case .capacityReached: return "最多保存 100 条链接，请先移除不再需要的记录。"
        }
    }
}

private actor ForwardedLinkPermits {
    private var available = 3
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if available > 0 {
                    available -= 1
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().1.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

@MainActor
final class ForwardedLinksModel: ObservableObject {
    @Published private(set) var records: [ForwardedLinkRecord] = []
    @Published private(set) var statuses: [UUID: ForwardedLinkStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var restorationNotice: String?

    private struct Operation {
        let token: UUID
        let task: Task<URL, Error>
    }

    private struct StopOperation {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let service: SSHLocalForwardingService
    private let defaults: UserDefaults
    private let permits = ForwardedLinkPermits()
    private let storageKey = "tmuxhub.forwarded-links.v1"
    private var operations: [UUID: Operation] = [:]
    private var stops: [UUID: StopOperation] = [:]
    private var refreshOperation: (UUID, Task<Void, Never>)?
    private var startupTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var isShuttingDown = false

    init(
        service: SSHLocalForwardingService,
        defaults: UserDefaults = .standard,
        autoStart: Bool = true
    ) {
        self.service = service
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ForwardedLinkRecord].self, from: data) {
            var ids = Set<UUID>()
            let validRecords = saved.filter {
                ids.insert($0.id).inserted
                    && Self.isValidDestination($0.destination)
                    && LoopbackURL($0.originalURL) != nil
                    && ($0.localPort.map { (1...65_535).contains($0) } ?? true)
            }
            if validRecords.count > 100 {
                records = Array(validRecords.sorted { $0.lastUsed > $1.lastUsed }.prefix(100))
                restorationNotice = "保存的链接超过 100 条，仅载入最近使用的 100 条。"
            } else {
                records = validRecords
            }
        }
        statuses = Dictionary(uniqueKeysWithValues: records.map {
            ($0.id, $0.enabled ? .saved : .stopped)
        })
        if autoStart {
            startupTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshAll()
            }
            periodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(25)) }
                    catch { return }
                    guard let self, !self.isShuttingDown else { return }
                    await self.refreshAll()
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isShuttingDown else { return }
                    for record in self.records where record.enabled {
                        self.statuses[record.id] = .saved
                    }
                    await self.refreshAll()
                }
            }
        }
    }

    func open(destination: String, endpoint: LoopbackURL) async throws -> URL {
        guard !isShuttingDown else { throw ForwardedLinksError.shuttingDown }
        guard Self.isValidDestination(destination) else { throw ForwardedLinksError.invalidLink }
        let id: UUID
        if let index = records.firstIndex(where: {
            $0.destination == destination && $0.originalURL == endpoint.originalLink
        }) {
            id = records[index].id
            records[index].enabled = true
            records[index].lastUsed = Date()
        } else {
            guard records.count < 100 else { throw ForwardedLinksError.capacityReached }
            id = UUID()
            records.append(ForwardedLinkRecord(
                id: id,
                destination: destination,
                originalURL: endpoint.originalLink,
                localPort: nil,
                enabled: true,
                lastUsed: Date()
            ))
            statuses[id] = .saved
        }
        persist()
        return try await connect(id: id)
    }

    func reopen(id: UUID) async throws -> URL {
        guard !isShuttingDown else { throw ForwardedLinksError.shuttingDown }
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw ForwardedLinksError.missingRecord
        }
        records[index].enabled = true
        records[index].lastUsed = Date()
        persist()
        return try await connect(id: id)
    }

    func resume(id: UUID) async throws -> URL {
        try await reopen(id: id)
    }

    func stop(id: UUID) async {
        guard !isShuttingDown,
              let record = records.first(where: { $0.id == id }),
              let route = routeIdentity(record) else { return }
        let ids = records.filter { routeIdentity($0) == route }.map(\.id)
        for id in ids {
            if let index = records.firstIndex(where: { $0.id == id }) {
                records[index].enabled = false
            }
            statuses[id] = .stopped
        }
        persist()
        let pending = ids.map(beginStop)
        for operation in pending { await operation.task.value }
        clearFinishedStops(ids: ids, operations: pending)
    }

    func remove(id: UUID) async {
        guard !isShuttingDown, records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        statuses.removeValue(forKey: id)
        persist()
        let operation = beginStop(id)
        await operation.task.value
        clearFinishedStops(ids: [id], operations: [operation])
    }

    func refreshAll() async {
        guard !isShuttingDown else { return }
        if let current = refreshOperation {
            await current.1.value
            return
        }
        let token = UUID()
        let ids = records.filter(\.enabled).map(\.id)
        let task = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { [weak self] in
                        guard !Task.isCancelled else { return }
                        _ = try? await self?.connect(id: id)
                    }
                }
            }
        }
        refreshOperation = (token, task)
        isRefreshing = true
        await task.value
        if refreshOperation?.0 == token {
            refreshOperation = nil
            isRefreshing = false
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        startupTask?.cancel()
        periodicTask?.cancel()
        refreshOperation?.1.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        let pending = Array(operations.values)
        for operation in pending { operation.task.cancel() }
        for operation in pending { _ = await operation.task.result }
        for operation in Array(stops.values) { await operation.task.value }
        for record in records {
            await service.release(owner: record.id)
            statuses[record.id] = .stopped
        }
        operations.removeAll()
        stops.removeAll()
        isRefreshing = false
    }

    func status(for id: UUID) -> ForwardedLinkStatus {
        statuses[id] ?? .saved
    }

    func localURL(for id: UUID) -> URL? {
        guard case let .ready(url, _) = status(for: id) else { return nil }
        return url
    }

    nonisolated static func displayURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return "无效地址" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "无效地址"
    }

    func displayError(_ error: Error, id: UUID? = nil) -> String {
        var message = error.localizedDescription
        if let id, let record = records.first(where: { $0.id == id }) {
            message = message.replacingOccurrences(of: record.originalURL, with: record.displayURL)
        }
        guard let pattern = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"']+") else {
            return message
        }
        let matches = pattern.matches(in: message, range: NSRange(message.startIndex..., in: message))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: message) else { continue }
            message.replaceSubrange(range, with: Self.displayURL(String(message[range])))
        }
        return message
    }

    private func connect(id: UUID) async throws -> URL {
        if let stopping = stops[id] {
            await stopping.task.value
            if stops[id]?.token == stopping.token { stops.removeValue(forKey: id) }
        }
        guard !isShuttingDown else { throw ForwardedLinksError.shuttingDown }
        guard let record = records.first(where: { $0.id == id }) else {
            throw ForwardedLinksError.missingRecord
        }
        guard record.enabled else { throw ForwardedLinksError.disabled }
        if let operation = operations[id] { return try await operation.task.value }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performConnection(id: id, token: token)
        }
        operations[id] = Operation(token: token, task: task)
        do {
            let url = try await task.value
            if operations[id]?.token == token { operations.removeValue(forKey: id) }
            return url
        } catch {
            if operations[id]?.token == token { operations.removeValue(forKey: id) }
            throw error
        }
    }

    private func performConnection(id: UUID, token: UUID) async throws -> URL {
        try await permits.acquire()
        do {
            try Task.checkCancellation()
            guard !isShuttingDown, operations[id]?.token == token,
                  let record = records.first(where: { $0.id == id }), record.enabled,
                  let endpoint = LoopbackURL(record.originalURL) else {
                throw CancellationError()
            }
            if case .ready = statuses[id] {} else { statuses[id] = .connecting }
            let url = try await service.acquire(
                owner: id,
                destination: record.destination,
                endpoint: endpoint,
                localPort: record.localPort
            )
            try Task.checkCancellation()
            guard !isShuttingDown, operations[id]?.token == token,
                  let index = records.firstIndex(where: { $0.id == id }),
                  records[index].enabled else { throw CancellationError() }
            records[index].localPort = url.port
            statuses[id] = .ready(url, Date())
            persist()
            await permits.release()
            return url
        } catch {
            let shouldKeepOwner = !isShuttingDown && operations[id]?.token == token
                && records.contains(where: { $0.id == id && $0.enabled })
                && !(error is CancellationError) && !Task.isCancelled
            if shouldKeepOwner {
                // The service retains an existing route's desired port after a
                // failed repair. Preserve that ownership for the next retry.
                statuses[id] = .failed(displayError(error, id: id))
            } else {
                await service.release(owner: id)
            }
            await permits.release()
            throw error
        }
    }

    private func beginStop(_ id: UUID) -> StopOperation {
        if let stopping = stops[id] { return stopping }
        let pending = operations[id]
        pending?.task.cancel()
        let service = self.service
        let task = Task { [weak self] in
            if let pending {
                _ = await pending.task.result
                if self?.operations[id]?.token == pending.token {
                    self?.operations.removeValue(forKey: id)
                }
            }
            await service.release(owner: id)
        }
        let operation = StopOperation(token: UUID(), task: task)
        stops[id] = operation
        return operation
    }

    private func clearFinishedStops(ids: [UUID], operations: [StopOperation]) {
        for (id, operation) in zip(ids, operations) where stops[id]?.token == operation.token {
            stops.removeValue(forKey: id)
        }
    }

    private func routeIdentity(_ record: ForwardedLinkRecord) -> String? {
        guard let endpoint = LoopbackURL(record.originalURL) else { return nil }
        return "\(record.destination)\u{0}\(endpoint.remoteHost.lowercased())\u{0}\(endpoint.remotePort)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    nonisolated private static func isValidDestination(_ value: String) -> Bool {
        IdentifierValidator.isSSHDestination(value)
    }
}
