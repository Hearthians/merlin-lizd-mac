import Foundation

/// A terminal survives workspace/pane moves. Pane IDs and agent names do not.
public struct HerdrTerminalReference: Codable, Hashable, Sendable {
    public let sessionName: String?
    public let terminalID: String

    public init(sessionName: String? = nil, terminalID: String) {
        self.sessionName = sessionName
        self.terminalID = terminalID
    }

    public var isValid: Bool { (try? HerdrCommands.validate(self)) != nil }
}

public struct HerdrPaneRecord: Equatable, Hashable, Identifiable, Sendable {
    public var id: HerdrTerminalReference { reference }
    public let reference: HerdrTerminalReference
    public let paneID: String
    public let workspaceID: String
    public let cwd: String?
    public let foregroundCwd: String?
    public let agent: String?
    public let agentStatus: String?
    public let occupantID: String?
    public let label: String

    public var workingDirectory: String? { foregroundCwd ?? cwd }
}

public struct HerdrWorkspaceRecord: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let cwd: String?
    public let panes: [HerdrPaneRecord]
}

public struct HerdrSessionSnapshot: Equatable, Sendable {
    public let name: String
    public let sessionName: String?
    public let workspaces: [HerdrWorkspaceRecord]
}

public enum HerdrError: Error, Equatable, LocalizedError, Sendable {
    case notInstalled
    case noRunningSessions
    case serverUnavailable
    case terminalUnavailable
    case malformedResponse
    case invalidIdentifier
    case invalidPath
    case unsupportedOperation
    case commandFailed(exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 Herdr。请先在目标主机安装 Herdr。"
        case .noRunningSessions: "没有正在运行的 Herdr 会话。请先在目标主机打开 Herdr。"
        case .serverUnavailable: "无法读取 Herdr 会话。服务可能已停止，请刷新后重试。"
        case .terminalUnavailable: "原 Herdr 终端已不存在。请重新选择终端。"
        case .malformedResponse: "Herdr 返回的数据不完整或不受支持，无法安全确定目标终端。"
        case .invalidIdentifier: "Herdr 会话或终端标识无效。"
        case .invalidPath: "Herdr 返回的工作目录无效。"
        case .unsupportedOperation: "当前运行的 Herdr 服务不支持此操作，请检查其版本。"
        case let .commandFailed(exitCode): "Herdr 查询失败（退出码 \(exitCode)）。"
        }
    }
}

public enum HerdrCommands {
    public static func attach(
        target: TerminalTarget,
        reference: HerdrTerminalReference
    ) throws -> CommandSpec {
        try validate(reference)
        return try command(
            target: target,
            arguments: sessionArguments(reference.sessionName)
                + ["terminal", "attach", reference.terminalID],
            interactive: true
        )
    }

    static func sessionList(target: TerminalTarget) throws -> CommandSpec {
        try command(target: target, arguments: ["session", "list", "--json"])
    }

    static func snapshot(target: TerminalTarget, sessionName: String?) throws -> CommandSpec {
        if let sessionName { try validateSessionName(sessionName) }
        return try command(
            target: target,
            arguments: sessionArguments(sessionName) + ["api", "snapshot"]
        )
    }

    public static func validate(_ reference: HerdrTerminalReference) throws {
        if let name = reference.sessionName { try validateSessionName(name) }
        try validateID(reference.terminalID)
    }

    static func validateSessionName(_ value: String) throws {
        guard matches(value, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#) else {
            throw HerdrError.invalidIdentifier
        }
    }

    static func validateID(_ value: String) throws {
        guard matches(value, #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#) else {
            throw HerdrError.invalidIdentifier
        }
    }

    static func validatePath(_ value: String) throws {
        guard value.hasPrefix("/"), value.utf8.count <= 16_384,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw HerdrError.invalidPath }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func sessionArguments(_ name: String?) -> [String] {
        name.map { ["--session", $0] } ?? []
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression)
            == value.startIndex..<value.endIndex
    }

    private static func command(
        target: TerminalTarget, arguments: [String], interactive: Bool = false
    ) throws -> CommandSpec {
        switch target {
        case .local:
            guard let executable = LocalHerdrResolver.resolve() else {
                throw HerdrError.notInstalled
            }
            // App launches from a Herdr pane must not inherit that pane's server.
            return CommandSpec(
                executable: "/usr/bin/env",
                arguments: ["-u", "HERDR_SESSION", "-u", "HERDR_SOCKET_PATH", executable]
                    + arguments
            )
        case let .ssh(destination):
            guard IdentifierValidator.isSSHDestination(destination) else {
                throw CommandValidationError.invalidSSHDestination
            }
            let options = interactive
                ? ["-tt", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
                : ["-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            let script = """
                unset HERDR_SESSION HERDR_SOCKET_PATH
                herdr_binary=''
                for herdr_candidate in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr /usr/bin/herdr; do
                    if [ -x "$herdr_candidate" ]; then herdr_binary="$herdr_candidate"; break; fi
                done
                if [ -z "$herdr_binary" ]; then herdr_binary=$(command -v herdr 2>/dev/null) || exit 127; fi
                if [ -z "$herdr_binary" ] || [ ! -x "$herdr_binary" ]; then exit 127; fi
                exec "$herdr_binary" \(arguments.map(shellQuote).joined(separator: " "))
                """
            // Always use a known POSIX shell, regardless of the SSH login shell.
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: options + [destination, "exec /bin/sh -c " + shellQuote(script)]
            )
        }
    }
}

enum LocalHerdrResolver {
    static func resolve() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/usr/bin/herdr"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { String($0) + "/herdr" }
        return paths.first {
            (try? HerdrCommands.validatePath($0)) != nil
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}

enum HerdrParser {
    struct Session: Equatable, Sendable {
        let name: String
        let sessionName: String?
    }

    static func sessions(_ json: String) throws -> [Session] {
        let response: SessionsResponse = try decode(json)
        var seen = Set<String>()
        var sessions: [Session] = []
        for value in response.sessions {
            try HerdrCommands.validateSessionName(value.name)
            let name = value.isDefault ? nil : value.name
            guard seen.insert(name ?? "default").inserted else {
                throw HerdrError.malformedResponse
            }
            if value.running { sessions.append(Session(name: value.name, sessionName: name)) }
        }
        return sessions
    }

    static func snapshot(_ json: String, sessionName: String?) throws -> HerdrSessionSnapshot {
        if let sessionName { try HerdrCommands.validateSessionName(sessionName) }
        let response: SnapshotResponse = try decode(json)
        if let error = response.error { throw apiError(error.code) }
        guard let snapshot = response.result?.snapshot else {
            throw HerdrError.malformedResponse
        }
        var workspaceIDs = Set<String>()
        for workspace in snapshot.workspaces {
            try HerdrCommands.validateID(workspace.workspaceID)
            guard workspaceIDs.insert(workspace.workspaceID).inserted else {
                throw HerdrError.malformedResponse
            }
            if let cwd = workspace.cwd { try HerdrCommands.validatePath(cwd) }
        }
        var paneIDs = Set<String>()
        var terminalIDs = Set<String>()
        var panesByWorkspace: [String: [HerdrPaneRecord]] = [:]
        for pane in snapshot.panes {
            try HerdrCommands.validateID(pane.paneID)
            try HerdrCommands.validateID(pane.terminalID)
            try HerdrCommands.validateID(pane.workspaceID)
            if let cwd = pane.cwd { try HerdrCommands.validatePath(cwd) }
            if let cwd = pane.foregroundCwd { try HerdrCommands.validatePath(cwd) }
            guard workspaceIDs.contains(pane.workspaceID),
                paneIDs.insert(pane.paneID).inserted,
                terminalIDs.insert(pane.terminalID).inserted
            else { throw HerdrError.malformedResponse }
            let agent = displayText(pane.agent)
            let label = displayText(pane.label) ?? displayText(pane.terminalTitleStripped)
                ?? displayText(pane.terminalTitle) ?? agent ?? pane.paneID
            panesByWorkspace[pane.workspaceID, default: []].append(HerdrPaneRecord(
                reference: .init(sessionName: sessionName, terminalID: pane.terminalID),
                paneID: pane.paneID,
                workspaceID: pane.workspaceID,
                cwd: pane.cwd,
                foregroundCwd: pane.foregroundCwd,
                agent: agent,
                agentStatus: displayText(pane.agentStatus),
                occupantID: try pane.agentSession?.identity(),
                label: label
            ))
        }
        let workspaces = snapshot.workspaces.map { workspace in
            let panes = panesByWorkspace[workspace.workspaceID, default: []]
            return HerdrWorkspaceRecord(
                id: workspace.workspaceID,
                label: displayText(workspace.label) ?? workspace.workspaceID,
                cwd: workspace.cwd ?? panes.first?.cwd,
                panes: panes
            )
        }
        return HerdrSessionSnapshot(
            name: sessionName ?? "default", sessionName: sessionName, workspaces: workspaces
        )
    }

    static func resolve(
        _ reference: HerdrTerminalReference, in snapshot: HerdrSessionSnapshot
    ) throws -> HerdrPaneRecord {
        try HerdrCommands.validate(reference)
        guard snapshot.sessionName == reference.sessionName,
            let pane = snapshot.workspaces.lazy.flatMap(\.panes).first(where: {
                $0.reference == reference
            })
        else { throw HerdrError.terminalUnavailable }
        return pane
    }

    static func commandError(_ output: InventoryProcessOutput) -> HerdrError {
        if output.exitCode == 127 { return .notInstalled }
        for text in [output.stderr, output.stdout] {
            if let response = try? JSONDecoder().decode(ErrorResponse.self, from: Data(text.utf8)),
                let code = response.error?.code {
                return apiError(code)
            }
        }
        return .commandFailed(exitCode: output.exitCode)
    }

    private static func apiError(_ code: String) -> HerdrError {
        switch code {
        case "not_found", "terminal_not_found", "agent_not_running": .terminalUnavailable
        case "method_not_found", "unsupported_method", "unsupported": .unsupportedOperation
        case "connection_failed", "server_unavailable", "no_server": .serverUnavailable
        default: .serverUnavailable
        }
    }

    private static func displayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let safe = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? nil : String(safe.prefix(256))
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        guard json.utf8.count <= 16 * 1_024 * 1_024 else { throw HerdrError.malformedResponse }
        do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
        catch { throw HerdrError.malformedResponse }
    }

    private struct SessionsResponse: Decodable { let sessions: [SessionInfo] }
    private struct SessionInfo: Decodable {
        let name: String
        let isDefault: Bool
        let running: Bool
        enum CodingKeys: String, CodingKey { case name, isDefault = "default", running }
    }
    private struct APIError: Decodable { let code: String }
    private struct ErrorResponse: Decodable { let error: APIError? }
    private struct SnapshotResponse: Decodable {
        let result: SnapshotResult?
        let error: APIError?
    }
    private struct SnapshotResult: Decodable { let snapshot: SnapshotInfo }
    private struct SnapshotInfo: Decodable {
        let workspaces: [WorkspaceInfo]
        let panes: [PaneInfo]
    }
    private struct WorkspaceInfo: Decodable {
        let workspaceID: String
        let label: String?
        let cwd: String?
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", label, cwd }
    }
    private struct PaneInfo: Decodable {
        let paneID: String
        let terminalID: String
        let workspaceID: String
        let cwd: String?
        let foregroundCwd: String?
        let agent: String?
        let agentStatus: String?
        let agentSession: AgentSessionInfo?
        let label: String?
        let terminalTitle: String?
        let terminalTitleStripped: String?
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", terminalID = "terminal_id", workspaceID = "workspace_id"
            case cwd, foregroundCwd = "foreground_cwd", agent, agentStatus = "agent_status", label
            case agentSession = "agent_session"
            case terminalTitle = "terminal_title", terminalTitleStripped = "terminal_title_stripped"
        }
    }

    private struct AgentSessionInfo: Decodable {
        let source: String
        let agent: String
        let kind: String
        let value: String

        func identity() throws -> String {
            let fields = [source, agent, kind, value]
            guard fields.allSatisfy({ field in
                !field.isEmpty && field.utf8.count <= 16_384
                    && !field.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) else { throw HerdrError.malformedResponse }
            // Keep the namespace and kind: an ID and a transcript path can share
            // the same text. This is opaque equality data, never a command/path.
            return String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        }
    }
}

/// Discovery never starts, updates, focuses, or stops a Herdr server or terminal.
public actor HerdrService {
    private let sshMasterPool: SSHMasterPool?
    private let processRunner: any InventoryProcessRunning
    private let queryPolicy = BoundedAsyncOperationRunner(
        maxConcurrentOperations: 4, timeout: .seconds(25)
    )

    public init(sshMasterPool: SSHMasterPool) {
        self.sshMasterPool = sshMasterPool
        processRunner = FoundationInventoryProcessRunner()
    }

    init(processRunner: any InventoryProcessRunning, sshMasterPool: SSHMasterPool? = nil) {
        self.sshMasterPool = sshMasterPool
        self.processRunner = processRunner
    }

    public func discover(target: TerminalTarget) async throws -> [HerdrSessionSnapshot] {
        let list = try await run(HerdrCommands.sessionList(target: target), target: target)
        let sessions = try HerdrParser.sessions(list.stdout)
        guard !sessions.isEmpty else { throw HerdrError.noRunningSessions }
        var snapshots: [HerdrSessionSnapshot] = []
        for session in sessions {
            try Task.checkCancellation()
            let output = try await run(
                HerdrCommands.snapshot(target: target, sessionName: session.sessionName), target: target
            )
            snapshots.append(try HerdrParser.snapshot(output.stdout, sessionName: session.sessionName))
        }
        return snapshots
    }

    public func resolve(
        target: TerminalTarget, reference: HerdrTerminalReference
    ) async throws -> HerdrPaneRecord {
        try HerdrCommands.validate(reference)
        let output = try await run(
            HerdrCommands.snapshot(target: target, sessionName: reference.sessionName), target: target
        )
        return try HerdrParser.resolve(
            reference, in: HerdrParser.snapshot(output.stdout, sessionName: reference.sessionName)
        )
    }

    private func run(_ command: CommandSpec, target: TerminalTarget) async throws -> InventoryProcessOutput {
        let pool = sshMasterPool
        let runner = processRunner
        return try await queryPolicy.run {
            let output: InventoryProcessOutput
            if let alias = target.sshDestination, let pool {
                output = try await pool.run(command, alias: alias, replay: .readOnly)
            } else {
                output = try await runner.run(command)
            }
            guard output.exitCode == 0 else { throw HerdrParser.commandError(output) }
            return output
        }
    }
}
