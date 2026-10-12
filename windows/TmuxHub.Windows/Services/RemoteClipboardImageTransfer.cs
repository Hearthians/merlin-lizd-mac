using System.Diagnostics;
using System.IO;
using System.Text;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Uploads a clipboard PNG through a separate, non-interactive SFTP process.
/// No transfer command is ever written into the interactive SSH console.
/// </summary>
internal sealed class RemoteClipboardImageTransfer
{
    internal const int MaximumImageBytes = 100 * 1024 * 1024;
    private const int MaximumCapturedCharacters = 1024 * 1024;
    private const string HomeMarker = "TMUXHUB_HOME_V1\t";
    private static readonly TimeSpan HomeTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan TransferTimeout = TimeSpan.FromMinutes(5);
    private readonly string destination;
    private readonly string sftpExecutable;
    private readonly SshProcessRunner sshRunner;

    internal RemoteClipboardImageTransfer(
        string destination,
        string? sshExecutable = null)
    {
        this.destination = SshInvocation.RequireDestination(destination);
        var ssh = OpenSshLocator.Locate(sshExecutable);
        sftpExecutable = Path.Combine(
            Path.GetDirectoryName(ssh)
                ?? throw new FileNotFoundException("The OpenSSH directory is unavailable."),
            "sftp.exe");
        if (!File.Exists(sftpExecutable))
        {
            throw new FileNotFoundException(
                "Windows OpenSSH SFTP is not installed.",
                sftpExecutable);
        }
        sshRunner = new SshProcessRunner(ssh);
    }

    internal async Task<string> UploadPngAsync(
        byte[] png,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(png);
        if (png.Length == 0
            || png.Length > MaximumImageBytes
            || !HasPngSignature(png))
        {
            throw new InvalidDataException("The clipboard image is not a bounded PNG.");
        }

        var remoteHome = await ResolveRemoteHomeAsync(cancellationToken)
            .ConfigureAwait(false);
        var token = Guid.NewGuid().ToString("D").ToLowerInvariant();
        var stagingRoot = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "TmuxHub",
            "clipboard"));
        var staging = Path.GetFullPath(Path.Combine(stagingRoot, token));
        var guardedRoot = stagingRoot.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!staging.StartsWith(guardedRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("The clipboard staging path is invalid.");
        }

        Directory.CreateDirectory(staging);
        try
        {
            var localImage = Path.Combine(staging, "screenshot.png");
            var batchFile = Path.Combine(staging, "transfer.batch");
            await File.WriteAllBytesAsync(localImage, png, cancellationToken)
                .ConfigureAwait(false);
            var batch = BuildBatch(localImage, remoteHome, token);
            await File.WriteAllTextAsync(
                    batchFile,
                    batch.Text,
                    new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                    cancellationToken)
                .ConfigureAwait(false);

            var result = await RunSftpAsync(batchFile, cancellationToken)
                .ConfigureAwait(false);
            if (result.ExitCode != 0)
            {
                throw new IOException("The clipboard image could not be uploaded by SFTP.");
            }
            return batch.RemotePath;
        }
        finally
        {
            try
            {
                if (Directory.Exists(staging))
                {
                    Directory.Delete(staging, recursive: true);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    internal static (string Text, string RemotePath) BuildBatch(
        string localImage,
        string remoteHome,
        string token)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localImage);
        if (!Path.IsPathFullyQualified(localImage)
            || !Guid.TryParseExact(token, "D", out _))
        {
            throw new ArgumentException("The attachment path or token is invalid.");
        }
        ValidateRemotePath(remoteHome);

        var root = remoteHome == "/"
            ? "/.tmuxhub"
            : remoteHome.TrimEnd('/') + "/.tmuxhub";
        var attachments = root + "/attachments";
        var directory = attachments + "/" + token.ToLowerInvariant();
        var partial = directory + "/.partial-" + token.ToLowerInvariant();
        var remotePath = directory + "/screenshot.png";
        var normalizedLocalImage = localImage.Replace('\\', '/');
        RejectControlCharacters(normalizedLocalImage);

        var lines = new[]
        {
            "-mkdir " + SftpQuote(root),
            "-mkdir " + SftpQuote(attachments),
            "mkdir " + SftpQuote(directory),
            "chmod 700 " + SftpQuote(directory),
            "put " + SftpQuote(normalizedLocalImage) + " " + SftpQuote(partial),
            "chmod 600 " + SftpQuote(partial),
            "rename " + SftpQuote(partial) + " " + SftpQuote(remotePath),
        };
        return (string.Join('\n', lines) + "\n", remotePath);
    }

    internal static string ParseRemoteHome(string output)
    {
        ArgumentNullException.ThrowIfNull(output);
        string? home = null;
        foreach (var line in output.Replace("\r\n", "\n", StringComparison.Ordinal)
                     .Split('\n'))
        {
            if (line.StartsWith(HomeMarker, StringComparison.Ordinal))
            {
                home = line[HomeMarker.Length..];
            }
        }
        if (home is null)
        {
            throw new InvalidDataException("The remote home directory was not returned.");
        }
        ValidateRemotePath(home);
        return home;
    }

    internal static string ShellQuote(string path)
    {
        ValidateRemotePath(path);
        return "'" + path.Replace("'", "'\"'\"'", StringComparison.Ordinal) + "'";
    }

    internal static string SftpDestination(string value)
    {
        _ = SshInvocation.RequireDestination(value);
        if (!value.Contains(':', StringComparison.Ordinal)
            || value.Contains('[', StringComparison.Ordinal))
        {
            return value;
        }
        var at = value.LastIndexOf('@');
        return at >= 0
            ? value[..(at + 1)] + "[" + value[(at + 1)..] + "]"
            : "[" + value + "]";
    }

    private async Task<string> ResolveRemoteHomeAsync(
        CancellationToken cancellationToken)
    {
        const string script = """
            set -eu
            case ${HOME:-} in
                /*) ;;
                *) exit 20 ;;
            esac
            printf 'TMUXHUB_HOME_V1\t%s\n' "$HOME"
            """;
        var command = SshInvocation.PosixCommand(
            "sh",
            "-c",
            script,
            "tmuxhub-home");
        var result = await sshRunner.RunAsync(
                SshInvocation.BackgroundArguments(destination, command),
                HomeTimeout,
                cancellationToken)
            .ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new IOException("The remote home directory could not be resolved.");
        }
        return ParseRemoteHome(result.StandardOutput);
    }

    private async Task<SftpResult> RunSftpAsync(
        string batchFile,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = sftpExecutable,
            UseShellExecute = false,
            RedirectStandardInput = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in new[]
        {
            "-q", "-b", batchFile,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            SftpDestination(destination),
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("Windows OpenSSH SFTP could not be started.");
        }
        var stdoutTask = CaptureAsync(process.StandardOutput);
        var stderrTask = CaptureAsync(process.StandardError);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TransferTimeout);
        try
        {
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch
        {
            TryKill(process);
            await ObserveCaptureAsync(stdoutTask, stderrTask).ConfigureAwait(false);
            throw;
        }

        var captured = await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
        if (captured.Any(static value => value.Truncated))
        {
            throw new InvalidDataException("Windows OpenSSH SFTP produced excessive output.");
        }
        return new SftpResult(process.ExitCode, captured[0].Value, captured[1].Value);
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

    private static async Task ObserveCaptureAsync(
        Task<CapturedText> stdout,
        Task<CapturedText> stderr)
    {
        try
        {
            await Task.WhenAll(stdout, stderr)
                .WaitAsync(TimeSpan.FromSeconds(2))
                .ConfigureAwait(false);
        }
        catch
        {
        }
    }

    private static void TryKill(Process process)
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
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
    }

    private static bool HasPngSignature(IReadOnlyList<byte> bytes) =>
        bytes.Count >= 8
        && bytes[0] == 0x89
        && bytes[1] == 0x50
        && bytes[2] == 0x4e
        && bytes[3] == 0x47
        && bytes[4] == 0x0d
        && bytes[5] == 0x0a
        && bytes[6] == 0x1a
        && bytes[7] == 0x0a;

    private static string SftpQuote(string path)
    {
        RejectControlCharacters(path);
        return "\""
            + path.Replace("\\", "\\\\", StringComparison.Ordinal)
                .Replace("\"", "\\\"", StringComparison.Ordinal)
            + "\"";
    }

    private static void ValidateRemotePath(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (!path.StartsWith("/", StringComparison.Ordinal)
            || path.Length > 4096)
        {
            throw new InvalidDataException("The remote path is invalid.");
        }
        RejectControlCharacters(path);
    }

    private static void RejectControlCharacters(string value)
    {
        if (value.Any(char.IsControl))
        {
            throw new InvalidDataException("A transfer path contains control characters.");
        }
    }

    private sealed record CapturedText(string Value, bool Truncated);
    private sealed record SftpResult(int ExitCode, string StandardOutput, string StandardError);
}
