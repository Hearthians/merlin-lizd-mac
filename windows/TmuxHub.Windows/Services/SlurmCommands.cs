using System.Globalization;
using System.Text;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

public enum SlurmValidationError
{
    InvalidPlatform,
    InvalidPreset,
    InvalidReceipt,
    InvalidJobIdentity,
}

public sealed class SlurmValidationException : ArgumentException
{
    internal SlurmValidationException(SlurmValidationError error)
        : base(error switch
        {
            SlurmValidationError.InvalidPlatform => "Slurm 平台配置无效。",
            SlurmValidationError.InvalidPreset => "Slurm 资源预设包含无效值。",
            SlurmValidationError.InvalidReceipt => "任务启动凭据无效或不属于当前平台。",
            SlurmValidationError.InvalidJobIdentity => "Slurm 作业身份无效。",
            _ => "Slurm 配置无效。",
        })
    {
        Error = error;
    }

    public SlurmValidationError Error { get; }
}

/// <summary>
/// Builds OpenSSH argument lists without invoking a local command shell. All
/// scheduler values are separately POSIX-quoted before becoming a remote script.
/// </summary>
public static class SlurmCommands
{
    public static IReadOnlyList<string> ListJobs(SlurmPlatformProfile platform)
    {
        ValidatePlatform(platform);
        return RemoteQuery(
            platform,
            ["squeue", "--array", "--user", platform.Owner, "--json"]);
    }

    public static IReadOnlyList<string> InspectJob(
        SlurmPlatformProfile platform,
        SlurmJobId jobId)
    {
        ValidatePlatform(platform);
        ArgumentNullException.ThrowIfNull(jobId);
        return RemoteQuery(
            platform,
            ["squeue", "--array", "--jobs", jobId.Value, "--json"]);
    }

    public static SlurmLaunchReceipt CreateLaunchReceipt(
        SlurmPlatformProfile platform,
        Guid? requestId = null,
        DateTimeOffset? requestedAt = null)
    {
        ValidatePlatform(platform);
        var id = requestId ?? Guid.NewGuid();
        var identity = LaunchIdentity(id);
        var timestamp = requestedAt ?? DateTimeOffset.UtcNow;
        return new SlurmLaunchReceipt(
            id,
            platform.Id,
            platform.LoginDestination,
            platform.Owner,
            identity.JobName,
            identity.Comment,
            identity.TmuxSessionName,
            timestamp,
            SlurmLaunchPhase.Submitting,
            timestamp);
    }

    /// <summary>
    /// Starts one detached login-node tmux session. The tmux session owns srun,
    /// so the allocation survives an app or SSH disconnect.
    /// </summary>
    public static IReadOnlyList<string> StartInteractive(
        SlurmPlatformProfile platform,
        SlurmInteractivePreset preset,
        SlurmLaunchReceipt receipt)
    {
        ValidatePlatform(platform);
        ValidatePreset(preset);
        ValidateReceipt(receipt, platform);

        var srun = new List<string>
        {
            "srun",
            "--job-name", receipt.JobName,
            "--comment", receipt.Comment,
            "--partition", preset.Partition,
            "--ntasks", preset.Tasks.ToString(CultureInfo.InvariantCulture),
            "--cpus-per-task", preset.CpusPerTask.ToString(CultureInfo.InvariantCulture),
            "--mem", preset.MemoryMiB.ToString(CultureInfo.InvariantCulture) + "M",
            "--time", preset.WallTime.SchedulerValue,
        };
        if (preset.Gpu is not null)
        {
            var resource = preset.Gpu.Type is null
                ? $"gpu:{preset.Gpu.Count.ToString(CultureInfo.InvariantCulture)}"
                : $"gpu:{preset.Gpu.Type}:{preset.Gpu.Count.ToString(CultureInfo.InvariantCulture)}";
            srun.AddRange(["--gres", resource]);
        }
        if (preset.WorkingDirectory is not null)
        {
            srun.AddRange(["--chdir", preset.WorkingDirectory]);
        }
        srun.Add("--pty");
        srun.AddRange(["/bin/bash", "-l"]);

        var srunScript = "exec " + ShellJoin(srun);
        var target = "=" + receipt.TmuxSessionName;
        var script = string.Join('\n',
        [
            "command -v tmux >/dev/null 2>&1 || exit 127",
            "command -v srun >/dev/null 2>&1 || exit 127",
            $"if tmux has-session -t {SshInvocation.PosixQuote(target)} 2>/dev/null; then exit 73; fi",
            $"exec tmux new-session -d -s {SshInvocation.PosixQuote(receipt.TmuxSessionName)} "
                + $"/bin/bash -lc {SshInvocation.PosixQuote(srunScript)}",
        ]);
        return RemoteShell(platform, script, interactive: false);
    }

    public static IReadOnlyList<string> AttachInteractive(
        SlurmPlatformProfile platform,
        SlurmLaunchReceipt receipt)
    {
        ValidatePlatform(platform);
        ValidateReceipt(receipt, platform);
        var script = "exec tmux attach-session -t "
            + SshInvocation.PosixQuote("=" + receipt.TmuxSessionName);
        return RemoteShell(platform, script, interactive: true);
    }

    /// <summary>
    /// Builds a fail-closed cancellation. The remote host re-reads all four
    /// ownership fields immediately before scancel, rejecting stale identities.
    /// </summary>
    public static IReadOnlyList<string> CancelVerified(
        SlurmPlatformProfile platform,
        SlurmManagedJob managedJob)
    {
        ValidatePlatform(platform);
        ArgumentNullException.ThrowIfNull(managedJob);
        ValidateReceipt(managedJob.Receipt, platform);
        var snapshot = managedJob.Snapshot;
        if (!string.Equals(snapshot.Owner, managedJob.Receipt.Owner, StringComparison.Ordinal)
            || !string.Equals(snapshot.Name, managedJob.Receipt.JobName, StringComparison.Ordinal)
            || !string.Equals(snapshot.Comment, managedJob.Receipt.Comment, StringComparison.Ordinal))
        {
            throw new SlurmValidationException(SlurmValidationError.InvalidJobIdentity);
        }

        var query = ShellJoin([
            "squeue",
            "--noheader",
            "--jobs", snapshot.JobId.Value,
            "--format", "%i %u %j %k",
        ]);
        var script = string.Join('\n',
        [
            "set -f",
            $"tmuxhub_identity=$({query}) || exit 74",
            "set -- $tmuxhub_identity",
            "[ \"$#\" -eq 4 ] || exit 74",
            $"[ \"$1\" = {SshInvocation.PosixQuote(snapshot.JobId.Value)} ] || exit 74",
            $"[ \"$2\" = {SshInvocation.PosixQuote(managedJob.Receipt.Owner)} ] || exit 74",
            $"[ \"$3\" = {SshInvocation.PosixQuote(managedJob.Receipt.JobName)} ] || exit 74",
            $"[ \"$4\" = {SshInvocation.PosixQuote(managedJob.Receipt.Comment)} ] || exit 74",
            $"exec scancel {SshInvocation.PosixQuote(snapshot.JobId.Value)}",
        ]);
        return RemoteShell(platform, script, interactive: false);
    }

    internal static void ValidatePlatform(SlurmPlatformProfile? platform)
    {
        if (platform is null
            || !SlurmModelValidation.IsSafeIdentifier(platform.Id)
            || string.IsNullOrWhiteSpace(platform.Name)
            || Encoding.UTF8.GetByteCount(platform.Name) > 256
            || !IdentifierValidator.IsSshDestination(platform.LoginDestination)
            || !SlurmModelValidation.IsSafeIdentifier(platform.Owner))
        {
            throw new SlurmValidationException(SlurmValidationError.InvalidPlatform);
        }
    }

    internal static void ValidatePreset(SlurmInteractivePreset? preset)
    {
        var invalid = preset is null
            || !SlurmModelValidation.IsSafeIdentifier(preset.Id)
            || string.IsNullOrWhiteSpace(preset.Name)
            || Encoding.UTF8.GetByteCount(preset.Name) > 256
            || !SlurmModelValidation.IsSafeIdentifier(preset.Partition)
            || preset.Tasks is < 1 or > 4_096
            || preset.CpusPerTask is < 1 or > 4_096
            || preset.MemoryMiB is < 1 or > 1_073_741_824
            || preset.WallTime.Seconds is < 1 or > 31_536_000
            // The Windows transport intentionally does not place arbitrary
            // paths or scripts (and possible credentials) in ssh.exe process
            // arguments. Either may expand beyond CreateProcess limits after
            // nested POSIX and Windows quoting.
            || preset.WorkingDirectory is not null
            || preset.InitializationScript is not null;
        if (invalid
            || preset!.Gpu is { Count: < 1 or > 1_024 }
            || preset.Gpu?.Type is { } type && !SlurmModelValidation.IsSafeIdentifier(type))
        {
            throw new SlurmValidationException(SlurmValidationError.InvalidPreset);
        }
    }

    internal static void ValidateReceipt(
        SlurmLaunchReceipt? receipt,
        SlurmPlatformProfile platform)
    {
        if (receipt is null)
        {
            throw new SlurmValidationException(SlurmValidationError.InvalidReceipt);
        }
        var identity = LaunchIdentity(receipt.RequestId);
        if (!string.Equals(receipt.PlatformId, platform.Id, StringComparison.Ordinal)
            || !string.Equals(receipt.LoginDestination, platform.LoginDestination, StringComparison.Ordinal)
            || !string.Equals(receipt.Owner, platform.Owner, StringComparison.Ordinal)
            || !string.Equals(receipt.JobName, identity.JobName, StringComparison.Ordinal)
            || !string.Equals(receipt.Comment, identity.Comment, StringComparison.Ordinal)
            || !string.Equals(receipt.TmuxSessionName, identity.TmuxSessionName, StringComparison.Ordinal))
        {
            throw new SlurmValidationException(SlurmValidationError.InvalidReceipt);
        }
    }

    private static (string JobName, string Comment, string TmuxSessionName) LaunchIdentity(Guid id)
    {
        var token = id.ToString("D", CultureInfo.InvariantCulture).ToLowerInvariant();
        var shortToken = token.Replace("-", string.Empty, StringComparison.Ordinal)[..16];
        return (
            "tmuxhub-" + shortToken,
            "tmuxhub:" + token,
            "tmuxhub-slurm-" + shortToken);
    }

    private static string ShellJoin(IEnumerable<string> arguments) =>
        string.Join(' ', arguments.Select(SshInvocation.PosixQuote));

    private static IReadOnlyList<string> RemoteQuery(
        SlurmPlatformProfile platform,
        IReadOnlyList<string> remoteArguments) =>
        RemoteShell(platform, "exec " + ShellJoin(remoteArguments), interactive: false);

    private static IReadOnlyList<string> RemoteShell(
        SlurmPlatformProfile platform,
        string script,
        bool interactive)
    {
        ValidatePlatform(platform);
        var command = LoginShell(script);
        return interactive
            ? SshInvocation.InteractiveArguments(platform.LoginDestination, command)
            : SshInvocation.BackgroundArguments(platform.LoginDestination, command);
    }

    /// <summary>
    /// Cluster commands are commonly added by the login profile. Profile banners
    /// remain on stderr; only the command payload is restored to stdout so queue
    /// parsing cannot mistake a banner for a job row.
    /// </summary>
    private static string LoginShell(string script)
    {
        var payload = "exec 1>&3 3>&-\n" + script;
        return "exec /bin/bash -lc " + SshInvocation.PosixQuote(payload) + " 3>&1 1>&2";
    }
}
