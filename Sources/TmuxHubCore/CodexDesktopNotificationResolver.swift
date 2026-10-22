import Foundation

/// Opens only a desktop chat whose identity can be proven from local session metadata.
/// A working directory or a transient engine ID alone cannot identify a chat.
public enum CodexDesktopNotificationResolver {
    public static func resolve(event: CodexNotificationEvent, codexHome: URL? = nil) async -> URL? {
        let home = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let work = Task.detached(priority: .utility) {
            resolveLocally(event: event, codexHome: home)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func resolveLocally(event: CodexNotificationEvent, codexHome: URL) -> URL? {
        let candidates = [event.desktopThreadID, event.sessionID].compactMap { value -> String? in
            guard let value, UUID(uuidString: value) != nil else { return nil }
            return value.lowercased()
        }
        guard !candidates.isEmpty else { return nil }
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let pattern = try? NSRegularExpression(
            pattern: "^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}t[0-9]{2}-[0-9]{2}-[0-9]{2}-(\(uuid))(?:_(\(uuid)))?\\.jsonl$"
        ) else { return nil }
        var matches: [String: Set<String>] = [:]
        var examined = 0
        for directory in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(directory, isDirectory: true)
            guard let properties = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                properties.isDirectory == true, properties.isSymbolicLink != true
            else { continue }
            guard let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in files {
                if Task.isCancelled { return nil }
                examined += 1
                guard examined <= 50_000 else { return nil }
                guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                    properties.isSymbolicLink != true
                else { files.skipDescendants(); continue }
                guard properties.isRegularFile == true else { continue }
                let name = file.lastPathComponent.lowercased()
                guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                    let parentRange = Range(match.range(at: 1), in: name)
                else { continue }
                let parentID = String(name[parentRange])
                let engineID = Range(match.range(at: 2), in: name).map { String(name[$0]) }
                let relevant = candidates.filter { $0 == parentID || $0 == engineID }
                guard !relevant.isEmpty, let metadata = metadataHeader(at: file),
                    metadata.type == "session_meta",
                    metadata.payload.id.lowercased() == parentID,
                    metadata.payload.isDesktop
                else { continue }
                for candidate in relevant { matches[candidate, default: []].insert(parentID) }
            }
        }
        for candidate in candidates {
            guard let found = matches[candidate], found.count == 1, let threadID = found.first else { continue }
            return URL(string: "codex://threads/\(threadID)")
        }
        return nil
    }

    private struct Header: Decodable {
        let type: String
        let payload: Metadata
    }

    private struct Metadata: Decodable {
        let id: String
        let originator: String?
        var isDesktop: Bool {
            originator == "Codex Desktop" || originator == "codex_work_desktop"
        }
    }

    private static func metadataHeader(at file: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var header = Data()
        // Read only the bounded first record; never load conversation contents.
        while header.count < 262_144 {
            guard let chunk = try? handle.read(upToCount: min(4096, 262_144 - header.count)), !chunk.isEmpty else { return nil }
            if let newline = chunk.firstIndex(of: 10) {
                header.append(chunk[..<newline])
                return try? JSONDecoder().decode(Header.self, from: header)
            }
            header.append(chunk)
        }
        return nil
    }
}
