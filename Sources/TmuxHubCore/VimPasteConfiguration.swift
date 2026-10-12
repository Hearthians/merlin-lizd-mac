import Foundation

public struct VimPasteConfigurationResult: Equatable, Sendable {
    public let configurationPath: String
    public let backupPath: String?
    public let changed: Bool

    static func parse(_ output: String) throws -> Self {
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasPrefix("TMUXHUB_VIM_PASTE_V1\t") }),
            lines.count == index + 4,
            lines[index + 1].hasPrefix("/"),
            lines[index + 2].isEmpty || lines[index + 2].hasPrefix("/"),
            lines[index + 3].isEmpty
        else { throw VimPasteConfigurationError.unexpectedResponse }
        let fields = lines[index].components(separatedBy: "\t")
        guard fields.count == 2, ["yes", "no"].contains(fields[1]) else {
            throw VimPasteConfigurationError.unexpectedResponse
        }
        return Self(configurationPath: lines[index + 1],
                    backupPath: lines[index + 2].isEmpty ? nil : lines[index + 2],
                    changed: fields[1] == "yes")
    }
}

public enum VimPasteConfigurationError: LocalizedError, Equatable, Sendable {
    case alreadyApplying
    case commandFailed(exitCode: Int32, detail: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .alreadyApplying:
            return "正在为此主机修复 Vim 粘贴，请稍候。"
        case let .commandFailed(exitCode, detail):
            return detail.isEmpty
                ? "Vim 粘贴修复失败（退出码 \(exitCode)），请检查连接和文件权限。"
                : "Vim 粘贴修复失败（退出码 \(exitCode)）：\(detail)"
        case .unexpectedResponse:
            return "未收到完整的 Vim 粘贴修复结果，请检查目标主机后重试。"
        }
    }
}

/// Installs Vim's documented screen/tmux bracketed-paste termcap settings.
/// This changes neither the user's vimrc nor their normal indentation options.
public enum VimPasteConfiguration {
    public static let pluginContents = #"""
        " Managed by TmuxHub: see :help xterm-bracketed-paste and tmux-integration.
        if has('nvim') || has('gui_running') || !exists('+t_BE')
          finish
        endif
        if &term !~# '^\%(screen\|tmux\)' || &compatible || !&esckeys
          finish
        endif
        let &t_BE = "\<Esc>[?2004h"
        let &t_BD = "\<Esc>[?2004l"
        let &t_PS = "\<Esc>[200~"
        let &t_PE = "\<Esc>[201~"
        " Pasted text is literal; autoindent remains available for typed text.
        """# + "\n"

    static func command(target: TerminalTarget) throws -> CommandSpec {
        switch target {
        case .local:
            return CommandSpec(executable: "/bin/sh", arguments: [
                "-c", installScript, "tmuxhub-vim-paste",
            ])
        case let .ssh(destination):
            guard IdentifierValidator.isSSHDestination(destination) else {
                throw CommandValidationError.invalidSSHDestination
            }
            let quotedScript = "'" + installScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return CommandSpec(executable: "/usr/bin/ssh", arguments: [
                "-nT", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                destination, "sh -c \(quotedScript) tmuxhub-vim-paste",
            ])
        }
    }

    private static var installScript: String {
        #"""
        set -eu
        export LC_ALL=C
        tmuxhub_home=${1:-$HOME}
        case "$tmuxhub_home" in /*) ;; *) exit 11 ;; esac
        tmuxhub_config="$tmuxhub_home/.vim/plugin/tmuxhub-paste.vim"

        tmuxhub_resolve_target() {
            tmuxhub_resolved=$1
            tmuxhub_links=0
            while [ -L "$tmuxhub_resolved" ]; do
                tmuxhub_links=$((tmuxhub_links + 1))
                if [ "$tmuxhub_links" -gt 40 ]; then
                    printf '%s\n' 'Too many Vim plugin symlinks.' >&2
                    return 11
                fi
                tmuxhub_link=$(readlink "$tmuxhub_resolved")
                case "$tmuxhub_link" in
                    /*) tmuxhub_resolved=$tmuxhub_link ;;
                    *) tmuxhub_resolved="${tmuxhub_resolved%/*}/$tmuxhub_link" ;;
                esac
            done
            printf '%s\n' "$tmuxhub_resolved"
        }
        tmuxhub_target=$(tmuxhub_resolve_target "$tmuxhub_config")
        if [ -e "$tmuxhub_target" ] && [ ! -f "$tmuxhub_target" ]; then
            printf '%s\n' 'The Vim paste plugin is not a regular file.' >&2
            exit 11
        fi

        umask 077
        mkdir -p "${tmuxhub_target%/*}"
        tmuxhub_work=$(mktemp -d "${tmuxhub_target}.tmuxhub.XXXXXX")
        trap 'rm -rf "$tmuxhub_work"' EXIT
        trap 'exit 1' HUP INT TERM
        tmuxhub_existed=no
        if [ -f "$tmuxhub_target" ]; then
            tmuxhub_existed=yes
            cp -p "$tmuxhub_target" "$tmuxhub_work/original"
            cp -p "$tmuxhub_target" "$tmuxhub_work/plugin"
        else
            : > "$tmuxhub_work/original"
        fi
        cat > "$tmuxhub_work/plugin" <<'TMUXHUB_VIM_PASTE_EOF'
        """# + "\n" + pluginContents + #"""
        TMUXHUB_VIM_PASTE_EOF

        tmuxhub_changed=no
        tmuxhub_backup=
        if ! cmp -s "$tmuxhub_work/original" "$tmuxhub_work/plugin"; then
            if [ "$(tmuxhub_resolve_target "$tmuxhub_config")" != "$tmuxhub_target" ]; then
                printf '%s\n' 'The Vim plugin symlink changed during setup.' >&2
                exit 11
            fi
            if [ "$tmuxhub_existed" = yes ]; then
                if ! cmp -s "$tmuxhub_target" "$tmuxhub_work/original"; then
                    printf '%s\n' 'The Vim plugin changed during setup. Please retry.' >&2
                    exit 11
                fi
                tmuxhub_backup=$(mktemp "${tmuxhub_target}.tmuxhub-backup.XXXXXX")
                cp "$tmuxhub_work/original" "$tmuxhub_backup"
            elif [ -e "$tmuxhub_target" ] || [ -L "$tmuxhub_target" ]; then
                printf '%s\n' 'The Vim plugin was created during setup. Please retry.' >&2
                exit 11
            fi
            mv -f "$tmuxhub_work/plugin" "$tmuxhub_target"
            tmuxhub_changed=yes
        fi
        printf 'TMUXHUB_VIM_PASTE_V1\t%s\n%s\n%s\n' \
            "$tmuxhub_changed" "$tmuxhub_config" "$tmuxhub_backup"
        """#
    }
}
