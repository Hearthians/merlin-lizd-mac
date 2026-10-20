import Foundation
import Darwin

public struct NetworkMeshBandwidthService: Sendable {
    private let runner: any InventoryProcessRunning
    private let cleanupRunner: any InventoryProcessRunning
    private let pollMilliseconds: Int

    public init(timeoutSeconds: Double = 25) {
        self.init(runner: FoundationInventoryProcessRunner(), timeoutSeconds: timeoutSeconds)
    }

    init(runner: any InventoryProcessRunning, timeoutSeconds: Double = 25, pollMilliseconds: Int = 100) {
        let timeout = timeoutSeconds.isFinite ? min(max(0.01, timeoutSeconds), 120) : 25
        self.runner = TimedInventoryProcessRunner(timeout: .seconds(timeout), underlying: runner)
        self.cleanupRunner = TimedInventoryProcessRunner(timeout: .seconds(4), underlying: runner)
        self.pollMilliseconds = max(1, pollMilliseconds)
    }

    public func probe(
        source: NetworkMeshHost, sourceEndpoint: NetworkMeshEndpoint,
        target: NetworkMeshHost, targetEndpoint: NetworkMeshEndpoint
    ) async -> NetworkMeshProbeResult {
        let route = NetworkMeshRoute(sourceHostID: source.id, sourceEndpointID: sourceEndpoint.id,
                                     targetHostID: target.id, targetEndpointID: targetEndpoint.id)
        func failure(_ status: NetworkMeshProbeStatus, _ message: String) -> NetworkMeshProbeResult {
            .init(route: route, mode: .bandwidth, status: status, message: message)
        }
        do {
            try Task.checkCancellation()
            try NetworkMeshBandwidthCommands.validate(sourceEndpoint: sourceEndpoint, targetEndpoint: targetEndpoint)
            async let sourceSelection = selectControl(host: source, endpoint: sourceEndpoint)
            async let targetSelection = selectControl(host: target, endpoint: targetEndpoint)
            let (sourceControl, targetControl) = try await (sourceSelection, targetSelection)
            for (name, selection) in [("来源", sourceControl), ("目标", targetControl)] {
                guard selection.output.exitCode == 0, selection.output.stdout.contains("TMUXHUB_IPERF_READY") else {
                    return failure(NetworkMeshBandwidthParser.status(selection.output),
                                   "\(name)：" + NetworkMeshBandwidthParser.diagnostic(selection.output))
                }
            }
            let token = UUID().uuidString
            let serverScript = try NetworkMeshBandwidthCommands.server(
                sourceEndpoint: sourceEndpoint, targetEndpoint: targetEndpoint, token: token
            )
            let clientScript = try NetworkMeshBandwidthCommands.client(sourceEndpoint: sourceEndpoint, targetEndpoint: targetEndpoint)
            let completion = NetworkMeshBandwidthServerCompletion()
            let serverTask = Task {
                do {
                    let output = try await execute(targetControl, script: serverScript, runner: runner)
                    await completion.finish(.success(output))
                    return output
                } catch {
                    await completion.finish(.failure(error))
                    throw error
                }
            }
            let result: NetworkMeshProbeResult
            do {
                result = try await withTaskCancellationHandler {
                    let readinessScript = try NetworkMeshBandwidthCommands.readiness(targetEndpoint: targetEndpoint, token: token)
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(10))
                    var ownedReady = false
                    while clock.now < deadline {
                        try Task.checkCancellation()
                        if let ended = await completion.result() {
                            let output = try ended.get()
                            return failure(NetworkMeshBandwidthParser.status(output),
                                           "目标测速服务在客户端启动前结束：" + NetworkMeshBandwidthParser.diagnostic(output))
                        }
                        let ready = try await execute(targetControl, script: readinessScript, runner: runner)
                        if ready.exitCode == 0, ready.stdout.split(whereSeparator: \.isNewline)
                            .contains(Substring("TMUXHUB_IPERF_OWNED_READY:" + token)) {
                            ownedReady = true
                            break
                        }
                        if ready.exitCode != 0 {
                            return failure(NetworkMeshBandwidthParser.status(ready),
                                           "目标监听所有权检查：" + NetworkMeshBandwidthParser.diagnostic(ready))
                        }
                        try await Task.sleep(for: .milliseconds(pollMilliseconds))
                    }
                    guard ownedReady else {
                        return failure(.unreachable, "目标临时服务未确认监听所有权，未启动客户端")
                    }
                    // Control endpoints are now pinned. A transport failure must not replay server/client creation.
                    let clientOutput = try await execute(sourceControl, script: clientScript, runner: runner)
                    try Task.checkCancellation()
                    guard clientOutput.exitCode == 0 else {
                        return failure(NetworkMeshBandwidthParser.status(clientOutput), NetworkMeshBandwidthParser.diagnostic(clientOutput))
                    }
                    let serverOutput = try await serverTask.value
                    try Task.checkCancellation()
                    guard serverOutput.exitCode == 0 else {
                        return failure(NetworkMeshBandwidthParser.status(serverOutput),
                                       "目标测速服务：" + NetworkMeshBandwidthParser.diagnostic(serverOutput))
                    }
                    let measurement = try NetworkMeshBandwidthParser.measurement(
                        clientOutput.stdout, expectedSource: sourceEndpoint.address, serverText: serverOutput.stdout
                    )
                    return .init(route: route, mode: .bandwidth, status: .reachable,
                                 message: "iperf3 · TCP · 来源地址 \(sourceEndpoint.address) · \(String(format: "%.1f", measurement.seconds)) 秒",
                                 throughputMbps: measurement.mbps)
                } onCancel: {
                    serverTask.cancel()
                }
            } catch is CancellationError {
                result = failure(.cancelled, "已取消")
            } catch InventoryProcessTimeoutError.timedOut {
                result = failure(.unreachable, "带宽测试超时，已停止本次测速")
            } catch {
                result = failure(.unsupported, networkMeshDiagnostic(error.localizedDescription) ?? "无法测量网络带宽")
            }
            serverTask.cancel()
            _ = try? await serverTask.value
            // Detached cleanup remains runnable even when the parent task is cancelled.
            let cleaned = await Task.detached {
                do {
                    let script = try NetworkMeshBandwidthCommands.cleanup(targetEndpoint: targetEndpoint, token: token)
                    var controls = [targetControl]
                    if !target.isLocal {
                        controls += NetworkMeshCommands.controlEndpoints(for: target, sourceEndpoint: targetEndpoint)
                            .filter { $0.id != targetControl.endpoint.id }
                            .map { NetworkMeshBandwidthControl(isLocal: false, endpoint: $0, output: targetControl.output) }
                    }
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(4))
                    for control in controls {
                        let remaining = clock.now.duration(to: deadline)
                        guard remaining > .zero else { break }
                        let boundedCleanup = TimedInventoryProcessRunner(timeout: remaining, underlying: cleanupRunner)
                        let output: InventoryProcessOutput
                        do { output = try await execute(control, script: script, runner: boundedCleanup) }
                        catch InventoryProcessTimeoutError.timedOut { continue }
                        if output.exitCode == 0 { return output.stdout.contains("TMUXHUB_IPERF_CLEANED:" + token) }
                        if !NetworkMeshBandwidthParser.isControlNetworkFailure(output) { break }
                    }
                    return false
                } catch { return false }
            }.value
            var final = result
            if !cleaned {
                final.message += "；临时服务清理未确认，服务端绝对限时 45 秒自动停止"
            }
            return final
        } catch is CancellationError {
            return failure(.cancelled, "已取消")
        } catch InventoryProcessTimeoutError.timedOut {
            return failure(.unreachable, "管理连接本次超时，尚未启动测速")
        } catch {
            return failure(.unsupported, networkMeshDiagnostic(error.localizedDescription) ?? "无法测量网络带宽")
        }
    }

    private func selectControl(host: NetworkMeshHost, endpoint: NetworkMeshEndpoint) async throws -> NetworkMeshBandwidthControl {
        let script = NetworkMeshBandwidthCommands.availability(platform: endpoint.platform)
        let candidates = host.isLocal ? [endpoint] : NetworkMeshCommands.controlEndpoints(for: host, sourceEndpoint: endpoint)
        var last: NetworkMeshBandwidthControl?
        for candidate in candidates {
            try Task.checkCancellation()
            let selection = NetworkMeshBandwidthControl(isLocal: host.isLocal, endpoint: candidate,
                                                         output: .init(stdout: "", stderr: "", exitCode: 0))
            let output: InventoryProcessOutput
            do {
                output = try await execute(selection, script: script, runner: runner)
            } catch InventoryProcessTimeoutError.timedOut {
                last = .init(isLocal: host.isLocal, endpoint: candidate,
                             output: .init(stdout: "", stderr: "管理入口本次 timed out", exitCode: 255))
                continue
            }
            last = .init(isLocal: host.isLocal, endpoint: candidate, output: output)
            if output.exitCode == 0 || !NetworkMeshBandwidthParser.isControlNetworkFailure(output) { return last! }
        }
        return last ?? .init(isLocal: host.isLocal, endpoint: endpoint,
                             output: .init(stdout: "", stderr: "未配置管理入口", exitCode: 255))
    }

    private func execute(
        _ control: NetworkMeshBandwidthControl, script: String, runner: any InventoryProcessRunning
    ) async throws -> InventoryProcessOutput {
        if control.isLocal {
            guard control.endpoint.platform == .posix else { throw NetworkMeshBandwidthError.unsupportedLocalPlatform }
            return try await runner.run(.init(executable: "/bin/sh", arguments: ["-c", script],
                                               environment: NetworkMeshCommands.environment))
        }
        return try await runner.run(NetworkMeshCommands.controlCommand(
            endpoint: control.endpoint,
            remoteCommand: NetworkMeshCommands.remoteCommand(script: script, platform: control.endpoint.platform)
        ))
    }
}

private struct NetworkMeshBandwidthControl: Sendable {
    let isLocal: Bool
    let endpoint: NetworkMeshEndpoint
    let output: InventoryProcessOutput
}

private actor NetworkMeshBandwidthServerCompletion {
    private var completed: Result<InventoryProcessOutput, any Error>?
    func finish(_ result: Result<InventoryProcessOutput, any Error>) { completed = result }
    func result() -> Result<InventoryProcessOutput, any Error>? { completed }
}

enum NetworkMeshBandwidthError: LocalizedError {
    case invalidPort, incompleteMeasurement, sourceMismatch, unsupportedLocalPlatform, invalidToken, sessionMismatch
    var errorDescription: String? {
        switch self {
        case .invalidPort: "测速端口必须在 1–65535 之间"
        case .incompleteMeasurement: "iperf3 未返回完整的接收端统计"
        case .sourceMismatch: "实际来源地址与所选入口不一致；未保存测速值"
        case .unsupportedLocalPlatform: "本机环境必须使用 macOS / POSIX 平台"
        case .invalidToken: "临时测速标识无效"
        case .sessionMismatch: "客户端与本次拥有的测速服务会话不一致；未保存测速值"
        }
    }
}

enum NetworkMeshBandwidthCommands {
    static let durationSeconds = 3

    static func validate(sourceEndpoint: NetworkMeshEndpoint, targetEndpoint: NetworkMeshEndpoint) throws {
        _ = try SSHHostConfiguration(alias: "mesh-source", hostname: sourceEndpoint.address)
        _ = try SSHHostConfiguration(alias: "mesh-target", hostname: targetEndpoint.address, port: targetEndpoint.port)
        _ = try NetworkMeshCommands.addressFamily(sourceEndpoint.address)
        guard (1...65535).contains(targetEndpoint.bandwidthPort) else { throw NetworkMeshBandwidthError.invalidPort }
    }

    static func availability(platform: NetworkMeshPlatform) -> String {
        // TMUXHUB_BANDWIDTH_AVAILABILITY is a stable test/lifecycle marker in generated commands.
        switch platform {
        case .posix:
            return """
            # TMUXHUB_BANDWIDTH_AVAILABILITY
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            if command -v iperf3 >/dev/null 2>&1; then
                printf '%s\\n' 'TMUXHUB_IPERF_READY'
            else
                printf '%s\\n' 'TMUXHUB_IPERF_MISSING'
                exit 69
            fi
            """
        case .windows:
            return """
            # TMUXHUB_BANDWIDTH_AVAILABILITY
            $tool = Get-Command iperf3,iperf3.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $tool) { Write-Output 'TMUXHUB_IPERF_MISSING'; exit 69 }
            Write-Output 'TMUXHUB_IPERF_READY'
            """
        }
    }

    static func server(
        sourceEndpoint: NetworkMeshEndpoint, targetEndpoint: NetworkMeshEndpoint, token: String = UUID().uuidString
    ) throws -> String {
        try validate(sourceEndpoint: sourceEndpoint, targetEndpoint: targetEndpoint)
        try validateToken(token)
        let family = try NetworkMeshCommands.addressFamily(sourceEndpoint.address)
        let args = [family, "-s", "-1", "-p", String(targetEndpoint.bandwidthPort), "--idle-timeout", "15", "-J"]
        if targetEndpoint.platform == .windows {
            return windowsServer(arguments: args, port: targetEndpoint.bandwidthPort, token: token)
        }
        let command = "iperf3 " + args.map(NetworkMeshCommands.quote).joined(separator: " ")
        return posixOwnership(port: targetEndpoint.bandwidthPort, token: token) + """
        # TMUXHUB_BANDWIDTH_SERVER
        umask 077
        if ! mkdir -m 700 "$state" 2>/dev/null; then
            printf '%s\\n' 'TMUXHUB_IPERF_OWNERSHIP_UNSUPPORTED:无法创建独占临时目录'
            exit 69
        fi
        printf '%s\\n' "$token" > "$state/owner"
        watchdog=''
        cleanup_server() {
            trap - EXIT HUP INT TERM
            stop_owned
            if [ -n "$watchdog" ]; then kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true; fi
            remove_owned_state
        }
        trap cleanup_server EXIT
        trap 'exit 130' HUP INT TERM
        if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1 && ! [ -d /proc/self/fd ]; then
            printf '%s\\n' 'TMUXHUB_IPERF_OWNERSHIP_UNSUPPORTED:缺少监听 PID 检查能力'
            exit 69
        fi
        \(command) > "$state/stdout" 2> "$state/stderr" &
        server_pid=$!
        printf '%s\\n' "$server_pid" > "$state/server.pid"
        ps -p "$server_pid" -o lstart= 2>/dev/null > "$state/server.start"
        if [ ! -s "$state/server.start" ]; then
            if [ "$(ps -p "$server_pid" -o ppid= 2>/dev/null | tr -d ' ')" = "$$" ]; then kill "$server_pid" 2>/dev/null || true; fi
            wait "$server_pid" 2>/dev/null || true
            printf '%s\\n' 'TMUXHUB_IPERF_OWNERSHIP_UNSUPPORTED:无法确认临时子进程启动时间'
            exit 69
        fi
        (
            sleeper=''
            trap 'if [ -n "$sleeper" ]; then kill "$sleeper" 2>/dev/null || true; fi' EXIT
            trap 'exit 0' HUP INT TERM
            second=0
            while [ "$second" -lt 45 ]; do
                sleep 1 & sleeper=$!
                wait "$sleeper" || exit 0
                [ -d "$state" ] || exit 0
                second=$((second + 1))
            done
            stop_owned
            remove_owned_state
        ) >/dev/null 2>&1 &
        watchdog=$!
        ready=0
        for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
            if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
            if has_owned_listener; then
                printf '%s\\n' "$token" > "$state/ready"
                ready=1
                break
            fi
            sleep 0.1
        done
        if [ "$ready" -ne 1 ]; then
            cat "$state/stdout" 2>/dev/null
            cat "$state/stderr" >&2 2>/dev/null
            printf '%s\\n' 'TMUXHUB_IPERF_OWNERSHIP_UNSUPPORTED:临时子进程未确认拥有监听端口'
            exit 69
        fi
        wait "$server_pid"
        server_status=$?
        cat "$state/stdout" 2>/dev/null
        cat "$state/stderr" >&2 2>/dev/null
        exit "$server_status"
        """
    }

    static func readiness(targetEndpoint: NetworkMeshEndpoint, token: String) throws -> String {
        try validateToken(token)
        if targetEndpoint.platform == .windows {
            return windowsOwnership(port: targetEndpoint.bandwidthPort, token: token) + """
            # TMUXHUB_BANDWIDTH_READINESS
            if ((Test-Path -LiteralPath (Join-Path $state 'ready')) -and (Has-OwnedListener)) {
                Write-Output ('TMUXHUB_IPERF_OWNED_READY:' + $token)
            } else { Write-Output 'TMUXHUB_IPERF_PENDING' }
            """
        }
        return posixOwnership(port: targetEndpoint.bandwidthPort, token: token) + """
        # TMUXHUB_BANDWIDTH_READINESS
        if [ -f "$state/ready" ] && [ "$(cat "$state/ready" 2>/dev/null)" = "$token" ] && has_owned_listener; then
            printf 'TMUXHUB_IPERF_OWNED_READY:%s\\n' "$token"
        else
            printf '%s\\n' 'TMUXHUB_IPERF_PENDING'
        fi
        """
    }

    static func cleanup(targetEndpoint: NetworkMeshEndpoint, token: String) throws -> String {
        try validateToken(token)
        if targetEndpoint.platform == .windows {
            return windowsOwnership(port: targetEndpoint.bandwidthPort, token: token) + """
            # TMUXHUB_BANDWIDTH_CLEANUP
            Stop-Owned
            Remove-OwnedState
            if (!(Test-Path -LiteralPath $state)) { Write-Output ('TMUXHUB_IPERF_CLEANED:' + $token) }
            else { exit 1 }
            """
        }
        return posixOwnership(port: targetEndpoint.bandwidthPort, token: token) + """
        # TMUXHUB_BANDWIDTH_CLEANUP
        stop_owned
        remove_owned_state
        if [ ! -e "$state" ]; then printf 'TMUXHUB_IPERF_CLEANED:%s\\n' "$token"; else exit 1; fi
        """
    }

    private static func validateToken(_ token: String) throws {
        guard UUID(uuidString: token) != nil else { throw NetworkMeshBandwidthError.invalidToken }
    }

    private static func posixOwnership(port: Int, token: String) -> String {
        """
        export LC_ALL=C
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        token=\(NetworkMeshCommands.quote(token))
        state="/tmp/tmuxhub-iperf-$token"
        port=\(port)
        owned_state() {
            [ -d "$state" ] && [ ! -L "$state" ] && [ -f "$state/owner" ] && [ ! -L "$state/owner" ] &&
                [ "$(cat "$state/owner" 2>/dev/null)" = "$token" ]
        }
        owned_process() {
            owned_state || return 1
            pid=$(cat "$state/server.pid" 2>/dev/null) || return 1
            case "$pid" in ''|*[!0-9]*) return 1 ;; esac
            [ "$pid" -gt 1 ] || return 1
            start=$(cat "$state/server.start" 2>/dev/null) || return 1
            [ -n "$start" ] && [ "$(ps -p "$pid" -o lstart= 2>/dev/null)" = "$start" ] || return 1
            process=$(ps -p "$pid" -o comm= 2>/dev/null)
            case "$process" in iperf3|*/iperf3) return 0 ;; *) return 1 ;; esac
        }
        has_owned_listener() {
            owned_process || return 1
            if command -v lsof >/dev/null 2>&1; then
                owners=$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
                for owner in $owners; do [ "$owner" = "$pid" ] && return 0; done
            fi
            if command -v ss >/dev/null 2>&1; then
                listeners=$(ss -ltnp "sport = :$port" 2>/dev/null)
                case "$listeners" in *"pid=$pid,"*) return 0 ;; esac
            fi
            if [ -d "/proc/$pid/fd" ] && command -v readlink >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
                hexport=$(printf '%04X' "$port")
                for descriptor in "/proc/$pid/fd/"*; do
                    link=$(readlink "$descriptor" 2>/dev/null)
                    case "$link" in
                        socket:\\[*\\])
                            inode=$(printf '%s' "$link" | tr -cd '0-9')
                            if awk -v port="$hexport" -v inode="$inode" '$4 == "0A" && $10 == inode && $2 ~ (":" port "$") { found=1 } END { exit !found }' "/proc/$pid/net/tcp" "/proc/$pid/net/tcp6" 2>/dev/null; then return 0; fi ;;
                    esac
                done
            fi
            return 1
        }
        stop_owned() {
            if owned_process; then
                stop_pid=$pid
                kill "$stop_pid" 2>/dev/null || true
                for attempt in 1 2 3 4 5 6 7 8 9 10; do
                    owned_process || break
                    sleep 0.1
                done
                if owned_process && [ "$pid" = "$stop_pid" ]; then kill -KILL "$stop_pid" 2>/dev/null || true; fi
            fi
        }
        remove_owned_state() {
            owned_state || return 0
            owned_process && return 1
            rm -f "$state/ready" "$state/server.pid" "$state/server.start" "$state/stdout" "$state/stderr" "$state/owner"
            rmdir "$state" 2>/dev/null || true
        }

        """
    }

    private static func windowsOwnership(port: Int, token: String) -> String {
        """
        $ErrorActionPreference = 'Stop'
        $token = \(NetworkMeshCommands.powerShellQuote(token))
        $state = Join-Path $env:TEMP ('tmuxhub-iperf-' + $token)
        $port = \(port)
        function Owned-State {
            if (!(Test-Path -LiteralPath $state -PathType Container)) { return $false }
            if (([IO.File]::GetAttributes($state) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $owner = Join-Path $state 'owner'
            return (Test-Path -LiteralPath $owner) -and ((Get-Content -LiteralPath $owner -Raw).Trim() -eq $token)
        }
        function Owned-Process {
            if (!(Owned-State)) { return $null }
            $file = Join-Path $state 'server.pid'
            $start = Join-Path $state 'server.start'
            if (!(Test-Path -LiteralPath $file) -or !(Test-Path -LiteralPath $start)) { return $null }
            $ownedID = 0
            if (![int]::TryParse((Get-Content -LiteralPath $file -Raw).Trim(), [ref]$ownedID) -or $ownedID -le 1) { return $null }
            $process = Get-Process -Id $ownedID -ErrorAction SilentlyContinue
            if ($null -eq $process -or $process.ProcessName -ne 'iperf3') { return $null }
            if ($process.StartTime.Ticks.ToString() -ne (Get-Content -LiteralPath $start -Raw).Trim()) { return $null }
            return $process
        }
        function Has-OwnedListener {
            $owned = Owned-Process
            if ($null -eq $owned) { return $false }
            if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
                $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwningProcess -eq $owned.Id })
                if ($listeners.Count -gt 0) { return $true }
            }
            if (Get-Command netstat.exe -ErrorAction SilentlyContinue) {
                foreach ($line in (& netstat.exe -ano -p TCP)) {
                    $parts = $line.Trim() -split '\\s+'
                    if ($parts.Count -ge 5 -and $parts[3] -eq 'LISTENING' -and
                        $parts[1] -match (':' + $port + '$') -and $parts[4] -eq $owned.Id.ToString()) { return $true }
                }
            }
            return $false
        }
        function Stop-Owned {
            $owned = Owned-Process
            if ($null -ne $owned) { try { $owned.Kill(); [void]$owned.WaitForExit(1000) } catch {} }
        }
        function Remove-OwnedState {
            if (!(Owned-State) -or $null -ne (Owned-Process)) { return }
            foreach ($file in @('ready', 'server.pid', 'server.start', 'stdout', 'stderr', 'owner')) {
                Remove-Item -LiteralPath (Join-Path $state $file) -Force -ErrorAction SilentlyContinue
            }
            try { [IO.Directory]::Delete($state, $false) } catch {}
        }

        """
    }

    private static func windowsServer(arguments: [String], port: Int, token: String) -> String {
        let ownership = windowsOwnership(port: port, token: token)
        let arguments = arguments.map(NetworkMeshCommands.powerShellQuote).joined(separator: ", ")
        let watchdog = ownership + """
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.Elapsed.TotalSeconds -lt 45) {
            if (!(Test-Path -LiteralPath $state)) { exit 0 }
            Start-Sleep -Milliseconds 200
        }
        Stop-Owned
        Remove-OwnedState
        """
        return ownership + """
        # TMUXHUB_BANDWIDTH_SERVER
        $tool = Get-Command iperf3,iperf3.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $tool) { Write-Output 'TMUXHUB_IPERF_MISSING'; exit 69 }
        if (Test-Path -LiteralPath $state) { Write-Output 'TMUXHUB_IPERF_OWNERSHIP_UNSUPPORTED:临时目录已存在'; exit 69 }
        [void](New-Item -ItemType Directory -Path $state -ErrorAction Stop)
        Set-Content -LiteralPath (Join-Path $state 'owner') -Value $token
        $process = New-Object Diagnostics.Process
        try {
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $tool.Source
            $info.Arguments = @(\(arguments)) -join ' '
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process.StartInfo = $info
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            Set-Content -LiteralPath (Join-Path $state 'server.pid') -Value $process.Id
            Set-Content -LiteralPath (Join-Path $state 'server.start') -Value $process.StartTime.Ticks.ToString()
            $watchInfo = New-Object Diagnostics.ProcessStartInfo
            $watchInfo.FileName = 'powershell.exe'
            $watchInfo.Arguments = '-NoProfile -NonInteractive -EncodedCommand \(NetworkMeshCommands.encodedPowerShell(watchdog))'
            $watchInfo.UseShellExecute = $false
            $watchInfo.CreateNoWindow = $true
            $watchInfo.RedirectStandardOutput = $true
            $watchInfo.RedirectStandardError = $true
            $watcher = [Diagnostics.Process]::Start($watchInfo)
            $watcher.Dispose()
            $ready = $false
            for ($i = 0; $i -lt 50; $i++) {
                if ($process.HasExited) { break }
                if (Has-OwnedListener) { Set-Content -LiteralPath (Join-Path $state 'ready') -Value $token; $ready = $true; break }
                Start-Sleep -Milliseconds 100
            }
            if (!$ready) { Write-Output 'TMUXHUB_IPERF_OWNERSHIP_UNSUPPORTED:子进程未拥有监听端口'; exit 69 }
            $process.WaitForExit()
            Write-Output $stdout.Result
            [Console]::Error.Write($stderr.Result)
            exit $process.ExitCode
        } finally {
            try { if (!$process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1000) } } catch {}
            Stop-Owned
            Remove-OwnedState
            $process.Dispose()
        }
        """
    }

    static func client(sourceEndpoint: NetworkMeshEndpoint, targetEndpoint: NetworkMeshEndpoint) throws -> String {
        try validate(sourceEndpoint: sourceEndpoint, targetEndpoint: targetEndpoint)
        let family = try NetworkMeshCommands.addressFamily(sourceEndpoint.address)
        let args = [family, "-c", targetEndpoint.address, "-B", sourceEndpoint.address,
                    "-p", String(targetEndpoint.bandwidthPort), "-t", String(durationSeconds), "--connect-timeout", "5000", "-J"]
        return "# TMUXHUB_BANDWIDTH_CLIENT\n" + invocation(args, platform: sourceEndpoint.platform)
    }

    private static func invocation(_ arguments: [String], platform: NetworkMeshPlatform) -> String {
        switch platform {
        case .posix:
            return "export LC_ALL=C\nexport PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\nexec iperf3 " + arguments.map(NetworkMeshCommands.quote).joined(separator: " ")
        case .windows:
            let args = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
            return """
            $tool = Get-Command iperf3,iperf3.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $tool) { Write-Output 'TMUXHUB_IPERF_MISSING'; exit 69 }
            & $tool.Source @(\(args))
            exit $LASTEXITCODE
            """
        }
    }
}

enum NetworkMeshBandwidthParser {
    struct Measurement: Equatable { let mbps: Double; let seconds: Double }

    static func measurement(
        _ text: String, expectedSource: String, serverText: String? = nil
    ) throws -> Measurement {
        guard let data = text.data(using: .utf8),
              let client = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              client["error"] == nil,
              let start = client["start"] as? [String: Any],
              let connections = start["connected"] as? [[String: Any]], !connections.isEmpty
        else { throw NetworkMeshBandwidthError.incompleteMeasurement }
        guard connections.allSatisfy({
            ($0["local_host"] as? String).map { sameAddress($0, expectedSource) } == true
        }) else { throw NetworkMeshBandwidthError.sourceMismatch }
        var receiving = client
        if let serverText {
            guard let serverData = serverText.data(using: .utf8),
                  let server = try JSONSerialization.jsonObject(with: serverData) as? [String: Any],
                  server["error"] == nil,
                  let serverStart = server["start"] as? [String: Any],
                  let clientCookie = start["cookie"] as? String, !clientCookie.isEmpty,
                  let serverCookie = serverStart["cookie"] as? String, serverCookie == clientCookie
            else { throw NetworkMeshBandwidthError.sessionMismatch }
            receiving = server
        }
        guard let end = receiving["end"] as? [String: Any],
              let receiver = end["sum_received"] as? [String: Any],
              let seconds = (receiver["seconds"] as? NSNumber)?.doubleValue,
              let bytes = (receiver["bytes"] as? NSNumber)?.doubleValue,
              let bps = (receiver["bits_per_second"] as? NSNumber)?.doubleValue,
              seconds.isFinite, seconds > 0, bytes.isFinite, bytes > 0, bps.isFinite, bps > 0
        else { throw NetworkMeshBandwidthError.incompleteMeasurement }
        return .init(mbps: bps / 1_000_000, seconds: seconds)
    }

    private static func sameAddress(_ left: String, _ right: String) -> Bool {
        let a = left.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        let b = right.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        var a4 = in_addr(), b4 = in_addr()
        if a.withCString({ inet_pton(AF_INET, $0, &a4) }) == 1,
           b.withCString({ inet_pton(AF_INET, $0, &b4) }) == 1 { return a4.s_addr == b4.s_addr }
        var a6 = in6_addr(), b6 = in6_addr()
        if a.withCString({ inet_pton(AF_INET6, $0, &a6) }) == 1,
           b.withCString({ inet_pton(AF_INET6, $0, &b6) }) == 1 {
            return withUnsafeBytes(of: a6) { lhs in withUnsafeBytes(of: b6) { rhs in lhs.elementsEqual(rhs) } }
        }
        return false
    }

    static func status(_ output: InventoryProcessOutput) -> NetworkMeshProbeStatus {
        let text = (output.stdout + "\n" + output.stderr).lowercased()
        if text.contains("host key verification failed") || text.contains("identification has changed") { return .hostKeyFailure }
        if NetworkMeshProbeParser.isAuthenticationFailure(text) { return .authenticationRequired }
        if text.contains("tmuxhub_iperf_ownership_unsupported") || text.contains("tmuxhub_iperf_missing") || text.contains("not found") || text.contains("unrecognized option") || text.contains("unknown option") { return .unsupported }
        return .unreachable
    }

    static func isControlNetworkFailure(_ output: InventoryProcessOutput) -> Bool {
        guard output.exitCode == 255, status(output) == .unreachable else { return false }
        let text = (output.stdout + output.stderr).lowercased()
        return NetworkMeshProbeParser.isNetworkFailure(text)
    }

    static func diagnostic(_ output: InventoryProcessOutput) -> String {
        if let data = output.stdout.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let reason = json["error"] as? String {
            return networkMeshDiagnostic(reason) ?? "iperf3 测试失败"
        }
        let text = output.stderr.isEmpty ? output.stdout : output.stderr
        return networkMeshDiagnostic(text) ?? "iperf3 未能完成测试"
    }
}
