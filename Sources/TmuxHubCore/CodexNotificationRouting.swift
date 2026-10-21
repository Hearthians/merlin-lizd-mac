import Foundation

/// A notification refers to one existing tmux server/pane, never a command to run.
public struct CodexNotificationRoute: Codable, Hashable, Sendable {
    public let hostname: String
    public let socket: String
    public let sessionID: String
    public let sessionCreated: Int
    public let serverPID: Int
    public let pane: String

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
    }

    public func isSameSession(as other: Self) -> Bool {
        hostname == other.hostname && socket == other.socket
            && sessionID == other.sessionID && sessionCreated == other.sessionCreated
            && serverPID == other.serverPID
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
    public static func focus(
        route: CodexNotificationRoute, target: TerminalTarget, sshMasterPool: SSHMasterPool
    ) async throws {
        let command = try command(route: route, target: target, attach: false)
        let runner = BoundedAsyncOperationRunner(maxConcurrentOperations: 1, timeout: .seconds(20))
        let output = try await runner.run {
            if let destination = target.sshDestination {
                return try await sshMasterPool.run(command, alias: destination, replay: .never)
            }
            return try await TimedInventoryProcessRunner(timeout: .seconds(15),
                underlying: FoundationInventoryProcessRunner()).run(command)
        }
        guard output.exitCode == 0 else { throw CodexNotificationRoutingError.commandFailed }
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
        guard route.isValid else { throw CodexNotificationRoutingError.unavailable }
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
        raise ValueError('host changed')
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
