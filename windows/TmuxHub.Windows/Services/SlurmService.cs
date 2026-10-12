using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

public sealed class SlurmCommandException : Exception
{
    internal SlurmCommandException(int exitCode, string diagnostic)
        : base(string.IsNullOrEmpty(diagnostic)
            ? $"Slurm 命令失败（退出码 {exitCode}）。"
            : $"Slurm 命令失败（退出码 {exitCode}）：{diagnostic}")
    {
        ExitCode = exitCode;
        Diagnostic = diagnostic;
    }

    public int ExitCode { get; }

    public string Diagnostic { get; }
}

public sealed class SlurmConnectionException : Exception
{
    internal SlurmConnectionException(string diagnostic, Exception? innerException = null)
        : base(ConnectionSummary(diagnostic), innerException)
    {
        Diagnostic = diagnostic;
    }

    public string Diagnostic { get; }

    public static string ConnectionSummary(string diagnostic)
    {
        if (diagnostic.Contains(
            "REMOTE HOST IDENTIFICATION HAS CHANGED",
            StringComparison.OrdinalIgnoreCase))
        {
            return "登录节点的 SSH 主机密钥与本机记录不一致。请先核实主机指纹。";
        }
        if (diagnostic.Contains("Host key verification failed", StringComparison.OrdinalIgnoreCase))
        {
            return "登录节点的 SSH 身份尚未通过验证。请先打开登录 Shell 并核实服务器身份。";
        }
        if (diagnostic.Contains("Permission denied", StringComparison.OrdinalIgnoreCase))
        {
            return "SSH 认证未通过。请先打开登录 Shell 完成登录。";
        }
        return "无法连接登录节点。请检查 SSH 配置和网络。";
    }
}

public sealed class SlurmSubmissionOutcomeUnknownException : Exception
{
    internal SlurmSubmissionOutcomeUnknownException(
        SlurmLaunchReceipt receipt,
        Exception innerException)
        : base("启动连接在结果确认前中断。请按启动凭据查询，避免重复提交。", innerException)
    {
        Receipt = receipt;
    }

    public SlurmLaunchReceipt Receipt { get; }
}

public sealed class SlurmCancellationOutcomeUnknownException : Exception
{
    internal SlurmCancellationOutcomeUnknownException(
        SlurmManagedJob job,
        Exception innerException)
        : base("取消连接在结果确认前中断。请刷新作业状态，避免重复取消。", innerException)
    {
        Job = job;
    }

    public SlurmManagedJob Job { get; }
}

public sealed class SlurmAmbiguousLaunchException : Exception
{
    internal SlurmAmbiguousLaunchException(SlurmLaunchReceipt receipt)
        : base("发现多个匹配同一启动凭据的作业，已停止自动操作。")
    {
        Receipt = receipt;
    }

    public SlurmLaunchReceipt Receipt { get; }
}

public sealed class SlurmJobUnavailableException : Exception
{
    internal SlurmJobUnavailableException(SlurmJobId jobId)
        : base($"作业 {jobId.Value} 已不在活动队列中。")
    {
        JobId = jobId;
    }

    public SlurmJobId JobId { get; }
}

public sealed class SlurmIdentityMismatchException : Exception
{
    internal SlurmIdentityMismatchException()
        : base("作业身份已经变化，已拒绝取消。")
    {
    }
}

/// <summary>
/// Windows Slurm control plane over Windows OpenSSH. Read-only operations and
/// mutations each start one shell-free ssh.exe process. Mutations are never
/// retried automatically, and no password is accepted or stored by this layer.
/// </summary>
public sealed class SlurmService
{
    private const int IdentityMismatchExitCode = 74;
    private readonly SshProcessRunner _runner;
    private readonly TerminalLauncher _terminalLauncher;

    public SlurmService(
        SshProcessRunner? runner = null,
        TerminalLauncher? terminalLauncher = null)
    {
        _runner = runner ?? new SshProcessRunner();
        _terminalLauncher = terminalLauncher ?? new TerminalLauncher();
    }

    public SlurmLaunchReceipt CreateLaunchReceipt(
        SlurmPlatformProfile platform,
        Guid? requestId = null,
        DateTimeOffset? requestedAt = null) =>
        SlurmCommands.CreateLaunchReceipt(platform, requestId, requestedAt);

    public async Task<IReadOnlyList<SlurmJobSnapshot>> ListJobsAsync(
        SlurmPlatformProfile platform,
        CancellationToken cancellationToken = default)
    {
        var output = await QueryAsync(
            SlurmCommands.ListJobs(platform),
            cancellationToken).ConfigureAwait(false);
        return SlurmParser.ParseQueue(output.StandardOutput);
    }

    public async Task<SlurmQueueParseResult> ListJobsWithDiagnosticsAsync(
        SlurmPlatformProfile platform,
        CancellationToken cancellationToken = default)
    {
        var output = await QueryAsync(
            SlurmCommands.ListJobs(platform),
            cancellationToken).ConfigureAwait(false);
        return SlurmParser.ParseQueueWithDiagnostics(output.StandardOutput);
    }

    /// <summary>
    /// Performs exactly one remote mutation using a receipt the caller can
    /// persist before this method is invoked. Any transport exception carries
    /// the same receipt so callers can reconcile instead of resubmitting.
    /// </summary>
    public async Task<SlurmLaunchReceipt> StartInteractiveAsync(
        SlurmPlatformProfile platform,
        SlurmInteractivePreset preset,
        SlurmLaunchReceipt receipt,
        CancellationToken cancellationToken = default)
    {
        var arguments = SlurmCommands.StartInteractive(platform, preset, receipt);
        SshProcessResult output;
        try
        {
            output = await _runner.RunAsync(
                arguments,
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            throw new SlurmSubmissionOutcomeUnknownException(receipt, error);
        }
        // OpenSSH reserves 255 for a transport-level failure. The remote
        // wrapper may already have submitted the allocation before the link
        // dropped, so a retry could create a duplicate allocation.
        if (output.ExitCode == 255)
        {
            throw new SlurmSubmissionOutcomeUnknownException(receipt, CommandError(output));
        }
        if (output.ExitCode != 0)
        {
            throw CommandError(output);
        }
        return receipt;
    }

    public Task<SlurmLaunchReceipt> StartInteractiveAsync(
        SlurmPlatformProfile platform,
        SlurmInteractivePreset preset,
        Guid? requestId = null,
        DateTimeOffset? requestedAt = null,
        CancellationToken cancellationToken = default)
    {
        var receipt = CreateLaunchReceipt(platform, requestId, requestedAt);
        return StartInteractiveAsync(platform, preset, receipt, cancellationToken);
    }

    public async Task<SlurmReconciliation> ReconcileAsync(
        SlurmLaunchReceipt receipt,
        SlurmPlatformProfile platform,
        CancellationToken cancellationToken = default)
    {
        SlurmCommands.ValidateReceipt(receipt, platform);
        var jobs = await ListJobsAsync(platform, cancellationToken).ConfigureAwait(false);
        return Reconcile(receipt, jobs);
    }

    internal static SlurmReconciliation Reconcile(
        SlurmLaunchReceipt receipt,
        IReadOnlyList<SlurmJobSnapshot> jobs)
    {
        var matches = jobs.Where(job => Matches(receipt, job)).ToArray();
        if (matches.Length > 1)
        {
            throw new SlurmAmbiguousLaunchException(receipt);
        }
        return matches.Length == 0
            ? new SlurmReconciliation.Waiting(receipt)
            : new SlurmReconciliation.Found(new SlurmManagedJob(receipt, matches[0]));
    }

    internal static int MatchCount(
        SlurmLaunchReceipt receipt,
        IReadOnlyList<SlurmJobSnapshot> jobs) =>
        jobs.Count(job => Matches(receipt, job));

    /// <summary>
    /// Re-reads the exact JobID and checks owner/name/comment locally, then the
    /// remote guard checks all four fields once more immediately before scancel.
    /// </summary>
    public async Task CancelVerifiedAsync(
        SlurmManagedJob managedJob,
        SlurmPlatformProfile platform,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(managedJob);
        SlurmCommands.ValidateReceipt(managedJob.Receipt, platform);
        var inspected = SlurmParser.ParseQueue((await QueryAsync(
            SlurmCommands.InspectJob(platform, managedJob.Snapshot.JobId),
            cancellationToken).ConfigureAwait(false)).StandardOutput);
        var current = inspected
            .Where(job => job.JobId == managedJob.Snapshot.JobId)
            .ToArray();
        if (current.Length == 0)
        {
            throw new SlurmJobUnavailableException(managedJob.Snapshot.JobId);
        }
        if (current.Length != 1 || !Matches(managedJob.Receipt, current[0]))
        {
            throw new SlurmIdentityMismatchException();
        }

        var verified = new SlurmManagedJob(managedJob.Receipt, current[0]);
        SshProcessResult output;
        try
        {
            output = await _runner.RunAsync(
                SlurmCommands.CancelVerified(platform, verified),
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            throw new SlurmCancellationOutcomeUnknownException(verified, error);
        }
        if (output.ExitCode == IdentityMismatchExitCode)
        {
            throw new SlurmIdentityMismatchException();
        }
        if (output.ExitCode == 255)
        {
            throw new SlurmCancellationOutcomeUnknownException(verified, CommandError(output));
        }
        if (output.ExitCode != 0)
        {
            throw CommandError(output);
        }
    }

    public Task CancelAsync(
        SlurmManagedJob managedJob,
        SlurmPlatformProfile platform,
        CancellationToken cancellationToken = default) =>
        CancelVerifiedAsync(managedJob, platform, cancellationToken);

    /// <summary>
    /// Opens an external terminal for the interactive tmux attachment. Password
    /// prompts, when required by SSH, remain in that terminal and are not seen or
    /// persisted by TmuxHub.
    /// </summary>
    public uint AttachInteractive(
        SlurmPlatformProfile platform,
        SlurmLaunchReceipt receipt) =>
        _terminalLauncher.Launch(
            platform.LoginDestination,
            SlurmCommands.AttachInteractive(platform, receipt));

    public uint OpenInteractive(
        SlurmPlatformProfile platform,
        SlurmLaunchReceipt receipt) =>
        AttachInteractive(platform, receipt);

    private async Task<SshProcessResult> QueryAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        SshProcessResult output;
        try
        {
            output = await _runner.RunAsync(
                arguments,
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            var diagnostic = SafeMessage(error.Message, 4_096);
            throw new SlurmConnectionException(diagnostic, error);
        }

        if (output.ExitCode == 255)
        {
            var diagnostic = SafeMessage(
                string.IsNullOrWhiteSpace(output.StandardError)
                    ? output.StandardOutput
                    : output.StandardError,
                4_096);
            throw new SlurmConnectionException(diagnostic);
        }
        if (output.ExitCode != 0)
        {
            throw CommandError(output);
        }
        return output;
    }

    private static bool Matches(SlurmLaunchReceipt receipt, SlurmJobSnapshot job) =>
        string.Equals(job.Owner, receipt.Owner, StringComparison.Ordinal)
        && string.Equals(job.Name, receipt.JobName, StringComparison.Ordinal)
        && string.Equals(job.Comment, receipt.Comment, StringComparison.Ordinal);

    private static SlurmCommandException CommandError(SshProcessResult output)
    {
        var diagnostic = string.IsNullOrWhiteSpace(output.StandardError)
            ? output.StandardOutput
            : output.StandardError;
        return new SlurmCommandException(output.ExitCode, SafeMessage(diagnostic));
    }

    private static string SafeMessage(string? value, int limit = 512)
        => SshConnectionDiagnostics.SanitizeDiagnostic(value, limit);
}
