using System.Globalization;

namespace TmuxHub.Windows.Models;

/// <summary>
/// Stable Slurm control-plane identity. Compute nodes are deliberately not
/// represented here because they are transient scheduler output, not SSH
/// destinations.
/// </summary>
public sealed record SlurmPlatformProfile(
    string Id,
    string Name,
    string LoginDestination,
    string Owner);

public sealed record SlurmGpuRequest(string? Type, int Count);

public readonly record struct SlurmWallTime(int Seconds)
{
    public string SchedulerValue
    {
        get
        {
            var days = Seconds / 86_400;
            var remainder = Seconds % 86_400;
            var hours = remainder / 3_600;
            var minutes = remainder % 3_600 / 60;
            var seconds = remainder % 60;
            return days > 0
                ? string.Create(
                    CultureInfo.InvariantCulture,
                    $"{days}-{hours:00}:{minutes:00}:{seconds:00}")
                : string.Create(
                    CultureInfo.InvariantCulture,
                    $"{hours:00}:{minutes:00}:{seconds:00}");
        }
    }
}

/// <summary>
/// Reusable desired resources for one interactive allocation. The optional
/// initialization script is explicit user input executed inside the allocation.
/// </summary>
public sealed record SlurmInteractivePreset(
    string Id,
    string Name,
    string Partition,
    int Tasks,
    int CpusPerTask,
    int MemoryMiB,
    SlurmWallTime WallTime,
    SlurmGpuRequest? Gpu = null,
    string? WorkingDirectory = null,
    string? InitializationScript = null);

public sealed record SlurmJobId
{
    public SlurmJobId(string value)
    {
        if (!SlurmModelValidation.IsJobId(value))
        {
            throw new ArgumentException("Slurm 作业编号无效。", nameof(value));
        }
        Value = value;
    }

    public string Value { get; }

    public override string ToString() => Value;

    public static bool TryParse(string? value, out SlurmJobId? jobId)
    {
        if (SlurmModelValidation.IsJobId(value))
        {
            jobId = new SlurmJobId(value!);
            return true;
        }
        jobId = null;
        return false;
    }
}

public enum SlurmJobStateKind
{
    Pending,
    Running,
    Completing,
    Completed,
    Cancelled,
    Failed,
    Timeout,
    NodeFailure,
    OutOfMemory,
    Preempted,
    Suspended,
    Unknown,
}

public sealed record SlurmJobState(SlurmJobStateKind Kind, string SchedulerValue)
{
    public bool IsTerminal => Kind is
        SlurmJobStateKind.Completed or
        SlurmJobStateKind.Cancelled or
        SlurmJobStateKind.Failed or
        SlurmJobStateKind.Timeout or
        SlurmJobStateKind.NodeFailure or
        SlurmJobStateKind.OutOfMemory or
        SlurmJobStateKind.Preempted;

    public static SlurmJobState Parse(string schedulerValue)
    {
        ArgumentNullException.ThrowIfNull(schedulerValue);
        var value = schedulerValue.Trim().ToUpperInvariant();
        var kind = value switch
        {
            "PENDING" or "PD" => SlurmJobStateKind.Pending,
            "RUNNING" or "R" => SlurmJobStateKind.Running,
            "COMPLETING" or "CG" => SlurmJobStateKind.Completing,
            "COMPLETED" or "CD" => SlurmJobStateKind.Completed,
            "CANCELLED" or "CA" => SlurmJobStateKind.Cancelled,
            "FAILED" or "F" => SlurmJobStateKind.Failed,
            "TIMEOUT" or "TO" => SlurmJobStateKind.Timeout,
            "NODE_FAIL" or "NF" => SlurmJobStateKind.NodeFailure,
            "OUT_OF_MEMORY" or "OOM" => SlurmJobStateKind.OutOfMemory,
            "PREEMPTED" or "PR" => SlurmJobStateKind.Preempted,
            "SUSPENDED" or "S" => SlurmJobStateKind.Suspended,
            _ => SlurmJobStateKind.Unknown,
        };
        return new SlurmJobState(kind, value);
    }
}

public sealed record SlurmJobSnapshot(
    SlurmJobId JobId,
    string Name,
    string Owner,
    SlurmJobState State,
    string ReasonOrNodeList,
    string Partition,
    int NodeCount,
    string Elapsed,
    string TimeLimit,
    string? StartTime,
    string? SubmitTime,
    string? NodeList,
    string Comment);

public enum SlurmLaunchPhase
{
    Submitting,
    AwaitingScheduler,
    Active,
    LaunchOutcomeUnknown,
    Ambiguous,
    LaunchFailed,
    NotFound,
    CancellationRequested,
    CancellationOutcomeUnknown,
    LeftQueue,
}

/// <summary>
/// Durable identity created before the remote mutation. The same UUID is
/// represented independently in the Slurm job name, Slurm comment, and tmux
/// session name, which makes an uncertain SSH outcome safe to reconcile.
/// </summary>
public sealed record SlurmLaunchReceipt(
    Guid RequestId,
    string PlatformId,
    string LoginDestination,
    string Owner,
    string JobName,
    string Comment,
    string TmuxSessionName,
    DateTimeOffset RequestedAt,
    SlurmLaunchPhase Phase = SlurmLaunchPhase.Submitting,
    DateTimeOffset? PhaseUpdatedAt = null);

public sealed record SlurmManagedJob(
    SlurmLaunchReceipt Receipt,
    SlurmJobSnapshot Snapshot);

public abstract record SlurmReconciliation
{
    private SlurmReconciliation()
    {
    }

    public sealed record Waiting(SlurmLaunchReceipt Receipt) : SlurmReconciliation;

    public sealed record Found(SlurmManagedJob Job) : SlurmReconciliation;
}

internal static class SlurmModelValidation
{
    private const string IdentifierPunctuation = "._:@+-";

    internal static bool IsSafeIdentifier(string? value, int maximumBytes = 128)
    {
        return !string.IsNullOrEmpty(value)
            && System.Text.Encoding.UTF8.GetByteCount(value) <= maximumBytes
            && value.All(static character =>
                char.IsLetterOrDigit(character)
                || IdentifierPunctuation.Contains(character, StringComparison.Ordinal));
    }

    internal static bool IsJobId(string? value)
    {
        return !string.IsNullOrEmpty(value)
            && System.Text.Encoding.UTF8.GetByteCount(value) <= 64
            && value[0] is >= '0' and <= '9'
            && value.All(static character =>
                character is >= '0' and <= '9' or '_' or '+' or '.');
    }

    internal static bool IsAbsolutePath(string? value)
    {
        return !string.IsNullOrEmpty(value)
            && value.StartsWith("/", StringComparison.Ordinal)
            && System.Text.Encoding.UTF8.GetByteCount(value) <= 16_384
            && !value.Any(static character => char.IsControl(character));
    }

    internal static bool IsScript(string? value)
    {
        return !string.IsNullOrEmpty(value)
            && System.Text.Encoding.UTF8.GetByteCount(value) <= 64 * 1_024
            && value.IndexOf('\0') < 0;
    }
}
