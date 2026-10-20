import CryptoKit
import Darwin
import Foundation

public struct NetworkOnboardingEnvironment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let hostID: UUID
    public let hostName: String
    public let environmentID: String
    public let environmentName: String
    public let username: String
    public let platform: NetworkMeshPlatform
    public let isLocal: Bool
    public let endpoints: [NetworkMeshEndpoint]
    public var displayName: String { "\(hostName) / \(environmentName) / \(username.isEmpty ? "默认用户" : username)" }

    public static func environments(for host: NetworkMeshHost) -> [Self] {
        let groups = Dictionary(grouping: host.endpoints) { endpoint in
            "\(endpoint.environmentID)\u{0}\(endpoint.username)\u{0}\(endpoint.platform.rawValue)"
        }
        return groups.values.compactMap { endpoints in
            guard let first = endpoints.first else { return nil }
            let identity = "\(host.id.uuidString.lowercased())\u{0}\(first.environmentID)\u{0}\(first.username)\u{0}\(first.platform.rawValue)"
            return Self(
                id: NetworkMembershipCommands.digest(identity), hostID: host.id, hostName: host.name,
                environmentID: first.environmentID, environmentName: first.environmentName,
                username: first.username, platform: first.platform, isLocal: host.isLocal,
                endpoints: endpoints.sorted {
                    let lhs = NetworkMembershipCommands.networkPriority($0.networkKind)
                    let rhs = NetworkMembershipCommands.networkPriority($1.networkKind)
                    return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
                }
            )
        }.sorted { $0.id < $1.id }
    }
}

public enum NetworkMembershipTaskKind: String, Codable, Sendable {
    case prepare, configure, revoke
}

public struct NetworkMembershipTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public let kind: NetworkMembershipTaskKind
    public let source: NetworkOnboardingEnvironment
    public let target: NetworkOnboardingEnvironment
    public var authorizationApplied: Bool = false
    public var configurationApplied: Bool = false
    public var lastAttempt: Date?
    public var lastError: String?
    public var sourceID: String { source.id }
    public var targetID: String { target.id }
    public var sourceName: String { source.displayName }
    public var targetName: String { target.displayName }
    public var sourceHostID: UUID { source.hostID }
    public var targetHostID: UUID { target.hostID }
    public var sourceEnvironmentID: String { source.environmentID }
    public var targetEnvironmentID: String { target.environmentID }
    public var sourceUsername: String { source.username }
    public var targetUsername: String { target.username }
}

/// Keep this journal when a member is removed: its snapshots make offline revocation possible.
public struct NetworkMembershipJournal: Codable, Equatable, Sendable {
    public var environments: [NetworkOnboardingEnvironment] = []
    public var pendingTasks: [NetworkMembershipTask] = []
    public var publicKeys: [String: String] = [:]
    public var hostPublicKeys: [String: [String]] = [:]
    public var completedTaskIDs: [String] = []
    public var managerID: String = UUID().uuidString.lowercased()
    public var windowsAuthorizationScopes: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case environments, pendingTasks, publicKeys, hostPublicKeys, completedTaskIDs, managerID, windowsAuthorizationScopes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        environments = try values.decodeIfPresent([NetworkOnboardingEnvironment].self, forKey: .environments) ?? []
        pendingTasks = try values.decodeIfPresent([NetworkMembershipTask].self, forKey: .pendingTasks) ?? []
        publicKeys = try values.decodeIfPresent([String: String].self, forKey: .publicKeys) ?? [:]
        hostPublicKeys = try values.decodeIfPresent([String: [String]].self, forKey: .hostPublicKeys) ?? [:]
        completedTaskIDs = try values.decodeIfPresent([String].self, forKey: .completedTaskIDs) ?? []
        managerID = try values.decodeIfPresent(String.self, forKey: .managerID) ?? UUID().uuidString.lowercased()
        windowsAuthorizationScopes = try values.decodeIfPresent([String: String].self, forKey: .windowsAuthorizationScopes) ?? [:]
    }
}

public struct NetworkMembershipRunResult: Equatable, Sendable {
    public let journal: NetworkMembershipJournal
    public let report: NetworkOnboardingReport
    public let managementAliases: [UUID: String]

    public init(journal: NetworkMembershipJournal, report: NetworkOnboardingReport, managementAliases: [UUID: String] = [:]) {
        self.journal = journal
        self.report = report
        self.managementAliases = managementAliases
    }

    public var isComplete: Bool { journal.pendingTasks.isEmpty && report.steps.allSatisfy(\.succeeded) }
}

public enum NetworkMembershipCommands {
    public static let managementIdentityFile = "~/.ssh/tmuxhub_management_ed25519"
    public static let managementPublicKeyFile = "~/.ssh/tmuxhub_management_ed25519.pub"
    public static let knownHostsFile = "~/.ssh/tmuxhub_mesh_known_hosts"
    static let includeLine = "Include ~/.ssh/tmuxhub_mesh.d/*.conf"

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    static func networkPriority(_ kind: NetworkMeshNetworkKind) -> Int {
        switch kind {
        case .campus: 0
        case .zeroTier: 1
        case .lan: 2
        case .publicInternet: 3
        case .other: 4
        }
    }

    public static func controlAlias(for endpoint: NetworkMeshEndpoint) -> String {
        "tmuxhub-control-\(endpoint.id.uuidString.lowercased())"
    }

    public static func managedAlias(for endpoint: NetworkMeshEndpoint) -> String {
        "tmuxhub-\(endpoint.id.uuidString.lowercased().prefix(12))"
    }

    static func configuration(_ endpoint: NetworkMeshEndpoint) throws -> SSHHostConfiguration {
        let rawAlias = endpoint.sshDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = rawAlias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"#, options: .regularExpression) != nil
            ? rawAlias : managedAlias(for: endpoint)
        return try SSHHostConfiguration(alias: alias, hostname: endpoint.address, username: endpoint.username, port: endpoint.port)
    }

    static func psQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    static func remoteInvocation(_ script: String, platform: NetworkMeshPlatform) -> String {
        if platform == .windows {
            let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
            return "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand \(encoded)"
        }
        return "sh -c \(NetworkOnboardingCommands.quote(script))"
    }

    static func managementCommand(
        endpoint: NetworkMeshEndpoint, script: String, interactive: Bool = false,
        tty: Bool = false, meshIdentity: Bool = false
    ) throws -> CommandSpec {
        let configuration = try configuration(endpoint)
        var arguments = [
            "-o", "StrictHostKeyChecking=\(interactive ? "ask" : "yes")", "-o", "ForwardAgent=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1", "-o", "HostName=\(configuration.hostname.replacingOccurrences(of: "%", with: "%%"))",
            "-p", String(configuration.port),
        ]
        if !interactive { arguments += ["-o", "BatchMode=yes"] }
        if tty { arguments.insert("-tt", at: 0) }
        if meshIdentity { arguments += ["-i", managementIdentityFile] }
        if !configuration.username.isEmpty { arguments += ["-l", configuration.username] }
        arguments += ["--", configuration.alias, remoteInvocation(script, platform: endpoint.platform)]
        return CommandSpec(executable: "/usr/bin/ssh", arguments: arguments)
    }

    static func identityScript(platform: NetworkMeshPlatform) -> String {
        if platform == .posix { return "# TMUXHUB PREPARE\n" + NetworkOnboardingCommands.keyGenerationScript }
        return """
            # TMUXHUB PREPARE
            $ErrorActionPreference = 'Stop'
            $dir = Join-Path $env:USERPROFILE '.ssh'
            [IO.Directory]::CreateDirectory($dir) | Out-Null
            $key = Join-Path $dir 'tmuxhub_mesh_ed25519'
            if (!(Test-Path -LiteralPath $key)) {
                & ssh-keygen.exe -q -t ed25519 -f $key -N '\"\"' -C 'TmuxHub-mesh'
                if ($LASTEXITCODE -ne 0) { throw 'Could not generate the mesh key. Install the OpenSSH Client capability first.' }
            }
            if (!(Test-Path -LiteralPath ($key + '.pub'))) { throw 'Existing mesh key has no public key file. It was not overwritten.' }
            Get-Content -LiteralPath ($key + '.pub')
            """
    }

    static func hostKeysScript(platform: NetworkMeshPlatform) -> String {
        if platform == .posix { return "# TMUXHUB HOSTKEYS\n" + NetworkOnboardingCommands.hostPublicKeysScript }
        return """
            # TMUXHUB HOSTKEYS
            $ErrorActionPreference = 'Stop'
            $keys = @(Get-ChildItem -Path (Join-Path $env:ProgramData 'ssh/ssh_host_*_key.pub') -ErrorAction Stop)
            if ($keys.Count -eq 0) { throw 'No SSH server public keys were found.' }
            foreach ($key in $keys) { Get-Content -LiteralPath $key.FullName }
            """
    }

    static var windowsAuthorizationPath: String {
        """
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $admin = @($identity.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-32-544'
            $auth = if ($admin) { Join-Path $env:ProgramData 'ssh/administrators_authorized_keys' } else { Join-Path $env:USERPROFILE '.ssh/authorized_keys' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($auth)) | Out-Null
            if (Test-Path -LiteralPath $auth) {
                if ((Get-Item -LiteralPath $auth).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'authorized_keys is a link. Add managed public keys to its target manually.' }
            }
            """
    }

    static func authorizationScript(sourceID: String, targetID: String, publicKey: String?, platform: NetworkMeshPlatform, revoke: Bool) throws -> String {
        guard sourceID.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil,
              targetID.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil else {
            throw NetworkOnboardingError.commandFailed("互联身份标识无效，请重新登记该环境。")
        }
        let marker = "tmuxhub-mesh:\(sourceID):\(targetID)"
        let line = try publicKey.map { try NetworkOnboardingCommands.validatedPublicKey($0) + " " + marker }
        if !revoke && line == nil { throw NetworkOnboardingError.commandFailed("来源主机尚未完成首次认证和独立密钥准备。") }
        if platform == .windows {
            let append = revoke ? "" : "$lines += \(psQuote(line!))"
            return """
                # TMUXHUB \(revoke ? "REVOKE" : "AUTHORIZE") \(sourceID)
                $ErrorActionPreference = 'Stop'
                try {
                    \(windowsAuthorizationPath)
                    $marker = \(psQuote(marker))
                    $lines = if (Test-Path -LiteralPath $auth) { @([IO.File]::ReadAllLines($auth)) } else { @() }
                    $lines = @($lines | Where-Object { ($_ -split '\\s+')[-1] -ne $marker })
                    \(append)
                    [IO.File]::WriteAllLines($auth, [string[]]$lines, [Text.UTF8Encoding]::new($false))
                    if ($admin) {
                        & icacls.exe $auth /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw 'Administrator authorized_keys ACL could not be set.' }
                    }
                    Write-Output 'TMUXHUB_APPLIED'
                } catch { Write-Error ('Administrator permissions or authorized_keys ACL need attention: ' + $_.Exception.Message); exit 1 }
                """
        }
        let append = revoke ? "" : "printf '%s\\n' \(NetworkOnboardingCommands.quote(line!)) >> \"$tmp\""
        return """
            # TMUXHUB \(revoke ? "REVOKE" : "AUTHORIZE") \(sourceID)
            set -eu
            umask 077
            mkdir -p "$HOME/.ssh"
            chmod 700 "$HOME/.ssh"
            auth="$HOME/.ssh/authorized_keys"
            test ! -L "$auth" || { printf 'authorized_keys is a symlink; configure its managed entries manually.\\n' >&2; exit 67; }
            touch "$auth"
            tmp=$(mktemp "$HOME/.ssh/tmuxhub-auth.XXXXXX")
            trap 'rm -f "$tmp"' EXIT HUP INT TERM
            awk -v marker=\(NetworkOnboardingCommands.quote(marker)) '$NF != marker' "$auth" > "$tmp"
            \(append)
            chmod 600 "$tmp"
            mv "$tmp" "$auth"
            printf 'TMUXHUB_APPLIED\\n'
            """
    }

    static func aliasConfiguration(target: NetworkOnboardingEnvironment, endpoints: [NetworkMeshEndpoint]? = nil) throws -> String {
        try (endpoints ?? target.endpoints).map { endpoint in
            let config = try configuration(endpoint)
            var lines = [
                "Host \(managedAlias(for: endpoint))", "    HostName \(config.hostname.replacingOccurrences(of: "%", with: "%%"))",
                "    Port \(config.port)", "    IdentityFile ~/.ssh/tmuxhub_mesh_ed25519",
                "    IdentitiesOnly yes", "    ForwardAgent no", "    StrictHostKeyChecking yes", "    ProxyCommand none", "    ProxyJump none",
                "    UserKnownHostsFile ~/.ssh/tmuxhub_mesh_known_hosts",
            ]
            if !config.username.isEmpty { lines.append("    User \(config.username)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\nHost *\n"
    }

    static func trustedLines(target: NetworkOnboardingEnvironment, keys: [String: [String]]) throws -> String {
        try target.endpoints.flatMap { endpoint -> [String] in
            guard let endpointKeys = keys[endpoint.id.uuidString], !endpointKeys.isEmpty else { return [] }
            let configuration = try configuration(endpoint)
            return try endpointKeys.map { "\(NetworkOnboardingCommands.knownHostsToken(configuration)) \(try NetworkOnboardingCommands.validatedPublicKey($0))" }
        }.joined(separator: "\n") + "\n"
    }

    static func sourceConfigurationScript(target: NetworkOnboardingEnvironment, keys: [String: [String]], platform: NetworkMeshPlatform, revoke: Bool) throws -> String {
        guard target.id.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil else {
            throw NetworkOnboardingError.commandFailed("互联身份标识无效，请重新登记该环境。")
        }
        let verifiedEndpoints = target.endpoints.filter { !(keys[$0.id.uuidString] ?? []).isEmpty }
        guard revoke || !verifiedEndpoints.isEmpty else {
            throw NetworkOnboardingError.commandFailed("目标环境尚无经过认证的入口指纹，请先完成首次登录。")
        }
        let config = revoke ? "" : try aliasConfiguration(target: target, endpoints: verifiedEndpoints)
        let fingerprints = revoke ? "" : try trustedLines(target: target, keys: keys)
        if platform == .windows {
            let mutation = revoke ? """
                Remove-Item -LiteralPath $configFile, $keysFile -ErrorAction SilentlyContinue
                """ : """
                [IO.File]::WriteAllText($configFile, \(psQuote(config)), $encoding)
                [IO.File]::WriteAllText($keysFile, \(psQuote(fingerprints)), $encoding)
                """
            return """
                # TMUXHUB \(revoke ? "REMOVE_CONFIG" : "CONFIGURE") \(target.id)
                $ErrorActionPreference = 'Stop'
                $encoding = [Text.UTF8Encoding]::new($false)
                $sshDir = Join-Path $env:USERPROFILE '.ssh'
                $userConfig = Join-Path $sshDir 'config'
                if (Test-Path -LiteralPath $userConfig) {
                    if (((Get-Item -LiteralPath $userConfig).Attributes -band [IO.FileAttributes]::ReparsePoint) -and ([IO.File]::ReadAllLines($userConfig) -notcontains \(psQuote(includeLine)))) { throw 'SSH config is a link. Manually add: Include ~/.ssh/tmuxhub_mesh.d/*.conf' }
                }
                $managed = Join-Path $sshDir 'tmuxhub_mesh.d'
                [IO.Directory]::CreateDirectory($managed) | Out-Null
                $configFile = Join-Path $managed '\(target.id).conf'
                $keysFile = Join-Path $managed '\(target.id).known_hosts'
                \(mutation)
                $allKeys = @(Get-ChildItem -Path $managed -Filter '*.known_hosts' | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
                [IO.File]::WriteAllLines((Join-Path $sshDir 'tmuxhub_mesh_known_hosts'), [string[]]$allKeys, $encoding)
                $userConfig = Join-Path $sshDir 'config'
                $lines = if (Test-Path -LiteralPath $userConfig) { @([IO.File]::ReadAllLines($userConfig)) } else { @() }
                if ($lines -notcontains \(psQuote(includeLine))) {
                    if (Test-Path -LiteralPath $userConfig) { Copy-Item -LiteralPath $userConfig -Destination ($userConfig + '.tmuxhub-mesh-backup') }
                    [IO.File]::WriteAllLines($userConfig, [string[]](@(\(psQuote(includeLine))) + $lines), $encoding)
                }
                Write-Output 'TMUXHUB_APPLIED'
                """
        }
        let mutation = revoke ? "rm -f \"$managed/\(target.id).conf\" \"$managed/\(target.id).known_hosts\"" : """
            printf '%s' \(NetworkOnboardingCommands.quote(config)) > "$managed/\(target.id).conf"
            printf '%s' \(NetworkOnboardingCommands.quote(fingerprints)) > "$managed/\(target.id).known_hosts"
            """
        return """
            # TMUXHUB \(revoke ? "REMOVE_CONFIG" : "CONFIGURE") \(target.id)
            set -eu
            umask 077
            if [ -L "$HOME/.ssh/config" ] && ! grep -Fqx -- \(NetworkOnboardingCommands.quote(includeLine)) "$HOME/.ssh/config"; then
                printf 'SSH config is a symlink. Manually add: Include ~/.ssh/tmuxhub_mesh.d/*.conf\\n' >&2; exit 67
            fi
            mkdir -p "$HOME/.ssh/tmuxhub_mesh.d"
            managed="$HOME/.ssh/tmuxhub_mesh.d"
            \(mutation)
            tmp=$(mktemp "$HOME/.ssh/tmuxhub-known-hosts.XXXXXX")
            trap 'rm -f "$tmp"' EXIT HUP INT TERM
            for file in "$managed"/*.known_hosts; do [ ! -f "$file" ] || cat "$file" >> "$tmp"; done
            chmod 600 "$tmp"
            mv "$tmp" "$HOME/.ssh/tmuxhub_mesh_known_hosts"
            touch "$HOME/.ssh/config"
            if ! grep -Fqx -- \(NetworkOnboardingCommands.quote(includeLine)) "$HOME/.ssh/config"; then
                cp -p "$HOME/.ssh/config" "$HOME/.ssh/config.tmuxhub-mesh-backup"
                printf '%s\\n' \(NetworkOnboardingCommands.quote(includeLine)) > "$tmp"
                cat "$HOME/.ssh/config" >> "$tmp"
                cat "$tmp" > "$HOME/.ssh/config"
            fi
            printf 'TMUXHUB_APPLIED\\n'
            """
    }

    static func probeScript(sourceEndpoint: NetworkMeshEndpoint, targetEndpoint: NetworkMeshEndpoint, token: String) throws -> String {
        let source = try configuration(sourceEndpoint)
        let target = try configuration(targetEndpoint)
        let markerScript = targetEndpoint.platform == .windows ? "Write-Output \(psQuote(token))" : "printf '%s\\n' \(NetworkOnboardingCommands.quote(token))"
        guard let family = sourceAddressFamily(sourceEndpoint.address), compatibleFamilies(source: sourceEndpoint, target: targetEndpoint) else {
            throw NetworkOnboardingError.commandFailed("该入口无法绑定实际来源 IP，或来源与目标的地址类型不兼容。")
        }
        var args = [
            family == AF_INET ? "-4" : "-6", "-F", sourceEndpoint.platform == .windows ? "NUL" : "/dev/null",
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ForwardAgent=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-b", source.hostname,
            "-p", String(target.port),
        ]
        if !target.username.isEmpty { args += ["-l", target.username] }
        args += ["--", target.hostname, remoteInvocation(markerScript, platform: targetEndpoint.platform)]
        if sourceEndpoint.platform == .windows {
            return """
                # TMUXHUB PROBE \(token)
                $ErrorActionPreference = 'Stop'
                $key = Join-Path $env:USERPROFILE '.ssh/tmuxhub_mesh_ed25519'
                $known = Join-Path $env:USERPROFILE '.ssh/tmuxhub_mesh_known_hosts'
                & ssh.exe '-i' $key '-o' ('UserKnownHostsFile=' + $known) \(args.map(psQuote).joined(separator: " "))
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                """
        }
        return """
            # TMUXHUB PROBE \(token)
            ssh -i "$HOME/.ssh/tmuxhub_mesh_ed25519" -o "UserKnownHostsFile=$HOME/.ssh/tmuxhub_mesh_known_hosts" \(args.map(NetworkOnboardingCommands.quote).joined(separator: " "))
            """
    }

    static func sourceAddressFamily(_ value: String) -> Int32? {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return AF_INET }
        let address = value.components(separatedBy: "%").first ?? value
        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return AF_INET6 }
        return nil
    }

    static func compatibleFamilies(source: NetworkMeshEndpoint, target: NetworkMeshEndpoint) -> Bool {
        guard let family = sourceAddressFamily(source.address) else { return false }
        return sourceAddressFamily(target.address).map { $0 == family } ?? true
    }

    static var windowsAccountScopeScript: String {
        """
            # TMUXHUB ACCOUNT_SCOPE
            $ErrorActionPreference = 'Stop'
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $sid = $identity.User.Value
            $admin = @($identity.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-32-544'
            if ($admin) {
                $machine = (Get-ItemProperty -LiteralPath 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' -Name MachineGuid).MachineGuid
                if (!$machine) { throw 'Could not identify administrator authorization scope.' }
                Write-Output ('TMUXHUB_WINDOWS_ADMIN:' + $machine + ':' + $sid)
            } else { Write-Output ('TMUXHUB_WINDOWS_USER:' + $sid) }
            """
    }

    /// Run on the new machine itself if no SSH server is listening yet.
    public static func serverSetupInstructions(platform: NetworkMeshPlatform, environmentName: String) -> String {
        if platform == .windows {
            return """
                # 在新 Windows 主机上以管理员身份打开 PowerShell
                Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
                Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
                Start-Service sshd
                Set-Service sshd -StartupType Automatic
                # 若安装时未创建规则，再启用 SSH 入站规则：
                if (!(Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }
                """
        }
        if environmentName.lowercased().contains("mac") {
            return "在新 Mac 的「系统设置 → 通用 → 共享」开启「远程登录」，并允许所选用户登录。"
        }
        return """
            # 在新 Linux / WSL 环境本机终端运行（Debian / Ubuntu）
            sudo apt-get update
            sudo apt-get install -y openssh-server
            sudo service ssh start
            # WSL 的 Windows 转发端口与 WSL sshd 端口应分别核对；WSL 与 Windows 分别登记环境。
            """
    }
}

extension NetworkOnboardingService {
    public func reconcile(
        hosts: [NetworkMeshHost], journal original: NetworkMembershipJournal, forceRepair: Bool = false,
        onProgress: @Sendable (NetworkOnboardingStep) async -> Void = { _ in }
    ) async -> NetworkMembershipRunResult {
        var journal = original
        if forceRepair {
            journal.completedTaskIDs.removeAll { $0.hasPrefix("prepare:") || $0.hasPrefix("configure:") }
            for index in journal.pendingTasks.indices where journal.pendingTasks[index].kind == .configure {
                journal.pendingTasks[index].authorizationApplied = false
                journal.pendingTasks[index].configurationApplied = false
            }
        }
        let memberHosts = hosts.filter(\.isMember)
        var desired = memberHosts.flatMap(NetworkOnboardingEnvironment.environments)
        for host in memberHosts where host.endpoints.isEmpty {
            let previous = journal.environments.filter { $0.hostID == host.id }
            if !previous.isEmpty {
                desired.append(contentsOf: previous)
            } else {
                let username = host.isLocal ? NSUserName() : ""
                let identity = "\(host.id.uuidString.lowercased())\u{0}main\u{0}\(username)\u{0}posix"
                desired.append(NetworkOnboardingEnvironment(id: NetworkMembershipCommands.digest(identity), hostID: host.id,
                    hostName: host.name, environmentID: "main", environmentName: host.isLocal ? "macOS" : "未登记环境",
                    username: username, platform: .posix, isLocal: host.isLocal, endpoints: []))
            }
        }
        let desiredIDs = Set(desired.map(\.id))
        var environments = Dictionary(journal.environments.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        for environment in desired {
            if let previous = environments[environment.id] {
                for endpoint in environment.endpoints {
                    if let old = previous.endpoints.first(where: { $0.id == endpoint.id }),
                       old.address != endpoint.address || old.port != endpoint.port || old.platform != endpoint.platform {
                        journal.hostPublicKeys[endpoint.id.uuidString] = nil
                    }
                }
            }
            environments[environment.id] = environment
        }
        journal.environments = environments.values.sorted { $0.id < $1.id }
        var steps: [NetworkOnboardingStep] = []
        var completions = Set(journal.completedTaskIDs)
        var preparationTasks: [NetworkMembershipTask] = []
        var blockedPreparationIDs: Set<String> = []
        for environment in desired {
            let signature = environmentSignature(environment)
            let taskID = "prepare:\(environment.id):\(signature)"
            if completions.contains(taskID), journal.publicKeys[environment.id] != nil,
               environment.endpoints.allSatisfy({ journal.hostPublicKeys[$0.id.uuidString] != nil }),
               environment.platform != .windows || journal.windowsAuthorizationScopes[environment.id] != nil { continue }
            var task = NetworkMembershipTask(id: taskID, kind: .prepare, source: environment, target: environment)
            task.lastAttempt = Date()
            var partialNetworkFailure = false
            do {
                try Task.checkCancellation()
                guard !environment.endpoints.isEmpty else {
                    throw NetworkOnboardingError.commandFailed("主机暂时没有可用入口；成员身份与已有授权保留，等待恢复。")
                }
                guard environment.isLocal || !environment.username.isEmpty else {
                    throw NetworkOnboardingError.commandFailed("请明确填写该系统环境的 SSH 用户名，再进行互联授权。")
                }
                if environment.platform == .windows {
                    let scopeOutput = try await runOnEnvironment(environment, script: NetworkMembershipCommands.windowsAccountScopeScript)
                    guard let scope = scopeOutput.stdout.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("TMUXHUB_WINDOWS_ADMIN:") || $0.hasPrefix("TMUXHUB_WINDOWS_USER:") }) else {
                        throw NetworkOnboardingError.commandFailed("无法确认 Windows 管理员授权文件的共享范围。")
                    }
                    journal.windowsAuthorizationScopes[environment.id] = String(scope).lowercased()
                }
                let output = try await runOnEnvironment(environment, script: NetworkMembershipCommands.identityScript(platform: environment.platform))
                journal.publicKeys[environment.id] = try NetworkOnboardingCommands.validatedPublicKey(output.stdout)
                var endpointErrors: [String] = []
                let hostKeyEndpoints = environment.isLocal ? Array(environment.endpoints.prefix(1)) : environment.endpoints
                for endpoint in hostKeyEndpoints {
                    do {
                        let keyOutput = try await runAtEndpoint(environment, endpoint: endpoint, script: NetworkMembershipCommands.hostKeysScript(platform: environment.platform))
                        let keys = try NetworkOnboardingCommands.validatedHostPublicKeys(keyOutput.stdout)
                        if environment.isLocal {
                            for localEndpoint in environment.endpoints { journal.hostPublicKeys[localEndpoint.id.uuidString] = keys }
                        } else {
                            journal.hostPublicKeys[endpoint.id.uuidString] = keys
                        }
                    } catch {
                        if error is CancellationError { throw error }
                        if !canTryNextNetworkRoute(after: error) { blockedPreparationIDs.insert(environment.id) }
                        endpointErrors.append("\(endpoint.label)：" + diagnostic(error))
                    }
                }
                if !endpointErrors.isEmpty {
                    partialNetworkFailure = !blockedPreparationIDs.contains(environment.id)
                    throw NetworkOnboardingError.commandFailed(endpointErrors.joined(separator: "\n"))
                }
                completions.insert(taskID)
                let step = NetworkOnboardingStep(title: "\(environment.displayName)：认证与密钥", detail: "独立私钥留在该环境；每个入口的服务器公钥均由已认证 SSH 读取。", succeeded: true)
                steps.append(step)
                await onProgress(step)
            } catch {
                if !partialNetworkFailure && !canTryNextNetworkRoute(after: error) { blockedPreparationIDs.insert(environment.id) }
                task.lastError = diagnostic(error)
                preparationTasks.append(task)
                let step = NetworkOnboardingStep(title: "\(environment.displayName)：等待准备", detail: task.lastError!, succeeded: false)
                steps.append(step)
                await onProgress(step)
                if error is CancellationError {
                    journal.pendingTasks = mergePending(journal.pendingTasks, adding: preparationTasks)
                    journal.completedTaskIDs = completions.sorted()
                    return NetworkMembershipRunResult(journal: journal, report: NetworkOnboardingReport(steps: steps))
                }
            }
        }
        let administratorGroups = Dictionary(grouping: desired.filter { journal.windowsAuthorizationScopes[$0.id]?.hasPrefix("tmuxhub_windows_admin:") == true }) { environment in
            journal.windowsAuthorizationScopes[environment.id]?.components(separatedBy: ":").dropLast().joined(separator: ":") ?? environment.id
        }
        let blockedAdministratorIDs = Set(administratorGroups.values.filter { group in
            Set(group.compactMap { journal.windowsAuthorizationScopes[$0.id]?.components(separatedBy: ":").last }).count > 1
        }.flatMap { $0.map(\.id) })
        let administratorLimitation = "同一 Windows 的多个管理员账户共用授权文件，无法保证账号隔离。请改用普通 SSH 用户；多个管理员账户暂不同时纳管。"
        for environment in desired where blockedAdministratorIDs.contains(environment.id) {
            let id = "prepare:\(environment.id):\(environmentSignature(environment))"
            completions.remove(id)
            if !preparationTasks.contains(where: { $0.id == id }) {
                var task = NetworkMembershipTask(id: id, kind: .prepare, source: environment, target: environment)
                task.lastAttempt = Date()
                task.lastError = administratorLimitation
                preparationTasks.append(task)
            }
            let step = NetworkOnboardingStep(title: "\(environment.displayName)：管理员账户待处理", detail: administratorLimitation, succeeded: false)
            steps.append(step)
            await onProgress(step)
        }
        let oldPending = Dictionary(journal.pendingTasks.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var planned = preparationTasks
        for source in journal.environments {
            for target in journal.environments where target.id != source.id {
                let pair = "\(source.id)>\(target.id)"
                let isDesired = desiredIDs.contains(source.id) && desiredIDs.contains(target.id)
                let kind: NetworkMembershipTaskKind = isDesired ? .configure : .revoke
                let relationshipExisted = original.completedTaskIDs.contains { $0.hasPrefix("configure:\(pair):") }
                    || original.pendingTasks.contains { $0.source.id == source.id && $0.target.id == target.id && $0.kind != .prepare }
                if !isDesired && !relationshipExisted { continue }
                if isDesired {
                    completions.remove("revoke:\(pair)")
                } else {
                    completions = Set(completions.filter { !$0.hasPrefix("configure:\(pair):") })
                }
                let revision = isDesired ? ":" + configurationRevision(source: source, target: target, journal: journal) : ""
                let id = "\(kind.rawValue):\(pair)\(revision)"
                if completions.contains(id) { continue }
                planned.append(oldPending[id] ?? NetworkMembershipTask(id: id, kind: kind, source: source, target: target))
            }
        }
        var pending = planned.filter { $0.kind == .prepare }
        // A departing/offline source does not block revoking its key on an online target.
        for var task in planned where task.kind != .prepare {
            task.lastAttempt = Date()
            if task.kind == .configure && (blockedAdministratorIDs.contains(task.source.id) || blockedAdministratorIDs.contains(task.target.id)) {
                task.lastError = administratorLimitation
                pending.append(task)
                continue
            }
            if task.kind == .configure && (blockedPreparationIDs.contains(task.source.id) || blockedPreparationIDs.contains(task.target.id)) {
                task.lastError = preparationTasks.first {
                    blockedPreparationIDs.contains($0.source.id) && ($0.source.id == task.source.id || $0.source.id == task.target.id)
                }?.lastError ?? "系统环境尚未完成安全认证。"
                pending.append(task)
                continue
            }
            var errors: [String] = []
            if !task.authorizationApplied {
                do {
                    try Task.checkCancellation()
                    let script = try NetworkMembershipCommands.authorizationScript(
                        sourceID: task.source.id, targetID: task.target.id, publicKey: journal.publicKeys[task.source.id],
                        platform: task.target.platform, revoke: task.kind == .revoke
                    )
                    let output = try await runOnEnvironment(task.target, script: script)
                    guard output.stdout.split(whereSeparator: \.isNewline).contains("TMUXHUB_APPLIED") else {
                        throw NetworkOnboardingError.commandFailed("远端未确认互联授权已写入。")
                    }
                    task.authorizationApplied = true
                } catch { errors.append("接收端授权：" + diagnostic(error)) }
            }
            if !task.configurationApplied {
                do {
                    try Task.checkCancellation()
                    let script = try NetworkMembershipCommands.sourceConfigurationScript(
                        target: task.target, keys: journal.hostPublicKeys,
                        platform: task.source.platform, revoke: task.kind == .revoke
                    )
                    let output = try await runOnEnvironment(task.source, script: script)
                    guard output.stdout.split(whereSeparator: \.isNewline).contains("TMUXHUB_APPLIED") else {
                        throw NetworkOnboardingError.commandFailed("远端未确认 SSH 别名与指纹配置已写入。")
                    }
                    task.configurationApplied = true
                } catch { errors.append("来源端配置：" + diagnostic(error)) }
            }
            if task.authorizationApplied && task.configurationApplied && task.kind == .configure {
                var routes: [(source: NetworkMeshEndpoint, target: NetworkMeshEndpoint)] = []
                for sourceEndpoint in task.source.endpoints where NetworkMembershipCommands.sourceAddressFamily(sourceEndpoint.address) != nil && !(journal.hostPublicKeys[sourceEndpoint.id.uuidString] ?? []).isEmpty {
                    for targetEndpoint in task.target.endpoints where !(journal.hostPublicKeys[targetEndpoint.id.uuidString] ?? []).isEmpty && NetworkMembershipCommands.compatibleFamilies(source: sourceEndpoint, target: targetEndpoint) {
                        routes.append((sourceEndpoint, targetEndpoint))
                    }
                }
                routes.sort {
                    let lhsPriority = max(NetworkMembershipCommands.networkPriority($0.source.networkKind), NetworkMembershipCommands.networkPriority($0.target.networkKind))
                        + ($0.source.networkKind == $0.target.networkKind ? 0 : 10)
                    let rhsPriority = max(NetworkMembershipCommands.networkPriority($1.source.networkKind), NetworkMembershipCommands.networkPriority($1.target.networkKind))
                        + ($1.source.networkKind == $1.target.networkKind ? 0 : 10)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                    let lhsID = $0.source.id.uuidString + $0.target.id.uuidString
                    let rhsID = $1.source.id.uuidString + $1.target.id.uuidString
                    return lhsID < rhsID
                }
                var verifiedRoute = false
                var routeErrors: [String] = []
                for route in routes {
                    do {
                        try Task.checkCancellation()
                        let token = "TMUXHUB_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        let script = try NetworkMembershipCommands.probeScript(sourceEndpoint: route.source, targetEndpoint: route.target, token: token)
                        let output = try await runOnEnvironment(task.source, script: script)
                        guard output.stdout.split(whereSeparator: \.isNewline).contains(Substring(token)) else {
                            throw NetworkOnboardingError.commandFailed("SSH 未返回本次验证标记，无法确认远端命令执行成功。")
                        }
                        verifiedRoute = true
                        let step = NetworkOnboardingStep(title: "\(task.source.hostName) / \(route.source.label) → \(task.target.hostName) / \(route.target.label)", detail: "绑定来源 \(route.source.address)，独立密钥登录与服务器指纹验证通过。", succeeded: true)
                        steps.append(step)
                        await onProgress(step)
                        break
                    } catch {
                        routeErrors.append("\(route.source.label) → \(route.target.label)：" + diagnostic(error))
                        guard canTryNextNetworkRoute(after: error) else { break }
                    }
                }
                if !verifiedRoute {
                    errors += routeErrors.isEmpty ? ["没有地址类型兼容且可绑定来源 IP 的直连路径。"] : routeErrors
                }
            }
            if errors.isEmpty && task.authorizationApplied && task.configurationApplied {
                completions.insert(task.id)
                let step = NetworkOnboardingStep(title: "\(task.sourceName) → \(task.targetName)", detail: task.kind == .revoke ? "已撤销接收端互联公钥和来源端别名、指纹；现有 SSH 会话保持。" : "授权、配置与直连验证完成。", succeeded: true)
                steps.append(step)
                await onProgress(step)
            } else {
                task.lastError = errors.joined(separator: "\n")
                pending.append(task)
                let step = NetworkOnboardingStep(title: "\(task.sourceName) → \(task.targetName)", detail: (task.kind == .revoke ? "待撤销：" : "待补配：") + (task.lastError ?? "尚未完成"), succeeded: false)
                steps.append(step)
                await onProgress(step)
            }
            if Task.isCancelled {
                let processedIDs = Set(pending.map(\.id)).union(completions)
                pending += planned.filter { !processedIDs.contains($0.id) && $0.kind != .prepare }
                break
            }
        }
        var managementAliases: [UUID: String] = [:]
        for environment in desired where !environment.isLocal {
            for endpoint in environment.endpoints {
                guard let publicKeys = journal.hostPublicKeys[endpoint.id.uuidString], !publicKeys.isEmpty else { continue }
                do {
                    managementAliases[endpoint.id] = try await saveControllerAlias(endpoint: endpoint, publicKeys: publicKeys)
                } catch {
                    let id = "controller:\(endpoint.id.uuidString)"
                    var task = NetworkMembershipTask(id: id, kind: .prepare, source: environment, target: environment)
                    task.lastAttempt = Date()
                    task.lastError = diagnostic(error)
                    pending.append(task)
                    let step = NetworkOnboardingStep(title: "\(environment.displayName) / \(endpoint.label)：管理别名待保存", detail: task.lastError!, succeeded: false)
                    steps.append(step)
                    await onProgress(step)
                }
            }
        }
        journal.pendingTasks = pending
        journal.completedTaskIDs = completions.sorted()
        let pendingEnvironmentIDs = Set(pending.flatMap { [$0.source.id, $0.target.id] })
        journal.environments.removeAll { !desiredIDs.contains($0.id) && !pendingEnvironmentIDs.contains($0.id) }
        // Retain only metadata referenced by current members or outstanding revocations.
        let retainedIDs = Set(journal.environments.map(\.id))
        journal.publicKeys = journal.publicKeys.filter { retainedIDs.contains($0.key) }
        journal.windowsAuthorizationScopes = journal.windowsAuthorizationScopes.filter { retainedIDs.contains($0.key) }
        let retainedEndpoints = Set(journal.environments.flatMap(\.endpoints).map { $0.id.uuidString })
        journal.hostPublicKeys = journal.hostPublicKeys.filter { retainedEndpoints.contains($0.key) }
        return NetworkMembershipRunResult(journal: journal, report: NetworkOnboardingReport(steps: steps), managementAliases: managementAliases)
    }

    private func environmentSignature(_ environment: NetworkOnboardingEnvironment) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return NetworkMembershipCommands.digest(String(decoding: (try? encoder.encode(environment)) ?? Data(), as: UTF8.self))
    }

    private func configurationRevision(source: NetworkOnboardingEnvironment, target: NetworkOnboardingEnvironment, journal: NetworkMembershipJournal) -> String {
        let keys = (source.endpoints + target.endpoints).map {
            $0.id.uuidString + ":" + (journal.hostPublicKeys[$0.id.uuidString]?.joined(separator: "\n") ?? "")
        }.joined(separator: "\n")
        return NetworkMembershipCommands.digest(environmentSignature(source) + environmentSignature(target) + (journal.publicKeys[source.id] ?? "") + keys)
    }

    private func mergePending(_ original: [NetworkMembershipTask], adding additions: [NetworkMembershipTask]) -> [NetworkMembershipTask] {
        var tasks = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        for task in additions { tasks[task.id] = task }
        return tasks.values.sorted { $0.id < $1.id }
    }

    private func runAtEndpoint(_ environment: NetworkOnboardingEnvironment, endpoint: NetworkMeshEndpoint, script: String) async throws -> InventoryProcessOutput {
        if environment.isLocal {
            guard environment.platform == .posix else { throw NetworkOnboardingError.commandFailed("本机直连仅支持当前 macOS 环境；Windows 环境需使用独立 SSH 入口。") }
            return try await checkedRun(localCommand(script))
        }
        return try await runManagementEndpoint(endpoint: endpoint, script: script)
    }

    var hasManagementIdentity: Bool {
        FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent(".ssh/tmuxhub_management_ed25519").path)
    }

    func runManagementEndpoint(endpoint: NetworkMeshEndpoint, script: String) async throws -> InventoryProcessOutput {
        let useManagementIdentity = hasManagementIdentity
        do {
            return try await checkedRun(NetworkMembershipCommands.managementCommand(
                endpoint: endpoint, script: script, meshIdentity: useManagementIdentity
            ))
        } catch {
            if error is CancellationError { throw error }
            let detail = error.localizedDescription.lowercased()
            let identityFailure = detail.contains("permission denied") || detail.contains("no such identity")
                || (detail.contains("identity file") && detail.contains("not accessible"))
            let trustFailure = detail.contains("host key verification failed") || detail.contains("remote host identification has changed")
            guard useManagementIdentity && identityFailure && !trustFailure else { throw error }
            // Imported SSH aliases keep their original credentials until manager setup succeeds.
            return try await checkedRun(NetworkMembershipCommands.managementCommand(endpoint: endpoint, script: script))
        }
    }

    private func canTryNextNetworkRoute(after error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        if error is InventoryProcessTimeoutError { return true }
        let detail = error.localizedDescription.lowercased()
        return NetworkMeshProbeParser.isNetworkFailure(detail)
    }

    private func runOnEnvironment(_ environment: NetworkOnboardingEnvironment, script: String) async throws -> InventoryProcessOutput {
        var lastError: Error = NetworkOnboardingError.commandFailed("该系统环境没有 SSH 入口。")
        for endpoint in environment.endpoints {
            do { return try await runAtEndpoint(environment, endpoint: endpoint, script: script) }
            catch {
                lastError = error
                guard canTryNextNetworkRoute(after: error) else { throw error }
            }
        }
        throw lastError
    }
}
