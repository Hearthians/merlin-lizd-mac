import CryptoKit
import Darwin
import Foundation

struct RemoteEditorBuild: Decodable, Sendable {
    let commit: String
    let version: String

    init(application: URL) throws {
        let url = application.appendingPathComponent("Contents/Resources/app/product.json")
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard commit.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil,
            version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil else {
            throw RemoteEditorSetupError.failed("无法识别本机 VS Code 版本，请重新安装正式版 VS Code。")
        }
    }
}

struct RemoteEditorExtension: Sendable {
    let id: String
    let version: String
    let platform: String?
    let engine: String
    var sha256: String? = nil

    var packageURL: URL {
        let fields = id.split(separator: ".", maxSplits: 1)
        var components = URLComponents(string: "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/\(fields[0])/vsextensions/\(fields[1])/\(version)/vspackage")!
        if let platform, platform != "undefined", platform != "universal" {
            components.queryItems = [URLQueryItem(name: "targetPlatform", value: platform)]
        }
        return components.url!
    }
}

struct RemoteEditorMarketplace: Sendable {
    let runner: any InventoryProcessRunning
    let cache: URL
    let session: URLSession

    init(runner: any InventoryProcessRunning, cache: URL, session: URLSession = .shared) {
        self.runner = runner
        self.cache = cache
        self.session = session
    }

    func select(id: String, platform: String, version: String) async throws -> RemoteEditorExtension {
        guard RemoteEditorVSCodeSettings.validExtensionID(id) else { throw RemoteEditorSetupError.settings }
        var request = URLRequest(url: URL(string: "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json;api-version=7.2-preview.1", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filters": [["criteria": [["filterType": 7, "value": id]], "pageNumber": 1, "pageSize": 1]],
            "assetTypes": [], "flags": 147,
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 32 * 1_024 * 1_024 else {
            throw RemoteEditorSetupError.failed("本机暂时无法连接 VS Code 扩展市场，请检查网络后重试 code。")
        }
        return try Self.select(id: id, platform: platform, version: version, response: data)
    }

    static func select(id: String, platform: String, version: String, response: Data) throws -> RemoteEditorExtension {
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let result = (object["results"] as? [[String: Any]])?.first,
            let extensionObject = (result["extensions"] as? [[String: Any]])?.first,
            let versions = extensionObject["versions"] as? [[String: Any]] else {
            throw RemoteEditorSetupError.failed("VS Code 扩展市场中找不到 \(id)。")
        }
        for candidate in versions {
            let target = candidate["targetPlatform"] as? String
            guard target == nil || target == "undefined" || target == "universal" || target == platform,
                let name = candidate["version"] as? String,
                name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else { continue }
            let entries = candidate["properties"] as? [[String: String]] ?? []
            let properties = Dictionary(entries.compactMap { entry -> (String, String)? in
                guard let key = entry["key"], let value = entry["value"] else { return nil }
                return (key, value)
            }, uniquingKeysWith: { _, last in last })
            guard properties["Microsoft.VisualStudio.Code.PreRelease"] != "true",
                let engine = properties["Microsoft.VisualStudio.Code.Engine"], compatible(version, with: engine) else { continue }
            let digest = properties["Microsoft.VisualStudio.Services.VsixSha256"]
            guard digest == nil || digest?.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else { continue }
            return RemoteEditorExtension(id: id, version: name, platform: target, engine: engine, sha256: digest?.lowercased())
        }
        throw RemoteEditorSetupError.failed("扩展 \(id) 没有适用于当前 VS Code 和远端系统的版本，请更新 VS Code 后重试。")
    }

    /// Gallery engines normally use ^1.x.y; also handle the documented common
    /// comparator ranges. Unknown ranges fail closed rather than installing an
    /// incompatible extension on an older Mac's VS Code.
    static func compatible(_ version: String, with engine: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            guard let head = value.split(separator: "-", maxSplits: 1).first else { return nil }
            let core = head.split(separator: ".")
            guard core.count == 3 else { return nil }
            let result = core.compactMap { Int($0) }
            return result.count == 3 ? result : nil
        }
        guard let current = parts(version) else { return false }
        func compare(_ a: [Int], _ b: [Int]) -> Int {
            for index in 0..<3 where a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
            return 0
        }
        return engine.components(separatedBy: "||").contains { alternative in
            let range = alternative.trimmingCharacters(in: .whitespaces)
            if range == "*" { return true }
            let pattern = #"(\^|~|>=|<=|>|<|=)?\s*(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let string = range as NSString
            let matches = regex.matches(in: range, range: NSRange(location: 0, length: string.length))
            let remaining = regex.stringByReplacingMatches(in: range, range: NSRange(location: 0, length: string.length), withTemplate: "")
            guard !matches.isEmpty, remaining.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return matches.allSatisfy { match in
                let op = match.range(at: 1).location == NSNotFound ? "=" : string.substring(with: match.range(at: 1))
                guard let minimum = parts(string.substring(with: match.range(at: 2))) else { return false }
                let order = compare(current, minimum)
                switch op {
                case "^":
                    let upper = minimum[0] > 0 ? [minimum[0] + 1, 0, 0] : minimum[1] > 0 ? [0, minimum[1] + 1, 0] : [0, 0, minimum[2] + 1]
                    return order >= 0 && compare(current, upper) < 0
                case "~": return order >= 0 && compare(current, [minimum[0], minimum[1] + 1, 0]) < 0
                case ">=": return order >= 0
                case "<=": return order <= 0
                case ">": return order > 0
                case "<": return order < 0
                default: return order == 0
                }
            }
        }
    }

    func package(_ selected: RemoteEditorExtension, vscodeVersion: String) async throws -> (URL, [String]) {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let filename = "\(selected.id)-\(selected.version)-\(selected.platform ?? "universal").vsix"
        let target = cache.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: target.path) {
            try await download(selected.packageURL, to: target, limit: 256 * 1_024 * 1_024)
        }
        try Self.validateCachedFile(target, limit: 256 * 1_024 * 1_024)
        // Some Marketplace endpoints wrap the VSIX in gzip independently of the
        // transport's Content-Encoding; normalize it without any local Python.
        let handle = try FileHandle(forReadingFrom: target)
        let magic = try handle.read(upToCount: 2)
        try handle.close()
        if magic == Data([0x1F, 0x8B]) {
            let zipped = cache.appendingPathComponent(".\(UUID().uuidString).vsix.gz")
            let decoded = zipped.deletingPathExtension()
            defer { try? FileManager.default.removeItem(at: zipped); try? FileManager.default.removeItem(at: decoded) }
            try FileManager.default.copyItem(at: target, to: zipped)
            let output = try await runner.run(CommandSpec(executable: "/usr/bin/gzip", arguments: ["-d", zipped.path]))
            guard output.exitCode == 0 else { throw RemoteEditorSetupError.failed("VS Code 扩展下载不完整，请重试。") }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: decoded)
        }
        if let expected = selected.sha256, try Self.sha256(target) != expected {
            try? FileManager.default.removeItem(at: target)
            throw RemoteEditorSetupError.failed("VS Code 扩展包校验失败，请重新运行 code。")
        }
        let output = try await runner.run(CommandSpec(executable: "/usr/bin/unzip",
            arguments: ["-p", target.path, "extension/package.json"]))
        guard output.exitCode == 0, output.stdout.utf8.count <= 2 * 1_024 * 1_024,
            let manifest = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
            let publisher = manifest["publisher"] as? String, let name = manifest["name"] as? String,
            (publisher + "." + name).lowercased() == selected.id,
            manifest["version"] as? String == selected.version,
            let engine = (manifest["engines"] as? [String: String])?["vscode"],
            Self.compatible(vscodeVersion, with: engine) else {
            try? FileManager.default.removeItem(at: target)
            throw RemoteEditorSetupError.failed("VS Code 扩展包验证失败，请重新运行 code。")
        }
        let dependencies = try RemoteEditorVSCodeSettings.extensionIDs(manifest["extensionDependencies"])
            + RemoteEditorVSCodeSettings.extensionIDs(manifest["extensionPack"])
        return (target, dependencies)
    }

    func server(commit: String, platform: String) async throws -> URL {
        let target = cache.appendingPathComponent("server-\(commit)-\(platform).tar.gz")
        if !FileManager.default.fileExists(atPath: target.path) {
            try await download(URL(string: "https://update.code.visualstudio.com/commit:\(commit)/server-\(platform)/stable")!,
                               to: target, limit: 512 * 1_024 * 1_024)
        }
        try Self.validateCachedFile(target, limit: 512 * 1_024 * 1_024)
        return target
    }

    private static func validateCachedFile(_ url: URL, limit: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= limit else {
            throw RemoteEditorSetupError.failed("VS Code 下载缓存无效，请检查本机缓存目录权限。")
        }
    }

    func download(_ url: URL, to target: URL, limit: Int) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url?.scheme == "https", size > 0, size <= limit else {
            throw RemoteEditorSetupError.failed("本机下载 VS Code 组件失败，请检查网络后重试 code。")
        }
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_024 * 1_024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
