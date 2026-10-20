import Foundation

public struct NetworkOnboardingToolStatus: Equatable, Sendable {
    public let hasIperf3: Bool
    public let hasZeroTier: Bool
}

extension NetworkMembershipCommands {
    public static func bootstrapCommand(endpoint: NetworkMeshEndpoint, managerID: String) throws -> CommandSpec {
        let marker = "tmuxhub-manager:" + digest(managerID)
        let install: String
        if endpoint.platform == .windows {
            install = """
                $ErrorActionPreference = 'Stop'
                $key = [Console]::ReadLine()
                if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\\s+[A-Za-z0-9+/=]+(\\s.*)?$') { throw 'Invalid public key.' }
                \(windowsAuthorizationPath)
                $lines = if (Test-Path -LiteralPath $auth) { @([IO.File]::ReadAllLines($auth)) } else { @() }
                $lines = @($lines | Where-Object { ($_ -split '\\s+')[-1] -ne \(psQuote(marker)) })
                $parts = $key -split '\\s+'
                $lines += ($parts[0] + ' ' + $parts[1] + ' ' + \(psQuote(marker)))
                [IO.File]::WriteAllLines($auth, [string[]]$lines, [Text.UTF8Encoding]::new($false))
                if ($admin) {
                    & icacls.exe $auth /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Run this step with an administrator account to prepare administrators_authorized_keys ACL.' }
                }
                Write-Output 'Management public key installed. Return to TmuxHub and verify.'
                """
        } else {
            install = """
                set -eu
                umask 077
                IFS= read -r key
                mkdir -p "$HOME/.ssh"
                chmod 700 "$HOME/.ssh"
                auth="$HOME/.ssh/authorized_keys"
                test ! -L "$auth" || { printf 'authorized_keys is a symlink; install the management public key in its target manually.\\n' >&2; exit 67; }
                touch "$auth"
                tmp=$(mktemp "$HOME/.ssh/tmuxhub-bootstrap.XXXXXX")
                trap 'rm -f "$tmp"' EXIT HUP INT TERM
                awk -v marker=\(NetworkOnboardingCommands.quote(marker)) '$NF != marker' "$auth" > "$tmp"
                printf '%s %s\\n' "$key" \(NetworkOnboardingCommands.quote(marker)) >> "$tmp"
                chmod 600 "$tmp"
                mv "$tmp" "$auth"
                printf 'Management public key installed. Return to TmuxHub and verify.\\n'
                """
        }
        let remote = try ShellCommandRenderer.render(managementCommand(endpoint: endpoint, script: install, interactive: true, meshIdentity: false))
        let prepareKey = NetworkOnboardingCommands.keyGenerationScript.replacingOccurrences(of: "tmuxhub_mesh_ed25519", with: "tmuxhub_management_ed25519")
        let script = """
            set -eu
            \(prepareKey)
            public_key="$HOME/.ssh/tmuxhub_management_ed25519.pub"
            ssh-keygen -l -f "$public_key" >/dev/null
            key=$(awk 'NF && $1 !~ /^#/ { print $1 " " $2; exit }' "$public_key")
            test -n "$key"
            printf '%s\\n' "$key" | \(remote)
            """
        return CommandSpec(executable: "/bin/sh", arguments: ["-c", script])
    }

    public static func trustEndpointCommand(endpoint: NetworkMeshEndpoint) throws -> CommandSpec {
        let script = endpoint.platform == .windows ? "Write-Output 'SSH host identity verified.'" : "printf 'SSH host identity verified.\\n'"
        return try managementCommand(endpoint: endpoint, script: script, interactive: true)
    }

    public static func prepareToolsCommand(endpoint: NetworkMeshEndpoint) throws -> CommandSpec {
        if endpoint.platform == .windows {
            let script = """
                $ErrorActionPreference = 'Stop'
                if (!(Get-Command iperf3.exe -ErrorAction SilentlyContinue)) {
                    Write-Output 'Install iperf3 for Windows, add its directory to PATH, and reopen the SSH session.'
                    Write-Output 'https://iperf.fr/iperf-download.php#windows'
                    exit 69
                }
                & iperf3.exe --version
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                Write-Output 'iperf3 ready. No permanent server was started.'
                """
            return try managementCommand(endpoint: endpoint, script: script, interactive: true, tty: true)
        }
        let configuration = try configuration(endpoint)
        return NetworkOnboardingCommands.prepareSpeedToolsCommand(configuration: configuration)
    }

    public static func joinZeroTierCommand(endpoint: NetworkMeshEndpoint, networkID: String) throws -> CommandSpec {
        let id = try NetworkOnboardingCommands.validatedNetworkID(networkID)
        let script: String
        if endpoint.platform == .windows {
            script = """
                $ErrorActionPreference = 'Stop'
                \(windowsZeroTierExecutable)
                & $zt join \(psQuote(id))
                if ($LASTEXITCODE -ne 0) { throw 'ZeroTier join requires an administrator account.' }
                & $zt -j listnetworks
                Write-Output 'Network administrator authorization may still be required in ZeroTier Central.'
                """
        } else {
            script = """
                set -eu
                \(NetworkOnboardingCommands.zeroTierExecutableScript)
                sudo "$zt" join \(NetworkOnboardingCommands.quote(id))
                sudo "$zt" -j listnetworks
                printf 'Network administrator authorization may still be required in ZeroTier Central.\\n'
                """
        }
        return try managementCommand(endpoint: endpoint, script: script, interactive: true, tty: true)
    }

    static var windowsZeroTierExecutable: String {
        """
            $zt = (Get-Command zerotier-cli.bat -ErrorAction SilentlyContinue).Source
            if (!$zt) { $zt = (Get-Command zerotier-cli.exe -ErrorAction SilentlyContinue).Source }
            if (!$zt) {
                $candidate = Join-Path ${env:ProgramFiles(x86)} 'ZeroTier/One/zerotier-cli.bat'
                if (Test-Path -LiteralPath $candidate) { $zt = $candidate }
            }
            if (!$zt) { throw 'ZeroTier is not installed. Install from https://www.zerotier.com/download/ and retry.' }
            """
    }
}

extension NetworkOnboardingService {
    public func verifyEndpoint(_ endpoint: NetworkMeshEndpoint) async -> NetworkOnboardingStep {
        do {
            let token = "TMUXHUB_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let script = endpoint.platform == .windows ? "Write-Output \(NetworkMembershipCommands.psQuote(token))" : "printf '%s\\n' \(NetworkOnboardingCommands.quote(token))"
            let output = try await runManagementEndpoint(endpoint: endpoint, script: script)
            guard output.stdout.split(whereSeparator: \.isNewline).contains(Substring(token)) else {
                throw NetworkOnboardingError.commandFailed("未返回此次验证标记。")
            }
            return NetworkOnboardingStep(title: endpoint.label, detail: "SSH 管理登录通过；服务器指纹与远端命令执行已验证。", succeeded: true)
        } catch { return NetworkOnboardingStep(title: endpoint.label, detail: diagnostic(error), succeeded: false) }
    }

    public func toolStatus(endpoint: NetworkMeshEndpoint) async throws -> NetworkOnboardingToolStatus {
        let script: String
        if endpoint.platform == .windows {
            script = """
                $ErrorActionPreference = 'Stop'
                if (Get-Command iperf3.exe -ErrorAction SilentlyContinue) { Write-Output 'TMUXHUB_IPERF3' }
                try { \(NetworkMembershipCommands.windowsZeroTierExecutable); Write-Output 'TMUXHUB_ZEROTIER' } catch {}
                """
        } else {
            script = """
                PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
                export PATH
                if command -v iperf3 >/dev/null 2>&1; then printf 'TMUXHUB_IPERF3\\n'; fi
                if ( \(NetworkOnboardingCommands.zeroTierExecutableScript) ) >/dev/null 2>&1; then printf 'TMUXHUB_ZEROTIER\\n'; fi
                """
        }
        let output = try await runManagementEndpoint(endpoint: endpoint, script: script)
        let lines = Set(output.stdout.split(whereSeparator: \.isNewline).map(String.init))
        return NetworkOnboardingToolStatus(hasIperf3: lines.contains("TMUXHUB_IPERF3"), hasZeroTier: lines.contains("TMUXHUB_ZEROTIER"))
    }

    public func zeroTierStatus(endpoint: NetworkMeshEndpoint, networkID: String) async throws -> NetworkZeroTierStatus {
        let script: String
        if endpoint.platform == .windows {
            script = """
                $ErrorActionPreference = 'Stop'
                \(NetworkMembershipCommands.windowsZeroTierExecutable)
                & $zt -j listnetworks
                if ($LASTEXITCODE -ne 0) { throw 'ZeroTier status needs administrator permissions.' }
                """
        } else {
            script = """
                set -eu
                \(NetworkOnboardingCommands.zeroTierExecutableScript)
                "$zt" -j listnetworks 2>/dev/null || sudo -n "$zt" -j listnetworks
                """
        }
        let output = try await runManagementEndpoint(endpoint: endpoint, script: script)
        return try NetworkZeroTierStatus.parse(output.stdout, networkID: networkID)
    }

    public func saveEndpoints(_ endpoints: [NetworkMeshEndpoint]) -> NetworkOnboardingSaveReport {
        let configurations = endpoints.compactMap { endpoint -> SSHHostConfiguration? in
            guard let initial = try? NetworkMembershipCommands.configuration(endpoint) else { return nil }
            return try? SSHHostConfiguration(alias: initial.alias, hostname: initial.hostname, username: initial.username,
                                            port: initial.port, identityFile: hasManagementIdentity ? NetworkMembershipCommands.managementIdentityFile : nil)
        }
        let report = saveConfigurations(configurations)
        let invalid = endpoints.filter { (try? NetworkMembershipCommands.configuration($0)) == nil }
            .map { NetworkOnboardingStep(title: "保存 \($0.label)", detail: "请检查 SSH 地址、端口和用户名。", succeeded: false) }
        return NetworkOnboardingSaveReport(savedAliases: report.savedAliases, existingAliases: report.existingAliases, failures: report.failures + invalid)
    }
    func saveControllerAlias(endpoint: NetworkMeshEndpoint, publicKeys: [String]) async throws -> String? {
        let managementKey = homeDirectory.appendingPathComponent(".ssh/tmuxhub_management_ed25519").path
        guard FileManager.default.fileExists(atPath: managementKey) else { return nil }
        let configuration = try NetworkMembershipCommands.configuration(endpoint)
        let alias = NetworkMembershipCommands.controlAlias(for: endpoint)
        let probe = CommandSpec(executable: "/usr/bin/ssh", arguments: [
            "-G", "-o", "HostName=\(configuration.hostname.replacingOccurrences(of: "%", with: "%%"))",
            "-p", String(configuration.port), "--", configuration.alias,
        ])
        let evaluated = try await checkedRun(probe)
        let allowedRouting = ["proxycommand": "ProxyCommand", "proxyjump": "ProxyJump", "proxyusefdpass": "ProxyUseFdpass"]
        var effectiveRouting: [String: String] = [:]
        for line in evaluated.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let name = allowedRouting[String(parts[0])] else { continue }
            let value = String(parts[1])
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw NetworkOnboardingError.commandFailed("原 SSH 路由包含无效字符，未写入管理别名。")
            }
            effectiveRouting[name] = value
        }
        var routing: [String]
        if let proxy = effectiveRouting["ProxyCommand"], proxy != "none" {
            routing = ["    ProxyCommand \(proxy)"]
            if let fdpass = effectiveRouting["ProxyUseFdpass"] { routing.append("    ProxyUseFdpass \(fdpass)") }
        } else if let jump = effectiveRouting["ProxyJump"], jump != "none" {
            routing = ["    ProxyJump \(jump)"]
        } else {
            routing = ["    ProxyCommand none", "    ProxyJump none"]
        }
        var lines = [
            "# Managed by TmuxHub; original SSH aliases are preserved.", "Host \(alias)",
            "    HostName \(configuration.hostname.replacingOccurrences(of: "%", with: "%%"))",
            "    Port \(configuration.port)", "    HostKeyAlias \(alias)",
            "    IdentityFile ~/.ssh/tmuxhub_management_ed25519", "    IdentitiesOnly yes",
            "    UserKnownHostsFile ~/.ssh/tmuxhub_control_known_hosts", "    StrictHostKeyChecking yes", "    ForwardAgent no",
        ]
        if !configuration.username.isEmpty { lines.append("    User \(configuration.username)") }
        lines += routing
        lines += ["Host *", ""]
        let config = lines.joined(separator: "\n") + "\n"
        let knownToken = NetworkOnboardingCommands.knownHostsToken(configuration)
        let known = try publicKeys.map {
            "\(alias),[\(alias)]:\(configuration.port),\(knownToken) \(try NetworkOnboardingCommands.validatedPublicKey($0))"
        }.joined(separator: "\n") + "\n"
        let include = "Include ~/.ssh/tmuxhub_control.d/*.conf"
        let fileID = endpoint.id.uuidString.lowercased()
        let priorAliasExists = FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent(".ssh/tmuxhub_control.d/\(fileID).conf").path)
        let script = """
            # TMUXHUB CONTROL_ALIAS \(fileID)
            set -eu
            umask 077
            if [ -L "$HOME/.ssh/config" ] && ! grep -Fqx -- \(NetworkOnboardingCommands.quote(include)) "$HOME/.ssh/config"; then
                printf 'SSH config is a symlink. Manually add: Include ~/.ssh/tmuxhub_control.d/*.conf\\n' >&2; exit 67
            fi
            mkdir -p "$HOME/.ssh/tmuxhub_control.d"
            managed="$HOME/.ssh/tmuxhub_control.d"
            printf '%s' \(NetworkOnboardingCommands.quote(config)) > "$managed/\(fileID).conf"
            printf '%s' \(NetworkOnboardingCommands.quote(known)) > "$managed/\(fileID).known_hosts"
            tmp=$(mktemp "$HOME/.ssh/tmuxhub-control-trust.XXXXXX")
            trap 'rm -f "$tmp"' EXIT HUP INT TERM
            for file in "$managed"/*.known_hosts; do [ ! -f "$file" ] || cat "$file" >> "$tmp"; done
            chmod 600 "$tmp"
            mv "$tmp" "$HOME/.ssh/tmuxhub_control_known_hosts"
            touch "$HOME/.ssh/config"
            if ! grep -Fqx -- \(NetworkOnboardingCommands.quote(include)) "$HOME/.ssh/config"; then
                cp -p "$HOME/.ssh/config" "$HOME/.ssh/config.tmuxhub-control-backup"
                printf '%s\\n' \(NetworkOnboardingCommands.quote(include)) > "$tmp"
                cat "$HOME/.ssh/config" >> "$tmp"
                cat "$tmp" > "$HOME/.ssh/config"
            fi
            printf 'TMUXHUB_APPLIED\\n'
            """
        let output = try await checkedRun(localCommand(script))
        guard output.stdout.split(whereSeparator: \.isNewline).contains("TMUXHUB_APPLIED") else {
            throw NetworkOnboardingError.commandFailed("管理别名与指纹文件尚未确认写入。")
        }
        let token = "TMUXHUB_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let markerScript = endpoint.platform == .windows
            ? "# TMUXHUB CONTROL_VERIFY \(token)\nWrite-Output \(NetworkMembershipCommands.psQuote(token))"
            : "# TMUXHUB CONTROL_VERIFY \(token)\nprintf '%s\\n' \(NetworkOnboardingCommands.quote(token))"
        let trustPath = homeDirectory.appendingPathComponent(".ssh/tmuxhub_control_known_hosts").path
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var arguments = [
            "-F", "/dev/null", "-i", managementKey, "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1", "-o", "HostKeyAlias=\(alias)",
            "-o", "UserKnownHostsFile=\"\(trustPath)\"", "-p", String(configuration.port),
        ]
        if !configuration.username.isEmpty { arguments += ["-l", configuration.username] }
        if let proxy = effectiveRouting["ProxyCommand"], proxy != "none" {
            arguments += ["-o", "ProxyCommand=\(proxy)"]
            if let fdpass = effectiveRouting["ProxyUseFdpass"] { arguments += ["-o", "ProxyUseFdpass=\(fdpass)"] }
        } else if let jump = effectiveRouting["ProxyJump"], jump != "none" {
            arguments += ["-o", "ProxyJump=\(jump)"]
        }
        arguments += ["--", configuration.hostname, NetworkMembershipCommands.remoteInvocation(markerScript, platform: endpoint.platform)]
        do {
            let proof = try await checkedRun(CommandSpec(executable: "/usr/bin/ssh", arguments: arguments))
            guard proof.stdout.split(whereSeparator: \.isNewline).contains(Substring(token)) else {
                throw NetworkOnboardingError.commandFailed("管理密钥尚未通过独立登录验证。")
            }
            return alias
        } catch {
            if !priorAliasExists {
                let rollback = """
                    set -eu
                    umask 077
                    managed="$HOME/.ssh/tmuxhub_control.d"
                    rm -f "$managed/\(fileID).conf" "$managed/\(fileID).known_hosts"
                    tmp=$(mktemp "$HOME/.ssh/tmuxhub-control-rollback.XXXXXX")
                    trap 'rm -f "$tmp"' EXIT HUP INT TERM
                    for file in "$managed"/*.known_hosts; do [ ! -f "$file" ] || cat "$file" >> "$tmp"; done
                    mv "$tmp" "$HOME/.ssh/tmuxhub_control_known_hosts"
                    """
                _ = try? await checkedRun(localCommand(rollback))
            }
            if error is CancellationError { throw error }
            // Existing SSH credentials remain usable until management-key setup is verified.
            return nil
        }
    }
}
