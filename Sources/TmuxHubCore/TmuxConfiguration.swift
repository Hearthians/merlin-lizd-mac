import Foundation

public struct TmuxConfigurationResult: Equatable, Sendable {
    public enum Activation: String, Sendable {
        case reloaded
        case nextSession
        case reloadFailed
    }

    public let configurationPath: String
    public let backupPath: String?
    public let changed: Bool
    public let activation: Activation

    static func parse(_ output: String) throws -> Self {
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasPrefix("TMUXHUB_CONFIG_V1\t") }),
            lines.count == index + 4,
            lines[index + 1].hasPrefix("/"),
            lines[index + 2].isEmpty || lines[index + 2].hasPrefix("/"),
            lines[index + 3].isEmpty
        else { throw TmuxConfigurationError.unexpectedResponse }
        let fields = lines[index].components(separatedBy: "\t")
        guard fields.count == 3, ["yes", "no"].contains(fields[1]),
            let activation = Activation(rawValue: fields[2])
        else { throw TmuxConfigurationError.unexpectedResponse }
        return Self(
            configurationPath: lines[index + 1],
            backupPath: lines[index + 2].isEmpty ? nil : lines[index + 2],
            changed: fields[1] == "yes",
            activation: activation
        )
    }
}

public enum TmuxConfigurationError: LocalizedError, Equatable, Sendable {
    case alreadyApplying
    case tmuxNotFound
    case commandFailed(exitCode: Int32, detail: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .alreadyApplying:
            "正在为此主机配置 tmux，请稍候。"
        case .tmuxNotFound:
            "目标主机未找到 tmux，请先安装 tmux 后重试。"
        case let .commandFailed(exitCode, detail):
            detail.isEmpty
                ? "配置失败（退出码 \(exitCode)），请检查主机连接及配置文件权限。"
                : "配置失败（退出码 \(exitCode)）：\(detail)"
        case .unexpectedResponse:
            "未收到完整的配置结果，请检查目标主机上的 tmux 配置后重试。"
        }
    }
}

/// A marked block allows repeat applications without duplicating settings or
/// discarding the user's unrelated configuration.
public enum TmuxConfigurationPreset {
    public static let contents = """
        # BEGIN TmuxHub preset
        # Prefix: Ctrl+A (press twice to send Ctrl+A)
        unbind C-b
        set -g prefix C-a
        bind C-a send-prefix

        # Mouse selection and scrolling
        set -g mouse on
        set -g terminal-overrides 'xterm*:smcup@:rmcup@'

        # Status bar and pane borders
        set -g status-style bg=black,fg=white
        set -g pane-border-style fg=green
        set -g pane-active-border-style fg=red

        # Number new windows and panes from 1
        set -g base-index 1
        setw -g pane-base-index 1
        set -g default-terminal "screen-256color"
        # END TmuxHub preset
        """ + "\n"

    static func command(
        target: TerminalTarget,
        localTmuxPath: String
    ) throws -> CommandSpec {
        switch target {
        case .local:
            guard localTmuxPath.hasPrefix("/"),
                !localTmuxPath.contains(where: { $0.isNewline || $0 == "\0" })
            else { throw CommandValidationError.invalidExecutablePath }
            return CommandSpec(
                executable: "/bin/sh",
                arguments: ["-c", installScript, "tmuxhub-config", localTmuxPath]
            )
        case let .ssh(destination):
            guard IdentifierValidator.isSSHDestination(destination) else {
                throw CommandValidationError.invalidSSHDestination
            }
            // OpenSSH passes its final argument to the remote login shell.
            // Quote the complete POSIX script, including the literal heredoc.
            let quotedScript = "'" + installScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                destination, "sh -c \(quotedScript) tmuxhub-config tmux",
            ])
        }
    }

    private static var installScript: String {
        #"""
        set -eu
        export LC_ALL=C
        tmuxhub_tmux=$1
        tmuxhub_home=${2:-$HOME}
        if ! command -v "$tmuxhub_tmux" >/dev/null 2>&1; then
            printf '%s\n' 'tmux is not installed or is not on PATH.' >&2
            exit 10
        fi
        tmuxhub_config="$tmuxhub_home/.tmux.conf"
        if [ ! -e "$tmuxhub_config" ] && [ ! -L "$tmuxhub_config" ]; then
            tmuxhub_xdg="${3:-${XDG_CONFIG_HOME:-$tmuxhub_home/.config}}/tmux/tmux.conf"
            if [ -e "$tmuxhub_xdg" ] || [ -L "$tmuxhub_xdg" ]; then
                tmuxhub_config=$tmuxhub_xdg
            fi
        fi

        # Follow dotfile symlinks so the link itself survives the atomic update.
        tmuxhub_target=$tmuxhub_config
        tmuxhub_links=0
        while [ -L "$tmuxhub_target" ]; do
            tmuxhub_links=$((tmuxhub_links + 1))
            if [ "$tmuxhub_links" -gt 40 ]; then
                printf '%s\n' 'Too many configuration symlinks.' >&2
                exit 11
            fi
            tmuxhub_link=$(readlink "$tmuxhub_target")
            case "$tmuxhub_link" in
                /*) tmuxhub_target=$tmuxhub_link ;;
                *) tmuxhub_target="${tmuxhub_target%/*}/$tmuxhub_link" ;;
            esac
        done
        if [ -e "$tmuxhub_target" ] && [ ! -f "$tmuxhub_target" ]; then
            printf '%s\n' 'The tmux configuration is not a regular file.' >&2
            exit 11
        fi

        umask 077
        tmuxhub_work=$(mktemp -d "${tmuxhub_target}.tmuxhub.XXXXXX")
        trap 'rm -rf "$tmuxhub_work"' EXIT
        trap 'exit 1' HUP INT TERM
        tmuxhub_existed=no
        if [ -f "$tmuxhub_target" ]; then
            tmuxhub_existed=yes
            cp -p "$tmuxhub_target" "$tmuxhub_work/original"
            cp -p "$tmuxhub_target" "$tmuxhub_work/config"
        else
            : > "$tmuxhub_work/original"
        fi
        cat > "$tmuxhub_work/preset" <<'TMUXHUB_PRESET_EOF'
        """# + "\n" + contents + #"""
        TMUXHUB_PRESET_EOF
        if ! awk '
            $0 == "# BEGIN TmuxHub preset" {
                if (inside) { invalid = 1; exit 1 }
                inside = 1; next
            }
            $0 == "# END TmuxHub preset" {
                if (!inside) { invalid = 1; exit 1 }
                inside = 0; next
            }
            !inside { print }
            END { if (inside || invalid) exit 1 }
        ' "$tmuxhub_work/original" > "$tmuxhub_work/config"; then
            printf '%s\n' 'The existing TmuxHub configuration block is incomplete. Repair its BEGIN/END markers and retry.' >&2
            exit 11
        fi
        cat "$tmuxhub_work/preset" >> "$tmuxhub_work/config"

        tmuxhub_changed=no
        tmuxhub_backup=
        if ! cmp -s "$tmuxhub_work/original" "$tmuxhub_work/config"; then
            if [ "$tmuxhub_existed" = yes ]; then
                if ! cmp -s "$tmuxhub_target" "$tmuxhub_work/original"; then
                    printf '%s\n' 'The configuration changed during setup. Please retry.' >&2
                    exit 11
                fi
                tmuxhub_backup=$(mktemp "${tmuxhub_target}.tmuxhub-backup.XXXXXX")
                cp -p "$tmuxhub_work/original" "$tmuxhub_backup"
            elif [ -e "$tmuxhub_target" ] || [ -L "$tmuxhub_target" ]; then
                printf '%s\n' 'The configuration was created during setup. Please retry.' >&2
                exit 11
            fi
            mv -f "$tmuxhub_work/config" "$tmuxhub_target"
            tmuxhub_changed=yes
        fi

        # Only source our preset. Re-running the user's full config could create
        # duplicate windows or launch commands intended for server startup.
        tmuxhub_activation=nextSession
        if "$tmuxhub_tmux" list-sessions >/dev/null 2> "$tmuxhub_work/probe-error"; then
            if "$tmuxhub_tmux" source-file "$tmuxhub_work/preset" >&2; then
                tmuxhub_activation=reloaded
            else
                tmuxhub_activation=reloadFailed
            fi
        elif ! grep -Eq 'no server running|no sessions|No such file or directory' "$tmuxhub_work/probe-error"; then
            cat "$tmuxhub_work/probe-error" >&2
            tmuxhub_activation=reloadFailed
        fi
        printf 'TMUXHUB_CONFIG_V1\t%s\t%s\n%s\n%s\n' \
            "$tmuxhub_changed" "$tmuxhub_activation" "$tmuxhub_config" "$tmuxhub_backup"
        """#
    }
}
