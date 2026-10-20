import Foundation

/// A physical host. All of its addresses remain separate SSH destinations.
public struct NetworkOnboardingPeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let configurations: [SSHHostConfiguration]
    public let isLocal: Bool

    public init(id: String, name: String, configurations: [SSHHostConfiguration], isLocal: Bool = false) {
        self.id = id
        self.name = name
        self.configurations = configurations
        self.isLocal = isLocal
    }
}

public struct NetworkOnboardingStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let succeeded: Bool

    public init(title: String, detail: String, succeeded: Bool) {
        id = UUID()
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
    }
}

public struct NetworkOnboardingReport: Equatable, Sendable {
    public let steps: [NetworkOnboardingStep]
    public var succeeded: Bool { !steps.isEmpty && steps.allSatisfy(\.succeeded) }
}

public struct NetworkOnboardingSaveReport: Equatable, Sendable {
    public let savedAliases: [String]
    public let existingAliases: [String]
    public let failures: [NetworkOnboardingStep]
}

public struct NetworkOnboardingVerification: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let alias: String
    public let address: String
    public let succeeded: Bool
    public let detail: String

    init(configuration: SSHHostConfiguration, succeeded: Bool, detail: String) {
        id = UUID()
        alias = configuration.alias
        address = configuration.hostname
        self.succeeded = succeeded
        self.detail = detail
    }
}

public struct NetworkZeroTierStatus: Equatable, Sendable {
    public let networkID: String
    public let status: String
    public let addresses: [String]
    public let detail: String
    public var isReady: Bool { status == "OK" && !addresses.isEmpty }
    public var awaitsAuthorization: Bool { status == "ACCESS_DENIED" }

    public static func parse(_ output: String, networkID: String) throws -> Self {
        let id = try NetworkOnboardingCommands.validatedNetworkID(networkID)
        let data = Data(output.utf8)
        guard let networks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NetworkOnboardingError.invalidZeroTierResponse
        }
        guard let network = networks.first(where: {
            (($0["nwid"] as? String) ?? ($0["id"] as? String))?.lowercased() == id
        }) else {
            return Self(networkID: id, status: "NOT_JOINED", addresses: [], detail: "此主机尚未加入该网络。")
        }
        let status = network["status"] as? String ?? "UNKNOWN"
        let addresses = network["assignedAddresses"] as? [String] ?? []
        let detail: String
        switch status {
        case "OK": detail = addresses.isEmpty ? "网络已授权，等待分配 IP。" : "网络已授权并分配 IP。"
        case "ACCESS_DENIED": detail = "加入请求已提交，等待网络管理员在 ZeroTier Central 授权。"
        case "REQUESTING_CONFIGURATION": detail = "正在向网络控制器请求配置；尚未确认网络授权。"
        case "NOT_FOUND": detail = "网络控制器未找到该网络，请检查网络 ID。"
        default: detail = "ZeroTier 状态：\(status)"
        }
        return Self(networkID: id, status: status, addresses: addresses, detail: detail)
    }
}

public enum NetworkOnboardingError: Error, LocalizedError {
    case invalidPublicKey
    case invalidNetworkID
    case invalidZeroTierResponse
    case invalidPublicKeyPath
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey: "远端返回的 SSH 公钥格式无效。"
        case .invalidNetworkID: "ZeroTier 网络 ID 必须是 16 位十六进制字符。"
        case .invalidZeroTierResponse: "无法读取 ZeroTier 网络状态。"
        case .invalidPublicKeyPath: "请选择以 .pub 结尾的 SSH 公钥文件。"
        case .commandFailed(let detail): detail
        }
    }
}

/// Commands never disable host verification or forward the Mac's SSH agent.
public enum NetworkOnboardingCommands {
    public static let meshIdentityFile = "~/.ssh/tmuxhub_mesh_ed25519"
    public static let meshPublicKeyFile = "~/.ssh/tmuxhub_mesh_ed25519.pub"

    public static func validatedNetworkID(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil else {
            throw NetworkOnboardingError.invalidNetworkID
        }
        return value
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let supportedPublicKeyTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    static func validatedHostPublicKeys(_ output: String) throws -> [String] {
        let keys = try output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let type = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            guard let type, supportedPublicKeyTypes.contains(type) else { return nil }
            return try validatedPublicKey(String(line))
        }
        guard !keys.isEmpty else { throw NetworkOnboardingError.invalidPublicKey }
        return Array(Set(keys)).sorted()
    }

    static func validatedPublicKey(_ value: String) throws -> String {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.utf8.count <= 16_384, !line.contains("\n"), !line.contains("\r"), !line.contains("\0") else {
            throw NetworkOnboardingError.invalidPublicKey
        }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2,
              supportedPublicKeyTypes.contains(String(parts[0])),
              let decoded = Data(base64Encoded: String(parts[1])), decoded.count >= 16
        else { throw NetworkOnboardingError.invalidPublicKey }
        let bytes = [UInt8](decoded)
        let typeLength = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard typeLength > 0, typeLength <= 128, bytes.count > 4 + typeLength,
              String(bytes: bytes[4..<(4 + typeLength)], encoding: .utf8) == String(parts[0]) else {
            throw NetworkOnboardingError.invalidPublicKey
        }
        if parts[0] == "ssh-ed25519" {
            guard bytes.count == 51, Array(bytes[15..<19]) == [0, 0, 0, 32] else {
                throw NetworkOnboardingError.invalidPublicKey
            }
        }
        // Comments are intentionally removed, leaving only the key's type and data.
        return "\(parts[0]) \(parts[1])"
    }

    static func ssh(_ configuration: SSHHostConfiguration, script: String, interactive: Bool = false, meshIdentity: Bool = false) -> CommandSpec {
        var arguments = [
            "-o", "StrictHostKeyChecking=\(interactive ? "ask" : "yes")",
            "-o", "ForwardAgent=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
            "-o", "HostName=\(configuration.hostname.replacingOccurrences(of: "%", with: "%%"))",
            "-p", String(configuration.port),
        ]
        if !interactive { arguments += ["-o", "BatchMode=yes"] }
        if !configuration.username.isEmpty { arguments += ["-l", configuration.username] }
        if meshIdentity { arguments += ["-i", meshIdentityFile, "-o", "IdentitiesOnly=yes"] }
        arguments += ["--", configuration.alias, "sh -c \(quote(script))"]
        return CommandSpec(executable: "/usr/bin/ssh", arguments: arguments)
    }

    /// The interactive Terminal is the only place where passwords and new fingerprints are accepted.
    public static func bootstrapCommand(
        configuration: SSHHostConfiguration,
        publicKeyPath: String = meshPublicKeyFile,
        zeroTierNetworkID: String? = nil
    ) throws -> CommandSpec {
        let trimmedPath = publicKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.hasSuffix(".pub"), !trimmedPath.contains("\0"), !trimmedPath.contains("\n"),
              trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("~/")
        else { throw NetworkOnboardingError.invalidPublicKeyPath }
        let path = trimmedPath.hasPrefix("~/")
            ? "\"$HOME\"/" + quote(String(trimmedPath.dropFirst(2))) : quote(trimmedPath)
        let prepareDefaultKey = trimmedPath == meshPublicKeyFile ? keyGenerationScript : ""
        let installer = """
            set -eu
            umask 077
            IFS= read -r key
            mkdir -p "$HOME/.ssh"
            chmod 700 "$HOME/.ssh"
            touch "$HOME/.ssh/authorized_keys"
            chmod 600 "$HOME/.ssh/authorized_keys"
            grep -Fqx -- "$key" "$HOME/.ssh/authorized_keys" || printf '%s\\n' "$key" >> "$HOME/.ssh/authorized_keys"
            printf 'SSH public key installed.\\n'
            """
        let installCommand = try ShellCommandRenderer.render(ssh(configuration, script: installer, interactive: true))
        var script = """
            set -eu
            \(prepareDefaultKey)
            key_file=\(path)
            ssh-keygen -l -f "$key_file" >/dev/null
            key=$(awk 'NF && $1 !~ /^#/ { print; exit }' "$key_file")
            test -n "$key"
            printf '%s\\n' "$key" | \(installCommand)
            """
        if let zeroTierNetworkID, !zeroTierNetworkID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let networkID = try validatedNetworkID(zeroTierNetworkID)
            let joinScript = """
                set -eu
                \(zeroTierExecutableScript)
                sudo "$zt" join \(quote(networkID))
                sudo "$zt" -j listnetworks
                printf '\\nNetwork authorization may still be required in ZeroTier Central.\\n'
                """
            var join = ssh(configuration, script: joinScript, interactive: true)
            join = CommandSpec(executable: join.executable, arguments: ["-tt"] + join.arguments)
            script += "\n" + (try ShellCommandRenderer.render(join))
        }
        script += "\nprintf '\\nReturn to TmuxHub and verify each address.\\n'\n"
        return CommandSpec(executable: "/bin/sh", arguments: ["-c", script])
    }

    public static func trustCommand(configuration: SSHHostConfiguration) -> CommandSpec {
        ssh(configuration, script: "printf 'SSH host identity verified.\\n'", interactive: true, meshIdentity: true)
    }

    public static func prepareSpeedToolsCommand(configuration: SSHHostConfiguration) -> CommandSpec {
        let script = """
            set -eu
            PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
            export PATH
            if ! command -v iperf3 >/dev/null 2>&1; then
                case "$(uname -s)" in
                    Darwin)
                        command -v brew >/dev/null 2>&1 || { printf 'Install Homebrew or iperf3 manually, then retry.\\n' >&2; exit 69; }
                        brew install iperf3
                        ;;
                    Linux)
                        if command -v apt-get >/dev/null 2>&1; then
                            sudo apt-get update
                            if command -v debconf-set-selections >/dev/null 2>&1; then
                                printf 'iperf3 iperf3/start_daemon boolean false\\n' | sudo debconf-set-selections
                            fi
                            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3
                        elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y iperf3
                        elif command -v yum >/dev/null 2>&1; then sudo yum install -y iperf3
                        elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --needed iperf3
                        elif command -v zypper >/dev/null 2>&1; then sudo zypper install iperf3
                        else printf 'Install iperf3 with your package manager, then retry.\\n' >&2; exit 69
                        fi
                        ;;
                    *) printf 'Install iperf3 manually on this platform.\\n' >&2; exit 69 ;;
                esac
            fi
            command -v iperf3
            iperf3 --version
            printf '\\niperf3 ready. No permanent server was started.\\n'
            """
        let command = ssh(configuration, script: script, interactive: true)
        return CommandSpec(executable: command.executable, arguments: ["-tt"] + command.arguments)
    }

    static let keyGenerationScript = """
        set -eu
        umask 077
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        mesh_key="$HOME/.ssh/tmuxhub_mesh_ed25519"
        if [ ! -e "$mesh_key" ]; then
            ssh-keygen -q -t ed25519 -f "$mesh_key" -N '' -C 'TmuxHub mesh'
        fi
        test -f "$mesh_key.pub" || { printf 'Existing mesh key has no .pub file.\\n' >&2; exit 65; }
        chmod 600 "$mesh_key"
        cat "$mesh_key.pub"
        """

    static let hostPublicKeysScript = """
        set -eu
        found=0
        for key in /etc/ssh/ssh_host_*_key.pub; do
            if [ -r "$key" ]; then cat "$key"; found=1; fi
        done
        test "$found" = 1 || { printf 'Cannot read SSH server public keys.\\n' >&2; exit 66; }
        """

    static let zeroTierExecutableScript = """
        zt=$(command -v zerotier-cli || true)
        if [ -z "$zt" ]; then
            for candidate in /opt/homebrew/bin/zerotier-cli /opt/homebrew/sbin/zerotier-cli /usr/local/bin/zerotier-cli /usr/local/sbin/zerotier-cli /usr/sbin/zerotier-cli '/Library/Application Support/ZeroTier/One/zerotier-cli'; do
                if [ -x "$candidate" ]; then zt="$candidate"; break; fi
            done
        fi
        test -n "$zt" || { printf 'ZeroTier is not installed. Install from https://www.zerotier.com/download/ and retry.\\n' >&2; exit 69; }
        """

    static func authorizationScript(publicKeys: [String], knownHostsLines: [String]) throws -> String {
        let keys = try publicKeys.map(validatedPublicKey)
        var script = """
            set -eu
            umask 077
            mkdir -p "$HOME/.ssh"
            chmod 700 "$HOME/.ssh"
            touch "$HOME/.ssh/authorized_keys" "$HOME/.ssh/known_hosts"
            chmod 600 "$HOME/.ssh/authorized_keys" "$HOME/.ssh/known_hosts"
            """
        for key in Set(keys).sorted() {
            script += "\ngrep -Fqx -- \(quote(key)) \"$HOME/.ssh/authorized_keys\" || printf '%s\\n' \(quote(key)) >> \"$HOME/.ssh/authorized_keys\""
        }
        for line in Set(knownHostsLines).sorted() {
            script += "\ngrep -Fqx -- \(quote(line)) \"$HOME/.ssh/known_hosts\" || printf '%s\\n' \(quote(line)) >> \"$HOME/.ssh/known_hosts\""
        }
        return script + "\nprintf 'Mesh public keys and verified host fingerprints installed.\\n'\n"
    }

    static func knownHostsToken(_ configuration: SSHHostConfiguration) -> String {
        configuration.port == 22 ? configuration.hostname : "[\(configuration.hostname)]:\(configuration.port)"
    }

    static func meshProbeScript(_ configuration: SSHHostConfiguration) -> String {
        var arguments = [
            "ssh", "-i", "$HOME/.ssh/tmuxhub_mesh_ed25519", "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1", "-p", String(configuration.port),
        ]
        if !configuration.username.isEmpty { arguments += ["-l", configuration.username] }
        arguments += ["--", configuration.hostname, "true"]
        // Expand only the source host's own key path; all user fields are shell quoted.
        return arguments.map { $0 == "$HOME/.ssh/tmuxhub_mesh_ed25519" ? "\"$HOME/.ssh/tmuxhub_mesh_ed25519\"" : quote($0) }.joined(separator: " ")
    }
}

public actor NetworkOnboardingService {
    let runner: any InventoryProcessRunning
    let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        runner = TimedInventoryProcessRunner(timeout: .seconds(25), underlying: FoundationInventoryProcessRunner())
    }

    init(runner: any InventoryProcessRunning, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        self.homeDirectory = homeDirectory
    }

    /// Existing aliases keep their settings; new aliases receive the local management identity.
    public func saveConfigurations(_ configurations: [SSHHostConfiguration]) -> NetworkOnboardingSaveReport {
        var saved: [String] = []
        var existing: [String] = []
        var failures: [NetworkOnboardingStep] = []
        do {
            var aliases = Set(try SSHConfigCatalog(homeDirectory: homeDirectory).loadForConfigurationEdit().map { $0.destination.lowercased() })
            let writer = SSHConfigWriter(homeDirectory: homeDirectory)
            for configuration in configurations {
                if aliases.contains(configuration.alias.lowercased()) {
                    existing.append(configuration.alias)
                    continue
                }
                do {
                    let prepared = try SSHHostConfiguration(
                        alias: configuration.alias, hostname: configuration.hostname, username: configuration.username,
                        port: configuration.port, identityFile: configuration.identityFile ?? (hasManagementIdentity ? NetworkMembershipCommands.managementIdentityFile : nil)
                    )
                    _ = try writer.add(prepared)
                    aliases.insert(configuration.alias.lowercased())
                    saved.append(configuration.alias)
                } catch {
                    failures.append(NetworkOnboardingStep(title: "保存 \(configuration.alias)", detail: error.localizedDescription, succeeded: false))
                }
            }
        } catch {
            failures.append(NetworkOnboardingStep(title: "读取 SSH 配置", detail: error.localizedDescription, succeeded: false))
        }
        return NetworkOnboardingSaveReport(savedAliases: saved, existingAliases: existing, failures: failures)
    }

    public func verify(configuration: SSHHostConfiguration) async -> NetworkOnboardingVerification {
        do {
            _ = try await checkedRun(NetworkOnboardingCommands.ssh(configuration, script: "true", meshIdentity: true))
            return NetworkOnboardingVerification(configuration: configuration, succeeded: true, detail: "SSH 登录成功；服务器指纹已验证。")
        } catch {
            return NetworkOnboardingVerification(configuration: configuration, succeeded: false, detail: diagnostic(error))
        }
    }

    public func zeroTierStatus(configuration: SSHHostConfiguration, networkID: String) async throws -> NetworkZeroTierStatus {
        let script = """
            set -eu
            \(NetworkOnboardingCommands.zeroTierExecutableScript)
            "$zt" -j listnetworks 2>/dev/null || sudo -n "$zt" -j listnetworks
            """
        let output = try await checkedRun(NetworkOnboardingCommands.ssh(configuration, script: script, meshIdentity: true))
        return try NetworkZeroTierStatus.parse(output.stdout, networkID: networkID)
    }

    func localCommand(_ script: String) -> CommandSpec {
        let localScript = "tmuxhub_home=\(NetworkOnboardingCommands.quote(homeDirectory.path))\n" + script.replacingOccurrences(of: "$HOME", with: "$tmuxhub_home")
        return CommandSpec(executable: "/bin/sh", arguments: ["-c", localScript])
    }

    func checkedRun(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        try Task.checkCancellation()
        let output = try await runner.run(command)
        try Task.checkCancellation()
        guard output.exitCode == 0 else {
            throw NetworkOnboardingError.commandFailed(Self.sanitizedDiagnostic(output.stderr.isEmpty ? output.stdout : output.stderr) ?? "命令失败（\(output.exitCode)）。")
        }
        return output
    }

    func diagnostic(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消；已完成的公钥授权会保留。" }
        return Self.sanitizedDiagnostic(error.localizedDescription) ?? "操作失败。"
    }

    private static func sanitizedDiagnostic(_ value: String) -> String? {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(4_096))
    }
}
