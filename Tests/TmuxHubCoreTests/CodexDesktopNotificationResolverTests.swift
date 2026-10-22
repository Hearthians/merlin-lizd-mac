import Foundation
import Testing
@testable import TmuxHubCore

@Suite("Desktop Codex notification routing")
struct CodexDesktopNotificationResolverTests {
    private let parentID = "01a0864d-7711-7253-ab6d-ecb16cd6ae8e"
    private let engineID = "01a15f6e-148d-75f0-88ab-da55c2a313f2"

    @Test("legacy exact desktop identity and engine filename suffix open the existing parent")
    func existingDesktopMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSession(directory, id: parentID, engine: engineID, originator: "Codex Desktop")
        for id in [parentID, engineID] {
            let url = await CodexDesktopNotificationResolver.resolve(event: event(id), codexHome: directory)
            #expect(url?.absoluteString == "codex://threads/\(parentID)")
        }
    }

    @Test("captured desktop identity resolves a transient engine without using cwd")
    func explicitDesktopIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSession(directory, id: parentID, originator: "codex_work_desktop", archived: true)
        let unknown = UUID().uuidString
        #expect(await CodexDesktopNotificationResolver.resolve(event: event(unknown), codexHome: directory) == nil)
        let url = await CodexDesktopNotificationResolver.resolve(
            event: event(unknown, desktopThreadID: parentID), codexHome: directory
        )
        #expect(url?.absoluteString == "codex://threads/\(parentID)")
    }

    @Test("plain CLI, IDE, forged metadata and invalid IDs never become desktop links")
    func unprovenIdentity() async throws {
        for originator in ["codex_cli_rs", "codex_vscode", "unknown"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try writeSession(directory, id: parentID, originator: originator)
            #expect(await CodexDesktopNotificationResolver.resolve(event: event(parentID), codexHome: directory) == nil)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSession(directory, id: parentID, originator: "Codex Desktop", metadataID: engineID)
        #expect(await CodexDesktopNotificationResolver.resolve(event: event(parentID), codexHome: directory) == nil)
        #expect(await CodexDesktopNotificationResolver.resolve(event: event("../../other"), codexHome: directory) == nil)
    }

    @Test("ambiguous engine aliases and symlinked metadata are rejected")
    func ambiguousAndLinked() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSession(directory, id: parentID, engine: engineID, originator: "Codex Desktop")
        try writeSession(directory, id: UUID().uuidString.lowercased(), engine: engineID, originator: "Codex Desktop")
        #expect(await CodexDesktopNotificationResolver.resolve(event: event(engineID), codexHome: directory) == nil)
        let other = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let linked = other.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory.appendingPathComponent("sessions"))
        #expect(await CodexDesktopNotificationResolver.resolve(event: event(parentID), codexHome: other) == nil)
    }

    @Test("desktop identity is optional on old events, validated and persisted on new events")
    func wireFormat() throws {
        let sample = event(engineID, desktopThreadID: parentID)
        let encoded = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(CodexNotificationEvent.self, from: encoded).desktopThreadID == parentID)
        let legacy = event(parentID)
        #expect(try JSONDecoder().decode(CodexNotificationEvent.self, from: JSONEncoder().encode(legacy)).desktopThreadID == nil)
        let invalid = event(engineID, desktopThreadID: "id?prompt=run")
        let feed = CodexNotificationFeed(sourceID: invalid.sourceID, events: [invalid], latestSequence: 1, hasMore: false)
        let text = String(decoding: try JSONEncoder().encode(feed), as: UTF8.self)
        #expect(throws: CodexNotificationError.invalidResponse) {
            try CodexNotificationFeed.decode(text, after: 0, limit: 100)
        }
    }

    private func event(_ id: String, desktopThreadID: String? = nil) -> CodexNotificationEvent {
        .init(id: UUID().uuidString, sourceID: UUID().uuidString, kind: .turnCompleted,
              sessionID: id, cwd: "/same/workspace", hostname: "local", sequence: 1,
              timestamp: Date(), desktopThreadID: desktopThreadID)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-desktop-notification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSession(_ root: URL, id: String, engine: String? = nil, originator: String,
                              archived: Bool = false, metadataID: String? = nil) throws {
        let directory = root.appendingPathComponent(archived ? "archived_sessions" : "sessions/2026/10/22")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-2026-10-22T01-06-52-\(id)\(engine.map { "_\($0)" } ?? "").jsonl")
        let header: [String: Any] = ["type": "session_meta", "payload": [
            "id": metadataID ?? id, "originator": originator, "source": "vscode", "cwd": "/same/workspace",
        ]]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(Data("\nnot-json-and-not-read\n".utf8))
        try data.write(to: file)
    }
}
