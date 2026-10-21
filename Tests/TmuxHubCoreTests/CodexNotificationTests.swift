import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Durable Codex notifications")
struct CodexNotificationTests {
    private let sourceID = "A0DB5D13-821C-4CA7-9668-EF40B8C3D003"

    @Test("event routing metadata and ISO8601 timestamps survive persistence")
    func eventRoundTrip() throws {
        let event = sample(sequence: 1)
        let encoded = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(CodexNotificationEvent.self, from: encoded) == event)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["timestamp"] as? String == "2026-10-22T00:00:00.000Z")
        #expect(object["tmuxSession"] as? String == "research session")
        #expect(object["tmuxServerPID"] as? Int == 1234)
        #expect(object["prompt"] == nil)
        #expect(object["tool_input"] == nil)
        #expect(object["last_assistant_message"] == nil)
        var withoutFraction = object
        withoutFraction["timestamp"] = "2026-10-22T00:00:00Z"
        #expect(try JSONDecoder().decode(
            CodexNotificationEvent.self, from: JSONSerialization.data(withJSONObject: withoutFraction)
        ).timestamp == event.timestamp)
    }

    @Test("feed pages preserve the global cursor and source reset signal")
    func feedPages() throws {
        let page = CodexNotificationFeed(sourceID: sourceID, events: [sample(sequence: 11)], latestSequence: 30, hasMore: true)
        let decoded = try CodexNotificationFeed.decode(encode(page), after: 10, limit: 1)
        #expect(decoded.events.last?.sequence == 11)
        #expect(decoded.latestSequence == 30)
        #expect(decoded.hasMore)
        let reset = CodexNotificationFeed(sourceID: UUID().uuidString, events: [], latestSequence: 2, hasMore: false)
        #expect(try CodexNotificationFeed.decode(encode(reset), after: 300, limit: 100) == reset)
    }

    @Test("shared read receipts arrive without new events and older feeds remain decodable")
    func sharedReadSnapshot() throws {
        let id = UUID().uuidString
        let feed = CodexNotificationFeed(sourceID: sourceID, events: [], latestSequence: 20, hasMore: false, readEventIDs: [id])
        #expect(try CodexNotificationFeed.decode(encode(feed), after: 20, limit: 100).readEventIDs == [id])
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feed)) as? [String: Any])
        old.removeValue(forKey: "readEventIDs")
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
        #expect(try CodexNotificationFeed.decode(legacy, after: 20, limit: 100).readEventIDs.isEmpty)
        for ids in [["invalid"], [id, id], (0..<2_001).map { _ in UUID().uuidString }] {
            let invalid = CodexNotificationFeed(sourceID: sourceID, events: [], latestSequence: 20, hasMore: false, readEventIDs: ids)
            #expect(throws: CodexNotificationError.invalidResponse) {
                try CodexNotificationFeed.decode(encode(invalid), after: 20, limit: 100)
            }
        }
    }

    @Test("invalid ordering and foreign event identities never advance a feed")
    func invalidFeeds() throws {
        let invalid = [
            CodexNotificationFeed(sourceID: sourceID, events: [sample(sequence: 2), sample(sequence: 1)], latestSequence: 2, hasMore: false),
            CodexNotificationFeed(sourceID: sourceID, events: [sample(sequence: 2)], latestSequence: 1, hasMore: false),
            CodexNotificationFeed(sourceID: sourceID, events: [sample(sequence: 1)], latestSequence: 1, hasMore: false),
            CodexNotificationFeed(sourceID: UUID().uuidString, events: [sample(sequence: 2)], latestSequence: 2, hasMore: false),
            CodexNotificationFeed(sourceID: sourceID, events: [], latestSequence: 2, hasMore: true),
        ]
        for feed in invalid {
            #expect(throws: CodexNotificationError.invalidResponse) {
                try CodexNotificationFeed.decode(encode(feed), after: 1, limit: 100)
            }
        }
        #expect(throws: CodexNotificationError.invalidResponse) {
            try CodexNotificationFeed.decode("not json", after: 0, limit: 100)
        }
        let first = sample(sequence: 1)
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        let unsafeMetadata = [
            ("cwd", "/work/\u{001B}[31m"), ("cwd", "relative/path"),
            ("hostname", "host;touch /tmp/unwanted"), ("hostname", "-option"),
            ("tmuxSocket", "relative/socket"), ("tmuxSessionID", "$3;next"),
            ("tmuxWindow", "%2"), ("tmuxPane", "%"),
        ]
        for (key, value) in unsafeMetadata {
            var raw = original
            raw[key] = value
            let envelope: [String: Any] = ["sourceID": sourceID, "events": [raw], "latestSequence": 1, "hasMore": false]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            #expect(throws: CodexNotificationError.invalidResponse) {
                try CodexNotificationFeed.decode(text, after: 0, limit: 100)
            }
        }
    }

    @Test("bridge command construction validates destinations and bounded cursor arguments")
    func commandValidation() throws {
        for destination in ["host;touch /tmp/unwanted", "-oProxyCommand=bad", "host\nnext"] {
            #expect(throws: CodexNotificationError.invalidDestination) {
                try CodexNotificationBridge.installCommand(destination: destination)
            }
        }
        for (after, limit) in [(-1, 100), (0, 0), (0, 101)] {
            #expect(throws: CodexNotificationError.invalidCursor) {
                try CodexNotificationBridge.readCommand(destination: nil, after: after, limit: limit)
            }
        }
        let remote = try CodexNotificationBridge.readCommand(destination: "research@hpc3", after: 10, limit: 50)
        #expect(remote.executable == "/usr/bin/ssh")
        #expect(remote.arguments.contains("BatchMode=yes"))
        #expect(remote.arguments.contains("-nT"))
        #expect(remote.arguments.contains("research@hpc3"))
        let local = try CodexNotificationBridge.readCommand(destination: nil, after: 0, limit: 100)
        #expect(local.executable == "/usr/bin/env")
        #expect(local.arguments.first == "python3")
        #expect(!CodexNotificationBridge.helperSource.contains("dangerously-bypass"))
        for (source, ids) in [("invalid", [UUID().uuidString]), (sourceID, ["bad;command"]), (sourceID, (0..<101).map { _ in UUID().uuidString })] {
            #expect(throws: CodexNotificationError.invalidResponse) {
                try CodexNotificationBridge.markReadCommand(destination: nil, sourceID: source, eventIDs: ids)
            }
        }
    }

    @Test("service distinguishes explicit setup from replayable non-destructive reads")
    func serviceRouting() async throws {
        let feed = CodexNotificationFeed(sourceID: sourceID, events: [sample(sequence: 1)], latestSequence: 1, hasMore: false)
        let receipt = "{\"sourceID\":\"\(sourceID)\",\"message\":\"Review /hooks\"}"
        let runner = NotificationTestRunner(outputs: [
            .init(stdout: receipt, stderr: "", exitCode: 0),
            .init(stdout: try encode(feed), stderr: "", exitCode: 0),
        ])
        let service = CodexNotificationService(remote: runner, local: runner)
        #expect(try await service.install(destination: "host") == "Review /hooks")
        #expect(try await service.read(destination: "host", after: 0) == feed)
        #expect(await runner.modes == ["host:never", "host:readOnly"])
    }

    @Test("shared read acknowledgment uses idempotent replay and verifies source identity")
    func sharedReadService() async throws {
        let runner = NotificationTestRunner(outputs: [
            .init(stdout: "{\"sourceID\":\"\(sourceID)\",\"acknowledged\":true}", stderr: "", exitCode: 0),
            .init(stdout: "{\"sourceID\":\"\(UUID().uuidString)\",\"acknowledged\":true}", stderr: "", exitCode: 0),
        ])
        let service = CodexNotificationService(remote: runner, local: runner)
        try await service.markRead(destination: "host", sourceID: sourceID, eventIDs: [UUID().uuidString])
        await #expect(throws: CodexNotificationError.invalidResponse) {
            try await service.markRead(destination: "host", sourceID: sourceID, eventIDs: [UUID().uuidString])
        }
        #expect(await runner.modes == ["host:readOnly", "host:readOnly"])
    }

    @Test("missing installation is actionable and cannot masquerade as an empty feed")
    func missingInstallation() async {
        let runner = NotificationTestRunner(outputs: [.init(stdout: "", stderr: "TMUXHUB_NOT_INSTALLED\n", exitCode: 20)])
        let service = CodexNotificationService(remote: runner, local: runner)
        await #expect(throws: CodexNotificationError.notInstalled) {
            try await service.read(destination: nil, after: 0)
        }
    }

    @Test("cancelling a read propagates to the underlying command")
    func cancellation() async throws {
        let runner = NotificationTestRunner(outputs: [], suspend: true)
        let service = CodexNotificationService(remote: runner, local: runner)
        let operation = Task { try await service.read(destination: "host", after: 0) }
        for _ in 0..<10_000 {
            if await runner.started { break }
            await Task.yield()
        }
        #expect(await runner.started)
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await runner.wasCancelled)
    }

    private func sample(sequence: Int) -> CodexNotificationEvent {
        CodexNotificationEvent(
            id: UUID().uuidString, sourceID: sourceID, kind: .turnCompleted,
            sessionID: "codex-session", turnID: "turn", cwd: "/work/project", hostname: "host",
            sequence: sequence, timestamp: Date(timeIntervalSince1970: 1_792_627_200),
            tmuxSession: "research session", tmuxSessionID: "$3", tmuxSessionCreated: 123,
            tmuxServerPID: 1234, tmuxWindow: "@2", tmuxPane: "%4", tmuxSocket: "/tmp/tmux-501/default"
        )
    }

    private func encode(_ feed: CodexNotificationFeed) throws -> String {
        String(decoding: try JSONEncoder().encode(feed), as: UTF8.self)
    }
}

private actor NotificationTestRunner: CodexNotificationRemoteRunning, InventoryProcessRunning {
    private var outputs: [InventoryProcessOutput]
    private let suspend: Bool
    private(set) var modes: [String] = []
    private(set) var started = false
    private(set) var wasCancelled = false

    init(outputs: [InventoryProcessOutput], suspend: Bool = false) {
        self.outputs = outputs
        self.suspend = suspend
    }

    func run(_ command: CommandSpec, alias: String, replay: SSHReplayPolicy) async throws -> InventoryProcessOutput {
        switch replay {
        case .readOnly: modes.append(alias + ":readOnly")
        case .never: modes.append(alias + ":never")
        }
        return try await run(command)
    }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        started = true
        if suspend {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { wasCancelled = true; throw error }
        }
        return outputs.removeFirst()
    }
}
