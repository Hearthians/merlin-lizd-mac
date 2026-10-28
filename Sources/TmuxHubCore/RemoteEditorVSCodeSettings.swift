import Darwin
import Foundation

enum RemoteEditorSetupError: LocalizedError {
    case settings
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .settings: "无法安全更新 VS Code 设置，请检查 settings.json 的格式和权限。"
        case let .failed(message): message
        }
    }
}

/// Edits only the two network settings needed for offline SSH hosts. JSONC
/// comments, formatting, extension preferences and unrelated values survive.
struct RemoteEditorVSCodeSettings {
    private static let lock = NSLock()
    let url: URL

    func prepare() throws -> [String: Any] {
        try Self.lock.withLock {
            let manager = FileManager.default
            let target = url.resolvingSymlinksInPath()
            let original = try Self.read(target)
            let source = original ?? Data("{}\n".utf8)
            let document = try Document(source)
            let updated = try document.replacing([
                "remote.downloadExtensionsLocally": "true",
                "remote.SSH.localServerDownload": "\"always\"",
            ])
            if updated != source || original == nil {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard try Self.read(target) == original, url.resolvingSymlinksInPath() == target else {
                    throw RemoteEditorSetupError.settings
                }
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".tmuxhub-code-\(UUID().uuidString)")
                defer { try? manager.removeItem(at: temporary) }
                try updated.write(to: temporary, options: .withoutOverwriting)
                let attributes = try? manager.attributesOfItem(atPath: target.path)
                try manager.setAttributes([.posixPermissions: attributes?[.posixPermissions] ?? 0o600], ofItemAtPath: temporary.path)
                guard rename(temporary.path, target.path) == 0 else { throw RemoteEditorSetupError.settings }
            }
            return document.values
        }
    }

    static func extensionIDs(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let array = value as? [String], array.count <= 64,
            array.allSatisfy(validExtensionID) else {
            throw RemoteEditorSetupError.failed("VS Code 的默认远端扩展列表无效，请检查 remote.SSH.defaultExtensions。")
        }
        return Array(Set(array.map { $0.lowercased() })).sorted()
    }

    static func validExtensionID(_ value: String) -> Bool {
        value.utf8.count <= 160 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_-]*$"#,
                                             options: .regularExpression) != nil
    }

    private static func read(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1_024 * 1_024 else {
            throw RemoteEditorSetupError.settings
        }
        return try Data(contentsOf: url)
    }

    struct Document {
        struct Token {
            let range: Range<Int>
            let text: String
        }
        let bytes: [UInt8]
        let tokens: [Token]
        let values: [String: Any]

        init(_ data: Data) throws {
            guard String(data: data, encoding: .utf8) != nil else { throw RemoteEditorSetupError.settings }
            bytes = Array(data)
            var parsed: [Token] = []
            var cursor = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            while cursor < bytes.count {
                let start = cursor
                let byte = bytes[cursor]
                if [9, 10, 13, 32].contains(byte) { cursor += 1; continue }
                if byte == 47, cursor + 1 < bytes.count {
                    if bytes[cursor + 1] == 47 {
                        cursor += 2
                        while cursor < bytes.count, bytes[cursor] != 10 { cursor += 1 }
                        continue
                    }
                    if bytes[cursor + 1] == 42 {
                        cursor += 2
                        while cursor + 1 < bytes.count, !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) { cursor += 1 }
                        guard cursor + 1 < bytes.count else { throw RemoteEditorSetupError.settings }
                        cursor += 2
                        continue
                    }
                }
                if byte == 34 {
                    cursor += 1
                    while cursor < bytes.count, bytes[cursor] != 34 {
                        if bytes[cursor] == 92 { cursor += 1 }
                        cursor += 1
                    }
                    guard cursor < bytes.count else { throw RemoteEditorSetupError.settings }
                    cursor += 1
                } else if [123, 125, 91, 93, 58, 44].contains(byte) {
                    cursor += 1
                } else {
                    while cursor < bytes.count, ![9, 10, 13, 32, 123, 125, 91, 93, 58, 44, 47].contains(bytes[cursor]) {
                        cursor += 1
                    }
                    guard cursor > start else { throw RemoteEditorSetupError.settings }
                }
                parsed.append(Token(range: start..<cursor, text: String(decoding: bytes[start..<cursor], as: UTF8.self)))
            }
            tokens = parsed
            let normalized = parsed.enumerated().filter { index, token in
                !(token.text == "," && index + 1 < parsed.count && ["}", "]"].contains(parsed[index + 1].text))
            }.map { $0.element.text }.joined(separator: " ")
            guard let object = try? JSONSerialization.jsonObject(with: Data(normalized.utf8)),
                let values = object as? [String: Any], parsed.first?.text == "{", parsed.last?.text == "}" else {
                throw RemoteEditorSetupError.settings
            }
            self.values = values
        }

        func replacing(_ properties: [String: String]) throws -> Data {
            var edits: [(Range<Int>, [UInt8])] = []
            var found = Set<String>()
            var index = 1
            while index < tokens.count - 1 {
                guard let key = try? JSONSerialization.jsonObject(with: Data(tokens[index].text.utf8), options: .fragmentsAllowed) as? String,
                    index + 2 < tokens.count, tokens[index + 1].text == ":" else { throw RemoteEditorSetupError.settings }
                let first = index + 2
                index = first
                var depth = 0
                repeat {
                    if ["{", "["].contains(tokens[index].text) { depth += 1 }
                    if ["}", "]"].contains(tokens[index].text) { depth -= 1 }
                    index += 1
                } while depth > 0 && index < tokens.count
                if let replacement = properties[key] {
                    found.insert(key)
                    let range = tokens[first].range.lowerBound..<tokens[index - 1].range.upperBound
                    if Array(bytes[range]) != Array(replacement.utf8) { edits.append((range, Array(replacement.utf8))) }
                }
                if index < tokens.count - 1 { index += 1 } // root property separator, already validated as JSONC
            }
            let missing = properties.keys.filter { !found.contains($0) }.sorted()
            if !missing.isEmpty {
                let separator = tokens.count > 2 && tokens[tokens.count - 2].text != "," ? "," : ""
                let text = separator + "\n" + missing.map { "    \"\($0)\": \(properties[$0]!)" }.joined(separator: ",\n") + "\n"
                let offset = tokens.last!.range.lowerBound
                edits.append((offset..<offset, Array(text.utf8)))
            }
            var result = bytes
            for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
                result.replaceSubrange(range, with: replacement)
            }
            return Data(result)
        }
    }
}
