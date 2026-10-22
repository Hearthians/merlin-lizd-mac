import AppKit
import Foundation
@testable import TmuxHubCore

/// Exercises the real app model with isolated preferences and a fake transport.
/// No SSH, browser, application window, or user's saved links are touched.
@main
struct ForwardedLinksModelHarness {
    @MainActor
    static func main() async throws {
        try await restoredLinksKeepTheirFullAddress()
        try await pinnedNodesPersistAndRemainSeparate()
        try await refreshRepairsTheOriginalPort()
        try await temporaryRepairFailureKeepsTheSavedAddress()
        try await stoppingSharedRoutesPersistsTheDisabledState()
        try await removingOneLinkPreservesItsSibling()
        try await stopDuringOpenDoesNotResurrect()
        try await removeDuringOpenDoesNotResurrect()
        try await shutdownDuringOpenDoesNotResurrect()
        try await malformedPreferencesAreIgnored()
        print("Forwarded links model: 10 lifecycle checks passed.")
    }

    @MainActor
    private static func restoredLinksKeepTheirFullAddress() async throws {
        try await withFixture(ports: [49_181]) { fixture in
            let original = "https://localhost:8765/mesh%20viewer/?step=1250&mode=side#left"
            let endpoint = try endpoint(original)
            let first = try await fixture.model.open(destination: "hpc3", endpoint: endpoint)
            try expect(
                first.absoluteString == "https://localhost:49181/mesh%20viewer/?step=1250&mode=side#left",
                "Opening must retain scheme, escaped path, query, and fragment."
            )
            let record = try require(fixture.model.records.first, "The opened link must be saved.")
            try expect(record.originalURL == original && record.localPort == 49_181 && record.enabled,
                       "The full original URL and allocated port must be persisted.")
            let again = try await fixture.model.open(destination: "hpc3", endpoint: endpoint)
            try expect(again == first && fixture.model.records.count == 1,
                       "Opening the same link must reuse its saved record.")
            try expect(await fixture.transport.opened().count == 1, "A healthy shared route must be reused.")

            await fixture.model.shutdown()
            let nextTransport = HarnessTransport()
            let nextAllocator = HarnessPortAllocator([])
            let nextService = service(transport: nextTransport, allocator: nextAllocator)
            let restored = ForwardedLinksModel(service: nextService, defaults: fixture.defaults, autoStart: true)
            try expect(restored.records.count == 1 && restored.records[0].enabled,
                       "Quitting must preserve the user's enabled preference.")
            try expect(restored.status(for: record.id) == .saved, "Restored links must await a health check.")
            // No explicit refresh: startup itself must restore the saved route.
            await nextTransport.waitUntilOpenCount(1)
            try await eventually("Startup must publish ready state after restoring the saved link.") {
                restored.localURL(for: record.id) == first
            }
            try expect(restored.localURL(for: record.id) == first,
                       "A restart must recover the exact browser URL.")
            let calls = await nextTransport.opened()
            try expect(calls.map(\.localPort) == [49_181], "Restoring must request the saved local port.")
            try expect(nextAllocator.requests().isEmpty, "Restoring must not allocate a replacement port.")
            let reopened = try await restored.reopen(id: record.id)
            try expect(reopened == first, "Reopening must preserve the saved URL.")
            await restored.shutdown()
            await nextService.shutdown()
        }
    }

    @MainActor
    private static func pinnedNodesPersistAndRemainSeparate() async throws {
        try await withFixture(ports: [49_181, 49_182, 49_183]) { fixture in
            let endpoint = try endpoint("http://localhost:8765/view")
            let firstPin = CodexNotificationSSHEndpoint(destination: "hpc4",
                address: "10.120.81.43", hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
            let secondPin = CodexNotificationSSHEndpoint(destination: "hpc4",
                address: "10.120.81.41", hostKeyAlias: "hpc4login.hpc.hkust-gz.edu.cn")
            _ = try await fixture.model.open(destination: "hpc4", endpoint: endpoint, sshEndpoint: firstPin)
            _ = try await fixture.model.open(destination: "hpc4", endpoint: endpoint, sshEndpoint: secondPin)
            _ = try await fixture.model.open(destination: "hpc4", endpoint: endpoint)
            try expect(fixture.model.records.count == 3, "The same link on distinct login nodes must have separate saved records.")
            let first = try require(fixture.model.records.first(where: { $0.sshEndpoint == firstPin }), "Pinned record missing.")
            await fixture.model.stop(id: first.id)
            try expect(fixture.model.records.filter(\.enabled).count == 2, "Stopping one pinned node must not stop another node or the original alias.")
            let restored = ForwardedLinksModel(service: fixture.service, defaults: fixture.defaults, autoStart: false)
            try expect(restored.records == fixture.model.records, "Pinned node identities must survive app restart.")
            await restored.shutdown()
        }
    }

    @MainActor
    private static func refreshRepairsTheOriginalPort() async throws {
        try await withFixture(ports: [49_182]) { fixture in
            let first = try await fixture.model.open(
                destination: "hpc3", endpoint: endpoint("http://127.0.0.1:8765/view?q=2#mesh")
            )
            let id = try require(fixture.model.records.first?.id, "Missing saved link.")
            await fixture.transport.setMasterRunning(false)
            await fixture.model.refreshAll()
            try expect(fixture.model.localURL(for: id) == first, "Repair must retain the browser address.")
            try expect(await fixture.transport.opened().map(\.localPort) == [49_182, 49_182],
                       "Repair must reopen the original port.")
            try expect(fixture.allocator.requests().count == 1, "Repair must not allocate another port.")
        }
    }

    @MainActor
    private static func temporaryRepairFailureKeepsTheSavedAddress() async throws {
        try await withFixture(ports: [49_189]) { fixture in
            let first = try await fixture.model.open(
                destination: "hpc3", endpoint: endpoint("http://localhost:8765/view?step=7#compare")
            )
            let id = try require(fixture.model.records.first?.id, "Missing saved link.")
            await fixture.transport.setMasterRunning(false)
            await fixture.transport.failNextOpen()
            await fixture.model.refreshAll()
            if case .failed = fixture.model.status(for: id) {} else {
                throw HarnessFailure.failed("A temporary repair error must be visible.")
            }
            let failedRecord = try require(fixture.model.records.first, "A failed link must remain saved.")
            try expect(failedRecord.enabled && failedRecord.localPort == first.port,
                       "A repair error must retain the enabled preference and fixed browser port.")
            try expect(fixture.model.localURL(for: id) == nil, "A failed route must not appear ready.")
            await fixture.model.refreshAll()
            try expect(fixture.model.localURL(for: id) == first,
                       "Recovery after an ordinary error must restore the same full URL.")
            try expect(await fixture.transport.opened().map(\.localPort) == [49_189, 49_189, 49_189],
                       "Initial open, failed repair, and recovery must use the same local port.")
            try expect(fixture.allocator.requests().count == 1,
                       "An ordinary error must not trigger allocation of a replacement browser address.")
        }
    }

    @MainActor
    private static func stoppingSharedRoutesPersistsTheDisabledState() async throws {
        try await withFixture(ports: [49_183]) { fixture in
            let first = try await fixture.model.open(
                destination: "hpc3", endpoint: endpoint("http://localhost:8080/first")
            )
            _ = try await fixture.model.open(
                destination: "hpc3", endpoint: endpoint("http://localhost:8080/second?q=1#result")
            )
            let firstID = fixture.model.records[0].id
            let secondID = fixture.model.records[1].id
            try expect(await fixture.transport.opened().count == 1,
                       "Different paths on one endpoint must share a route.")
            await fixture.model.stop(id: firstID)
            try expect(fixture.model.records.allSatisfy { !$0.enabled },
                       "Stopping a route must disable every saved path on it.")
            try expect(fixture.model.status(for: firstID) == .stopped
                       && fixture.model.status(for: secondID) == .stopped,
                       "Every stopped path must display stopped.")
            try expect(await fixture.transport.cancelled().count == 1, "The shared route must close once.")
            await fixture.model.refreshAll()
            try expect(await fixture.transport.opened().count == 1, "Refresh must not restart stopped links.")
            await fixture.model.shutdown()

            let nextTransport = HarnessTransport()
            let nextService = service(transport: nextTransport, allocator: HarnessPortAllocator([]))
            let restored = ForwardedLinksModel(service: nextService, defaults: fixture.defaults, autoStart: false)
            await restored.refreshAll()
            try expect(restored.records.count == 2 && restored.records.allSatisfy { !$0.enabled },
                       "Stopped links must remain disabled after restart.")
            try expect(await nextTransport.opened().isEmpty, "Restart must not reconnect disabled records.")
            let resumed = try await restored.resume(id: firstID)
            try expect(resumed == first, "Explicit resume must preserve the saved address.")
            try expect(restored.records.first { $0.id == secondID }?.enabled == false,
                       "Resuming one link must not enable its stopped sibling.")
            await restored.shutdown()
            await nextService.shutdown()
        }
    }

    @MainActor
    private static func removingOneLinkPreservesItsSibling() async throws {
        try await withFixture(ports: [49_184]) { fixture in
            _ = try await fixture.model.open(
                destination: "hpc4", endpoint: endpoint("http://localhost:8080/first")
            )
            let second = try await fixture.model.open(
                destination: "hpc4", endpoint: endpoint("http://localhost:8080/second")
            )
            let firstID = fixture.model.records[0].id
            let secondID = fixture.model.records[1].id
            await fixture.model.remove(id: firstID)
            try expect(fixture.model.records.map(\.id) == [secondID], "Remove must delete only the selected record.")
            try expect(fixture.model.localURL(for: secondID) == second, "The sibling link must remain ready.")
            try expect(await fixture.transport.cancelled().isEmpty, "A remaining owner must keep its route.")
            await fixture.model.refreshAll()
            try expect(await fixture.transport.opened().count == 1, "Refresh must reuse the surviving route.")
            await fixture.model.remove(id: secondID)
            await fixture.model.refreshAll()
            try expect(fixture.model.records.isEmpty, "Removed records must not return.")
            try expect(await fixture.transport.cancelled().count == 1, "Removing the final owner must close its route.")
            let saved = try JSONDecoder().decode(
                [ForwardedLinkRecord].self,
                from: require(fixture.defaults.data(forKey: storageKey), "Missing saved record data.")
            )
            try expect(saved.isEmpty, "Removed records must be absent from persistent preferences.")
        }
    }

    @MainActor
    private static func stopDuringOpenDoesNotResurrect() async throws {
        try await withFixture(ports: [49_185], pauseFirstOpen: true) { fixture in
            let opening = Task { @MainActor in
                try await fixture.model.open(destination: "hpc3", endpoint: endpoint("http://localhost:8080/slow"))
            }
            await fixture.transport.waitUntilOpenCount(1)
            let id = try require(fixture.model.records.first?.id, "Missing pending link.")
            let stopping = Task { @MainActor in await fixture.model.stop(id: id) }
            try await eventually("Stop must disable the pending link immediately.") {
                fixture.model.records.first?.enabled == false
            }
            await fixture.transport.resumeOpen()
            let outcome = await opening.result
            await stopping.value
            try expect(isFailure(outcome), "An opening completed after stop must not return a live URL.")
            try expect(fixture.model.status(for: id) == .stopped, "A late open must not replace stopped status.")
            await fixture.model.refreshAll()
            try expect(await fixture.transport.opened().count == 1, "Stopped records must not auto-repair.")
            try expect(await fixture.transport.cancelled().count == 1, "The late route must be cleaned up.")
        }
    }

    @MainActor
    private static func removeDuringOpenDoesNotResurrect() async throws {
        try await withFixture(ports: [49_186], pauseFirstOpen: true) { fixture in
            let opening = Task { @MainActor in
                try await fixture.model.open(destination: "hpc3", endpoint: endpoint("http://localhost:8080/slow"))
            }
            await fixture.transport.waitUntilOpenCount(1)
            let id = try require(fixture.model.records.first?.id, "Missing pending link.")
            let removing = Task { @MainActor in await fixture.model.remove(id: id) }
            try await eventually("Remove must delete the pending record immediately.") {
                fixture.model.records.isEmpty
            }
            await fixture.transport.resumeOpen()
            let outcome = await opening.result
            await removing.value
            try expect(isFailure(outcome), "An opening completed after remove must not return a live URL.")
            try expect(fixture.model.records.isEmpty && fixture.model.statuses[id] == nil,
                       "Late completion must not recreate removed records or statuses.")
            await fixture.model.refreshAll()
            try expect(await fixture.transport.opened().count == 1, "Removed links must not auto-repair.")
            try expect(await fixture.transport.cancelled().count == 1, "The orphaned route must be cleaned up.")
        }
    }

    @MainActor
    private static func shutdownDuringOpenDoesNotResurrect() async throws {
        try await withFixture(ports: [49_187], pauseFirstOpen: true) { fixture in
            let opening = Task { @MainActor in
                try await fixture.model.open(destination: "hpc3", endpoint: endpoint("http://localhost:8080/slow"))
            }
            await fixture.transport.waitUntilOpenCount(1)
            let id = try require(fixture.model.records.first?.id, "Missing pending link.")
            var shutdownStarted = false
            let shuttingDown = Task { @MainActor in
                shutdownStarted = true
                await fixture.model.shutdown()
            }
            try await eventually("Shutdown must start.") { shutdownStarted }
            await fixture.transport.resumeOpen()
            let outcome = await opening.result
            await shuttingDown.value
            try expect(isFailure(outcome), "An opening completed during shutdown must not succeed.")
            try expect(fixture.model.localURL(for: id) == nil && fixture.model.status(for: id) == .stopped,
                       "Shutdown must clear ready state.")
            await fixture.model.refreshAll()
            do {
                _ = try await fixture.model.reopen(id: id)
                throw HarnessFailure.failed("Shutdown must reject subsequent reopen.")
            } catch ForwardedLinksError.shuttingDown {}
            try expect(await fixture.transport.opened().count == 1, "Shutdown must suppress future repair.")
            try expect(await fixture.transport.cancelled().count == 1, "Shutdown must close the late-created route.")
            try expect(fixture.model.records.first?.enabled == true,
                       "Shutdown must preserve desired restoration for the next app launch.")
        }
    }

    @MainActor
    private static func malformedPreferencesAreIgnored() async throws {
        try await withFixture(ports: []) { fixture in
            fixture.defaults.set(Data("not valid JSON".utf8), forKey: storageKey)
            let malformed = ForwardedLinksModel(service: fixture.service, defaults: fixture.defaults, autoStart: false)
            try expect(malformed.records.isEmpty, "Malformed JSON must not create records.")
            await malformed.shutdown()

            let valid = ForwardedLinkRecord(
                id: UUID(), destination: "hpc3", originalURL: "http://localhost:8080/view?q=1#mesh",
                localPort: 49_188, enabled: false, lastUsed: Date(timeIntervalSince1970: 100)
            )
            var invalidHost = valid
            invalidHost.id = UUID()
            invalidHost.destination = "-oProxyCommand=bad"
            var invalidURL = valid
            invalidURL.id = UUID()
            invalidURL.originalURL = "https://example.invalid/view"
            var invalidPort = valid
            invalidPort.id = UUID()
            invalidPort.localPort = 65_536
            fixture.defaults.set(
                try JSONEncoder().encode([valid, valid, invalidHost, invalidURL, invalidPort]),
                forKey: storageKey
            )
            let filtered = ForwardedLinksModel(service: fixture.service, defaults: fixture.defaults, autoStart: false)
            try expect(filtered.records == [valid], "Invalid records and duplicate identities must be ignored.")
            await filtered.refreshAll()
            try expect(await fixture.transport.opened().isEmpty, "Ignored or disabled records must not connect.")
            await filtered.shutdown()
        }
    }

    private static let storageKey = "tmuxhub.forwarded-links.v1"

    @MainActor
    private static func withFixture(
        ports: [Int], pauseFirstOpen: Bool = false,
        body: @MainActor (HarnessFixture) async throws -> Void
    ) async throws {
        let suite = "tmuxhub-forwarded-links-harness-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "Cannot create isolated preferences.")
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = HarnessFixture(defaults: defaults, ports: ports, pauseFirstOpen: pauseFirstOpen)
        do {
            try await body(fixture)
            await fixture.model.shutdown()
            await fixture.service.shutdown()
        } catch {
            await fixture.transport.resumeOpen()
            await fixture.model.shutdown()
            await fixture.service.shutdown()
            throw error
        }
    }

    private static func service(
        transport: HarnessTransport, allocator: HarnessPortAllocator
    ) -> SSHLocalForwardingService {
        SSHLocalForwardingService(
            transport: transport, portAllocator: allocator, listenerProbe: HarnessListenerProbe()
        )
    }

    private static func endpoint(_ value: String) throws -> LoopbackURL {
        try require(LoopbackURL(value), "Invalid fixture URL: \(value)")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure.failed(message) }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw HarnessFailure.failed(message) }
    }

    private static func isFailure<T>(_ result: Result<T, Error>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    @MainActor
    private static func eventually(_ message: String, condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessFailure.failed(message)
    }
}

private enum HarnessFailure: Error {
    case failed(String)
}

@MainActor
private final class HarnessFixture {
    let defaults: UserDefaults
    let transport: HarnessTransport
    let allocator: HarnessPortAllocator
    let service: SSHLocalForwardingService
    let model: ForwardedLinksModel

    init(defaults: UserDefaults, ports: [Int], pauseFirstOpen: Bool) {
        self.defaults = defaults
        transport = HarnessTransport(pauseFirstOpen: pauseFirstOpen)
        allocator = HarnessPortAllocator(ports)
        service = SSHLocalForwardingService(
            transport: transport, portAllocator: allocator, listenerProbe: HarnessListenerProbe()
        )
        model = ForwardedLinksModel(service: service, defaults: defaults, autoStart: false)
    }
}

private struct HarnessForwardCall: Equatable, Sendable {
    let alias: String
    let localPort: Int
    let remoteHost: String
    let remotePort: Int
}

private actor HarnessTransport: SSHLocalForwardingTransport {
    private var opens: [HarnessForwardCall] = []
    private var cancels: [HarnessForwardCall] = []
    private var masterRunning = true
    private var openFailuresRemaining = 0
    private var pauseFirstOpen: Bool
    private var pendingOpen: CheckedContinuation<Void, Never>?
    private var openWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(pauseFirstOpen: Bool = false) {
        self.pauseFirstOpen = pauseFirstOpen
    }

    nonisolated func connection(for endpoint: CodexNotificationSSHEndpoint?) throws -> any SSHLocalForwardingTransport {
        // Node separation and transport selection are covered by the core suite;
        // this harness verifies persisted model identities and stop grouping.
        self
    }

    func openLocalForward(alias: String, localPort: Int, remoteHost: String, remotePort: Int) async throws {
        opens.append(HarnessForwardCall(
            alias: alias, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort
        ))
        let ready = openWaiters.filter { $0.0 <= opens.count }
        openWaiters.removeAll { $0.0 <= opens.count }
        ready.forEach { $0.1.resume() }
        if pauseFirstOpen {
            pauseFirstOpen = false
            await withCheckedContinuation { pendingOpen = $0 }
        }
        if openFailuresRemaining > 0 {
            openFailuresRemaining -= 1
            throw HarnessTransportError.temporaryFailure
        }
        masterRunning = true
    }

    func cancelLocalForward(alias: String, localPort: Int, remoteHost: String, remotePort: Int) async {
        cancels.append(HarnessForwardCall(
            alias: alias, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort
        ))
    }

    func isMasterRunning(alias: String) -> Bool { masterRunning }
    func setMasterRunning(_ value: Bool) { masterRunning = value }
    func failNextOpen() { openFailuresRemaining += 1 }
    func opened() -> [HarnessForwardCall] { opens }
    func cancelled() -> [HarnessForwardCall] { cancels }

    func waitUntilOpenCount(_ count: Int) async {
        guard opens.count < count else { return }
        await withCheckedContinuation { openWaiters.append((count, $0)) }
    }

    func resumeOpen() {
        pendingOpen?.resume()
        pendingOpen = nil
    }
}

private final class HarnessPortAllocator: SSHLocalPortAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [Int]
    private var requestedPorts: [Int?] = []

    init(_ ports: [Int]) { self.ports = ports }

    func availablePort(preferredPort: Int?, excluding excludedPorts: Set<Int>) throws -> Int {
        try lock.withLock {
            requestedPorts.append(preferredPort)
            guard !ports.isEmpty else { throw SSHLocalForwardingError.unableToAllocateLocalPort }
            return ports.removeFirst()
        }
    }

    func requests() -> [Int?] { lock.withLock { requestedPorts } }
}

private enum HarnessTransportError: Error {
    case temporaryFailure
}

private struct HarnessListenerProbe: SSHLocalListenerProbing {
    func isListening(port: Int) -> Bool { true }
}
