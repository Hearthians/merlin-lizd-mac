using System.Diagnostics;
using System.IO;
using System.Text;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Models
{
    public sealed record SshProcessResult(
        int ExitCode,
        string StandardOutput,
        string StandardError
    );
}

namespace TmuxHub.Windows.Services
{
    /// <summary>
    /// Runs bounded, non-interactive Windows OpenSSH operations. Arguments are
    /// always passed with ProcessStartInfo.ArgumentList; no command shell is
    /// involved.
    /// </summary>
    public sealed class SshProcessRunner
    {
        private const int MaximumCapturedCharacters = 16 * 1024 * 1024;
        private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(25);
        private static readonly TimeSpan CleanupTimeout = TimeSpan.FromSeconds(2);
        private static readonly TimeSpan PipeDrainTimeout = TimeSpan.FromSeconds(2);
        private readonly string _sshExecutable;

        public SshProcessRunner(string? sshExecutable = null)
        {
            _sshExecutable = OpenSshLocator.Locate(sshExecutable);
        }

        public async Task<SshProcessResult> RunAsync(
            IReadOnlyList<string> arguments,
            TimeSpan? timeout = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(arguments);
            cancellationToken.ThrowIfCancellationRequested();

            var effectiveTimeout = timeout ?? DefaultTimeout;
            if (effectiveTimeout <= TimeSpan.Zero && effectiveTimeout != Timeout.InfiniteTimeSpan)
            {
                throw new ArgumentOutOfRangeException(nameof(timeout));
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = _sshExecutable,
                UseShellExecute = false,
                RedirectStandardInput = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var argument in arguments)
            {
                ValidateArgument(argument);
                startInfo.ArgumentList.Add(argument);
            }

            using var process = new Process { StartInfo = startInfo };
            if (!process.Start())
            {
                throw new InvalidOperationException("Windows OpenSSH could not be started.");
            }

            var stdoutTask = CaptureAsync(process.StandardOutput);
            var stderrTask = CaptureAsync(process.StandardError);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            if (effectiveTimeout != Timeout.InfiniteTimeSpan)
            {
                deadline.CancelAfter(effectiveTimeout);
            }

            try
            {
                await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                KillProcessTree(process);
                await CleanupAfterCancellationAsync(process, stdoutTask, stderrTask).ConfigureAwait(false);
                throw new TimeoutException($"Windows OpenSSH exceeded the {effectiveTimeout} timeout.");
            }
            catch (OperationCanceledException)
            {
                KillProcessTree(process);
                await CleanupAfterCancellationAsync(process, stdoutTask, stderrTask).ConfigureAwait(false);
                throw;
            }
            catch
            {
                KillProcessTree(process);
                await CleanupAfterCancellationAsync(process, stdoutTask, stderrTask).ConfigureAwait(false);
                throw;
            }

            CapturedText[] captured;
            var captureTask = Task.WhenAll(stdoutTask, stderrTask);
            try
            {
                captured = await captureTask.WaitAsync(PipeDrainTimeout).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                ObserveFault(captureTask);
                throw new IOException("Windows OpenSSH exited without closing its output pipes.");
            }

            var standardOutput = captured[0];
            var standardError = captured[1];
            if (standardOutput.Truncated || standardError.Truncated)
            {
                throw new InvalidDataException("Windows OpenSSH produced more than 16 MiB of output.");
            }

            return new SshProcessResult(
                process.ExitCode,
                standardOutput.Value,
                standardError.Value
            );
        }

        private static void ValidateArgument(string argument)
        {
            ArgumentNullException.ThrowIfNull(argument);
            if (argument.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("An OpenSSH argument contains a null character.", nameof(argument));
            }
        }

        private static async Task<CapturedText> CaptureAsync(StreamReader reader)
        {
            var value = new StringBuilder();
            var buffer = new char[4096];
            var truncated = false;
            while (true)
            {
                var count = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }

                var remaining = MaximumCapturedCharacters - value.Length;
                if (remaining > 0)
                {
                    value.Append(buffer, 0, Math.Min(count, remaining));
                }
                if (count > remaining)
                {
                    truncated = true;
                }
            }
            return new CapturedText(value.ToString(), truncated);
        }

        private static void KillProcessTree(Process process)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
                // It exited between HasExited and Kill.
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Preserve the original cancellation or process error.
            }
        }

        private static async Task CleanupAfterCancellationAsync(
            Process process,
            Task<CapturedText> stdoutTask,
            Task<CapturedText> stderrTask)
        {
            var waitTask = WaitForExitIgnoringInvalidOperationAsync(process);
            try
            {
                await waitTask.WaitAsync(CleanupTimeout).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                ObserveFault(waitTask);
            }

            var captureTask = Task.WhenAll(stdoutTask, stderrTask);
            try
            {
                await captureTask.WaitAsync(CleanupTimeout).ConfigureAwait(false);
            }
            catch
            {
                ObserveFault(captureTask);
            }
        }

        private static async Task WaitForExitIgnoringInvalidOperationAsync(Process process)
        {
            try
            {
                await process.WaitForExitAsync().ConfigureAwait(false);
            }
            catch (InvalidOperationException)
            {
                // The process has already been reaped.
            }
        }

        private static void ObserveFault(Task task)
        {
            _ = task.ContinueWith(
                static completed => _ = completed.Exception,
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default
            );
        }

        private sealed record CapturedText(string Value, bool Truncated);
    }

    internal static class SshInvocation
    {
        internal static string RequireDestination(string destination)
        {
            if (!IdentifierValidator.IsSshDestination(destination))
            {
                throw new ArgumentException("The SSH destination is invalid.", nameof(destination));
            }
            return destination;
        }

        internal static IReadOnlyList<string> BackgroundArguments(
            string destination,
            string remoteCommand)
        {
            ValidateRemoteCommand(remoteCommand);
            return new[]
            {
                "-nT",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ConnectionAttempts=1",
                "-o", "ClearAllForwardings=yes",
                "-o", "PermitLocalCommand=no",
                RequireDestination(destination),
                remoteCommand,
            };
        }

        internal static IReadOnlyList<string> InteractiveArguments(
            string destination,
            string remoteCommand)
        {
            ValidateRemoteCommand(remoteCommand);
            return new[]
            {
                "-tt",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=3",
                RequireDestination(destination),
                remoteCommand,
            };
        }

        internal static string PosixCommand(string executable, params string[] arguments)
        {
            var fields = new string[arguments.Length + 1];
            fields[0] = PosixQuote(executable);
            for (var index = 0; index < arguments.Length; index++)
            {
                fields[index + 1] = PosixQuote(arguments[index]);
            }
            return string.Join(' ', fields);
        }

        internal static string PosixQuote(string value)
        {
            ArgumentNullException.ThrowIfNull(value);
            if (value.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("A remote argument contains a null character.", nameof(value));
            }
            return "'" + value.Replace("'", "'\"'\"'", StringComparison.Ordinal) + "'";
        }

        private static void ValidateRemoteCommand(string remoteCommand)
        {
            ArgumentNullException.ThrowIfNull(remoteCommand);
            if (remoteCommand.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("The remote command contains a null character.", nameof(remoteCommand));
            }
        }
    }
}
