using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace TmuxHub.Windows.Models
{
    public sealed record HerdrTerminalReference(string TerminalId, string? SessionName = null)
    {
        [JsonIgnore]
        public bool IsValid => global::TmuxHub.Windows.Services.HerdrService.IsValidReference(this);
    }

    public sealed record HerdrPaneRecord(
        HerdrTerminalReference Reference,
        string PaneId,
        string WorkspaceId,
        string? Cwd,
        string? ForegroundCwd,
        string? Agent,
        string? AgentStatus,
        string? OccupantId,
        string Label)
    {
        [JsonIgnore]
        public HerdrTerminalReference Id => Reference;

        [JsonIgnore]
        public string? WorkingDirectory => ForegroundCwd ?? Cwd;
    }

    public sealed record HerdrWorkspaceRecord(
        string Id,
        string Label,
        string? Cwd,
        IReadOnlyList<HerdrPaneRecord> Panes);

    public sealed record HerdrSessionSnapshot(
        string Name,
        string? SessionName,
        IReadOnlyList<HerdrWorkspaceRecord> Workspaces);

    public enum HerdrError
    {
        NotInstalled,
        NoRunningSessions,
        ServerUnavailable,
        TerminalUnavailable,
        MalformedResponse,
        InvalidIdentifier,
        InvalidPath,
        UnsupportedOperation,
        CommandFailed,
    }

    public sealed class HerdrException : Exception
    {
        public HerdrException(HerdrError error, int? exitCode = null)
            : base(MessageFor(error, exitCode))
        {
            Error = error;
            ExitCode = exitCode;
        }

        public HerdrError Error { get; }
        public int? ExitCode { get; }

        private static string MessageFor(HerdrError error, int? exitCode) => error switch
        {
            HerdrError.NotInstalled => "未找到 Herdr。请先在目标主机安装 Herdr。",
            HerdrError.NoRunningSessions => "没有正在运行的 Herdr 会话。请先在目标主机打开 Herdr。",
            HerdrError.ServerUnavailable => "无法读取 Herdr 会话。服务可能已停止，请刷新后重试。",
            HerdrError.TerminalUnavailable => "原 Herdr 终端已不存在。请重新选择终端。",
            HerdrError.MalformedResponse => "Herdr 返回的数据不完整或不受支持，无法安全确定目标终端。",
            HerdrError.InvalidIdentifier => "Herdr 会话或终端标识无效。",
            HerdrError.InvalidPath => "Herdr 返回的工作目录无效。",
            HerdrError.UnsupportedOperation => "当前运行的 Herdr 服务不支持此操作，请检查其版本。",
            HerdrError.CommandFailed => $"Herdr 查询失败（退出码 {exitCode?.ToString(CultureInfo.InvariantCulture) ?? "未知"}）。",
            _ => "Herdr 操作失败。",
        };
    }
}

namespace TmuxHub.Windows.Services
{
    using TmuxHub.Windows.Models;

    /// <summary>
    /// Reads and attaches to existing remote Herdr terminals without changing
    /// the Herdr server lifecycle or taking over another terminal.
    /// </summary>
    public sealed class HerdrService
    {
        public const int MaximumJsonBytes = 16 * 1_024 * 1_024;

        private static readonly TimeSpan QueryTimeout = TimeSpan.FromSeconds(25);
        private static readonly Regex SessionNamePattern = new(
            @"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
        private static readonly Regex IdentifierPattern = new(
            @"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
            RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
        private static readonly JsonSerializerOptions JsonOptions = new()
        {
            PropertyNameCaseInsensitive = false,
        };

        private readonly SshProcessRunner processRunner;
        private readonly TerminalLauncher terminalLauncher;
        private readonly SemaphoreSlim queryGate = new(initialCount: 4, maxCount: 4);

        public HerdrService(
            SshProcessRunner? processRunner = null,
            TerminalLauncher? terminalLauncher = null)
        {
            this.processRunner = processRunner ?? new SshProcessRunner();
            this.terminalLauncher = terminalLauncher ?? new TerminalLauncher();
        }

        public async Task<IReadOnlyList<HerdrSessionSnapshot>> DiscoverAsync(
            string destination,
            CancellationToken cancellationToken = default)
        {
            ValidateDestination(destination);
            var listResult = await RunAsync(
                    BuildSshArguments(destination, ["session", "list", "--json"], interactive: false),
                    cancellationToken)
                .ConfigureAwait(false);
            var sessions = ParseSessions(listResult.StandardOutput);
            if (sessions.Count == 0)
            {
                throw new HerdrException(HerdrError.NoRunningSessions);
            }

            var snapshots = new List<HerdrSessionSnapshot>(sessions.Count);
            foreach (var session in sessions)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var arguments = SessionArguments(session.SessionName)
                    .Concat(["api", "snapshot"])
                    .ToArray();
                var result = await RunAsync(
                        BuildSshArguments(destination, arguments, interactive: false),
                        cancellationToken)
                    .ConfigureAwait(false);
                snapshots.Add(ParseSnapshot(result.StandardOutput, session.SessionName));
            }
            return snapshots;
        }

        public async Task<HerdrPaneRecord> ResolveAsync(
            string destination,
            HerdrTerminalReference reference,
            CancellationToken cancellationToken = default)
        {
            ValidateDestination(destination);
            ValidateReference(reference);
            var arguments = SessionArguments(reference.SessionName)
                .Concat(["api", "snapshot"])
                .ToArray();
            var result = await RunAsync(
                    BuildSshArguments(destination, arguments, interactive: false),
                    cancellationToken)
                .ConfigureAwait(false);
            return Resolve(
                reference,
                ParseSnapshot(result.StandardOutput, reference.SessionName));
        }

        public uint OpenTerminal(string destination, HerdrTerminalReference reference)
        {
            ValidateDestination(destination);
            ValidateReference(reference);
            var arguments = SessionArguments(reference.SessionName)
                .Concat(["terminal", "attach", reference.TerminalId])
                .ToArray();
            return terminalLauncher.Launch(
                BuildSshArguments(destination, arguments, interactive: true));
        }

        public uint Attach(string destination, HerdrTerminalReference reference) =>
            OpenTerminal(destination, reference);

        public static bool IsValidReference(HerdrTerminalReference? reference)
        {
            return reference is not null
                && (reference.SessionName is null || IsSessionName(reference.SessionName))
                && IsIdentifier(reference.TerminalId);
        }

        internal static IReadOnlyList<(string Name, string? SessionName)> ParseSessionList(
            string json) =>
            ParseSessions(json)
                .Select(static session => (session.Name, session.SessionName))
                .ToArray();

        internal static HerdrSessionSnapshot ParseSnapshotPayload(
            string json,
            string? sessionName) => ParseSnapshot(json, sessionName);

        private async Task<SshProcessResult> RunAsync(
            IReadOnlyList<string> arguments,
            CancellationToken cancellationToken)
        {
            await queryGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var result = await processRunner.RunAsync(arguments, QueryTimeout, cancellationToken)
                    .ConfigureAwait(false);
                if (result.ExitCode != 0)
                {
                    throw CommandError(result);
                }
                EnsureBounded(result.StandardOutput);
                return result;
            }
            finally
            {
                queryGate.Release();
            }
        }

        private static IReadOnlyList<string> BuildSshArguments(
            string destination,
            IReadOnlyList<string> herdrArguments,
            bool interactive)
        {
            ValidateDestination(destination);
            var script = BuildRemoteScript(herdrArguments);
            var remoteCommand = "exec /bin/sh -c " + SshInvocation.PosixQuote(script);
            return interactive
                ? SshInvocation.InteractiveArguments(destination, remoteCommand)
                : SshInvocation.BackgroundArguments(destination, remoteCommand);
        }

        private static string BuildRemoteScript(IReadOnlyList<string> arguments)
        {
            if (arguments.Count == 0)
            {
                throw new ArgumentException("A Herdr command is required.", nameof(arguments));
            }

            var command = string.Join(" ", arguments.Select(SshInvocation.PosixQuote));
            return string.Join('\n',
            [
                "unset HERDR_SESSION HERDR_SOCKET_PATH",
                "herdr_binary=''",
                "for herdr_candidate in \"$HOME/.local/bin/herdr\" /opt/homebrew/bin/herdr /usr/local/bin/herdr /usr/bin/herdr; do",
                "    if [ -x \"$herdr_candidate\" ]; then herdr_binary=\"$herdr_candidate\"; break; fi",
                "done",
                "if [ -z \"$herdr_binary\" ]; then herdr_binary=$(command -v herdr 2>/dev/null) || exit 127; fi",
                "if [ -z \"$herdr_binary\" ] || [ ! -x \"$herdr_binary\" ]; then exit 127; fi",
                "exec \"$herdr_binary\" " + command,
            ]);
        }

        private static IReadOnlyList<string> SessionArguments(string? sessionName)
        {
            if (sessionName is null)
            {
                return [];
            }
            ValidateSessionName(sessionName);
            return ["--session", sessionName];
        }

        private static IReadOnlyList<SessionRecord> ParseSessions(string json)
        {
            var response = Deserialize<SessionsResponse>(json);
            if (response.Sessions is null)
            {
                throw new HerdrException(HerdrError.MalformedResponse);
            }

            var seen = new HashSet<string>(StringComparer.Ordinal);
            var sessions = new List<SessionRecord>();
            foreach (var value in response.Sessions)
            {
                if (value?.Name is null || value.IsDefault is null || value.Running is null)
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }

                ValidateSessionName(value.Name);
                var sessionName = value.IsDefault.Value ? null : value.Name;
                if (!seen.Add(sessionName ?? "default"))
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }
                if (value.Running.Value)
                {
                    sessions.Add(new SessionRecord(value.Name, sessionName));
                }
            }
            return sessions;
        }

        private static HerdrSessionSnapshot ParseSnapshot(string json, string? sessionName)
        {
            if (sessionName is not null)
            {
                ValidateSessionName(sessionName);
            }

            var response = Deserialize<SnapshotResponse>(json);
            if (response.Error is not null)
            {
                if (string.IsNullOrEmpty(response.Error.Code))
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }
                throw new HerdrException(ApiError(response.Error.Code));
            }

            var snapshot = response.Result?.Snapshot;
            if (snapshot?.Workspaces is null || snapshot.Panes is null)
            {
                throw new HerdrException(HerdrError.MalformedResponse);
            }

            var workspaceIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var workspace in snapshot.Workspaces)
            {
                if (workspace?.WorkspaceId is null)
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }
                ValidateIdentifier(workspace.WorkspaceId);
                if (!workspaceIds.Add(workspace.WorkspaceId))
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }
                if (workspace.Cwd is not null)
                {
                    ValidatePath(workspace.Cwd);
                }
            }

            var paneIds = new HashSet<string>(StringComparer.Ordinal);
            var terminalIds = new HashSet<string>(StringComparer.Ordinal);
            var panesByWorkspace = new Dictionary<string, List<HerdrPaneRecord>>(StringComparer.Ordinal);
            foreach (var pane in snapshot.Panes)
            {
                if (pane?.PaneId is null || pane.TerminalId is null || pane.WorkspaceId is null)
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }
                ValidateIdentifier(pane.PaneId);
                ValidateIdentifier(pane.TerminalId);
                ValidateIdentifier(pane.WorkspaceId);
                if (pane.Cwd is not null)
                {
                    ValidatePath(pane.Cwd);
                }
                if (pane.ForegroundCwd is not null)
                {
                    ValidatePath(pane.ForegroundCwd);
                }
                if (!workspaceIds.Contains(pane.WorkspaceId)
                    || !paneIds.Add(pane.PaneId)
                    || !terminalIds.Add(pane.TerminalId))
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }

                var agent = DisplayText(pane.Agent);
                var label = DisplayText(pane.Label)
                    ?? DisplayText(pane.TerminalTitleStripped)
                    ?? DisplayText(pane.TerminalTitle)
                    ?? agent
                    ?? pane.PaneId;
                var record = new HerdrPaneRecord(
                    new HerdrTerminalReference(pane.TerminalId, sessionName),
                    pane.PaneId,
                    pane.WorkspaceId,
                    pane.Cwd,
                    pane.ForegroundCwd,
                    agent,
                    DisplayText(pane.AgentStatus),
                    AgentIdentity(pane.AgentSession),
                    label);
                if (!panesByWorkspace.TryGetValue(pane.WorkspaceId, out var panes))
                {
                    panes = [];
                    panesByWorkspace.Add(pane.WorkspaceId, panes);
                }
                panes.Add(record);
            }

            var workspaces = snapshot.Workspaces.Select(workspace =>
            {
                if (workspace is null)
                {
                    throw new HerdrException(HerdrError.MalformedResponse);
                }
                var panes = panesByWorkspace.TryGetValue(workspace.WorkspaceId!, out var records)
                    ? (IReadOnlyList<HerdrPaneRecord>)records.ToArray()
                    : [];
                return new HerdrWorkspaceRecord(
                    workspace.WorkspaceId!,
                    DisplayText(workspace.Label) ?? workspace.WorkspaceId!,
                    workspace.Cwd ?? panes.FirstOrDefault()?.Cwd,
                    panes);
            }).ToArray();

            return new HerdrSessionSnapshot(sessionName ?? "default", sessionName, workspaces);
        }

        private static HerdrPaneRecord Resolve(
            HerdrTerminalReference reference,
            HerdrSessionSnapshot snapshot)
        {
            ValidateReference(reference);
            if (!string.Equals(snapshot.SessionName, reference.SessionName, StringComparison.Ordinal))
            {
                throw new HerdrException(HerdrError.TerminalUnavailable);
            }

            var pane = snapshot.Workspaces
                .SelectMany(static workspace => workspace.Panes)
                .FirstOrDefault(candidate => candidate.Reference == reference);
            return pane ?? throw new HerdrException(HerdrError.TerminalUnavailable);
        }

        private static string? AgentIdentity(AgentSessionInfo? session)
        {
            if (session is null)
            {
                return null;
            }

            var fields = new[] { session.Source, session.Agent, session.Kind, session.Value };
            if (fields.Any(static field => field is null
                    || field.Length == 0
                    || Encoding.UTF8.GetByteCount(field) > 16_384
                    || ContainsControlCharacter(field)))
            {
                throw new HerdrException(HerdrError.MalformedResponse);
            }
            return JsonSerializer.Serialize(fields, JsonOptions);
        }

        private static string? DisplayText(string? value)
        {
            if (value is null)
            {
                return null;
            }

            var filtered = new string(value.Where(static character => !char.IsControl(character)).ToArray())
                .Trim();
            if (filtered.Length == 0)
            {
                return null;
            }
            var textElementOffsets = StringInfo.ParseCombiningCharacters(filtered);
            return textElementOffsets.Length > 256
                ? filtered[..textElementOffsets[256]]
                : filtered;
        }

        private static T Deserialize<T>(string json)
        {
            ArgumentNullException.ThrowIfNull(json);
            EnsureBounded(json);
            try
            {
                return JsonSerializer.Deserialize<T>(json, JsonOptions)
                    ?? throw new HerdrException(HerdrError.MalformedResponse);
            }
            catch (JsonException)
            {
                throw new HerdrException(HerdrError.MalformedResponse);
            }
            catch (NotSupportedException)
            {
                throw new HerdrException(HerdrError.MalformedResponse);
            }
        }

        private static void EnsureBounded(string value)
        {
            if (Encoding.UTF8.GetByteCount(value) > MaximumJsonBytes)
            {
                throw new HerdrException(HerdrError.MalformedResponse);
            }
        }

        private static HerdrException CommandError(SshProcessResult result)
        {
            if (result.ExitCode == 127)
            {
                return new HerdrException(HerdrError.NotInstalled);
            }
            foreach (var output in new[] { result.StandardError, result.StandardOutput })
            {
                if (TryReadApiError(output, out var error))
                {
                    return new HerdrException(error);
                }
            }
            return new HerdrException(HerdrError.CommandFailed, result.ExitCode);
        }

        private static bool TryReadApiError(string? json, out HerdrError error)
        {
            error = HerdrError.ServerUnavailable;
            if (string.IsNullOrWhiteSpace(json)
                || Encoding.UTF8.GetByteCount(json) > MaximumJsonBytes)
            {
                return false;
            }
            try
            {
                var response = JsonSerializer.Deserialize<ErrorResponse>(json, JsonOptions);
                if (string.IsNullOrEmpty(response?.Error?.Code))
                {
                    return false;
                }
                error = ApiError(response.Error.Code);
                return true;
            }
            catch (JsonException)
            {
                return false;
            }
            catch (NotSupportedException)
            {
                return false;
            }
        }

        private static HerdrError ApiError(string code) => code switch
        {
            "not_found" or "terminal_not_found" or "agent_not_running"
                => HerdrError.TerminalUnavailable,
            "method_not_found" or "unsupported_method" or "unsupported"
                => HerdrError.UnsupportedOperation,
            "connection_failed" or "server_unavailable" or "no_server"
                => HerdrError.ServerUnavailable,
            _ => HerdrError.ServerUnavailable,
        };

        private static void ValidateDestination(string? destination)
        {
            if (!IdentifierValidator.IsSshDestination(destination))
            {
                throw new ArgumentException("SSH 目标无效。", nameof(destination));
            }
        }

        private static void ValidateReference(HerdrTerminalReference? reference)
        {
            if (!IsValidReference(reference))
            {
                throw new HerdrException(HerdrError.InvalidIdentifier);
            }
        }

        private static bool IsSessionName(string value) =>
            Encoding.UTF8.GetByteCount(value) <= 64 && SessionNamePattern.IsMatch(value);

        private static void ValidateSessionName(string value)
        {
            if (!IsSessionName(value))
            {
                throw new HerdrException(HerdrError.InvalidIdentifier);
            }
        }

        private static bool IsIdentifier(string? value) =>
            value is not null
            && Encoding.UTF8.GetByteCount(value) <= 128
            && IdentifierPattern.IsMatch(value);

        private static void ValidateIdentifier(string value)
        {
            if (!IsIdentifier(value))
            {
                throw new HerdrException(HerdrError.InvalidIdentifier);
            }
        }

        private static void ValidatePath(string value)
        {
            if (!value.StartsWith("/", StringComparison.Ordinal)
                || Encoding.UTF8.GetByteCount(value) > 16_384
                || ContainsControlCharacter(value))
            {
                throw new HerdrException(HerdrError.InvalidPath);
            }
        }

        private static bool ContainsControlCharacter(string value) =>
            value.Any(static character => char.IsControl(character));

        private sealed record SessionRecord(string Name, string? SessionName);

        private sealed class SessionsResponse
        {
            [JsonPropertyName("sessions")]
            public List<SessionInfo?>? Sessions { get; init; }
        }

        private sealed class SessionInfo
        {
            [JsonPropertyName("name")]
            public string? Name { get; init; }

            [JsonPropertyName("default")]
            public bool? IsDefault { get; init; }

            [JsonPropertyName("running")]
            public bool? Running { get; init; }
        }

        private sealed class ApiErrorInfo
        {
            [JsonPropertyName("code")]
            public string? Code { get; init; }
        }

        private class ErrorResponse
        {
            [JsonPropertyName("error")]
            public ApiErrorInfo? Error { get; init; }
        }

        private sealed class SnapshotResponse : ErrorResponse
        {
            [JsonPropertyName("result")]
            public SnapshotResult? Result { get; init; }
        }

        private sealed class SnapshotResult
        {
            [JsonPropertyName("snapshot")]
            public SnapshotInfo? Snapshot { get; init; }
        }

        private sealed class SnapshotInfo
        {
            [JsonPropertyName("workspaces")]
            public List<WorkspaceInfo?>? Workspaces { get; init; }

            [JsonPropertyName("panes")]
            public List<PaneInfo?>? Panes { get; init; }
        }

        private sealed class WorkspaceInfo
        {
            [JsonPropertyName("workspace_id")]
            public string? WorkspaceId { get; init; }

            [JsonPropertyName("label")]
            public string? Label { get; init; }

            [JsonPropertyName("cwd")]
            public string? Cwd { get; init; }
        }

        private sealed class PaneInfo
        {
            [JsonPropertyName("pane_id")]
            public string? PaneId { get; init; }

            [JsonPropertyName("terminal_id")]
            public string? TerminalId { get; init; }

            [JsonPropertyName("workspace_id")]
            public string? WorkspaceId { get; init; }

            [JsonPropertyName("cwd")]
            public string? Cwd { get; init; }

            [JsonPropertyName("foreground_cwd")]
            public string? ForegroundCwd { get; init; }

            [JsonPropertyName("agent")]
            public string? Agent { get; init; }

            [JsonPropertyName("agent_status")]
            public string? AgentStatus { get; init; }

            [JsonPropertyName("agent_session")]
            public AgentSessionInfo? AgentSession { get; init; }

            [JsonPropertyName("label")]
            public string? Label { get; init; }

            [JsonPropertyName("terminal_title")]
            public string? TerminalTitle { get; init; }

            [JsonPropertyName("terminal_title_stripped")]
            public string? TerminalTitleStripped { get; init; }
        }

        private sealed class AgentSessionInfo
        {
            [JsonPropertyName("source")]
            public string? Source { get; init; }

            [JsonPropertyName("agent")]
            public string? Agent { get; init; }

            [JsonPropertyName("kind")]
            public string? Kind { get; init; }

            [JsonPropertyName("value")]
            public string? Value { get; init; }
        }
    }
}
