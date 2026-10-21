import AppKit
import Foundation
import TmuxHubCore
@preconcurrency import UserNotifications

protocol CodexNotificationClient: Sendable {
    func install(destination: String?) async throws -> String
    func read(destination: String?, after: Int, limit: Int) async throws -> CodexNotificationFeed
    func markRead(destination: String?, sourceID: String, eventIDs: [String]) async throws
}

extension CodexNotificationService: CodexNotificationClient {}

struct CodexNotificationSource: Codable, Identifiable, Equatable {
    var id: UUID
    var destination: String?
    var sourceID: String?
    var enabled: Bool
    var displayName: String { destination ?? "本机" }
}

struct CodexNotificationEntry: Codable, Identifiable, Equatable {
    var id: String
    var event: CodexNotificationEvent
    var destination: String?
    var isRead: Bool
    var isResolved: Bool
    var receivedAt: Date
    var notificationHandled: Bool
    var wasNotified: Bool

    var sourceLabel: String { destination ?? "本机" }
    var sessionKey: String { Self.key(event.sourceID, event.sessionID) }
    var title: String {
        switch event.kind {
        case .turnCompleted: "Codex 已完成"
        case .approvalRequested: "Codex 需要确认"
        case .turnStarted: "Codex 已继续"
        }
    }
    var message: String {
        event.kind == .approvalRequested
            ? "有一项操作等待确认。点击返回对应会话。"
            : "任务已完成。点击返回对应会话。"
    }
    static func key(_ source: String, _ value: String) -> String {
        // Length prefix avoids collisions even when an upstream identifier contains punctuation.
        "\(source.utf8.count):\(source)\(value)"
    }
}

enum CodexNotificationSourceStatus: Equatable {
    case idle, installing, syncing, ready(Date), failed(String), disabled
}

enum CodexNotificationsError: LocalizedError {
    case invalidDestination, capacity, removed, shuttingDown, storage, connection, malformedFeed
    case synchronization(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination: "SSH 主机名无效。"
        case .capacity: "最多保存 100 个通知来源，请先移除不再使用的来源。"
        case .removed: "这个通知来源已移除或停用。"
        case .shuttingDown: "应用正在关闭。"
        case .storage: "通知记录无法保存，本次读取进度未推进。"
        case .connection: "未能读取通知。请检查主机连接、通知配置及访问权限后重试。"
        case .malformedFeed: "通知记录格式无效，本次读取进度未推进。"
        case let .synchronization(message): message
        }
    }
}

@MainActor
protocol CodexNotificationDelivering: AnyObject {
    var onOpen: ((String) -> Void)? { get set }
    func requestAuthorization() async throws -> Bool
    func authorizationDescription() async -> String
    func deliver(_ entry: CodexNotificationEntry) async throws
    func remove(ids: [String])
}

/// Native notifications contain fixed text and an opaque local entry identifier only.
@MainActor
final class CodexNativeNotifications: NSObject, CodexNotificationDelivering, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func authorizationDescription() async -> String {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: "系统已允许通知"
        case .denied: "系统未允许通知，可在系统设置中修改"
        case .notDetermined: "尚未申请系统通知权限"
        default: "系统通知权限暂不可用"
        }
    }

    func deliver(_ entry: CodexNotificationEntry) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw CodexNotificationsError.connection
        }
        let content = UNMutableNotificationContent()
        content.title = entry.title
        content.subtitle = [entry.sourceLabel, entry.event.tmuxSession].compactMap { $0 }.joined(separator: " · ")
        content.body = entry.message
        content.sound = .default
        content.threadIdentifier = entry.sessionKey
        content.userInfo = ["entryID": entry.id]
        try await center.add(UNNotificationRequest(identifier: entry.id, content: content, trigger: nil))
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["entryID"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            if let id { self?.onOpen?(id) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private actor CodexNotificationPermits {
    private var available = 3
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if available > 0 { available -= 1; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

@MainActor
final class CodexNotificationsModel: ObservableObject {
    private struct Cursor: Codable {
        var sequence = 0
        var baselineComplete = false
        var baselineCutoff: Int?
    }
    private struct SavedState: Codable {
        var sources: [CodexNotificationSource] = []
        var entries: [CodexNotificationEntry] = []
        var cursors: [String: Cursor] = [:]
        var mutedSessions: Set<String> = []
        var systemNotificationsEnabled = false
        // Optional for compatibility with the first local-read-only preferences snapshot.
        var pendingReadReceipts: [String: Set<String>]?
    }
    private struct Operation {
        let token: UUID
        let installsBridge: Bool
        let task: Task<Void, Error>
    }

    @Published private var saved: SavedState
    @Published private(set) var statuses: [UUID: CodexNotificationSourceStatus] = [:]
    @Published private(set) var busySourceIDs: Set<UUID> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var systemNotificationStatus = "尚未启用系统通知"
    @Published private(set) var notice: String?
    @Published private(set) var readSyncError: String?
    var onOpen: ((CodexNotificationEntry) -> Void)? {
        didSet {
            guard onOpen != nil, let id = pendingOpenID,
                let entry = entries.first(where: { $0.id == id }) else { return }
            pendingOpenID = nil
            open(entry: entry)
        }
    }

    var entries: [CodexNotificationEntry] { saved.entries }
    var sources: [CodexNotificationSource] { saved.sources }
    var systemNotificationsEnabled: Bool { saved.systemNotificationsEnabled }
    var unreadCount: Int { entries.filter(isUnread).count }
    var pendingReadCount: Int { (saved.pendingReadReceipts ?? [:]).values.reduce(0) { $0 + $1.count } }

    private let service: any CodexNotificationClient
    private let defaults: UserDefaults
    private let delivery: any CodexNotificationDelivering
    private let permits = CodexNotificationPermits()
    private let storageKey = "tmuxhub.codex-notifications.v1"
    private var operations: [UUID: Operation] = [:]
    private var refreshTask: (UUID, Task<Void, Never>)?
    private var startupTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var receiptTasks: [String: Task<Void, Never>] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var shuttingDown = false
    private var pendingOpenID: String?

    init(
        service: any CodexNotificationClient,
        defaults: UserDefaults = .standard,
        delivery: (any CodexNotificationDelivering)? = nil,
        autoStart: Bool = true
    ) {
        self.service = service
        self.defaults = defaults
        self.delivery = delivery ?? CodexNativeNotifications()
        let decoded = defaults.data(forKey: storageKey).flatMap { data -> SavedState? in
            guard data.count <= 5_000_000 else { return nil }
            return try? JSONDecoder().decode(SavedState.self, from: data)
        }
        var restored = decoded ?? SavedState()
        var ids = Set<UUID>()
        var destinations = Set<String>()
        restored.sources = Array(restored.sources.filter {
            Self.validDestination($0.destination) && ids.insert($0.id).inserted
                && destinations.insert($0.destination ?? "").inserted
        }.prefix(100))
        var entryIDs = Set<String>()
        restored.entries = Array(restored.entries.filter {
            $0.id == CodexNotificationEntry.key($0.event.sourceID, $0.event.id)
                && $0.event.kind != .turnStarted && $0.event.sequence > 0
                && $0.event.timestamp.timeIntervalSince1970.isFinite
                && $0.receivedAt.timeIntervalSince1970.isFinite
                && Self.validDestination($0.destination) && entryIDs.insert($0.id).inserted
        }.sorted { $0.receivedAt > $1.receivedAt }.prefix(300))
        restored.cursors = restored.cursors.filter { !$0.key.isEmpty && $0.value.sequence >= 0 }
        saved = restored
        statuses = Dictionary(uniqueKeysWithValues: restored.sources.map { ($0.id, $0.enabled ? .idle : .disabled) })
        self.delivery.onOpen = { [weak self] id in
            guard let self, let entry = self.entries.first(where: { $0.id == id }) else { return }
            self.open(entry: entry)
        }
        if autoStart {
            startupTask = Task { [weak self] in
                guard let self else { return }
                self.systemNotificationStatus = await self.delivery.authorizationDescription()
                await self.refreshAll()
            }
            periodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, !self.shuttingDown else { return }
                    await self.refreshAll()
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.refreshAll() } }
        }
    }

    @discardableResult
    func setup(destination: String?) async throws -> UUID {
        guard !shuttingDown else { throw CodexNotificationsError.shuttingDown }
        let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validDestination(destination) else { throw CodexNotificationsError.invalidDestination }
        var next = saved
        let id: UUID
        if let index = next.sources.firstIndex(where: { $0.destination == destination }) {
            id = next.sources[index].id
            next.sources[index].enabled = true
        } else {
            guard next.sources.count < 100 else { throw CodexNotificationsError.capacity }
            id = UUID()
            next.sources.append(.init(id: id, destination: destination, sourceID: nil, enabled: true))
        }
        try commit(next)
        try await run(id: id, install: true)
        return id
    }

    func setSourceEnabled(id: UUID, enabled: Bool) async {
        guard !shuttingDown, let index = saved.sources.firstIndex(where: { $0.id == id }) else { return }
        var next = saved
        next.sources[index].enabled = enabled
        guard save(next) else { return }
        if enabled { await refresh(id: id) }
        else {
            operations.removeValue(forKey: id)?.task.cancel()
            busySourceIDs.remove(id)
            statuses[id] = .disabled
            removeNotifications(for: saved.sources[index])
        }
    }

    func removeSource(id: UUID) async {
        guard !shuttingDown else { return }
        let removed = saved.sources.first(where: { $0.id == id })
        var next = saved
        next.sources.removeAll { $0.id == id }
        guard save(next) else { return }
        operations.removeValue(forKey: id)?.task.cancel()
        busySourceIDs.remove(id)
        statuses.removeValue(forKey: id)
        if let removed { removeNotifications(for: removed) }
        // History, local read state and cursors survive removal/re-add. The server is untouched.
    }

    func refresh(id: UUID) async { _ = try? await run(id: id, install: false) }

    func refreshAll() async {
        guard !shuttingDown else { return }
        if let current = refreshTask { await current.1.value; return }
        let token = UUID()
        let ids = sources.filter(\.enabled).map(\.id)
        let task = Task { [weak self] in
            let model = self
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { [model] in await model?.refresh(id: id) } }
            }
        }
        refreshTask = (token, task)
        isRefreshing = true
        await task.value
        if refreshTask?.0 == token { refreshTask = nil; isRefreshing = false }
        await deliverPending()
    }

    func markRead(id: String) {
        var next = saved
        guard let index = next.entries.firstIndex(where: { $0.id == id }) else { return }
        next.entries[index].isRead = true
        next.entries[index].notificationHandled = true
        queueReceipt(for: next.entries[index], in: &next)
        if save(next) { delivery.remove(ids: [id]); scheduleReceiptFlush() }
    }

    func markAllRead() {
        var next = saved
        for index in next.entries.indices {
            next.entries[index].isRead = true
            next.entries[index].notificationHandled = true
            queueReceipt(for: next.entries[index], in: &next)
        }
        if save(next) { delivery.remove(ids: next.entries.map(\.id)); scheduleReceiptFlush() }
    }

    func isMuted(entry: CodexNotificationEntry) -> Bool { saved.mutedSessions.contains(entry.sessionKey) }

    func setMuted(entry: CodexNotificationEntry, muted: Bool) {
        var next = saved
        if muted { next.mutedSessions.insert(entry.sessionKey) }
        else { next.mutedSessions.remove(entry.sessionKey) }
        let matching = next.entries.indices.filter { next.entries[$0].sessionKey == entry.sessionKey }
        if muted { for index in matching { next.entries[index].notificationHandled = true } }
        if save(next), muted { delivery.remove(ids: matching.map { next.entries[$0].id }) }
    }

    func open(entry: CodexNotificationEntry) {
        guard !shuttingDown, let current = entries.first(where: { $0.id == entry.id }) else { return }
        guard let onOpen else {
            // A notification can launch the app before its root view installs the route callback.
            pendingOpenID = current.id
            return
        }
        markRead(id: current.id)
        let candidates = sources.filter { $0.enabled && $0.sourceID == current.event.sourceID }
        let preferred = candidates.first { source in
            guard let status = statuses[source.id] else { return false }
            if case .ready = status { return true }
            return false
        } ?? candidates.first
        var routed = current
        if let preferred { routed.destination = preferred.destination }
        onOpen(routed)
    }

    func unread(for destination: String?, tmuxSession: String? = nil, tmuxPane: String? = nil) -> Int {
        let identities = Set(sources.filter { $0.destination == destination }.compactMap(\.sourceID))
        return entries.filter {
            isUnread($0) && (identities.contains($0.event.sourceID) || $0.destination == destination)
                && (tmuxSession == nil || $0.event.tmuxSession == tmuxSession || $0.event.tmuxSessionID == tmuxSession)
                && (tmuxPane == nil || $0.event.tmuxPane == tmuxPane)
        }.count
    }

    /// This is the only path that may display the OS permission request.
    func enableSystemNotifications() async {
        guard !shuttingDown else { return }
        do {
            let allowed = try await delivery.requestAuthorization()
            guard !shuttingDown else { return }
            var next = saved
            next.systemNotificationsEnabled = allowed
            // Enabling banners now should not replay the user's existing inbox.
            for index in next.entries.indices { next.entries[index].notificationHandled = true }
            _ = save(next)
            systemNotificationStatus = await delivery.authorizationDescription()
        } catch { systemNotificationStatus = "无法申请系统通知权限，请稍后重试。" }
    }

    func disableSystemNotifications() {
        var next = saved
        next.systemNotificationsEnabled = false
        for index in next.entries.indices { next.entries[index].notificationHandled = true }
        if save(next) { delivery.remove(ids: next.entries.map(\.id)) }
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        startupTask?.cancel(); periodicTask?.cancel(); refreshTask?.1.cancel(); deliveryTask?.cancel()
        let pendingReceipts = Array(receiptTasks.values)
        for task in pendingReceipts { task.cancel() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        let pending = operations.values.map(\.task)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        await deliveryTask?.value
        for task in pendingReceipts { await task.value }
        operations.removeAll(); busySourceIDs.removeAll(); isRefreshing = false
    }

    private func run(id: UUID, install: Bool) async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CodexNotificationsError.shuttingDown }
        guard sources.contains(where: { $0.id == id && $0.enabled }) else { throw CodexNotificationsError.removed }
        if let current = operations[id] {
            if install && !current.installsBridge {
                // An explicit setup must still install after an already-running background read,
                // including a failed read from a host that has not installed the bridge yet.
                _ = await current.task.result
                if operations[id]?.token == current.token {
                    operations.removeValue(forKey: id)
                    busySourceIDs.remove(id)
                }
                return try await run(id: id, install: true)
            }
            return try await current.task.value
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            if let sourceID = self.sources.first(where: { $0.id == id })?.sourceID {
                await self.flushReadReceipts(sourceID: sourceID)
            }
            try await self.permits.acquire()
            do {
                try await self.synchronize(id: id, token: token, install: install)
                await self.permits.release()
            } catch {
                await self.permits.release()
                throw error
            }
        }
        operations[id] = Operation(token: token, installsBridge: install, task: task)
        busySourceIDs.insert(id)
        statuses[id] = install ? .installing : .syncing
        do {
            try await task.value
            if operations[id]?.token == token {
                operations.removeValue(forKey: id); busySourceIDs.remove(id)
                statuses[id] = .ready(Date())
            }
            if let sourceID = sources.first(where: { $0.id == id })?.sourceID {
                await flushReadReceipts(sourceID: sourceID)
            }
            await deliverPending()
        } catch {
            if operations[id]?.token == token {
                operations.removeValue(forKey: id); busySourceIDs.remove(id)
                if !shuttingDown { statuses[id] = .failed(Self.safeError(error)) }
            }
            if error is CancellationError { throw error }
            throw CodexNotificationsError.synchronization(Self.safeError(error))
        }
    }

    private func synchronize(id: UUID, token: UUID, install: Bool) async throws {
        var source = try activeSource(id, token: token)
        if install {
            let message = try await service.install(destination: source.destination)
            source = try activeSource(id, token: token)
            notice = message
        }
        for _ in 0..<5 {
            source = try activeSource(id, token: token)
            let after = source.sourceID.flatMap { saved.cursors[$0]?.sequence } ?? 0
            var feed = try await service.read(destination: source.destination, after: after, limit: 100)
            _ = try activeSource(id, token: token)
            if source.sourceID != nil, source.sourceID != feed.sourceID, after > 0 {
                // A reinstalled/reset spool has an independent sequence space.
                feed = try await service.read(destination: source.destination, after: 0, limit: 100)
                _ = try activeSource(id, token: token)
            }
            try ingest(feed, source: source)
            await deliverPending()
            if !feed.hasMore { return }
        }
    }

    private func ingest(_ feed: CodexNotificationFeed, source: CodexNotificationSource) throws {
        guard !feed.sourceID.isEmpty, feed.latestSequence >= 0,
            feed.events.allSatisfy({ $0.sourceID == feed.sourceID && $0.sequence > 0
                && $0.sequence <= feed.latestSequence && $0.timestamp.timeIntervalSince1970.isFinite })
        else { throw CodexNotificationsError.malformedFeed }
        var next = saved
        guard let sourceIndex = next.sources.firstIndex(where: { $0.id == source.id && $0.enabled }) else {
            throw CodexNotificationsError.removed
        }
        next.sources[sourceIndex].sourceID = feed.sourceID
        let previousSourceID = source.sourceID
        var outbox = next.pendingReadReceipts ?? [:]
        let obsolete = outbox.keys.filter { oldID in
            guard oldID != feed.sourceID,
                !next.sources.contains(where: { $0.enabled && $0.sourceID == oldID }) else { return false }
            return oldID == previousSourceID || next.entries.contains {
                $0.event.sourceID == oldID && $0.destination == source.destination
            }
        }
        for oldID in obsolete { outbox.removeValue(forKey: oldID) }
        if !obsolete.isEmpty { notice = "通知来源已重置；旧通知的已读状态保留在本机。" }
        let sharedReads = Set(feed.readEventIDs)
        if var pending = outbox[feed.sourceID] {
            pending.subtract(sharedReads)
            if pending.isEmpty { outbox.removeValue(forKey: feed.sourceID) }
            else { outbox[feed.sourceID] = pending }
        }
        next.pendingReadReceipts = outbox
        var cursor = next.cursors[feed.sourceID] ?? Cursor()
        if !cursor.baselineComplete, cursor.baselineCutoff == nil {
            // The initial import can span several polls. Events produced after this first
            // snapshot remain new even while the older pages are still being imported.
            cursor.baselineCutoff = feed.latestSequence
        }
        var removedNotifications: [String] = []
        for index in next.entries.indices where next.entries[index].event.sourceID == feed.sourceID
            && (sharedReads.contains(next.entries[index].event.id) || outbox[feed.sourceID]?.contains(next.entries[index].event.id) == true) {
            next.entries[index].isRead = true
            next.entries[index].notificationHandled = true
            removedNotifications.append(next.entries[index].id)
        }
        for event in feed.events.sorted(by: { $0.sequence < $1.sequence }) where event.sequence > cursor.sequence {
            let baseline = !cursor.baselineComplete && event.sequence <= (cursor.baselineCutoff ?? 0)
            let isRead = sharedReads.contains(event.id) || outbox[feed.sourceID]?.contains(event.id) == true
            let sessionKey = CodexNotificationEntry.key(event.sourceID, event.sessionID)
            if event.kind == .turnStarted || event.kind == .turnCompleted {
                for index in next.entries.indices where next.entries[index].sessionKey == sessionKey
                    && next.entries[index].event.kind == .approvalRequested && !next.entries[index].isResolved {
                    next.entries[index].isResolved = true
                    next.entries[index].notificationHandled = true
                    removedNotifications.append(next.entries[index].id)
                }
            }
            if event.kind != .turnStarted {
                let id = CodexNotificationEntry.key(event.sourceID, event.id)
                if !next.entries.contains(where: { $0.id == id }) {
                    next.entries.append(.init(
                        id: id, event: event, destination: source.destination, isRead: isRead,
                        isResolved: false, receivedAt: Date(),
                        notificationHandled: baseline || isRead || !next.systemNotificationsEnabled || next.mutedSessions.contains(sessionKey),
                        wasNotified: false
                    ))
                }
            }
            cursor.sequence = event.sequence
        }
        if !feed.hasMore {
            cursor.sequence = max(cursor.sequence, feed.latestSequence)
            cursor.baselineComplete = true
        }
        next.cursors[feed.sourceID] = cursor
        next.entries.sort { $0.receivedAt > $1.receivedAt }
        next.entries = Array(next.entries.prefix(300))
        // Entries, read/delivery state and cursor form one durable snapshot.
        try commit(next)
        if pendingReadCount == 0 { readSyncError = nil }
        delivery.remove(ids: removedNotifications)
    }

    private func queueReceipt(for entry: CodexNotificationEntry, in state: inout SavedState) {
        // If this alias has already been observed with a different producer identity, the old
        // notification can only be marked locally; never send its receipt to the replacement.
        let knownReplacement = state.sources.contains {
            $0.destination == entry.destination && $0.sourceID != nil && $0.sourceID != entry.event.sourceID
        }
        let knownOriginal = state.sources.contains { $0.sourceID == entry.event.sourceID }
        guard !knownReplacement || knownOriginal else { return }
        var outbox = state.pendingReadReceipts ?? [:]
        outbox[entry.event.sourceID, default: []].insert(entry.event.id)
        state.pendingReadReceipts = outbox
    }

    private func scheduleReceiptFlush() {
        Task { [weak self] in await self?.flushReadReceipts() }
    }

    private func flushReadReceipts() async {
        guard !shuttingDown else { return }
        let identities = Array((saved.pendingReadReceipts ?? [:]).keys)
        await withTaskGroup(of: Void.self) { group in
            for sourceID in identities {
                group.addTask { [weak self] in await self?.flushReadReceipts(sourceID: sourceID) }
            }
        }
    }

    private func flushReadReceipts(sourceID: String) async {
        guard !shuttingDown else { return }
        if let current = receiptTasks[sourceID] { await current.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            while let pending = self.saved.pendingReadReceipts?[sourceID], !pending.isEmpty {
                guard !Task.isCancelled, !self.shuttingDown else { return }
                let candidates = self.sources.filter { $0.enabled && $0.sourceID == sourceID }
                guard !candidates.isEmpty else { return }
                let batch = Array(pending.sorted().prefix(100))
                var acknowledged = false
                for source in candidates {
                    do {
                        try await self.permits.acquire()
                        do {
                            try Task.checkCancellation()
                            // Pausing/removing during the semaphore wait must not establish a connection.
                            guard self.sources.contains(where: { $0.id == source.id && $0.enabled && $0.sourceID == sourceID }) else {
                                throw CancellationError()
                            }
                            try await self.service.markRead(destination: source.destination, sourceID: sourceID, eventIDs: batch)
                            await self.permits.release()
                        } catch {
                            await self.permits.release()
                            throw error
                        }
                        acknowledged = true
                        break
                    } catch {
                        if Task.isCancelled || self.shuttingDown { return }
                        // Another enabled alias can reach the same producer while this one is offline.
                    }
                }
                guard !Task.isCancelled, !self.shuttingDown else { return }
                guard acknowledged else {
                    self.readSyncError = "已读状态已保存在本机，待主机恢复连接后同步。"
                    return
                }
                var next = self.saved
                var remaining = next.pendingReadReceipts?[sourceID] ?? []
                remaining.subtract(batch)
                if remaining.isEmpty { next.pendingReadReceipts?.removeValue(forKey: sourceID) }
                else { next.pendingReadReceipts?[sourceID] = remaining }
                guard self.save(next) else { return }
            }
        }
        receiptTasks[sourceID] = task
        await task.value
        receiptTasks.removeValue(forKey: sourceID)
        if pendingReadCount == 0 { readSyncError = nil }
    }

    private func deliverPending() async {
        guard !shuttingDown, systemNotificationsEnabled else { return }
        if let deliveryTask { await deliveryTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            for id in self.entries.reversed().filter({ !$0.notificationHandled }).map(\.id) {
                guard !Task.isCancelled, !self.shuttingDown, self.systemNotificationsEnabled else { return }
                guard let entry = self.entries.first(where: { $0.id == id }), !entry.notificationHandled,
                    !entry.isRead, !entry.isResolved, !self.isMuted(entry: entry),
                    self.sources.contains(where: { $0.enabled && $0.sourceID == entry.event.sourceID }) else { continue }
                do {
                    try await self.delivery.deliver(entry)
                    guard !Task.isCancelled, !self.shuttingDown else {
                        self.delivery.remove(ids: [id])
                        return
                    }
                    // A pause, read, mute, or approval resolution can occur while the OS queues the banner.
                    guard self.systemNotificationsEnabled,
                        let current = self.entries.first(where: { $0.id == id }),
                        !current.notificationHandled, !current.isRead, !current.isResolved,
                        !self.isMuted(entry: current),
                        self.sources.contains(where: { $0.enabled && $0.sourceID == current.event.sourceID }) else {
                        self.delivery.remove(ids: [id])
                        continue
                    }
                    var next = self.saved
                    guard let index = next.entries.firstIndex(where: { $0.id == id }) else { continue }
                    next.entries[index].notificationHandled = true
                    next.entries[index].wasNotified = true
                    guard self.save(next) else { return }
                } catch {
                    self.systemNotificationStatus = "系统通知未能送达；通知记录仍保留，可在系统设置中检查权限。"
                    return
                }
            }
        }
        deliveryTask = task
        await task.value
        deliveryTask = nil
    }

    private func activeSource(_ id: UUID, token: UUID) throws -> CodexNotificationSource {
        try Task.checkCancellation()
        guard !shuttingDown, operations[id]?.token == token,
            let source = sources.first(where: { $0.id == id && $0.enabled }) else {
            throw CodexNotificationsError.removed
        }
        return source
    }

    func isUnread(_ entry: CodexNotificationEntry) -> Bool {
        !entry.isRead && !entry.isResolved && !isMuted(entry: entry)
    }
    private func removeNotifications(for source: CodexNotificationSource) {
        if let sourceID = source.sourceID,
            sources.contains(where: { $0.id != source.id && $0.enabled && $0.sourceID == sourceID }) {
            // Aliases share the producer, not ownership of its local notification history.
            return
        }
        let ids = entries.filter {
            if let sourceID = source.sourceID { return $0.event.sourceID == sourceID }
            return $0.destination == source.destination
        }.map(\.id)
        delivery.remove(ids: ids)
    }
    private func commit(_ next: SavedState) throws {
        guard let data = try? JSONEncoder().encode(next) else { throw CodexNotificationsError.storage }
        defaults.set(data, forKey: storageKey)
        saved = next
    }
    @discardableResult private func save(_ next: SavedState) -> Bool {
        do { try commit(next); return true }
        catch { notice = CodexNotificationsError.storage.localizedDescription; return false }
    }
    private static func validDestination(_ value: String?) -> Bool {
        value.map { IdentifierValidator.isSSHDestination($0) } ?? true
    }
    private static func safeError(_ error: Error) -> String {
        if let error = error as? CodexNotificationsError { return error.localizedDescription }
        if let error = error as? CodexNotificationError {
            switch error {
            case .invalidDestination, .invalidCursor, .notInstalled, .invalidResponse:
                return error.localizedDescription
            case .commandFailed: break
            }
        }
        return CodexNotificationsError.connection.localizedDescription
    }
}
