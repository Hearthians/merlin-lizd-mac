using System.IO;
using System.Text.Json;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

public sealed class AppStateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        AllowTrailingCommas = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Skip,
        WriteIndented = true,
    };

    public AppStateStore(string? stateFilePath = null)
    {
        StateFilePath = Path.GetFullPath(
            string.IsNullOrWhiteSpace(stateFilePath)
                ? DefaultStateFilePath()
                : stateFilePath);
    }

    public string StateFilePath { get; }

    public AppState Load()
    {
        try
        {
            if (!File.Exists(StateFilePath))
            {
                return new AppState();
            }

            var json = File.ReadAllText(StateFilePath);
            var persisted = JsonSerializer.Deserialize<PersistedAppState>(json, JsonOptions);
            return persisted is null ? new AppState() : Sanitize(persisted);
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException
            or JsonException
            or NotSupportedException)
        {
            return new AppState();
        }
    }

    public void Save(AppState state)
    {
        ArgumentNullException.ThrowIfNull(state);

        var persisted = ToPersistedState(state);
        var directory = Path.GetDirectoryName(StateFilePath)
            ?? throw new InvalidOperationException("The state path has no parent directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(StateFilePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(
                temporaryPath,
                JsonSerializer.Serialize(persisted, JsonOptions));
            File.Move(temporaryPath, StateFilePath, overwrite: true);
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (IOException)
            {
                // The replacement succeeded or another cleanup attempt can
                // remove the unique temporary file later.
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static AppState Sanitize(PersistedAppState persisted)
    {
        var state = new AppState();
        foreach (var destination in persisted.CustomDestinations ?? [])
        {
            if (IdentifierValidator.IsSshDestination(destination))
            {
                state.CustomDestinations.Add(destination);
            }
        }

        foreach (var destination in persisted.PinnedDestinations ?? [])
        {
            if (IdentifierValidator.IsSshDestination(destination))
            {
                state.PinnedDestinations.Add(destination);
            }
        }

        foreach (var entry in persisted.LastUsedAt
            ?? new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal))
        {
            if (IdentifierValidator.IsSshDestination(entry.Key)
                && entry.Value > DateTimeOffset.UnixEpoch)
            {
                state.LastUsedAt[entry.Key] = entry.Value;
            }
        }

        return state;
    }

    private static PersistedAppState ToPersistedState(AppState state)
    {
        var custom = state.CustomDestinations
            .Where(IdentifierValidator.IsSshDestination)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(static value => value, StringComparer.Ordinal)
            .ToArray();
        var pinned = state.PinnedDestinations
            .Where(IdentifierValidator.IsSshDestination)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(static value => value, StringComparer.Ordinal)
            .ToArray();
        var recent = new SortedDictionary<string, DateTimeOffset>(StringComparer.Ordinal);
        foreach (var entry in state.LastUsedAt)
        {
            if (IdentifierValidator.IsSshDestination(entry.Key)
                && entry.Value > DateTimeOffset.UnixEpoch)
            {
                recent[entry.Key] = entry.Value;
            }
        }

        return new PersistedAppState
        {
            Version = AppState.CurrentVersion,
            CustomDestinations = custom,
            PinnedDestinations = pinned,
            LastUsedAt = recent,
        };
    }

    private static string DefaultStateFilePath()
    {
        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            localApplicationData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "AppData",
                "Local");
        }

        return Path.Combine(localApplicationData, "TmuxHub", "state.json");
    }

    private sealed class PersistedAppState
    {
        public int Version { get; set; } = AppState.CurrentVersion;

        public string[]? CustomDestinations { get; set; }

        public string[]? PinnedDestinations { get; set; }

        public IDictionary<string, DateTimeOffset>? LastUsedAt { get; set; }
    }
}
