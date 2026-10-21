import AppKit
import Foundation
import TmuxHubCore

@main
struct CodexNotificationsModelHarness {
    @MainActor static func main() async throws {
        try await baselineAliasesAndRestart()
        try await devicesKeepIndependentCursors()
        try await approvalsResolveAndSessionsMute()
        try await sourceResetAndPagination()
        try await removalDuringReadDoesNotResurrect()
        try await shutdownDuringReadDoesNotCommit()
        try await readDuringNativeDeliveryRemovesBanner()
        try await setupDuringReadStillInstalls()
        try await offlineReadReceiptSurvivesRestart()
        try await concurrentReadsUnionWithoutReadingFutureEvents()
        try await readReceiptsTryAnotherAlias()
        print("Codex notifications model: 11 lifecycle checks passed.")
    }

    @MainActor private static func baselineAliasesAndRestart() async throws {
        try await fixture { model, client, native, defaults in
            await client.set(events: [event(1)])
            let source = try await model.setup(destination: "hpc3")
            try expect(native.permissionRequests == 0, "Setup must never ask for OS permission.")
            try expect(model.entries.count == 1 && model.unreadCount == 1, "First sync must preserve unread history without banners.")
            try expect(model.sources.first?.sourceID == "remote-a", "Install's setup message is not a source identifier.")
            await model.enableSystemNotifications()
            try expect(native.permissionRequests == 1, "Permission requires the explicit action.")
            await client.set(events: [event(1), event(2)])
            await model.refresh(id: source)
            _ = try await model.setup(destination: "hpc3-alias")
            try expect(model.entries.count == 2 && native.delivered.count == 1, "Aliases must not duplicate events or banners.")
            let id = try require(model.entries.first(where: { $0.event.sequence == 2 })?.id)
            await model.setSourceEnabled(id: source, enabled: false)
            try expect(native.active.contains(id), "Pausing one alias must preserve banners while another alias stays enabled.")
            native.onOpen?(id)
            var opened: String?
            model.onOpen = { opened = $0.id }
            try expect(opened == id && model.unreadCount == 1, "A launch-time notification click must mark only the selected entry.")
            model.markAllRead()
            await model.shutdown()
            let secondNative = HarnessNotifications()
            let restored = CodexNotificationsModel(service: client, defaults: defaults, delivery: secondNative, autoStart: false)
            await restored.refreshAll()
            try expect(restored.entries.count == 2 && restored.unreadCount == 0 && secondNative.delivered.isEmpty,
                       "Restart must retain read/delivery state and avoid replay.")
            await restored.shutdown()
        }
    }

    @MainActor private static func devicesKeepIndependentCursors() async throws {
        try await fixture { first, client, native, _ in
            _ = try await first.setup(destination: nil)
            await first.enableSystemNotifications()
            let name = "tmuxhub.notification-harness.second.\(UUID())"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let secondNative = HarnessNotifications()
            let second = CodexNotificationsModel(service: client, defaults: defaults, delivery: secondNative, autoStart: false)
            _ = try await second.setup(destination: "same-machine")
            await second.enableSystemNotifications()
            await client.set(events: [event(1)])
            await first.refreshAll()
            await second.refreshAll()
            try expect(native.delivered.count == 1 && secondNative.delivered.count == 1,
                       "Reading on one device must not consume the other device's event.")
            first.markRead(id: try require(first.entries.first?.id))
            await first.refreshAll()
            await second.refreshAll()
            try expect(second.unreadCount == 0 && secondNative.active.isEmpty,
                       "A shared read receipt must update the other device even when its event cursor is unchanged.")
            await second.shutdown()
        }
    }

    @MainActor private static func approvalsResolveAndSessionsMute() async throws {
        try await fixture { model, client, native, _ in
            _ = try await model.setup(destination: "hpc4")
            await model.enableSystemNotifications()
            await client.set(events: [event(1, kind: .approvalRequested)])
            await model.refreshAll()
            let approval = try require(model.entries.first)
            model.setMuted(entry: approval, muted: true)
            await client.set(events: [event(1, kind: .approvalRequested), event(2)])
            await model.refreshAll()
            try expect(native.delivered.count == 1 && model.unreadCount == 0, "Muted sessions must not produce more banners/badges.")
            model.setMuted(entry: approval, muted: false)
            await client.set(events: [event(1, kind: .approvalRequested), event(2), event(3, kind: .approvalRequested), event(4, kind: .turnStarted)])
            await model.refreshAll()
            try expect(model.entries.count == 3 && model.entries.filter { $0.event.kind == .approvalRequested }.allSatisfy(\.isResolved),
                       "Turn start resolves approvals without creating a visible event.")
            try expect(native.active.isEmpty, "Resolved approval banners must be removed.")
        }
    }

    @MainActor private static func sourceResetAndPagination() async throws {
        try await fixture { model, client, native, _ in
            await client.set(events: (1...510).map { event($0) })
            _ = try await model.setup(destination: "hpc3")
            await model.enableSystemNotifications()
            try expect(model.entries.count == 300 && native.delivered.isEmpty && model.unreadCount == 300,
                       "The first five pages import bounded history quietly.")
            await client.set(events: (1...511).map { event($0) })
            await model.refreshAll()
            try expect(model.entries.count == 300 && native.delivered.count == 1 && model.unreadCount == 300,
                       "A new event arriving during initial pagination must deliver beyond the saved baseline cutoff.")
            try expect(model.entries.filter { $0.event.sequence <= 510 }.allSatisfy { !$0.isRead && $0.notificationHandled },
                       "Initial history must remain unread while its old banners are suppressed locally.")
            await client.setOffline(true)
            model.markRead(id: try require(model.entries.first(where: { $0.event.sequence == 511 })?.id))
            await model.refreshAll()
            try expect(model.pendingReadCount == 1, "An offline old-source receipt must remain durable until identity is checked.")
            await client.set(sourceID: "remote-reset", events: [event(1, source: "remote-reset")])
            await client.setOffline(false)
            await model.refreshAll()
            try expect(model.sources.first?.sourceID == "remote-reset" && native.delivered.count == 1,
                       "A replaced spool restarts its baseline without applying the old cursor.")
            try expect(model.pendingReadCount == 0, "A confirmed replacement must retire obsolete receipts instead of applying them to the new source.")
            let newFeed = try await client.read(destination: "hpc3", after: 0, limit: 100)
            try expect(newFeed.readEventIDs.isEmpty, "A receipt for the old source must never mark a new source event read.")
            await client.set(sourceID: "remote-reset", events: [event(1, source: "remote-reset"), event(2, source: "remote-reset")])
            await model.refreshAll()
            try expect(native.delivered.count == 2, "New events after a spool reset must deliver normally.")
        }
    }

    @MainActor private static func removalDuringReadDoesNotResurrect() async throws {
        try await fixture { model, client, _, _ in
            let id = try await model.setup(destination: "hpc3")
            await client.set(events: [event(1)])
            await client.pauseNextRead()
            let refresh = Task { await model.refreshAll() }
            try await eventually { await client.blocked }
            await model.removeSource(id: id)
            await client.resume()
            await refresh.value
            try expect(model.sources.isEmpty && model.entries.isEmpty, "A removed source must not return from an in-flight read.")
        }
    }

    @MainActor private static func shutdownDuringReadDoesNotCommit() async throws {
        try await fixture { model, client, _, defaults in
            _ = try await model.setup(destination: nil)
            await client.set(events: [event(1)])
            await client.pauseNextRead()
            let refresh = Task { await model.refreshAll() }
            try await eventually { await client.blocked }
            let shutdown = Task { await model.shutdown() }
            await Task.yield()
            await client.resume()
            await shutdown.value
            await refresh.value
            try expect(model.entries.isEmpty, "Shutdown must prevent an in-flight result from advancing the cursor.")
            let restored = CodexNotificationsModel(service: client, defaults: defaults, delivery: HarnessNotifications(), autoStart: false)
            await restored.refreshAll()
            try expect(restored.entries.count == 1, "An uncommitted event must remain available next launch.")
            await restored.shutdown()
        }
    }

    @MainActor private static func readDuringNativeDeliveryRemovesBanner() async throws {
        try await fixture { model, client, native, _ in
            _ = try await model.setup(destination: nil)
            await model.enableSystemNotifications()
            native.pauseNextDelivery = true
            await client.set(events: [event(1, kind: .approvalRequested)])
            let refresh = Task { await model.refreshAll() }
            try await eventually { native.blocked }
            let entry = try require(model.entries.first)
            model.markRead(id: entry.id)
            native.resume()
            await refresh.value
            try expect(native.active.isEmpty && model.unreadCount == 0,
                       "A banner queued concurrently with reading must be removed after OS completion.")
        }
    }

    @MainActor private static func setupDuringReadStillInstalls() async throws {
        try await fixture { model, client, _, _ in
            let id = try await model.setup(destination: "hpc3")
            await client.pauseNextRead(fails: true)
            let refresh = Task { await model.refreshAll() }
            try await eventually { await client.blocked }
            let setup = Task { try await model.setup(destination: "hpc3") }
            await Task.yield()
            await client.resume()
            try expect(try await setup.value == id, "Setup must retain the existing source identity.")
            await refresh.value
            try expect(await client.installCount == 2, "Explicit setup must install even after joining a failed background read.")
            let status = try require(model.statuses[id])
            if case .ready = status {} else {
                throw HarnessFailure.failed("Setup must recover the failed read through installation.")
            }
        }
    }

    @MainActor private static func offlineReadReceiptSurvivesRestart() async throws {
        try await fixture { first, client, _, defaults in
            _ = try await first.setup(destination: "hpc3")
            await first.enableSystemNotifications()
            let peerName = "tmuxhub.notification-peer.\(UUID())"
            let peerDefaults = UserDefaults(suiteName: peerName)!
            defer { peerDefaults.removePersistentDomain(forName: peerName) }
            let peerNative = HarnessNotifications()
            let peer = CodexNotificationsModel(service: client, defaults: peerDefaults, delivery: peerNative, autoStart: false)
            _ = try await peer.setup(destination: "hpc3")
            await peer.enableSystemNotifications()
            await client.set(events: [event(1)])
            await first.refreshAll(); await peer.refreshAll()
            await client.setOffline(true)
            first.markRead(id: try require(first.entries.first?.id))
            await first.refreshAll()
            try expect(first.pendingReadCount == 1 && first.unreadCount == 0, "Offline reads must persist an optimistic state and receipt outbox together.")
            await first.shutdown()
            let restored = CodexNotificationsModel(service: client, defaults: defaults, delivery: HarnessNotifications(), autoStart: false)
            try expect(restored.pendingReadCount == 1 && restored.unreadCount == 0, "Restart must retain unsent read receipts.")
            await client.setOffline(false)
            await restored.refreshAll(); await peer.refreshAll()
            try expect(restored.pendingReadCount == 0 && peer.unreadCount == 0 && peerNative.active.isEmpty,
                       "Reconnect must flush the durable receipt and remove the other device's banner.")
            await restored.shutdown(); await peer.shutdown()
        }
    }

    @MainActor private static func concurrentReadsUnionWithoutReadingFutureEvents() async throws {
        try await fixture { first, client, _, _ in
            await client.set(events: [event(1), event(2)])
            _ = try await first.setup(destination: nil)
            let peerName = "tmuxhub.notification-union.\(UUID())"
            let peerDefaults = UserDefaults(suiteName: peerName)!
            defer { peerDefaults.removePersistentDomain(forName: peerName) }
            let peer = CodexNotificationsModel(service: client, defaults: peerDefaults, delivery: HarnessNotifications(), autoStart: false)
            _ = try await peer.setup(destination: "alias")
            await client.setOffline(true)
            first.markRead(id: try require(first.entries.first(where: { $0.event.sequence == 1 })?.id))
            peer.markRead(id: try require(peer.entries.first(where: { $0.event.sequence == 2 })?.id))
            await first.refreshAll(); await peer.refreshAll()
            await client.setOffline(false)
            async let firstFlush: Void = first.refreshAll()
            async let secondFlush: Void = peer.refreshAll()
            _ = await (firstFlush, secondFlush)
            await first.refreshAll(); await peer.refreshAll()
            try expect(first.unreadCount == 0 && peer.unreadCount == 0, "Concurrent receipts must merge instead of replacing each other.")
            first.markAllRead()
            await client.set(events: [event(1), event(2), event(3)])
            await first.refreshAll(); await peer.refreshAll()
            try expect(first.unreadCount == 1 && peer.unreadCount == 1,
                       "Mark-all must upload explicit existing IDs without marking a future event read.")
            await peer.shutdown()
        }
    }

    @MainActor private static func readReceiptsTryAnotherAlias() async throws {
        try await fixture { model, client, _, _ in
            await client.set(events: [event(1)])
            _ = try await model.setup(destination: "offline-alias")
            _ = try await model.setup(destination: "working-alias")
            await client.setOffline(destination: "offline-alias", true)
            model.markRead(id: try require(model.entries.first?.id))
            await model.refreshAll()
            let feed = try await client.read(destination: "working-alias", after: 1, limit: 100)
            try expect(model.pendingReadCount == 0 && feed.readEventIDs == ["event-1"],
                       "Read receipts must fall back to another enabled alias for the same producer.")
        }
    }

    private static func event(_ sequence: Int, kind: CodexNotificationKind = .turnCompleted, source: String = "remote-a") -> CodexNotificationEvent {
        .init(id: "event-\(sequence)", sourceID: source, kind: kind, sessionID: "codex-session", cwd: "/work", hostname: "host",
              sequence: sequence, timestamp: Date(timeIntervalSince1970: Double(sequence)), tmuxSession: "work", tmuxSessionID: "$1", tmuxPane: "%1")
    }

    @MainActor private static func fixture(_ work: @MainActor (CodexNotificationsModel, HarnessNotificationClient, HarnessNotifications, UserDefaults) async throws -> Void) async throws {
        let name = "tmuxhub.notification-harness.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = HarnessNotificationClient()
        let native = HarnessNotifications()
        let model = CodexNotificationsModel(service: client, defaults: defaults, delivery: native, autoStart: false)
        do { try await work(model, client, native, defaults) }
        catch { await model.shutdown(); throw error }
        await model.shutdown()
    }
    @MainActor private static func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HarnessFailure.failed("Timed out waiting for the controlled operation.")
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw HarnessFailure.failed(message) }
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw HarnessFailure.failed("Missing expected fixture value.") }
        return value
    }
    private enum HarnessFailure: Error { case failed(String) }
}

private actor HarnessNotificationClient: CodexNotificationClient {
    private var sourceID = "remote-a"
    private var events: [CodexNotificationEvent] = []
    private var shouldPause = false
    private var shouldFail = false
    private var offline = false
    private var offlineDestinations = Set<String>()
    private var receipts: [String: Set<String>] = [:]
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var blocked = false
    private(set) var installCount = 0
    func install(destination: String?) async throws -> String {
        installCount += 1
        return "通知桥接已配置，请在 Codex /hooks 中确认。"
    }
    func set(sourceID: String = "remote-a", events: [CodexNotificationEvent]) { self.sourceID = sourceID; self.events = events }
    func setOffline(_ value: Bool) { offline = value }
    func setOffline(destination: String, _ value: Bool) {
        if value { offlineDestinations.insert(destination) } else { offlineDestinations.remove(destination) }
    }
    func markRead(destination: String?, sourceID: String, eventIDs: [String]) async throws {
        guard !offline && !offlineDestinations.contains(destination ?? "") else { throw CodexNotificationError.commandFailed("offline") }
        guard sourceID == self.sourceID, eventIDs.count <= 100 else { throw CodexNotificationError.invalidResponse }
        let retained = Set(events.map(\.id))
        receipts[sourceID, default: []].formUnion(eventIDs.filter { retained.contains($0) })
    }
    func pauseNextRead(fails: Bool = false) { shouldPause = true; shouldFail = fails }
    func resume() { continuation?.resume(); continuation = nil; blocked = false }
    func read(destination: String?, after: Int, limit: Int) async throws -> CodexNotificationFeed {
        guard !offline && !offlineDestinations.contains(destination ?? "") else { throw CodexNotificationError.commandFailed("offline") }
        let fail = shouldFail
        shouldFail = false
        let available = events.filter { $0.sequence > after }
        let feed = CodexNotificationFeed(sourceID: sourceID, events: Array(available.prefix(limit)), latestSequence: events.map(\.sequence).max() ?? 0, hasMore: available.count > limit, readEventIDs: Array(receipts[sourceID] ?? []))
        if shouldPause {
            shouldPause = false; blocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        if fail { throw CodexNotificationError.notInstalled }
        return feed
    }
}

@MainActor private final class HarnessNotifications: CodexNotificationDelivering {
    var onOpen: ((String) -> Void)?
    var permissionRequests = 0
    var delivered: [String] = []
    var active = Set<String>()
    var pauseNextDelivery = false
    var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func requestAuthorization() async throws -> Bool { permissionRequests += 1; return true }
    func authorizationDescription() async -> String { "测试通知权限" }
    func deliver(_ entry: CodexNotificationEntry) async throws {
        if pauseNextDelivery {
            pauseNextDelivery = false; blocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        delivered.append(entry.id); active.insert(entry.id)
    }
    func remove(ids: [String]) { active.subtract(ids) }
    func resume() { continuation?.resume(); continuation = nil; blocked = false }
}
