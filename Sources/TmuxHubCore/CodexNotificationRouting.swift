import Foundation

/// A private cluster address resolved through its configured, authenticated
/// login alias. Host keys remain checked against the configured cluster host.
public struct CodexNotificationSSHEndpoint: Codable, Hashable, Sendable {
    public let destination: String
    public let address: String
    public let hostKeyAlias: String

    public var isValid: Bool {
        guard IdentifierValidator.isSSHDestination(destination),
            Self.cluster(hostKeyAlias) != nil else { return false }
        let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let numbers = pieces.compactMap { piece -> Int? in
            guard let number = Int(piece), (0...255).contains(number), String(number) == piece else { return nil }
            return number
        }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1]))
            || (numbers[0] == 192 && numbers[1] == 168)
    }

    static func cluster(_ hostname: String) -> String? {
        ["hpc2", "hpc3", "hpc4"].first { hostname.lowercased() == "\($0)login.hpc.hkust-gz.edu.cn" }
    }

    static func matches(loginHostname: String, configuredHostname: String) -> Bool {
        guard let cluster = cluster(configuredHostname) else { return false }
        // HPC2 and HPC3 report their internal node names instead of the public
        // cluster name. Keep these aliases scoped to their configured cluster.
        var prefixes = [cluster + "-login-"]
        if cluster == "hpc2" { prefixes.append("mgmt-") }
        if cluster == "hpc3" { prefixes.append("acd-login-") }
        let hostname = loginHostname.lowercased()
        return prefixes.contains { prefix in
            guard hostname.hasPrefix(prefix) else { return false }
            let number = hostname.dropFirst(prefix.count)
            return !number.isEmpty && number.count <= 3 && number.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    var sshOptions: [String] {
        ["-o", "HostName=\(address)", "-o", "HostKeyAlias=\(hostKeyAlias)",
         "-o", "StrictHostKeyChecking=yes"]
    }
}

/// A notification refers to one existing tmux server/pane, never a command to run.
public struct CodexNotificationRoute: Codable, Hashable, Sendable {
    public let hostname: String
    public let socket: String
    public let sessionID: String
    public let sessionCreated: Int
    public let serverPID: Int
    public let pane: String
    public private(set) var sshEndpoint: CodexNotificationSSHEndpoint?

    public init(event: CodexNotificationEvent) throws {
        guard let socket = event.tmuxSocket,
            let sessionID = event.tmuxSessionID,
            let sessionCreated = event.tmuxSessionCreated,
            let serverPID = event.tmuxServerPID,
            let pane = event.tmuxPane
        else { throw CodexNotificationRoutingError.unavailable }
        hostname = event.hostname
        self.socket = socket
        self.sessionID = sessionID
        self.sessionCreated = sessionCreated
        self.serverPID = serverPID
        self.pane = pane
        guard isValid else { throw CodexNotificationRoutingError.unavailable }
    }

    public var isValid: Bool {
        !hostname.isEmpty && hostname.count <= 255
            && socket.hasPrefix("/") && socket.utf8.count <= 4096
            && !socket.contains("\0")
            && IdentifierValidator.isTmuxSessionID(sessionID)
            && pane.first == "%" && !pane.dropFirst().isEmpty
            && pane.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
            && sessionCreated > 0 && serverPID > 0
            && (sshEndpoint.map { $0.isValid && CodexNotificationSSHEndpoint.matches(
                loginHostname: hostname, configuredHostname: $0.hostKeyAlias) } ?? true)
    }

    public func isSameSession(as other: Self) -> Bool {
        hostname == other.hostname && socket == other.socket
            && sessionID == other.sessionID && sessionCreated == other.sessionCreated
            && serverPID == other.serverPID
    }

    func pinned(to endpoint: CodexNotificationSSHEndpoint) -> Self {
        var copy = self
        copy.sshEndpoint = endpoint
        return copy
    }
}

public enum CodexNotificationRoutingError: LocalizedError {
    case unavailable
    case commandFailed

    public var errorDescription: String? {
        "原终端已不可用，或通知来自这台主机之外的计算节点。请在通知记录中查看主机和会话。"
    }
}

public enum CodexNotificationRouting {
    public static func prepare(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) async throws {
        let pool = try connectionPool(route: route, target: target, sshMasterPool: sshMasterPool)
        guard let destination = target.sshDestination else { return }
        guard await pool.prepare(alias: destination, priority: .foreground) == .ready else {
            throw CodexNotificationRoutingError.commandFailed
        }
    }

    public static func managedAttachCommand(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) throws -> CommandSpec {
        let command = try command(route: route, target: target, attach: true)
        guard let destination = target.sshDestination else { return command }
        return try connectionPool(route: route, target: target, sshMasterPool: sshMasterPool)
            .managedCommand(command, alias: destination)
    }

    /// Shared cluster home directories contain notifications from every login
    /// node, while the SSH entry point may send this connection to another one.
    public static func resolveAndFocus(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) async throws -> CodexNotificationRoute {
        try await resolveAndFocus(route: route, target: target, sshMasterPool: sshMasterPool,
            propertiesReader: SSHHostPropertiesReader())
    }

    static func resolveAndFocus(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool,
        propertiesReader: SSHHostPropertiesReader
    ) async throws -> CodexNotificationRoute {
        let output = try await runFocus(route: route, target: target, sshMasterPool: sshMasterPool)
        guard output.exitCode == 0 || output.exitCode == 21 else {
            throw CodexNotificationRoutingError.commandFailed
        }
        guard route.sshEndpoint == nil, let destination = target.sshDestination else {
            guard output.exitCode == 0 else { throw CodexNotificationRoutingError.commandFailed }
            return route
        }
        let properties: SSHHostProperties
        do { properties = try await propertiesReader.load(destination: destination) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // A successful ordinary SSH route does not depend on configuration
            // introspection; only cluster node recovery needs this information.
            if output.exitCode == 0 { return route }
            throw error
        }
        guard CodexNotificationSSHEndpoint.matches(
            loginHostname: route.hostname, configuredHostname: properties.hostname
        ) else {
            if output.exitCode == 0 { return route }
            throw CodexNotificationRoutingError.unavailable
        }
        // Pin recognized cluster nodes even when the current alias master is
        // already on the right node: its replacement may land elsewhere later.
        let resolver = try resolutionCommand(hostname: route.hostname, destination: destination)
        let resolution = BoundedAsyncOperationRunner(maxConcurrentOperations: 1, timeout: .seconds(15))
        let resolved = try await resolution.run {
            try await sshMasterPool.run(resolver, alias: destination, replay: .readOnly)
        }
        let endpoints = try parseEndpoints(resolved, destination: destination, configuredHostname: properties.hostname)
        for endpoint in endpoints {
            try Task.checkCancellation()
            let candidate = route.pinned(to: endpoint)
            do {
                let result = try await runFocus(route: candidate, target: target, sshMasterPool: sshMasterPool)
                if result.exitCode == 0 { return candidate }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw CodexNotificationRoutingError.commandFailed
    }

    public static func focus(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) async throws {
        let output = try await runFocus(route: route, target: target, sshMasterPool: sshMasterPool)
        guard output.exitCode == 0 else { throw CodexNotificationRoutingError.commandFailed }
    }

    private static func runFocus(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) async throws -> InventoryProcessOutput {
        let command = try command(route: route, target: target, attach: false)
        let pool = try connectionPool(route: route, target: target, sshMasterPool: sshMasterPool)
        let runner = BoundedAsyncOperationRunner(maxConcurrentOperations: 1, timeout: .seconds(20))
        return try await runner.run {
            if let destination = target.sshDestination {
                return try await pool.run(command, alias: destination, replay: .never)
            }
            return try await TimedInventoryProcessRunner(timeout: .seconds(15),
                underlying: FoundationInventoryProcessRunner()).run(command)
        }
    }

    static func connectionPool(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) throws -> SSHMasterPool {
        guard route.isValid else { throw CodexNotificationRoutingError.unavailable }
        guard let endpoint = route.sshEndpoint else { return sshMasterPool }
        guard endpoint.destination == target.sshDestination else { throw CodexNotificationRoutingError.unavailable }
        return try sshMasterPool.pinned(to: endpoint)
    }

    static func resolutionCommand(hostname: String, destination: String) throws -> CommandSpec {
        guard IdentifierValidator.isSSHDestination(destination),
            hostname.utf8.count <= 255,
            hostname.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { throw CodexNotificationRoutingError.unavailable }
        let script = "import json,socket,sys; print(json.dumps(sorted({v[4][0] for v in socket.getaddrinfo(sys.argv[1],22,socket.AF_INET,socket.SOCK_STREAM)})[:4]))"
        return CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", destination,
            ["python3", "-c", script, hostname].map(quote).joined(separator: " "),
        ])
    }

    static func parseEndpoints(
        _ output: InventoryProcessOutput, destination: String, configuredHostname: String
    ) throws -> [CodexNotificationSSHEndpoint] {
        guard output.exitCode == 0, output.stdout.utf8.count <= 1_024,
            let data = output.stdout.data(using: .utf8),
            let addresses = try? JSONDecoder().decode([String].self, from: data),
            (1...4).contains(addresses.count) else { throw CodexNotificationRoutingError.unavailable }
        let endpoints = addresses.map { CodexNotificationSSHEndpoint(
            destination: destination, address: $0, hostKeyAlias: configuredHostname
        ) }
        guard endpoints.allSatisfy(\.isValid) else { throw CodexNotificationRoutingError.unavailable }
        return endpoints
    }

    public static func command(
        route: CodexNotificationRoute,
        target: TerminalTarget,
        attach: Bool
    ) throws -> CommandSpec {
        try command(route: route, target: target, mode: attach ? "attach" : "focus")
    }

    /// Read the active pane in the original session without changing focus.
    public static func contextCommand(
        route: CodexNotificationRoute, target: TerminalTarget
    ) throws -> CommandSpec {
        try command(route: route, target: target, mode: "context")
    }

    private static func command(
        route: CodexNotificationRoute, target: TerminalTarget, mode: String
    ) throws -> CommandSpec {
        guard route.isValid,
            route.sshEndpoint == nil || route.sshEndpoint?.destination == target.sshDestination
        else { throw CodexNotificationRoutingError.unavailable }
        let data = try JSONEncoder().encode(route)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw CodexNotificationRoutingError.unavailable
        }
        let arguments = ["python3", "-c", script, payload, mode]
        if let destination = target.sshDestination {
            guard IdentifierValidator.isSSHDestination(destination) else {
                throw CommandValidationError.invalidSSHDestination
            }
            return CommandSpec(executable: "/usr/bin/ssh", arguments: [
                mode == "attach" ? "-tt" : "-nT", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=3", destination,
                arguments.map(quote).joined(separator: " "),
            ])
        }
        return CommandSpec(executable: "/usr/bin/env", arguments: arguments,
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")])
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // All event fields are argv/JSON data. Check the original server identity
    // before selecting anything, including after app restart and on another Mac.
    static let script = #"""
import json, os, shutil, socket, subprocess, sys
try:
    route = json.loads(sys.argv[1])
    if socket.gethostname() != route['hostname']:
        print('通知来自另一台登录节点。', file=sys.stderr)
        sys.exit(21)
    tmux = shutil.which('tmux')
    if not tmux:
        raise ValueError('tmux unavailable')
    base = [tmux, '-S', route['socket']]
    if sys.argv[2] == 'context':
        # The user may have switched panes or closed the notification's pane.
        # Resolve the current pane by immutable session identity, never its name.
        result = subprocess.run(base + ['display-message', '-p', '-t', route['sessionID'] + ':',
            '#{pid}\t#{session_id}\t#{session_created}\t#{pane_id}\t#{pane_current_command}\t#{pane_current_path}'],
            capture_output=True, text=True, timeout=5, check=True)
        output = result.stdout[:-1] if result.stdout.endswith('\n') else result.stdout
        fields = output.split('\t')
        if len(fields) != 6 or fields[:3] != [str(route['serverPID']), route['sessionID'],
                str(route['sessionCreated'])]:
            raise ValueError('original session no longer exists')
        print('\t'.join(fields[3:]))
        sys.exit(0)
    result = subprocess.run(base + ['display-message', '-p', '-t', route['pane'],
        '#{pid}|#{session_id}|#{session_created}|#{pane_id}|#{window_id}'],
        capture_output=True, text=True, timeout=5, check=True)
    fields = result.stdout.strip().split('|')
    if len(fields) != 5 or fields[:4] != [str(route['serverPID']), route['sessionID'],
            str(route['sessionCreated']), route['pane']]:
        raise ValueError('original session no longer exists')
    subprocess.run(base + ['select-window', '-t', route['sessionID'] + ':' + fields[4]],
        capture_output=True, timeout=5, check=True)
    subprocess.run(base + ['select-pane', '-t', route['pane']],
        capture_output=True, timeout=5, check=True)
    if sys.argv[2] == 'attach':
        os.execv(tmux, base + ['attach-session', '-t', route['sessionID']])
except Exception:
    print('原 tmux 终端不可用；未创建新会话。', file=sys.stderr)
    sys.exit(1)
"""#
}
