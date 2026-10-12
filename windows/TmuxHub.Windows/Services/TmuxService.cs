using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services
{
    public sealed class TmuxServiceException : Exception
    {
        public TmuxServiceException(int exitCode, string diagnostic)
            : base($"The remote tmux command failed with exit code {exitCode}: {TrimDiagnostic(diagnostic)}")
        {
            ExitCode = exitCode;
        }

        public int ExitCode { get; }

        private static string TrimDiagnostic(string value)
        {
            var clean = value.Replace("\0", string.Empty, StringComparison.Ordinal).Trim();
            return clean.Length <= 4096 ? clean : clean[..4096];
        }
    }

    public sealed class TmuxSessionChangedException : Exception
    {
        public TmuxSessionChangedException()
            : base("The tmux session no longer has the identity that was displayed. Refresh and try again.")
        {
        }
    }

    /// <summary>
    /// Manages tmux on SSH targets with independent Windows OpenSSH processes.
    /// Windows OpenSSH ControlMaster is deliberately not used.
    /// </summary>
    public sealed class TmuxService
    {
        private const int IdentityMismatchExitCode = 75;
        private const string IdentityMismatchMarker = "TMUXHUB_IDENTITY_MISMATCH";
        private readonly SshProcessRunner _runner;
        private readonly TerminalLauncher _terminalLauncher;

        public TmuxService(
            SshProcessRunner? runner = null,
            TerminalLauncher? terminalLauncher = null)
        {
            _runner = runner ?? new SshProcessRunner();
            _terminalLauncher = terminalLauncher ?? new TerminalLauncher();
        }

        public async Task<IReadOnlyList<TmuxSessionRecord>> ListAsync(
            string destination,
            CancellationToken cancellationToken = default)
        {
            var remoteCommand = BuildTmuxCommand(
                "list-sessions",
                "-F#{session_name},#{session_id},#{session_created}"
            );
            var output = await _runner.RunAsync(
                SshInvocation.BackgroundArguments(destination, remoteCommand),
                cancellationToken: cancellationToken
            ).ConfigureAwait(false);

            if (output.ExitCode != 0)
            {
                var diagnostic = output.StandardOutput + "\n" + output.StandardError;
                if (diagnostic.Contains("no server running", StringComparison.OrdinalIgnoreCase) ||
                    diagnostic.Contains("no sessions", StringComparison.OrdinalIgnoreCase))
                {
                    return Array.Empty<TmuxSessionRecord>();
                }
                throw new TmuxServiceException(output.ExitCode, diagnostic);
            }

            return ParseSessions(output.StandardOutput);
        }

        public async Task CreateAsync(
            string destination,
            string sessionName,
            CancellationToken cancellationToken = default)
        {
            var normalizedName = RequireSessionName(sessionName);
            await RunMutationAsync(
                destination,
                BuildTmuxCommand("new-session", "-d", "-s", normalizedName),
                cancellationToken
            ).ConfigureAwait(false);
        }

        public async Task RenameAsync(
            string destination,
            string currentName,
            string newName,
            TmuxSessionIdentity? identity = null,
            CancellationToken cancellationToken = default)
        {
            var current = RequireSessionName(currentName);
            var replacement = RequireSessionName(newName);
            var selector = current;
            if (identity is not null)
            {
                ValidateIdentity(identity);
                selector = identity.ServerSessionId;
            }

            var mutation = BuildTmuxCommand("rename-session", "-t", selector, replacement);
            await RunMutationAsync(
                destination,
                identity is null ? mutation : BuildIdentityCheckedMutation(identity, mutation),
                cancellationToken
            ).ConfigureAwait(false);
        }

        public async Task KillAsync(
            string destination,
            string sessionName,
            CancellationToken cancellationToken = default)
        {
            var normalizedName = RequireSessionName(sessionName);
            await RunMutationAsync(
                destination,
                BuildTmuxCommand("kill-session", "-t", normalizedName),
                cancellationToken
            ).ConfigureAwait(false);
        }

        public async Task KillVerifiedAsync(
            string destination,
            string sessionName,
            TmuxSessionIdentity identity,
            CancellationToken cancellationToken = default)
        {
            _ = RequireSessionName(sessionName);
            ValidateIdentity(identity);
            var mutation = BuildTmuxCommand("kill-session", "-t", identity.ServerSessionId);
            await RunMutationAsync(
                destination,
                BuildIdentityCheckedMutation(identity, mutation),
                cancellationToken
            ).ConfigureAwait(false);
        }

        public async Task<bool> VerifyIdentityAsync(
            string destination,
            TmuxSessionIdentity identity,
            CancellationToken cancellationToken = default)
        {
            ValidateIdentity(identity);
            var sessions = await ListAsync(destination, cancellationToken).ConfigureAwait(false);
            return sessions.Any(session => session.Identity == identity);
        }

        /// <summary>
        /// Opens a new console and atomically creates or attaches the requested
        /// remote session. Authentication remains interactive in that console.
        /// </summary>
        public uint OpenOrAttach(string destination, string sessionName)
        {
            var normalizedName = RequireSessionName(sessionName);
            var remoteCommand = "exec " + BuildTmuxCommand(
                "new-session", "-A", "-s", normalizedName
            );
            return _terminalLauncher.Launch(
                destination,
                SshInvocation.InteractiveArguments(destination, remoteCommand)
            );
        }

        public static IReadOnlyList<TmuxSessionRecord> ParseSessions(string output)
        {
            return TmuxSessionParser.Parse(output);
        }

        private async Task RunMutationAsync(
            string destination,
            string remoteCommand,
            CancellationToken cancellationToken)
        {
            var output = await _runner.RunAsync(
                SshInvocation.BackgroundArguments(destination, remoteCommand),
                cancellationToken: cancellationToken
            ).ConfigureAwait(false);
            if (output.ExitCode != 0)
            {
                var diagnostic = output.StandardError.Length > 0
                    ? output.StandardError
                    : output.StandardOutput;
                if (output.ExitCode == IdentityMismatchExitCode &&
                    diagnostic.Contains(IdentityMismatchMarker, StringComparison.Ordinal))
                {
                    throw new TmuxSessionChangedException();
                }
                throw new TmuxServiceException(
                    output.ExitCode,
                    diagnostic
                );
            }
        }

        private static string BuildTmuxCommand(params string[] arguments) =>
            SshInvocation.PosixCommand("tmux", arguments);

        private static string BuildIdentityCheckedMutation(
            TmuxSessionIdentity identity,
            string mutation)
        {
            var probe = BuildTmuxCommand(
                "display-message",
                "-p",
                "-t",
                identity.ServerSessionId,
                "#{session_created}"
            );
            var expected = SshInvocation.PosixQuote(
                identity.CreatedAtEpoch.ToString(System.Globalization.CultureInfo.InvariantCulture)
            );
            var marker = SshInvocation.PosixQuote(IdentityMismatchMarker);
            return $"actual=$({probe}) || exit $?; " +
                $"if [ \"$actual\" != {expected} ]; then printf '%s\\n' {marker} >&2; " +
                $"exit {IdentityMismatchExitCode}; fi; exec {mutation}";
        }

        private static string RequireSessionName(string value)
        {
            var normalized = IdentifierValidator.NormalizeTmuxSessionName(value);
            if (normalized is null)
            {
                throw new ArgumentException("The tmux session name is invalid.", nameof(value));
            }
            return normalized;
        }

        private static void ValidateIdentity(TmuxSessionIdentity identity)
        {
            ArgumentNullException.ThrowIfNull(identity);
            if (identity.CreatedAtEpoch < 0 ||
                !IdentifierValidator.IsTmuxSessionId(identity.ServerSessionId))
            {
                throw new ArgumentException("The tmux session identity is invalid.", nameof(identity));
            }
        }

    }
}
