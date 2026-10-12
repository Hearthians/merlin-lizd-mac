using System.Collections.Concurrent;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Installs TmuxHub's marked tmux preset on an SSH target. The local process is
/// always Windows OpenSSH, launched directly by <see cref="SshProcessRunner"/>;
/// authentication is intentionally non-interactive and passwords are never
/// accepted or persisted by this service.
/// </summary>
public sealed class TmuxConfigurationService
{
    private const string ResponseMarker = "TMUXHUB_CONFIG_V1\t";
    private const int TmuxNotFoundExitCode = 10;
    private static readonly TimeSpan ApplyTimeout = TimeSpan.FromSeconds(30);
    private readonly ConcurrentDictionary<string, byte> _configuringDestinations =
        new(StringComparer.Ordinal);
    private readonly SshProcessRunner _runner;

    public TmuxConfigurationService(SshProcessRunner? runner = null)
    {
        _runner = runner ?? new SshProcessRunner();
    }

    public async Task<TmuxConfigurationResult> ApplyAsync(
        string destination,
        CancellationToken cancellationToken = default)
    {
        var validatedDestination = SshInvocation.RequireDestination(destination);
        if (!_configuringDestinations.TryAdd(validatedDestination, 0))
        {
            throw TmuxConfigurationException.AlreadyApplying();
        }

        try
        {
            var remoteCommand = SshInvocation.PosixCommand(
                "sh",
                "-c",
                InstallScript,
                "tmuxhub-config",
                "tmux");
            var output = await _runner.RunAsync(
                SshInvocation.BackgroundArguments(validatedDestination, remoteCommand),
                ApplyTimeout,
                cancellationToken
            ).ConfigureAwait(false);

            if (output.ExitCode == TmuxNotFoundExitCode)
            {
                throw TmuxConfigurationException.TmuxNotFound();
            }
            if (output.ExitCode != 0)
            {
                var diagnostic = output.StandardError.Length > 0
                    ? output.StandardError
                    : output.StandardOutput;
                throw TmuxConfigurationException.CommandFailed(output.ExitCode, diagnostic);
            }
            return ParseResult(output.StandardOutput);
        }
        finally
        {
            _configuringDestinations.TryRemove(validatedDestination, out _);
        }
    }

    internal static TmuxConfigurationResult ParseResult(string output)
    {
        ArgumentNullException.ThrowIfNull(output);
        var normalized = output
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        var lines = normalized.Split('\n');
        var markerIndex = -1;
        for (var index = lines.Length - 1; index >= 0; index--)
        {
            if (lines[index].StartsWith(ResponseMarker, StringComparison.Ordinal))
            {
                markerIndex = index;
                break;
            }
        }

        if (markerIndex < 0 ||
            lines.Length != markerIndex + 4 ||
            !IsAbsoluteRemotePath(lines[markerIndex + 1]) ||
            (lines[markerIndex + 2].Length > 0 &&
                !IsAbsoluteRemotePath(lines[markerIndex + 2])) ||
            lines[markerIndex + 3].Length != 0)
        {
            throw TmuxConfigurationException.UnexpectedResponse();
        }

        var fields = lines[markerIndex].Split('\t');
        if (fields.Length != 3 ||
            (fields[1] != "yes" && fields[1] != "no") ||
            !TryParseActivation(fields[2], out var activation))
        {
            throw TmuxConfigurationException.UnexpectedResponse();
        }

        return new TmuxConfigurationResult(
            lines[markerIndex + 1],
            lines[markerIndex + 2].Length == 0 ? null : lines[markerIndex + 2],
            fields[1] == "yes",
            activation);
    }

    private static bool IsAbsoluteRemotePath(string value) =>
        value.StartsWith("/", StringComparison.Ordinal) &&
        value.IndexOf('\0') < 0;

    private static bool TryParseActivation(
        string value,
        out TmuxConfigurationActivation activation)
    {
        activation = value switch
        {
            "reloaded" => TmuxConfigurationActivation.Reloaded,
            "nextSession" => TmuxConfigurationActivation.NextSession,
            "reloadFailed" => TmuxConfigurationActivation.ReloadFailed,
            _ => default,
        };
        return value is "reloaded" or "nextSession" or "reloadFailed";
    }

    private const string InstallScript = """
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
        # Serialize TmuxHub writers when flock is available. Keep the lock file:
        # unlinking a held lock would allow a second inode to be locked.
        tmuxhub_lock="${tmuxhub_target}.tmuxhub.lock"
        if command -v flock >/dev/null 2>&1; then
            exec 9> "$tmuxhub_lock"
            if ! flock -n 9; then
                printf '%s\n' 'Another TmuxHub configuration update is in progress.' >&2
                exit 12
            fi
        fi
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
        # BEGIN TmuxHub preset
        # Prefix: Ctrl+A (press twice to send Ctrl+A)
        unbind C-b
        set -g prefix C-a
        bind C-a send-prefix

        # Mouse selection and scrolling
        set -g mouse on
        # Keep remote copy operations write-only: tmux may publish a selection
        # to the outer terminal, but programs cannot read the local clipboard.
        set -g set-clipboard external
        set -g terminal-overrides 'xterm*:smcup@:rmcup@:Ms=\E]52;c;%p2%s\7'

        # Status bar and pane borders
        set -g status-style bg=black,fg=white
        set -g pane-border-style fg=green
        set -g pane-active-border-style fg=red

        # Number new windows and panes from 1
        set -g base-index 1
        setw -g pane-base-index 1
        set -g default-terminal "screen-256color"
        # END TmuxHub preset
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
            # Recheck after creating the backup, immediately before replacement.
            # This catches edits made during the backup window.
            if [ "$tmuxhub_existed" = yes ]; then
                if ! cmp -s "$tmuxhub_target" "$tmuxhub_work/original"; then
                    rm -f "$tmuxhub_backup"
                    printf '%s\n' 'The configuration changed during setup. Please retry.' >&2
                    exit 11
                fi
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
        """;
}
