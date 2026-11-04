import Foundation

public struct HerdrInstallationResult: Equatable, Sendable {
    public let executablePath: String
    public let version: String

    static func parse(_ output: String) throws -> Self {
        let lines = output.components(separatedBy: "\n")
        guard let marker = lines.lastIndex(where: {
            $0.hasPrefix("TMUXHUB_HERDR_INSTALL_V1\t")
        }), lines.count == marker + 3, lines[marker + 2].isEmpty else {
            throw HerdrInstallationError.unexpectedResponse
        }
        let fields = lines[marker].components(separatedBy: "\t")
        let path = lines[marker + 1]
        guard fields.count == 2,
            !fields[1].isEmpty, fields[1].utf8.count <= 256,
            !fields[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            path.hasPrefix("/"), path.utf8.count <= 16_384,
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw HerdrInstallationError.unexpectedResponse }
        return Self(executablePath: path, version: fields[1])
    }
}

public enum HerdrInstallationError: LocalizedError, Equatable, Sendable {
    case alreadyInstalling
    case commandFailed(exitCode: Int32, detail: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalling:
            "正在为此主机安装 Herdr，请稍候。"
        case let .commandFailed(exitCode, detail):
            detail.isEmpty
                ? "Herdr 安装失败（退出码 \(exitCode)），请检查网络、SSH 连接和主目录权限。"
                : "Herdr 安装失败（退出码 \(exitCode)）：\(detail)"
        case .unexpectedResponse:
            "Herdr 安装程序已结束，但未能验证可执行文件和版本。请检查目标主机后重试。"
        }
    }
}

enum HerdrInstallationCommand {
    static let installerURL = "https://herdr.dev/install.sh"

    static func make(target: TerminalTarget) throws -> CommandSpec {
        switch target {
        case .local:
            return CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", script, "tmuxhub-herdr-install"]
            )
        case let .ssh(destination):
            guard IdentifierValidator.isSSHDestination(destination) else {
                throw CommandValidationError.invalidSSHDestination
            }
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    destination,
                    "exec /bin/sh -c " + HerdrCommands.shellQuote(script)
                        + " tmuxhub-herdr-install",
                ]
            )
        }
    }

    private static let script = #"""
        set -eu
        export LC_ALL=C
        case "${HOME:-}" in /*) ;; *) exit 20 ;; esac
        HERDR_INSTALL_DIR="$HOME/.local/bin"
        export HERDR_INSTALL_DIR

        tmuxhub_find_herdr() {
            for tmuxhub_candidate in "$HOME/.local/bin/herdr" "$HOME/.local/share/mise/shims/herdr" "$HOME/.nix-profile/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr /opt/local/bin/herdr /run/current-system/sw/bin/herdr /nix/var/nix/profiles/default/bin/herdr /usr/bin/herdr; do
                if test -x "$tmuxhub_candidate"; then
                    printf '%s\n' "$tmuxhub_candidate"
                    return 0
                fi
            done
            command -v herdr 2>/dev/null || return 1
        }
        tmuxhub_report_herdr() {
            tmuxhub_binary=$1
            test -n "$tmuxhub_binary" && test -x "$tmuxhub_binary"
            case "$tmuxhub_binary" in /*) ;; *) exit 22 ;; esac
            tmuxhub_version=$("$tmuxhub_binary" --version 2>&1) || exit 23
            test -n "$tmuxhub_version"
            printf 'TMUXHUB_HERDR_INSTALL_V1\t%s\n%s\n' "$tmuxhub_version" "$tmuxhub_binary"
        }

        tmuxhub_existing=$(tmuxhub_find_herdr || true)
        if test -n "$tmuxhub_existing"; then
            tmuxhub_report_herdr "$tmuxhub_existing"
            exit 0
        fi

        tmuxhub_tmp=${TMPDIR:-/tmp}
        case "$tmuxhub_tmp" in /*) ;; *) tmuxhub_tmp=/tmp ;; esac
        tmuxhub_work=$(mktemp -d "$tmuxhub_tmp/tmuxhub-herdr.XXXXXX")
        trap 'rm -rf "$tmuxhub_work"' EXIT
        trap 'exit 1' HUP INT TERM
        tmuxhub_installer="$tmuxhub_work/install.sh"
        curl -fsSL --output "$tmuxhub_installer" https://herdr.dev/install.sh
        test -f "$tmuxhub_installer" && test ! -L "$tmuxhub_installer"
        tmuxhub_size=$(wc -c < "$tmuxhub_installer" | tr -d ' ')
        case "$tmuxhub_size" in ''|*[!0-9]*) exit 21 ;; esac
        test "$tmuxhub_size" -ge 128 && test "$tmuxhub_size" -le 1048576
        /bin/sh "$tmuxhub_installer"

        tmuxhub_binary=$(tmuxhub_find_herdr || true)
        test -n "$tmuxhub_binary" || exit 22
        tmuxhub_report_herdr "$tmuxhub_binary"
        """#
}

/// Installs Herdr through its official stable-channel installer when it is
/// missing. Existing direct or package-manager installations are left intact.
/// The downloaded installer is staged before execution so network errors can
/// never leave a partially streamed shell program running.
public actor HerdrInstallationService {
    private let processRunner: any InventoryProcessRunning
    private let sshMasterPool: SSHMasterPool?
    private let executionPolicy: BoundedAsyncOperationRunner?
    private var installingTargets: Set<TerminalTarget> = []

    public init(sshMasterPool: SSHMasterPool) {
        let timeout: Duration = .seconds(300)
        processRunner = TimedInventoryProcessRunner(
            timeout: timeout,
            underlying: FoundationInventoryProcessRunner()
        )
        self.sshMasterPool = sshMasterPool
        executionPolicy = BoundedAsyncOperationRunner(
            maxConcurrentOperations: 2,
            timeout: timeout
        )
    }

    init(
        sshMasterPool: SSHMasterPool? = nil,
        processRunner: any InventoryProcessRunning
    ) {
        self.sshMasterPool = sshMasterPool
        self.processRunner = processRunner
        executionPolicy = nil
    }

    public func install(on target: TerminalTarget) async throws -> HerdrInstallationResult {
        guard installingTargets.insert(target).inserted else {
            throw HerdrInstallationError.alreadyInstalling
        }
        defer { installingTargets.remove(target) }
        let command = try HerdrInstallationCommand.make(target: target)
        let output: InventoryProcessOutput
        if let destination = target.sshDestination, let sshMasterPool {
            do {
                if let executionPolicy {
                    output = try await executionPolicy.run {
                        try await sshMasterPool.run(
                            command, alias: destination, replay: .never
                        )
                    }
                } else {
                    output = try await sshMasterPool.run(
                        command, alias: destination, replay: .never
                    )
                }
            } catch let error as SSHMasterPoolError {
                throw mapSSHError(error)
            }
        } else {
            output = try await processRunner.run(command)
        }
        guard output.exitCode == 0 else {
            throw HerdrInstallationError.commandFailed(
                exitCode: output.exitCode,
                detail: diagnostic(output.stderr)
            )
        }
        return try HerdrInstallationResult.parse(output.stdout)
    }

    private func mapSSHError(_ error: SSHMasterPoolError) -> HerdrInstallationError {
        switch error {
        case let .commandFailed(exitCode):
            .commandFailed(exitCode: exitCode, detail: "")
        case let .connectionFailed(exitCode, message):
            .commandFailed(exitCode: exitCode, detail: message)
        case .shuttingDown:
            .commandFailed(exitCode: 255, detail: "TmuxHub 正在关闭 SSH 连接。")
        }
    }

    private func diagnostic(_ value: String) -> String {
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        }))
        return String(
            filtered.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2_000)
        )
    }
}
