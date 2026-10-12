using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Stable categories that the Windows UI can use without parsing OpenSSH text
/// itself. The retained diagnostic is always sanitized.
/// </summary>
public enum SshDiagnosticKind
{
    None,
    UnknownHostKey,
    ChangedHostKey,
    AuthenticationFailed,
    TimedOut,
    NameResolutionFailed,
    ConnectionRefused,
    NetworkUnavailable,
    ConnectionLost,
    RemoteCommandFailed,
    ClientUnavailable,
    Cancelled,
    ConnectionFailed,
}

public sealed record SshConnectionDiagnostic(
    SshDiagnosticKind Kind,
    string UserMessage,
    string DiagnosticSummary,
    int? ExitCode = null)
{
    public bool IsSuccess => Kind == SshDiagnosticKind.None;

    public string DisplayMessage => string.IsNullOrWhiteSpace(DiagnosticSummary)
        ? UserMessage
        : $"{UserMessage}\n\n诊断信息：{DiagnosticSummary}";
}

/// <summary>
/// Converts OpenSSH failures into short Chinese recovery guidance. All public
/// methods are deterministic and side-effect free; none starts ssh.exe.
/// </summary>
public static class SshConnectionDiagnostics
{
    public const int MaximumDiagnosticCharacters = 4_096;

    private const int MaximumInputCharacters = 65_536;
    private const string RedactedValue = "[已隐藏]";
    private const string RedactedPrivateKey = "[私钥内容已隐藏]";

    private static readonly Regex CredentialAssignmentPattern = new(
        """(?<name>["']?\b(?:[A-Za-z0-9]+[_-])*(?:password|passwd|passphrase|secret|token|api[-_ ]?key|access[-_ ]?key)["']?\s*[:=]\s*)(?<value>"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+)""",
        RegexOptions.IgnoreCase
            | RegexOptions.CultureInvariant
            | RegexOptions.NonBacktracking);

    private static readonly Regex CredentialArgumentPattern = new(
        """(?<name>--(?:password|passwd|passphrase|secret|token|api-key|access-key)\s+)(?<value>"[^"\r\n]*"|'[^'\r\n]*'|\S+)""",
        RegexOptions.IgnoreCase
            | RegexOptions.CultureInvariant
            | RegexOptions.NonBacktracking);

    private static readonly Regex AuthorizationPattern = new(
        @"(?<name>\bAuthorization\s*:\s*(?:Bearer|Basic)\s+)(?<value>\S+)",
        RegexOptions.IgnoreCase
            | RegexOptions.CultureInvariant
            | RegexOptions.NonBacktracking);

    private static readonly Regex UrlPasswordPattern = new(
        @"(?<prefix>\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)(?<password>[^@\s/]+)(?<suffix>@)",
        RegexOptions.IgnoreCase
            | RegexOptions.CultureInvariant
            | RegexOptions.NonBacktracking);

    private static readonly Regex CommonTokenPattern = new(
        @"\b(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9_-]{16,}|github_pat_[A-Za-z0-9_-]{16,})\b",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex BarePrivateKeyMaterialPattern = new(
        @"^[A-Za-z0-9+/]{64,}={0,2}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    public static SshConnectionDiagnostic FromResult(SshProcessResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return Classify(result.ExitCode, result.StandardOutput, result.StandardError);
    }

    public static SshConnectionDiagnostic Classify(
        int exitCode,
        string? standardOutput,
        string? standardError)
    {
        var source = !string.IsNullOrWhiteSpace(standardError)
            ? standardError
            : standardOutput;
        var diagnostic = SanitizeDiagnostic(source);

        if (exitCode == 0)
        {
            return new SshConnectionDiagnostic(
                SshDiagnosticKind.None,
                "SSH 操作已完成。",
                diagnostic,
                exitCode);
        }

        return ClassifyFailure(exitCode, diagnostic);
    }

    public static SshConnectionDiagnostic FromException(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        error = Unwrap(error);

        if (error is OperationCanceledException)
        {
            return new SshConnectionDiagnostic(
                SshDiagnosticKind.Cancelled,
                "SSH 操作已取消。",
                string.Empty);
        }

        if (error is TimeoutException)
        {
            return new SshConnectionDiagnostic(
                SshDiagnosticKind.TimedOut,
                MessageFor(SshDiagnosticKind.TimedOut, null),
                SanitizeDiagnostic(error.Message));
        }

        if (error is FileNotFoundException or Win32Exception)
        {
            return new SshConnectionDiagnostic(
                SshDiagnosticKind.ClientUnavailable,
                MessageFor(SshDiagnosticKind.ClientUnavailable, null),
                SanitizeDiagnostic(error.Message));
        }

        var exitCode = error is TmuxServiceException tmuxError
            ? tmuxError.ExitCode
            : (int?)null;
        var diagnostic = SanitizeDiagnostic(error.Message);
        if (exitCode is not null)
        {
            return ClassifyFailure(exitCode.Value, diagnostic);
        }

        var detectedKind = DetectKind(diagnostic);
        if (detectedKind is not null)
        {
            return new SshConnectionDiagnostic(
                detectedKind.Value,
                MessageFor(detectedKind.Value, null),
                diagnostic);
        }

        return new SshConnectionDiagnostic(
            SshDiagnosticKind.ConnectionFailed,
            MessageFor(SshDiagnosticKind.ConnectionFailed, null),
            diagnostic);
    }

    /// <summary>Convenience entry point for MainWindow.FriendlyError.</summary>
    public static string Describe(Exception error) => FromException(error).DisplayMessage;

    /// <summary>Convenience entry point for services that still own process output.</summary>
    public static string DescribeProcessFailure(
        int exitCode,
        string? standardOutput,
        string? standardError) =>
        Classify(exitCode, standardOutput, standardError).DisplayMessage;

    /// <summary>
    /// Removes control characters and likely credentials/private-key material,
    /// then bounds the text retained for support diagnostics.
    /// </summary>
    public static string SanitizeDiagnostic(
        string? value,
        int maximumCharacters = MaximumDiagnosticCharacters)
    {
        if (maximumCharacters < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumCharacters));
        }
        if (maximumCharacters == 0 || string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var normalized = NormalizeControls(BoundInput(value));
        var output = new StringBuilder(Math.Min(normalized.Length, maximumCharacters));
        var privateKeyBlock = false;
        var wrotePrivateKeyMarker = false;

        foreach (var rawLine in normalized.Split('\n'))
        {
            var line = rawLine.TrimEnd();
            if (IsPrivateKeyBegin(line))
            {
                privateKeyBlock = true;
                AppendLine(output, RedactedPrivateKey);
                wrotePrivateKeyMarker = true;
                continue;
            }
            if (privateKeyBlock)
            {
                if (IsPrivateKeyEnd(line))
                {
                    privateKeyBlock = false;
                }
                continue;
            }
            if (BarePrivateKeyMaterialPattern.IsMatch(line.Trim()))
            {
                if (!wrotePrivateKeyMarker)
                {
                    AppendLine(output, RedactedPrivateKey);
                    wrotePrivateKeyMarker = true;
                }
                continue;
            }

            wrotePrivateKeyMarker = false;
            AppendLine(output, RedactCredentials(line));
        }

        return Truncate(output.ToString().Trim(), maximumCharacters);
    }

    private static SshConnectionDiagnostic ClassifyFailure(int exitCode, string diagnostic)
    {
        var kind = DetectKind(diagnostic)
            ?? (exitCode == 255
                ? SshDiagnosticKind.ConnectionFailed
                : SshDiagnosticKind.RemoteCommandFailed);
        return new SshConnectionDiagnostic(
            kind,
            MessageFor(kind, exitCode),
            diagnostic,
            exitCode);
    }

    private static SshDiagnosticKind? DetectKind(string diagnostic)
    {
        if (ContainsAny(
                diagnostic,
                "REMOTE HOST IDENTIFICATION HAS CHANGED",
                "HOST IDENTIFICATION HAS CHANGED",
                "POSSIBLE DNS SPOOFING DETECTED",
                "Offending ECDSA key in",
                "Offending ED25519 key in",
                "Offending RSA key in"))
        {
            return SshDiagnosticKind.ChangedHostKey;
        }

        if (ContainsAny(
                diagnostic,
                "The authenticity of host",
                "can't be established",
                "cannot be established",
                "No ED25519 host key is known for",
                "No ECDSA host key is known for",
                "No RSA host key is known for",
                "Host key verification failed"))
        {
            return SshDiagnosticKind.UnknownHostKey;
        }

        if (ContainsAny(
                diagnostic,
                "Permission denied",
                "Authentication failed",
                "No supported authentication methods available",
                "Too many authentication failures")
            || (ContainsAny(diagnostic, "Load key")
                && ContainsAny(diagnostic, "invalid format", "error in libcrypto")))
        {
            return SshDiagnosticKind.AuthenticationFailed;
        }

        if (ContainsAny(
                diagnostic,
                "Could not resolve hostname",
                "Name or service not known",
                "Temporary failure in name resolution",
                "No such host is known",
                "nodename nor servname provided"))
        {
            return SshDiagnosticKind.NameResolutionFailed;
        }

        if (ContainsAny(
                diagnostic,
                "Connection timed out",
                "Operation timed out",
                "Connection timeout",
                "connect timeout"))
        {
            return SshDiagnosticKind.TimedOut;
        }

        if (ContainsAny(diagnostic, "Connection refused"))
        {
            return SshDiagnosticKind.ConnectionRefused;
        }

        if (ContainsAny(
                diagnostic,
                "No route to host",
                "Network is unreachable",
                "Network is down"))
        {
            return SshDiagnosticKind.NetworkUnavailable;
        }

        if (ContainsAny(
                diagnostic,
                "Connection reset",
                "Connection closed",
                "Broken pipe",
                "kex_exchange_identification"))
        {
            return SshDiagnosticKind.ConnectionLost;
        }

        return null;
    }

    private static string MessageFor(SshDiagnosticKind kind, int? exitCode) => kind switch
    {
        SshDiagnosticKind.None => "SSH 操作已完成。",
        SshDiagnosticKind.UnknownHostKey =>
            "SSH 主机身份尚未受信任。请先在 SSH Shell 中核对并接受服务器指纹。",
        SshDiagnosticKind.ChangedHostKey =>
            "SSH 主机密钥与本机记录不一致，已阻止连接。请先向服务器管理员核实新指纹，再更新 known_hosts。",
        SshDiagnosticKind.AuthenticationFailed =>
            "SSH 认证失败。请检查用户名、私钥和 ssh-agent，或先在 SSH Shell 中完成登录。",
        SshDiagnosticKind.TimedOut =>
            "SSH 连接超时。请检查网络、主机地址、VPN 或 ZeroTier，以及 SSH 端口。",
        SshDiagnosticKind.NameResolutionFailed =>
            "无法解析 SSH 主机名。请检查 Host 配置、主机名和网络 DNS。",
        SshDiagnosticKind.ConnectionRefused =>
            "SSH 连接被目标主机拒绝。请确认 SSH 服务和端口正在运行。",
        SshDiagnosticKind.NetworkUnavailable =>
            "当前网络无法到达 SSH 主机。请检查网络、VPN 或 ZeroTier 路由。",
        SshDiagnosticKind.ConnectionLost =>
            "SSH 连接已中断。请检查网络稳定性后重试。",
        SshDiagnosticKind.RemoteCommandFailed => exitCode is null
            ? "远端命令执行失败。请查看诊断信息。"
            : $"远端命令执行失败（退出码 {exitCode.Value.ToString(CultureInfo.InvariantCulture)}）。请查看诊断信息。",
        SshDiagnosticKind.ClientUnavailable =>
            "Windows OpenSSH Client 不可用。请在 Windows 可选功能中启用 OpenSSH 客户端。",
        SshDiagnosticKind.Cancelled => "SSH 操作已取消。",
        _ => "SSH 连接失败。请查看诊断信息，或打开 SSH Shell 检查。",
    };

    private static string RedactCredentials(string line)
    {
        var redacted = CredentialAssignmentPattern.Replace(
            line,
            static match => match.Groups["name"].Value + RedactedValue);
        redacted = CredentialArgumentPattern.Replace(
            redacted,
            static match => match.Groups["name"].Value + RedactedValue);
        redacted = AuthorizationPattern.Replace(
            redacted,
            static match => match.Groups["name"].Value + RedactedValue);
        redacted = UrlPasswordPattern.Replace(
            redacted,
            static match => match.Groups["prefix"].Value
                + RedactedValue
                + match.Groups["suffix"].Value);
        return CommonTokenPattern.Replace(redacted, RedactedValue);
    }

    private static bool ContainsAny(string value, params string[] candidates) =>
        candidates.Any(candidate => value.Contains(candidate, StringComparison.OrdinalIgnoreCase));

    private static Exception Unwrap(Exception error)
    {
        while (error is AggregateException { InnerExceptions.Count: 1 } aggregate)
        {
            error = aggregate.InnerExceptions[0];
        }
        return error;
    }

    private static bool IsPrivateKeyBegin(string line) =>
        line.Contains("-----BEGIN ", StringComparison.OrdinalIgnoreCase)
        && line.Contains("PRIVATE KEY-----", StringComparison.OrdinalIgnoreCase);

    private static bool IsPrivateKeyEnd(string line) =>
        line.Contains("-----END ", StringComparison.OrdinalIgnoreCase)
        && line.Contains("PRIVATE KEY-----", StringComparison.OrdinalIgnoreCase);

    private static string NormalizeControls(string value)
    {
        var output = new StringBuilder(value.Length);
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (character == '\r')
            {
                if (index + 1 < value.Length && value[index + 1] == '\n')
                {
                    continue;
                }
                output.Append('\n');
                continue;
            }
            if (!char.IsControl(character) || character == '\n')
            {
                output.Append(character);
            }
        }
        return output.ToString();
    }

    private static string BoundInput(string value)
    {
        if (value.Length <= MaximumInputCharacters)
        {
            return value;
        }
        var half = MaximumInputCharacters / 2;
        return value[..half] + "\n…\n" + value[^half..];
    }

    private static string Truncate(string value, int maximumCharacters)
    {
        if (value.Length <= maximumCharacters)
        {
            return value;
        }
        var length = maximumCharacters;
        if (length > 0 && char.IsHighSurrogate(value[length - 1]))
        {
            length--;
        }
        return value[..length].TrimEnd();
    }

    private static void AppendLine(StringBuilder output, string line)
    {
        if (output.Length > 0)
        {
            output.Append('\n');
        }
        output.Append(line);
    }
}
