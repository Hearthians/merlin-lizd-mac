import Foundation

public protocol CodexExecutableFileChecking: Sendable {
    func isExecutableFile(at url: URL) -> Bool
}

public protocol CodexVersionProbing: Sendable {
    func versionOutput(
        executable: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> String
}

public struct ResolvedCodexExecutable: Equatable, Sendable {
    public let executable: URL
    public let version: CodexVersion

    public init(executable: URL, version: CodexVersion) {
        self.executable = executable
        self.version = version
    }
}

public enum CodexExecutableResolverError: Error, Equatable, Sendable {
    case notFound
    case probeTimedOut
    case versionProbeFailed
    case malformedVersion
    case unsupportedVersion(String)
}

public struct FoundationCodexExecutableFileChecker:
    CodexExecutableFileChecking, Sendable
{
    public init() {}

    public func isExecutableFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}

public struct CodexExecutableResolver: Sendable {
    public static let defaultProbeTimeout: Duration = .seconds(2)

    private let override: URL?
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileChecker: any CodexExecutableFileChecking
    private let versionProbe: any CodexVersionProbing
    private let probeTimeout: Duration

    public init(
        override: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileChecker: any CodexExecutableFileChecking =
            FoundationCodexExecutableFileChecker(),
        versionProbe: any CodexVersionProbing = FoundationCodexVersionProbe(),
        probeTimeout: Duration = Self.defaultProbeTimeout
    ) {
        self.override = override
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileChecker = fileChecker
        self.versionProbe = versionProbe
        self.probeTimeout = probeTimeout
    }

    var candidatePathsForTesting: [String] {
        candidateURLs.map(\.path)
    }

    public func resolve() async throws -> ResolvedCodexExecutable {
        guard let executable = candidateURLs.first(where: {
            fileChecker.isExecutableFile(at: $0)
        }) else {
            throw CodexExecutableResolverError.notFound
        }

        let deadline = ContinuousClock.now.advanced(by: probeTimeout)
        let output: String
        do {
            output = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [versionProbe] in
                    try await versionProbe.versionOutput(
                        executable: executable,
                        deadline: deadline
                    )
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw CodexExecutableResolverError.probeTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
        } catch let error as CodexExecutableResolverError {
            throw error
        } catch is CancellationError {
            if ContinuousClock.now >= deadline {
                throw CodexExecutableResolverError.probeTimedOut
            }
            throw CancellationError()
        } catch {
            throw CodexExecutableResolverError.versionProbeFailed
        }

        let version: CodexVersion
        do {
            version = try CodexVersion.parse(commandOutput: output)
        } catch {
            throw CodexExecutableResolverError.malformedVersion
        }
        guard version.isSupported else {
            throw CodexExecutableResolverError.unsupportedVersion(
                version.description
            )
        }
        return ResolvedCodexExecutable(
            executable: executable,
            version: version
        )
    }

    private var candidateURLs: [URL] {
        var candidates: [URL] = []
        if let override { candidates.append(override) }
        candidates.append(URL(
            fileURLWithPath:
                "/Applications/ChatGPT.app/Contents/Resources/codex"
        ))
        if let path = environment["PATH"] {
            for entry in path.split(
                separator: ":",
                omittingEmptySubsequences: true
            ) {
                candidates.append(
                    URL(fileURLWithPath: String(entry), isDirectory: true)
                        .appendingPathComponent("codex", isDirectory: false)
                )
            }
        }
        candidates.append(
            homeDirectory
                .appendingPathComponent(".local/bin", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false)
        )
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))

        var seen: Set<String> = []
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }
}

public struct FoundationCodexVersionProbe: CodexVersionProbing, Sendable {
    public init() {}

    public func versionOutput(
        executable: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        let process = AppServerProcess(
            executable: executable,
            arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment
        )
        try await process.start()
        var output = Data()
        while ContinuousClock.now < deadline,
            let event = await process.nextEvent()
        {
            switch event {
            case let .standardOutput(data):
                output.append(data)
                guard output.count <= 4_096 else {
                    await process.terminate()
                    _ = await process.waitForTermination()
                    throw CodexExecutableResolverError.versionProbeFailed
                }
            case .standardError:
                break
            case let .terminated(exitCode):
                _ = await process.waitForTermination()
                guard exitCode == 0 else {
                    throw CodexExecutableResolverError.versionProbeFailed
                }
                return String(decoding: output, as: UTF8.self)
            }
        }
        await process.terminate()
        _ = await process.waitForTermination()
        throw CodexExecutableResolverError.probeTimedOut
    }
}
