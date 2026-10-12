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
        ("Windows SSH config Include", SshConfigIncludes),
        ("state round trip and sanitization", StateRoundTrip),
        ("shell-free SSH command construction", SshCommandConstruction),
        ("CreateProcess argument quoting", WindowsArgumentQuoting),
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

        var store = new AppStateStore(path);
        store.Save(state);
        var restored = store.Load();

        Check.Equal(AppState.CurrentVersion, restored.Version);
        Check.True(restored.CustomDestinations.SetEquals(["prod", "user@example.com"]));
        Check.True(restored.PinnedDestinations.SetEquals(["prod"]));
        Check.Equal(timestamp, restored.LastUsedAt["prod"]);
        Check.False(restored.LastUsedAt.ContainsKey("host name"));
        Check.True(File.ReadAllText(path).Contains("\"customDestinations\"", StringComparison.Ordinal));

        File.WriteAllText(path, "{ this is not valid JSON }");
        var recovered = store.Load();
        Check.Equal(0, recovered.CustomDestinations.Count);
        Check.Equal(0, recovered.PinnedDestinations.Count);
        Check.Equal(0, recovered.LastUsedAt.Count);
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
