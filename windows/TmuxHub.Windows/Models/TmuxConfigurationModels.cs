using TmuxHub.Windows.Services;

namespace TmuxHub.Windows.Models;

public enum TmuxConfigurationActivation
{
    Reloaded,
    NextSession,
    ReloadFailed,
}

public sealed record TmuxConfigurationResult(
    string ConfigurationPath,
    string? BackupPath,
    bool Changed,
    TmuxConfigurationActivation Activation)
{
    /// <summary>
    /// A concise status suitable for the current Chinese Windows UI. Paths are
    /// kept as separate properties so callers can choose whether to show them.
    /// </summary>
    public string StatusMessage
    {
        get
        {
            var saved = Changed
                ? "tmux 配置已更新。"
                : "TmuxHub 配置已是最新。";
            var activation = Activation switch
            {
                TmuxConfigurationActivation.Reloaded =>
                    "正在运行的 tmux 会话已重新加载。",
                TmuxConfigurationActivation.NextSession =>
                    "配置将在下次 tmux 会话启动时生效。",
                TmuxConfigurationActivation.ReloadFailed =>
                    "配置已保存，但运行中的 tmux 会话重新加载失败。",
                _ => throw new InvalidOperationException("Unknown tmux configuration activation state."),
            };
            return saved + activation;
        }
    }
}

public enum TmuxConfigurationErrorKind
{
    AlreadyApplying,
    TmuxNotFound,
    CommandFailed,
    UnexpectedResponse,
}

public sealed class TmuxConfigurationException : Exception
{
    private TmuxConfigurationException(
        TmuxConfigurationErrorKind kind,
        string message,
        int? exitCode = null,
        string? diagnostic = null)
        : base(message)
    {
        Kind = kind;
        ExitCode = exitCode;
        Diagnostic = diagnostic;
    }

    public TmuxConfigurationErrorKind Kind { get; }

    public int? ExitCode { get; }

    public string? Diagnostic { get; }

    internal static TmuxConfigurationException AlreadyApplying() =>
        new(
            TmuxConfigurationErrorKind.AlreadyApplying,
            "正在为此主机配置 tmux，请稍候。");

    internal static TmuxConfigurationException TmuxNotFound() =>
        new(
            TmuxConfigurationErrorKind.TmuxNotFound,
            "目标主机未找到 tmux，请先安装 tmux 后重试。");

    internal static TmuxConfigurationException CommandFailed(
        int exitCode,
        string diagnostic)
    {
        var clean = SanitizeDiagnostic(diagnostic);
        var message = clean.Length == 0
            ? $"配置失败（退出码 {exitCode}），请检查主机连接及配置文件权限。"
            : $"配置失败（退出码 {exitCode}）：{clean}";
        return new TmuxConfigurationException(
            TmuxConfigurationErrorKind.CommandFailed,
            message,
            exitCode,
            clean);
    }

    internal static TmuxConfigurationException UnexpectedResponse() =>
        new(
            TmuxConfigurationErrorKind.UnexpectedResponse,
            "未收到完整的配置结果，请检查目标主机上的 tmux 配置后重试。");

    private static string SanitizeDiagnostic(string value)
        => SshConnectionDiagnostics.SanitizeDiagnostic(value, 2_000);
}
