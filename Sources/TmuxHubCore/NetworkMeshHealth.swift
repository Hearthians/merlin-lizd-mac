import Foundation

public enum NetworkMeshHealthStatus: String, Codable, CaseIterable, Sendable {
    case online, networkOnly, unreachable, authenticationRequired, hostKeyFailure, unsupported, cancelled

    public var displayName: String {
        switch self {
        case .online: "SSH 登录成功"
        case .networkOnly: "SSH 端口有响应"
        case .unreachable: "本次未连通"
        case .authenticationRequired: "需要认证"
        case .hostKeyFailure: "需要核对指纹"
        case .unsupported: "探测不受支持"
        case .cancelled: "已取消"
        }
    }
}

public struct NetworkMeshHealthResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var endpointID: UUID
    public var status: NetworkMeshHealthStatus
    public var message: String
    public var checkedAt: Date

    public var sshAuthenticated: Bool { status == .online }
    public var networkResponded: Bool {
        status == .online || status == .networkOnly || status == .authenticationRequired || status == .hostKeyFailure
    }

    public init(
        id: UUID = UUID(), hostID: UUID, endpointID: UUID, status: NetworkMeshHealthStatus,
        message: String, checkedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.endpointID = endpointID
        self.status = status
        self.message = message
        self.checkedAt = checkedAt
    }
}

/// Fresh per-entry health observations, kept separate from member-to-member SSH authorization.
public struct NetworkMeshHealthService: Sendable {
    private let runner: any InventoryProcessRunning

    public init(timeoutSeconds: Double = 5, maxConcurrentChecks: Int = 4) {
        self.init(runner: FoundationInventoryProcessRunner(), timeoutSeconds: timeoutSeconds,
                  maxConcurrentChecks: maxConcurrentChecks)
    }

    init(runner: any InventoryProcessRunning, timeoutSeconds: Double = 5, maxConcurrentChecks: Int = 4) {
        let timeout = timeoutSeconds.isFinite ? min(max(timeoutSeconds, 0.01), 30) : 5
        self.runner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(maxConcurrentChecks, 1),
            underlying: TimedInventoryProcessRunner(timeout: .seconds(timeout), underlying: runner)
        )
    }

    public func check(host: NetworkMeshHost, endpoint: NetworkMeshEndpoint) async -> NetworkMeshHealthResult {
        func result(_ status: NetworkMeshHealthStatus, _ message: String) -> NetworkMeshHealthResult {
            .init(hostID: host.id, endpointID: endpoint.id, status: status, message: message)
        }
        do {
            try Task.checkCancellation()
            let marker = "TMUXHUB_MESH_HEALTH_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let script = endpoint.platform == .windows
                ? "Write-Output " + NetworkMeshCommands.powerShellQuote(marker)
                : "printf '%s\\n' " + NetworkMeshCommands.quote(marker)
            let command = try NetworkMeshCommands.controlCommand(
                endpoint: endpoint,
                remoteCommand: NetworkMeshCommands.remoteCommand(script: script, platform: endpoint.platform)
            )
            var networkFailure = "SSH 本次未连通"
            do {
                let output = try await runner.run(command)
                try Task.checkCancellation()
                if output.exitCode == 0, output.stdout.split(whereSeparator: \.isNewline).contains(Substring(marker)) {
                    return result(.online, "此入口完成非交互 SSH 登录并执行标记命令")
                }
                let diagnostic = networkMeshDiagnostic(output.stderr) ?? "远端未返回登录标记"
                let lowered = output.stderr.lowercased()
                if lowered.contains("host key verification failed") || lowered.contains("remote host identification has changed")
                    || lowered.contains("host key is known") {
                    return result(.hostKeyFailure, "SSH 服务有响应，但指纹需要核对。\(diagnostic)")
                }
                if NetworkMeshProbeParser.isAuthenticationFailure(lowered) {
                    return result(.authenticationRequired, "SSH 服务有响应，但本机尚未完成非交互认证。\(diagnostic)")
                }
                if output.exitCode == 0 {
                    return result(.unsupported, "SSH 命令结束但没有正确的登录标记，无法确认所选环境")
                }
                networkFailure = diagnostic
            } catch InventoryProcessTimeoutError.timedOut {
                networkFailure = "SSH 本次探测超时"
            }
            try Task.checkCancellation()
            let config = try SSHHostConfiguration(alias: "mesh-health", hostname: endpoint.address, port: endpoint.port)
            let tcp = try await runner.run(CommandSpec(
                executable: "/usr/bin/nc", arguments: ["-z", "-w", "2", config.hostname, String(config.port)],
                environment: NetworkMeshCommands.environment
            ))
            try Task.checkCancellation()
            if tcp.exitCode == 0 {
                return result(.networkOnly, "此入口 TCP 端口有响应；尚未验证 SSH 登录。\(networkFailure)")
            }
            return result(.unreachable, "本次 SSH 与端口检查未连通，不能据此判断关机。\(networkFailure)")
        } catch is CancellationError {
            return result(.cancelled, "检查已取消")
        } catch InventoryProcessTimeoutError.timedOut {
            return result(.unreachable, "本次检查超时，不能据此判断关机")
        } catch {
            return result(.unsupported, networkMeshDiagnostic(error.localizedDescription) ?? "无法执行检查")
        }
    }
}
