using System.Reflection;
using TmuxHub.Windows.Models;
using TmuxHub.Windows.Services;

namespace TmuxHub.Windows.Tests;

internal static class Program
{
    private static readonly (string Name, Action Body)[] Tests =
    [
        ("validator and stable hash", ValidatorAndStableHash),
        ("tmux session parser", TmuxParser),
        ("tmux configuration parser", TmuxConfigurationParser),
        ("Windows SSH config Include", SshConfigIncludes),
        ("state round trip and sanitization", StateRoundTrip),
        ("Slurm command and parser", SlurmCore),
        ("SSH diagnostics", SshDiagnostics),
        ("shell-free SSH command construction", SshCommandConstruction),
        ("CreateProcess argument quoting", WindowsArgumentQuoting),
        ("clipboard bridge arguments", ClipboardBridgeArguments),
        ("clipboard attachment paths", ClipboardAttachmentPaths),
    ];

    [STAThread]
    private static int Main()
    {
        var failures = new List<string>();
        foreach (var test in Tests)
        {
            try
            {
                test.Body();
                Console.WriteLine($"PASS  {test.Name}");
            }
            catch (Exception error)
            {
                failures.Add(test.Name);
                Console.Error.WriteLine($"FAIL  {test.Name}");
                Console.Error.WriteLine(error);
            }
        }

        Console.WriteLine();
        Console.WriteLine($"{Tests.Length - failures.Count}/{Tests.Length} tests passed.");
        if (failures.Count == 0)
        {
            return 0;
        }

        Console.Error.WriteLine("Failed: " + string.Join(", ", failures));
        return 1;
    }

    private static void ValidatorAndStableHash()
    {
        foreach (var destination in new[]
        {
            "prod",
            "prod.example.com",
            "lizd@gfyh.fun",
            "10.0.0.8",
            "lizd@2001:db8::8",
            "[2001:db8::8]",
        })
        {
            Check.True(
                IdentifierValidator.IsSshDestination(destination),
                $"Expected a valid destination: {destination}");
        }

        foreach (var destination in new[]
        {
            "",
            "-oProxyCommand=id",
            "host name",
            "host;id",
            "host\nname",
            new string('a', 256),
        })
        {
            Check.False(
                IdentifierValidator.IsSshDestination(destination),
                $"Expected an invalid destination: {destination}");
        }

        var stable = IdentifierValidator.StableTmuxSessionName(
            "zhuodongli@10.30.45.144");
        Check.Equal(
            "tmuxhub-zhuodongli-10_30_45_144-f5add734",
            stable,
            "The Windows stable-name hash must remain compatible with macOS.");
        Check.Equal(
            stable,
            IdentifierValidator.StableTmuxSessionName("zhuodongli@10.30.45.144"));
        Check.NotEqual(
            stable,
            IdentifierValidator.StableTmuxSessionName("zhuodongli@10.30.45.145"));
        Check.True(stable!.Length <= 64);

        Check.Equal("main_build", IdentifierValidator.NormalizeTmuxSessionName("main.build"));
        Check.Equal<string?>(null, IdentifierValidator.NormalizeTmuxSessionName("unsafe;name"));
        Check.True(IdentifierValidator.IsTmuxSessionId("$17"));
        Check.False(IdentifierValidator.IsTmuxSessionId("$17;id"));
    }

    private static void TmuxParser()
    {
        var sessions = TmuxSessionParser.Parse(
            "main,$1,100\r\n"
            + "build,$2,101\n"
            + "main-copy,$1,100\n"
            + "warning: something happened\n"
            + "legacy: 2 windows (created today)\n"
            + "bad,$3,-1\n");

        Check.Equal(3, sessions.Count);
        Check.Equal("main", sessions[0].Name);
        Check.Equal(new TmuxSessionIdentity("$1", 100), sessions[0].Identity);
        Check.Equal("$1@100", sessions[0].Id);
        Check.Equal("build", sessions[1].Name);
        Check.Equal(new TmuxSessionIdentity("$2", 101), sessions[1].Identity);
        Check.Equal("legacy", sessions[2].Name);
        Check.Equal<TmuxSessionIdentity?>(null, sessions[2].Identity);
    }

    private static void TmuxConfigurationParser()
    {
        var result = (TmuxConfigurationResult)InvokeInternal(
            "TmuxHub.Windows.Services.TmuxConfigurationService",
            "ParseResult",
            "profile banner\n"
            + "TMUXHUB_CONFIG_V1\tyes\treloaded\n"
            + "/home/user/.tmux.conf\n"
            + "/home/user/.tmux.conf.tmuxhub-backup.ABC123\n");
        Check.True(result.Changed);
        Check.Equal(TmuxConfigurationActivation.Reloaded, result.Activation);
        Check.Equal("/home/user/.tmux.conf", result.ConfigurationPath);
        Check.Equal(
            "/home/user/.tmux.conf.tmuxhub-backup.ABC123",
            result.BackupPath);

        var service = typeof(SshProcessRunner).Assembly.GetType(
            "TmuxHub.Windows.Services.TmuxConfigurationService",
            throwOnError: true)!;
        var installScript = (string)(service.GetField(
                "InstallScript",
                BindingFlags.Static | BindingFlags.NonPublic)
            ?.GetRawConstantValue()
            ?? throw new MissingFieldException(service.FullName, "InstallScript"));
        Check.True(installScript.Contains(
            "set -g set-clipboard external",
            StringComparison.Ordinal));
        Check.True(installScript.Contains(
            "Ms=\\E]52;c;%p2%s\\7",
            StringComparison.Ordinal));
    }

    private static void SshConfigIncludes()
    {
        using var workspace = new TestWorkspace();
        var sshDirectory = Path.Combine(workspace.Root, ".ssh");
        var normalIncludes = Path.Combine(sshDirectory, "conf.d");
        var environmentIncludes = Path.Combine(sshDirectory, "included files");
        Directory.CreateDirectory(normalIncludes);
        Directory.CreateDirectory(environmentIncludes);

        var environmentName = "TMUXHUB_TEST_INCLUDE_" + Guid.NewGuid().ToString("N");
        Environment.SetEnvironmentVariable(environmentName, environmentIncludes);
        try
        {
            File.WriteAllText(
                Path.Combine(sshDirectory, "config"),
                "Host alpha *.wild !blocked\n"
                + "Include conf.d\\*.conf\n"
                + $"Include \"%{environmentName}%\\*.conf\"\n"
                + "Include conf.d\\[broken.conf\n");
            File.WriteAllText(
                Path.Combine(normalIncludes, "hosts.conf"),
                "Host beta alpha\nInclude config\n");
            File.WriteAllText(
                Path.Combine(environmentIncludes, "more.conf"),
                "Host delta gamma\n");

            var hosts = new SshConfigCatalog(homeDirectory: workspace.Root)
                .Load()
                .Select(static host => host.Destination)
                .ToArray();

            Check.SequenceEqual(["alpha", "beta", "delta", "gamma"], hosts);
        }
        finally
        {
            Environment.SetEnvironmentVariable(environmentName, null);
        }
    }

    private static void StateRoundTrip()
    {
        using var workspace = new TestWorkspace();
        var path = Path.Combine(workspace.Root, "state", "state.json");
        var timestamp = new DateTimeOffset(2026, 9, 14, 1, 2, 3, TimeSpan.Zero);
        var state = new AppState();
        state.CustomDestinations.UnionWith(["prod", "user@example.com", "host;bad"]);
        state.PinnedDestinations.UnionWith(["prod", "-oProxyCommand=id"]);
        state.LastUsedAt["prod"] = timestamp;
        state.LastUsedAt["host name"] = timestamp;
        state.SlurmSettings["prod"] = new SlurmHostSettings(
            "zhuodongli",
            "debug",
            4,
            16_384,
            30,
            1);
        var platform = new SlurmPlatformProfile(
            "windows-slurm",
            "prod",
            "prod",
            "zhuodongli");
        state.SlurmReceipts.Add(SlurmCommands.CreateLaunchReceipt(
            platform,
            Guid.Parse("12345678-1234-5678-90ab-1234567890ab"),
            timestamp));

        var store = new AppStateStore(path);
        store.Save(state);
        var restored = store.Load();

        Check.Equal(AppState.CurrentVersion, restored.Version);
        Check.True(restored.CustomDestinations.SetEquals(["prod", "user@example.com"]));
        Check.True(restored.PinnedDestinations.SetEquals(["prod"]));
        Check.Equal(timestamp, restored.LastUsedAt["prod"]);
        Check.False(restored.LastUsedAt.ContainsKey("host name"));
        Check.Equal("debug", restored.SlurmSettings["prod"].Partition);
        Check.Equal(1, restored.SlurmReceipts.Count);
        Check.Equal(
            "tmuxhub-1234567812345678",
            restored.SlurmReceipts[0].JobName);
        Check.Equal(
            SlurmLaunchPhase.LaunchOutcomeUnknown,
            restored.SlurmReceipts[0].Phase,
            "A persisted submitting receipt must become outcome-unknown after restart.");
        Check.True(File.ReadAllText(path).Contains("\"customDestinations\"", StringComparison.Ordinal));

        File.WriteAllText(path, "{ this is not valid JSON }");
        var recovered = store.Load();
        Check.Equal(0, recovered.CustomDestinations.Count);
        Check.Equal(0, recovered.PinnedDestinations.Count);
        Check.Equal(0, recovered.LastUsedAt.Count);
        Check.Equal(0, recovered.SlurmSettings.Count);
        Check.Equal(0, recovered.SlurmReceipts.Count);

        File.WriteAllText(path, "{\"slurmReceipts\":[null]}");
        var nullReceiptRecovered = store.Load();
        Check.Equal(0, nullReceiptRecovered.SlurmReceipts.Count);

        var validDuplicate = SlurmCommands.CreateLaunchReceipt(
            platform,
            Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            timestamp) with
        {
            Phase = SlurmLaunchPhase.Active,
            PhaseUpdatedAt = timestamp.AddMinutes(1),
        };
        var invalidNewerDuplicate = validDuplicate with
        {
            JobName = "tampered",
            PhaseUpdatedAt = timestamp.AddMinutes(2),
        };
        var duplicateJson = System.Text.Json.JsonSerializer.Serialize(
            new
            {
                version = AppState.CurrentVersion,
                slurmReceipts = new[] { invalidNewerDuplicate, validDuplicate },
            },
            new System.Text.Json.JsonSerializerOptions
            {
                PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
            });
        File.WriteAllText(path, duplicateJson);
        var duplicateRecovered = store.Load();
        Check.Equal(1, duplicateRecovered.SlurmReceipts.Count);
        Check.Equal(validDuplicate.JobName, duplicateRecovered.SlurmReceipts[0].JobName);

        var cancellationUncertain = validDuplicate with
        {
            Phase = SlurmLaunchPhase.CancellationOutcomeUnknown,
            PhaseUpdatedAt = timestamp.AddMinutes(3),
        };
        var cancellationState = new AppState();
        cancellationState.SlurmReceipts.Add(cancellationUncertain);
        store.Save(cancellationState);
        var cancellationRecovered = store.Load();
        Check.Equal(
            SlurmLaunchPhase.CancellationOutcomeUnknown,
            cancellationRecovered.SlurmReceipts.Single().Phase);

        var retention = new AppState();
        Guid oldestActiveId = default;
        for (var index = 0; index < 101; index++)
        {
            var requestId = new Guid(index + 1, 0, 0, new byte[8]);
            if (index == 0)
            {
                oldestActiveId = requestId;
            }
            var requestedAt = timestamp.AddSeconds(index);
            retention.SlurmReceipts.Add(SlurmCommands.CreateLaunchReceipt(
                platform,
                requestId,
                requestedAt) with
            {
                Phase = SlurmLaunchPhase.Active,
                PhaseUpdatedAt = requestedAt,
            });
        }
        for (var index = 0; index < 105; index++)
        {
            var requestedAt = timestamp.AddMinutes(10).AddSeconds(index);
            retention.SlurmReceipts.Add(SlurmCommands.CreateLaunchReceipt(
                platform,
                new Guid(index + 1_000, 0, 0, new byte[8]),
                requestedAt) with
            {
                Phase = SlurmLaunchPhase.LeftQueue,
                PhaseUpdatedAt = requestedAt,
            });
        }
        store.Save(retention);
        var retained = store.Load();
        Check.Equal(201, retained.SlurmReceipts.Count);
        Check.True(retained.SlurmReceipts.Any(
            receipt => receipt.RequestId == oldestActiveId));
        Check.Equal(
            100,
            retained.SlurmReceipts.Count(
                receipt => receipt.Phase == SlurmLaunchPhase.LeftQueue));
    }

    private static void SlurmCore()
    {
        var platform = new SlurmPlatformProfile(
            "hkust-hpc2",
            "HKUST HPC2",
            "hpc2",
            "zli760");
        var receipt = SlurmCommands.CreateLaunchReceipt(
            platform,
            Guid.Parse("12345678-1234-5678-90ab-1234567890ab"),
            new DateTimeOffset(2026, 10, 12, 0, 0, 0, TimeSpan.Zero));
        Check.Equal("tmuxhub-1234567812345678", receipt.JobName);
        Check.Equal(
            "tmuxhub:12345678-1234-5678-90ab-1234567890ab",
            receipt.Comment);
        Check.Equal("tmuxhub-slurm-1234567812345678", receipt.TmuxSessionName);

        var preset = new SlurmInteractivePreset(
            "default",
            "交互环境",
            "debug",
            1,
            4,
            16_384,
            new SlurmWallTime(1_800),
            new SlurmGpuRequest(null, 1));
        var arguments = SlurmCommands.StartInteractive(platform, preset, receipt);
        Check.Equal("-nT", arguments[0]);
        Check.True(arguments.Contains("hpc2"));
        Check.True(arguments[^1].Contains("srun", StringComparison.Ordinal));
        Check.True(arguments[^1].Contains(receipt.Comment, StringComparison.Ordinal));
        var queueArguments = SlurmCommands.ListJobs(platform);
        Check.True(queueArguments[^1].Contains("--json", StringComparison.Ordinal));
        Check.False(queueArguments[^1].Contains("--format", StringComparison.Ordinal));

        static Dictionary<string, object?> QueueJob(
            long jobId,
            string name,
            string comment) => new()
        {
            ["job_id"] = jobId,
            ["name"] = name,
            ["user_name"] = "zli760",
            ["job_state"] = new[] { "RUNNING" },
            ["nodes"] = "gpu01",
            ["state_reason"] = "NONE",
            ["partition"] = "debug",
            ["node_count"] = new Dictionary<string, object?>
            {
                ["set"] = true,
                ["number"] = 1L,
            },
            ["start_time"] = new Dictionary<string, object?>
            {
                ["set"] = true,
                ["number"] = 1_760_227_200L,
            },
            ["end_time"] = new Dictionary<string, object?>
            {
                ["set"] = true,
                ["number"] = 1_760_227_500L,
            },
            ["submit_time"] = 1_760_227_140L,
            ["time_limit"] = new Dictionary<string, object?>
            {
                ["set"] = true,
                ["number"] = 30L,
            },
            ["comment"] = comment,
        };
        static string QueueJson(params object[] jobs) =>
            System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["errors"] = Array.Empty<object>(),
                ["jobs"] = jobs,
            });

        var row = QueueJob(12345, receipt.JobName, receipt.Comment);
        var jobs = SlurmParser.ParseQueue(QueueJson(row));
        Check.Equal(1, jobs.Count);
        Check.Equal("12345", jobs[0].JobId.Value);
        Check.Equal(SlurmJobStateKind.Running, jobs[0].State.Kind);
        Check.Equal(receipt.Comment, jobs[0].Comment);
        Check.Equal("5:00", jobs[0].Elapsed);
        Check.Equal("30:00", jobs[0].TimeLimit);

        var secondJob = QueueJob(12347, "external-job", "external-comment");
        var tolerant = SlurmParser.ParseQueueWithDiagnostics(
            QueueJson(row, new { job_id = "not-a-job-id" }, secondJob));
        Check.Equal(2, tolerant.Jobs.Count);
        Check.Equal(1, tolerant.IgnoredRowCount);

        var fakeInjectedJob = QueueJob(99999, receipt.JobName, receipt.Comment);
        var unsafeFreeTextJob = QueueJob(
            12348,
            "external-job",
            "ordinary prefix\n" + System.Text.Json.JsonSerializer.Serialize(fakeInjectedJob));
        var unsafeFreeText = SlurmParser.ParseQueueWithDiagnostics(
            QueueJson(row, unsafeFreeTextJob));
        Check.Equal(1, unsafeFreeText.Jobs.Count);
        Check.Equal(1, unsafeFreeText.IgnoredRowCount);
        Check.False(unsafeFreeText.Jobs.Any(job => job.JobId.Value == "99999"));

        var duplicateIdJob = QueueJob(12345, "conflicting-job", "external-comment");
        var conflicted = SlurmParser.ParseQueueWithDiagnostics(
            QueueJson(row, duplicateIdJob));
        Check.Equal(0, conflicted.Jobs.Count);
        Check.Equal(2, conflicted.IgnoredRowCount);

        var secondMatchingJob = QueueJob(12346, receipt.JobName, receipt.Comment);
        var duplicateJobs = SlurmParser.ParseQueue(
            QueueJson(row, secondMatchingJob));
        Check.Equal(
            2,
            (int)InvokeInternal(
                "TmuxHub.Windows.Services.SlurmService",
                "MatchCount",
                receipt,
                duplicateJobs));
        try
        {
            InvokeInternal(
                "TmuxHub.Windows.Services.SlurmService",
                "Reconcile",
                receipt,
                duplicateJobs);
            throw new InvalidOperationException("Expected ambiguous Slurm reconciliation.");
        }
        catch (SlurmAmbiguousLaunchException)
        {
        }
    }

    private static void SshDiagnostics()
    {
        var changed = SshConnectionDiagnostics.Classify(
            255,
            string.Empty,
            "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!");
        Check.Equal(SshDiagnosticKind.ChangedHostKey, changed.Kind);

        var authentication = SshConnectionDiagnostics.Classify(
            255,
            string.Empty,
            "Permission denied (publickey,password).");
        Check.Equal(SshDiagnosticKind.AuthenticationFailed, authentication.Kind);

        var sanitized = SshConnectionDiagnostics.SanitizeDiagnostic(
            "password=secret-value\n"
            + "AWS_SECRET_ACCESS_KEY=aws-secret-value\n"
            + "GITHUB_TOKEN=github-secret-value\n"
            + "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + "AAAAverysecretmaterialBBBB\n"
            + "-----END OPENSSH PRIVATE KEY-----");
        Check.False(sanitized.Contains("secret-value", StringComparison.Ordinal));
        Check.False(sanitized.Contains("aws-secret-value", StringComparison.Ordinal));
        Check.False(sanitized.Contains("github-secret-value", StringComparison.Ordinal));
        Check.False(sanitized.Contains("OPENSSH PRIVATE KEY", StringComparison.Ordinal));
        Check.True(sanitized.Contains("已隐藏", StringComparison.Ordinal));

        var slurmFailure = (SlurmCommandException)InvokeInternal(
            "TmuxHub.Windows.Services.SlurmService",
            "CommandError",
            new SshProcessResult(
                1,
                string.Empty,
                "GITHUB_TOKEN=do-not-display"));
        Check.False(slurmFailure.Message.Contains("do-not-display", StringComparison.Ordinal));

        var tmuxFailure = (TmuxConfigurationException)InvokeInternal(
            "TmuxHub.Windows.Models.TmuxConfigurationException",
            "CommandFailed",
            1,
            "AWS_SECRET_ACCESS_KEY=do-not-display");
        Check.False(tmuxFailure.Message.Contains("do-not-display", StringComparison.Ordinal));

        var scriptedPreset = new SlurmInteractivePreset(
            "default",
            "交互环境",
            "debug",
            1,
            4,
            16_384,
            new SlurmWallTime(1_800),
            InitializationScript: "export TOKEN=do-not-place-in-argv");
        try
        {
            InvokeInternal(
                "TmuxHub.Windows.Services.SlurmCommands",
                "ValidatePreset",
                scriptedPreset);
            throw new InvalidOperationException(
                "Windows must reject initialization scripts in process arguments.");
        }
        catch (SlurmValidationException)
        {
        }

        var workingDirectoryPreset = scriptedPreset with
        {
            WorkingDirectory = "/tmp/allowed-looking-but-not-placed-in-argv",
            InitializationScript = null,
        };
        try
        {
            InvokeInternal(
                "TmuxHub.Windows.Services.SlurmCommands",
                "ValidatePreset",
                workingDirectoryPreset);
            throw new InvalidOperationException(
                "Windows must reject working directories in process arguments.");
        }
        catch (SlurmValidationException)
        {
        }
    }

    private static void SshCommandConstruction()
    {
        var remote = (string)InvokeInternal(
            "TmuxHub.Windows.Services.SshInvocation",
            "PosixCommand",
            "tmux",
            new[] { "new-session", "-A", "-s", "main's $(safe)" });
        Check.Equal(
            "'tmux' 'new-session' '-A' '-s' 'main'\"'\"'s $(safe)'",
            remote);

        var background = (IReadOnlyList<string>)InvokeInternal(
            "TmuxHub.Windows.Services.SshInvocation",
            "BackgroundArguments",
            "user@example.com",
            remote);
        Check.SequenceEqual(
            [
                "-nT",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ConnectionAttempts=1",
                "-o", "ClearAllForwardings=yes",
                "-o", "PermitLocalCommand=no",
                "user@example.com",
                remote,
            ],
            background);

        var interactive = (IReadOnlyList<string>)InvokeInternal(
            "TmuxHub.Windows.Services.SshInvocation",
            "InteractiveArguments",
            "prod",
            "exec " + remote);
        Check.SequenceEqual(
            [
                "-tt",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=3",
                "prod",
                "exec " + remote,
            ],
            interactive);
    }

    private static void WindowsArgumentQuoting()
    {
        Check.Equal(
            "plain",
            InvokeInternal(
                "TmuxHub.Windows.Services.TerminalLauncher",
                "QuoteWindowsArgument",
                "plain"));
        Check.Equal(
            "\"two words\"",
            InvokeInternal(
                "TmuxHub.Windows.Services.TerminalLauncher",
                "QuoteWindowsArgument",
                "two words"));
        Check.Equal(
            "\"C:\\path with space\\\\\"",
            InvokeInternal(
                "TmuxHub.Windows.Services.TerminalLauncher",
                "QuoteWindowsArgument",
                "C:\\path with space\\"));
    }

    private static void ClipboardBridgeArguments()
    {
        var type = typeof(SshProcessRunner).Assembly.GetType(
            "TmuxHub.Windows.Services.ConsoleClipboardPasteBridge",
            throwOnError: true)!;
        var method = type.GetMethod(
            "TryParseArguments",
            BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new MissingMethodException(type.FullName, "TryParseArguments");

        object?[] valid = [
            new[] { "--clipboard-paste-bridge", "4242", "cis-lab" },
            0,
            null,
        ];
        Check.True((bool)method.Invoke(null, valid)!);
        Check.Equal(4242, (int)valid[1]!);
        Check.Equal("cis-lab", (string)valid[2]!);

        object?[] invalid = [
            new[] { "--clipboard-paste-bridge", "0", "cis-lab" },
            0,
            null,
        ];
        Check.False((bool)method.Invoke(null, invalid)!);
    }

    private static void ClipboardAttachmentPaths()
    {
        var token = "12345678-1234-5678-90ab-1234567890ab";
        var batch = ((string Text, string RemotePath))InvokeInternal(
            "TmuxHub.Windows.Services.RemoteClipboardImageTransfer",
            "BuildBatch",
            "C:\\Temp Folder\\截图.png",
            "/home/user name",
            token);
        Check.Equal(
            "/home/user name/.tmuxhub/attachments/" + token + "/screenshot.png",
            batch.RemotePath);
        Check.True(batch.Text.Contains(
            "put \"C:/Temp Folder/截图.png\"",
            StringComparison.Ordinal));
        Check.True(batch.Text.Contains(
            "rename \"/home/user name/.tmuxhub/attachments/" + token,
            StringComparison.Ordinal));

        Check.Equal(
            "/home/user name",
            InvokeInternal(
                "TmuxHub.Windows.Services.RemoteClipboardImageTransfer",
                "ParseRemoteHome",
                "profile banner\nTMUXHUB_HOME_V1\t/home/user name\n"));
        Check.Equal(
            "user@[2001:db8::1]",
            InvokeInternal(
                "TmuxHub.Windows.Services.RemoteClipboardImageTransfer",
                "SftpDestination",
                "user@2001:db8::1"));
        Check.Equal(
            "'/home/a'\"'\"'b/screenshot.png'",
            InvokeInternal(
                "TmuxHub.Windows.Services.RemoteClipboardImageTransfer",
                "ShellQuote",
                "/home/a'b/screenshot.png"));
    }

    private static object InvokeInternal(
        string typeName,
        string methodName,
        params object[] arguments)
    {
        var type = typeof(SshProcessRunner).Assembly.GetType(typeName, throwOnError: true)!;
        var method = type.GetMethod(
            methodName,
            BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)
            ?? throw new MissingMethodException(typeName, methodName);
        try
        {
            return method.Invoke(null, arguments)
                ?? throw new InvalidOperationException($"{typeName}.{methodName} returned null.");
        }
        catch (TargetInvocationException error) when (error.InnerException is not null)
        {
            throw error.InnerException;
        }
    }

    private sealed class TestWorkspace : IDisposable
    {
        public TestWorkspace()
        {
            var testRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "test-work"));
            Directory.CreateDirectory(testRoot);
            Root = Path.Combine(testRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
        }

        public string Root { get; }

        public void Dispose()
        {
            var testRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "test-work"));
            var resolved = Path.GetFullPath(Root);
            if (!resolved.StartsWith(
                    testRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Refusing to remove a test path outside the test output directory.");
            }

            if (Directory.Exists(resolved))
            {
                Directory.Delete(resolved, recursive: true);
            }
        }
    }

    private static class Check
    {
        public static void True(bool condition, string? message = null)
        {
            if (!condition)
            {
                throw new InvalidOperationException(message ?? "Expected true, received false.");
            }
        }

        public static void False(bool condition, string? message = null) =>
            True(!condition, message ?? "Expected false, received true.");

        public static void Equal<T>(T expected, T actual, string? message = null)
        {
            if (!EqualityComparer<T>.Default.Equals(expected, actual))
            {
                throw new InvalidOperationException(
                    message ?? $"Expected <{expected}>, received <{actual}>.");
            }
        }

        public static void NotEqual<T>(T unexpected, T actual)
        {
            if (EqualityComparer<T>.Default.Equals(unexpected, actual))
            {
                throw new InvalidOperationException($"Did not expect <{actual}>.");
            }
        }

        public static void SequenceEqual<T>(
            IEnumerable<T> expected,
            IEnumerable<T> actual)
        {
            var expectedValues = expected.ToArray();
            var actualValues = actual.ToArray();
            if (!expectedValues.SequenceEqual(actualValues))
            {
                throw new InvalidOperationException(
                    $"Expected [{string.Join(", ", expectedValues)}], "
                    + $"received [{string.Join(", ", actualValues)}].");
            }
        }
    }
}
