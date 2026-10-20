import Darwin
import Foundation

/// Measures the selected source address to the selected destination address.
/// SSH to a remote source is a control channel only; its duration is never used as RTT or throughput.
public struct NetworkMeshProbeService: Sendable {
    private let runner: any InventoryProcessRunning
    private let bandwidthRunner: any InventoryProcessRunning
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 60, maxConcurrentProbes: Int = 3) {
        self.init(
            runner: FoundationInventoryProcessRunner(), timeoutSeconds: timeoutSeconds,
            maxConcurrentProbes: maxConcurrentProbes
        )
    }

    init(runner: any InventoryProcessRunning, timeoutSeconds: Double = 60, maxConcurrentProbes: Int = 3) {
        let timeout = timeoutSeconds.isFinite ? min(max(timeoutSeconds, 0.01), 600) : 60
        self.timeoutSeconds = timeout
        self.bandwidthRunner = TimedInventoryProcessRunner(timeout: .seconds(timeout), underlying: runner)
        self.runner = BoundedInventoryProcessRunner(
            maxConcurrentProcesses: max(maxConcurrentProbes, 1),
            underlying: TimedInventoryProcessRunner(timeout: .seconds(timeout), underlying: runner)
        )
    }

    public func probe(
        source: NetworkMeshHost, sourceEndpoint: NetworkMeshEndpoint,
        target: NetworkMeshHost, targetEndpoint: NetworkMeshEndpoint, mode: NetworkMeshProbeMode
    ) async -> NetworkMeshProbeResult {
        if mode == .bandwidth {
            return await NetworkMeshBandwidthService(runner: bandwidthRunner).probe(
                source: source, sourceEndpoint: sourceEndpoint, target: target, targetEndpoint: targetEndpoint
            )
        }
        let route = NetworkMeshRoute(
            sourceHostID: source.id, sourceEndpointID: sourceEndpoint.id,
            targetHostID: target.id, targetEndpointID: targetEndpoint.id
        )
        do {
            try Task.checkCancellation()
            let controls: [NetworkMeshEndpoint?] = source.isLocal
                ? [nil] : NetworkMeshCommands.controlEndpoints(for: source, sourceEndpoint: sourceEndpoint).map(Optional.some)
            var lastResult: NetworkMeshProbeResult?
            for control in controls {
                let command = try NetworkMeshCommands.probe(
                    source: source, sourceEndpoint: sourceEndpoint, targetEndpoint: targetEndpoint,
                    mode: mode, controlEndpoint: control
                )
                if let control {
                    let readyScript = sourceEndpoint.platform == .windows
                        ? "Write-Output 'TMUXHUB_MESH_SOURCE_READY'"
                        : "printf '%s\\n' 'TMUXHUB_MESH_SOURCE_READY'"
                    let readyCommand = try NetworkMeshCommands.controlCommand(
                        endpoint: control,
                        remoteCommand: NetworkMeshCommands.remoteCommand(script: readyScript, platform: sourceEndpoint.platform)
                    )
                    let readyOutput: InventoryProcessOutput
                    do {
                        readyOutput = try await runner.run(readyCommand)
                    } catch InventoryProcessTimeoutError.timedOut {
                        lastResult = .init(route: route, mode: mode, status: .unreachable,
                                           message: "来源控制入口本次超时，未产生有效测量")
                        continue
                    }
                    try Task.checkCancellation()
                    if readyOutput.exitCode != 0 || !readyOutput.stdout.contains("TMUXHUB_MESH_SOURCE_READY") {
                        let failedControl = NetworkMeshProbeParser.parse(readyOutput, route: route, mode: mode)
                        lastResult = failedControl
                        if failedControl.status == .unreachable { continue }
                        return failedControl
                    }
                }
                // Once the source can execute commands, timeout/failure belongs to the measured path.
                // It must not silently select a different source control path or source environment.
                let output = try await runner.run(command)
                try Task.checkCancellation()
                return NetworkMeshProbeParser.parse(output, route: route, mode: mode)
            }
            return lastResult ?? .init(route: route, mode: mode, status: .unsupported,
                                       message: "来源环境缺少匹配用户名的 SSH 控制入口")
        } catch is CancellationError {
            return .init(route: route, mode: mode, status: .cancelled, message: "探测已取消")
        } catch InventoryProcessTimeoutError.timedOut {
            return .init(
                route: route, mode: mode, status: .unreachable,
                message: "探测超过 \(Int(timeoutSeconds.rounded(.up))) 秒，已停止；未产生有效测量"
            )
        } catch {
            return .init(
                route: route, mode: mode, status: .unsupported,
                message: networkMeshDiagnostic(error.localizedDescription) ?? "无法执行探测"
            )
        }
    }
}

enum NetworkMeshCommandError: LocalizedError {
    case sourceAddressMustBeIP, missingControlDestination, missingTargetUsername, unsupportedLocalPlatform

    var errorDescription: String? {
        switch self {
        case .sourceAddressMustBeIP: "来源入口必须填写本机网卡上的 IPv4 或 IPv6 地址，才能绑定实际测量路径"
        case .missingControlDestination: "来源主机缺少用于执行探测的 SSH 入口"
        case .missingTargetUsername: "SSH 互通检测与测速需要目标入口的登录用户名"
        case .unsupportedLocalPlatform: "当前 macOS 本机只能执行 POSIX 来源环境；Windows 来源需要通过其 SSH 入口执行"
        }
    }
}

enum NetworkMeshCommands {
    static let transferBytes = 32 * 1024 * 1024
    static let environment = ["LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]

    static func probe(
        source: NetworkMeshHost, sourceEndpoint: NetworkMeshEndpoint,
        targetEndpoint: NetworkMeshEndpoint, mode: NetworkMeshProbeMode,
        controlEndpoint: NetworkMeshEndpoint? = nil
    ) throws -> CommandSpec {
        let validatedSource = try SSHHostConfiguration(alias: "mesh-source", hostname: sourceEndpoint.address)
        let validatedTarget = try SSHHostConfiguration(
            alias: "mesh-target", hostname: targetEndpoint.address,
            username: targetEndpoint.username, port: targetEndpoint.port
        )
        let family = try addressFamily(validatedSource.hostname)
        if validatedTarget.username.isEmpty {
            throw NetworkMeshCommandError.missingTargetUsername
        }
        let script: String
        if sourceEndpoint.platform == .windows {
            script = windowsScript(sourceAddress: validatedSource.hostname, targetAddress: validatedTarget.hostname,
                                   targetUsername: validatedTarget.username, targetPort: validatedTarget.port,
                                   family: family, mode: mode, targetPlatform: targetEndpoint.platform)
        } else {
            script = makeScript(sourceAddress: validatedSource.hostname, targetAddress: validatedTarget.hostname,
                                targetUsername: validatedTarget.username, targetPort: validatedTarget.port,
                                family: family, mode: mode, targetPlatform: targetEndpoint.platform)
        }
        if source.isLocal {
            guard sourceEndpoint.platform == .posix else {
                throw NetworkMeshCommandError.unsupportedLocalPlatform
            }
            return CommandSpec(executable: "/bin/sh", arguments: ["-c", script], environment: environment)
        }
        let control = controlEndpoint ?? controlEndpoints(for: source, sourceEndpoint: sourceEndpoint).first
        guard let control else { throw NetworkMeshCommandError.missingControlDestination }
        return try controlCommand(endpoint: control, remoteCommand: remoteCommand(script: script, platform: sourceEndpoint.platform))
    }

    static func controlEndpoints(for host: NetworkMeshHost, sourceEndpoint: NetworkMeshEndpoint) -> [NetworkMeshEndpoint] {
        let candidates = host.endpoints.filter {
            $0.environmentID == sourceEndpoint.environmentID && $0.username == sourceEndpoint.username
                && $0.platform == sourceEndpoint.platform
        }
        let sorted = candidates.sorted {
            let lhs = networkPriority($0.networkKind), rhs = networkPriority($1.networkKind)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        return sorted.isEmpty ? [sourceEndpoint] : sorted
    }

    static func networkPriority(_ kind: NetworkMeshNetworkKind) -> Int {
        switch kind { case .campus: 0; case .zeroTier: 1; case .lan: 2; case .publicInternet: 3; case .other: 4 }
    }

    static func controlCommand(endpoint: NetworkMeshEndpoint, remoteCommand: String) throws -> CommandSpec {
        let config = try SSHHostConfiguration(alias: "mesh-control", hostname: endpoint.address,
                                              username: endpoint.username, port: endpoint.port)
        let addressDestination = config.hostname.contains(":") ? "[\(config.hostname)]" : config.hostname
        let destination = endpoint.sshDestination.isEmpty ? addressDestination : endpoint.sshDestination
        guard IdentifierValidator.isSSHDestination(destination) else { throw SSHHostConfigurationError.invalidDestination }
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
                         "-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=1",
                         "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
                         "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "Hostname=\(config.hostname.replacingOccurrences(of: "%", with: "%%"))",
                         "-p", String(config.port)]
        if !config.username.isEmpty { arguments += ["-l", config.username] }
        arguments += ["--", destination, remoteCommand]
        return CommandSpec(executable: "/usr/bin/ssh", arguments: arguments, environment: environment)
    }

    static func remoteCommand(script: String, platform: NetworkMeshPlatform) -> String {
        platform == .posix ? "/bin/sh -c " + quote(script)
            : "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + encodedPowerShell(script)
    }

    static func encodedPowerShell(_ script: String) -> String {
        Data(script.utf16.flatMap { [UInt8($0 & 0xff), UInt8(($0 >> 8) & 0xff)] }).base64EncodedString()
    }

    static func addressFamily(_ address: String) throws -> String {
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return "-4" }
        var ipv6 = in6_addr()
        // An IPv6 zone is retained for binding while inet_pton validates the address itself.
        let literal = String(address.split(separator: "%", maxSplits: 1)[0])
        if literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return "-6" }
        throw NetworkMeshCommandError.sourceAddressMustBeIP
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func directSSHArguments(
        sourceAddress: String, targetAddress: String, targetUsername: String, targetPort: Int, family: String
    ) -> [String] {
        [family, "-T", "-F", "/dev/null", "-b", sourceAddress,
         "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
         "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
         "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes",
         "-o", "UserKnownHostsFile=~/.ssh/tmuxhub_mesh_known_hosts",
         "-o", "Compression=no", "-o", "ForwardAgent=no",
         "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "ControlMaster=no",
         "-o", "ControlPath=none", "-o", "ControlPersist=no", "-l", targetUsername,
         "-p", String(targetPort), "--", targetAddress]
    }

    static func targetScript(mode: NetworkMeshProbeMode, platform: NetworkMeshPlatform) -> String {
        if platform == .windows {
            if mode == .connectivity { return "Write-Output 'TMUXHUB_MESH_TARGET_LOGIN'" }
            return """
            $ErrorActionPreference = 'Stop'
            Write-Output 'TMUXHUB_MESH_TARGET_LOGIN'
            $stream = [Console]::OpenStandardInput()
            $buffer = New-Object byte[] 65536
            $bytes = [long]0
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $bytes += $count }
            $watch.Stop()
            $seconds = $watch.Elapsed.TotalSeconds.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
            Write-Output ('TMUXHUB_MESH_WINDOWS_TRANSFER=' + $bytes + '/' + $seconds)
            """
        }
        if mode == .connectivity { return "printf '%s\\n' 'TMUXHUB_MESH_TARGET_LOGIN'" }
        return """
        export LC_ALL=C
        if ! command -v dd >/dev/null 2>&1; then
            printf '%s\\n' 'TMUXHUB_MESH_UNSUPPORTED:目标主机缺少 dd，无法测量 SSH 吞吐'
            exit 69
        fi
        printf '%s\\n' 'TMUXHUB_MESH_TARGET_LOGIN'
        dd of=/dev/null bs=1048576
        """
    }

    static func makeScript(
        sourceAddress: String, targetAddress: String, targetUsername: String,
        targetPort: Int, family: String, mode: NetworkMeshProbeMode,
        targetPlatform: NetworkMeshPlatform = .posix
    ) -> String {
        let source = quote(sourceAddress), target = quote(targetAddress)
        let ready = "printf '%s\\n' 'TMUXHUB_MESH_SOURCE_READY'\nexport LC_ALL=C\n"
        var tokens = directSSHArguments(sourceAddress: sourceAddress, targetAddress: targetAddress,
                                        targetUsername: targetUsername, targetPort: targetPort, family: family)
        if mode == .connectivity { tokens.insert("-n", at: 0) }
        let destinationIndex = tokens.count - 1
        tokens.insert(contentsOf: ["-i", "$MESH_KEY"], at: destinationIndex - 1)
        let ssh = "ssh " + tokens.map { $0 == "$MESH_KEY" ? "\"$HOME/.ssh/tmuxhub_mesh_ed25519\"" : quote($0) }.joined(separator: " ")
        let targetCommand = quote(remoteCommand(script: targetScript(mode: mode, platform: targetPlatform), platform: targetPlatform))
        let check = """
        if ! command -v ssh >/dev/null 2>&1; then
            printf '%s\\n' 'TMUXHUB_MESH_UNSUPPORTED:来源主机缺少 ssh，无法验证互通登录'
            exit 69
        fi

        """
        switch mode {
        case .bandwidth: return ready
        case .connectivity:
            return ready + check + """
            \(ssh) \(targetCommand)
            login_status=$?
            printf '\\nTMUXHUB_MESH_LOGIN_EXIT=%s\\n' "$login_status"
            if [ "$login_status" -ne 0 ]; then exit "$login_status"; fi
            if command -v ping >/dev/null 2>&1; then
                case "$(uname -s)" in
                    Linux) ping \(family) -n -c 3 -i 0.2 -I \(source) -W 1 -w 4 \(target) 2>&1 || true ;;
                    Darwin) \(family == "-4" ? "ping -n -c 3 -i 0.2 -S \(source) -t 4 \(target) 2>&1 || true" : "true") ;;
                esac
            fi
            """
        case .speed:
            return ready + check + """
            if ! command -v dd >/dev/null 2>&1; then
                printf '%s\\n' 'TMUXHUB_MESH_UNSUPPORTED:来源主机缺少 dd，无法测量 SSH 吞吐'
                exit 69
            fi
            dd if=/dev/zero bs=1048576 count=32 2>/dev/null | \
                \(ssh) \(targetCommand)
            transfer_status=$?
            printf '\\nTMUXHUB_MESH_TRANSFER_EXIT=%s\\n' "$transfer_status"
            exit "$transfer_status"
            """
        }
    }

    static func windowsScript(
        sourceAddress: String, targetAddress: String, targetUsername: String, targetPort: Int,
        family: String, mode: NetworkMeshProbeMode, targetPlatform: NetworkMeshPlatform
    ) -> String {
        var tokens = directSSHArguments(sourceAddress: sourceAddress, targetAddress: targetAddress,
                                        targetUsername: targetUsername, targetPort: targetPort, family: family)
        // On Windows -F uses NUL rather than the POSIX /dev/null path.
        if let index = tokens.firstIndex(of: "/dev/null") { tokens[index] = "NUL" }
        tokens.insert(contentsOf: ["-i", "__MESH_KEY__"], at: tokens.count - 2)
        tokens.append(remoteCommand(script: targetScript(mode: mode, platform: targetPlatform), platform: targetPlatform))
        let argumentExpressions = tokens.map { $0 == "__MESH_KEY__" ? "(Join-Path $env:USERPROFILE '.ssh\\tmuxhub_mesh_ed25519')" : powerShellQuote($0) }.joined(separator: ", ")
        let send = mode == .speed ? """
        $buffer = New-Object byte[] 65536
        for ($i = 0; $i -lt 512; $i++) { $process.StandardInput.BaseStream.Write($buffer, 0, $buffer.Length) }
        """ : ""
        return """
        $ErrorActionPreference = 'Stop'
        Write-Output 'TMUXHUB_MESH_SOURCE_READY'
        $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
        if ($null -eq $ssh) { Write-Output 'TMUXHUB_MESH_UNSUPPORTED:来源 Windows 缺少 OpenSSH 客户端'; exit 69 }
        $tokens = @(\(argumentExpressions))
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $ssh.Source
        $info.Arguments = ($tokens | ForEach-Object { '"' + $_.Replace('"', '\\"') + '"' }) -join ' '
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        try {
            [void]$process.Start()
            try { \(send) } catch { Write-Output ('发送流已结束: ' + $_.Exception.Message) }
            $process.StandardInput.Close()
            $output = $process.StandardOutput.ReadToEnd()
            $errors = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            Write-Output $output
            [Console]::Error.Write($errors)
            Write-Output ('\(mode == .speed ? "TMUXHUB_MESH_TRANSFER_EXIT=" : "TMUXHUB_MESH_LOGIN_EXIT=")' + $process.ExitCode)
            exit $process.ExitCode
        } finally {
            if ($process.Id -and !$process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
        """
    }

    static func powerShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

enum NetworkMeshProbeParser {
    static func isAuthenticationFailure(_ diagnostic: String) -> Bool {
        let text = diagnostic.lowercased()
        return ["permission denied", "authentication failed", "too many authentication failures",
                "no supported authentication methods", "no more authentication methods",
                "authentication refused", "signing failed", "agent refused operation"].contains(where: text.contains)
    }

    static func isNetworkFailure(_ diagnostic: String) -> Bool {
        let text = diagnostic.lowercased()
        guard !isAuthenticationFailure(text),
              !["host key verification failed", "identification has changed", "host key is known",
                "bad configuration", "unknown option", "unrecognized option", "no matching",
                "invalid format", "invalid key", "error in libcrypto"].contains(where: text.contains) else { return false }
        return ["timed out", "timeout", "connection refused", "no route", "network is unreachable",
                "could not resolve", "nodename nor servname", "connection reset", "connection closed",
                "cannot assign requested address", "can't assign requested address", "address not available"]
            .contains(where: text.contains)
    }

    static func parse(
        _ output: InventoryProcessOutput, route: NetworkMeshRoute, mode: NetworkMeshProbeMode
    ) -> NetworkMeshProbeResult {
        let combined = output.stdout + "\n" + output.stderr
        let sourceReady = output.stdout.contains("TMUXHUB_MESH_SOURCE_READY")
        let context = sourceReady ? "来源入口 → 目标入口" : "来源主机 SSH 控制连接"
        let diagnostic = networkMeshDiagnostic(output.stderr) ?? "没有进一步诊断信息"
        let lowered = combined.lowercased()
        func result(_ status: NetworkMeshProbeStatus, _ message: String, latency: Double? = nil, throughput: Double? = nil) -> NetworkMeshProbeResult {
            .init(route: route, mode: mode, status: status, message: message,
                  latencyMilliseconds: latency, throughputMbps: throughput)
        }
        if let marker = combined.range(of: "TMUXHUB_MESH_UNSUPPORTED:") {
            let reason = combined[marker.upperBound...].split(separator: "\n").first.map(String.init) ?? "远端工具不支持探测"
            return result(.unsupported, reason)
        }
        if lowered.contains("host key verification failed") || lowered.contains("remote host identification has changed")
            || (lowered.contains("no ") && lowered.contains("host key is known")) {
            return result(.hostKeyFailure, "\(context)：主机指纹尚未验证或发生变化。\(diagnostic)")
        }
        if isAuthenticationFailure(lowered) {
            return result(.authenticationRequired, "\(context)：需要配置 SSH 密钥认证。\(diagnostic)")
        }
        guard sourceReady else {
            return result(output.exitCode != 0 && isNetworkFailure(combined) ? .unreachable : .unsupported,
                          "\(context)无法执行所选环境的探测命令。\(diagnostic)")
        }
        if lowered.contains("invalid option") || lowered.contains("illegal option") || lowered.contains("unrecognized option") {
            return result(.unsupported, "来源或目标工具不支持绑定来源地址所需的参数。\(diagnostic)")
        }
        switch mode {
        case .bandwidth:
            return result(.unsupported, "网络带宽测量需要 iperf3 探测服务")
        case .connectivity:
            guard output.exitCode == 0, output.stdout.contains("TMUXHUB_MESH_TARGET_LOGIN"),
                  output.stdout.contains("TMUXHUB_MESH_LOGIN_EXIT=0") else {
                return result(.unreachable, "绑定来源入口的非交互 SSH 登录失败；TCP 响应不代表免密互通。\(diagnostic)")
            }
            let latency = averagePingMilliseconds(combined)
            return result(.reachable, latency == nil
                          ? "绑定来源入口的非交互 SSH 登录成功；未返回有效 ICMP RTT"
                          : "绑定来源入口的非交互 SSH 登录成功；时延为该来源地址的 ICMP 平均 RTT", latency: latency)
        case .speed:
            guard output.exitCode == 0, output.stdout.contains("TMUXHUB_MESH_TARGET_LOGIN"),
                  output.stdout.contains("TMUXHUB_MESH_TRANSFER_EXIT=0") else {
                return result(.unreachable, "绑定来源入口的 SSH 传输失败。\(diagnostic)")
            }
            guard let transfer = transferredBytesAndSeconds(combined), transfer.bytes == NetworkMeshCommands.transferBytes else {
                return result(.unsupported, "传输未返回完整 32 MiB 的有效 dd 统计，未产生吞吐数值。\(diagnostic)")
            }
            let mbps = Double(transfer.bytes) * 8 / transfer.seconds / 1_000_000
            guard mbps.isFinite, mbps > 0 else {
                return result(.unsupported, "dd 传输耗时无效，未产生吞吐数值")
            }
            return result(.reachable, "已传输 32 MiB；SSH 应用层吞吐包含加密与主机处理开销，接收端 dd 计时排除控制连接和 SSH 登录", throughput: mbps)
        }
    }

    static func averagePingMilliseconds(_ text: String) -> Double? {
        let pattern = #"(?:round-trip|rtt)\s+min/avg/max/(?:stddev|mdev)\s*=\s*[0-9.]+/([0-9.]+)/[0-9.]+/[0-9.]+\s*ms"#
        guard let values = capture(pattern, in: text), let value = Double(values[0]), value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func transferredBytesAndSeconds(_ text: String) -> (bytes: Int, seconds: Double)? {
        let patterns = [
            #"TMUXHUB_MESH_WINDOWS_TRANSFER=([0-9]+)/([0-9.]+)"#,
            #"([0-9]+) bytes transferred in ([0-9.]+) secs"#,
            #"([0-9]+) bytes[^\n]*?copied,\s*([0-9.]+) s"#,
        ]
        for pattern in patterns {
            if let values = capture(pattern, in: text), let bytes = Int(values[0]),
               let seconds = Double(values[1]), seconds.isFinite, seconds > 0 {
                return (bytes, seconds)
            }
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }
}
