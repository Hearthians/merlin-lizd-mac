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

        foreach (var entry in persisted.SlurmSettings
            ?? new Dictionary<string, SlurmHostSettings>(StringComparer.Ordinal))
        {
            if (IsValidSlurmSettings(entry.Key, entry.Value))
            {
                state.SlurmSettings[entry.Key] = entry.Value;
            }
        }

        var receipts = (persisted.SlurmReceipts ?? [])
            .Where(static value => value is not null)
            .Where(IsValidReceipt)
            .GroupBy(static receipt => receipt.RequestId)
            .Select(static group => group
                .OrderByDescending(StatusTimestamp)
                .First())
            .Select(static receipt => receipt.Phase == SlurmLaunchPhase.Submitting
                ? receipt with
                {
                    Phase = SlurmLaunchPhase.LaunchOutcomeUnknown,
                    PhaseUpdatedAt = DateTimeOffset.UtcNow,
                }
                : receipt)
            .ToArray();
        state.SlurmReceipts.AddRange(receipts
            .Where(static receipt => !IsTerminalHistory(receipt.Phase))
            .Concat(receipts
                .Where(static receipt => IsTerminalHistory(receipt.Phase))
                .OrderByDescending(StatusTimestamp)
                .Take(100))
            .OrderByDescending(StatusTimestamp));

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

        var slurmSettings = new SortedDictionary<string, SlurmHostSettings>(
            StringComparer.Ordinal);
        foreach (var entry in state.SlurmSettings)
        {
            if (IsValidSlurmSettings(entry.Key, entry.Value))
            {
                slurmSettings[entry.Key] = entry.Value;
            }
        }
        var validReceipts = state.SlurmReceipts
            .Where(IsValidReceipt)
            .GroupBy(static receipt => receipt.RequestId)
            .Select(static group => group
                .OrderByDescending(StatusTimestamp)
                .First())
            .ToArray();
        var receipts = validReceipts
            .Where(static receipt => !IsTerminalHistory(receipt.Phase))
            .Concat(validReceipts
                .Where(static receipt => IsTerminalHistory(receipt.Phase))
                .OrderByDescending(StatusTimestamp)
                .Take(100))
            .OrderByDescending(StatusTimestamp)
            .ToArray();

        return new PersistedAppState
        {
            Version = AppState.CurrentVersion,
            CustomDestinations = custom,
            PinnedDestinations = pinned,
            LastUsedAt = recent,
            SlurmSettings = slurmSettings,
            SlurmReceipts = receipts,
        };
    }

    private static bool IsValidSlurmSettings(
        string destination,
        SlurmHostSettings? settings)
    {
        if (!IdentifierValidator.IsSshDestination(destination)
            || settings is null
            || settings.GpuCount is < 0 or > 1_024
            || settings.WallTimeMinutes is < 1 or > 525_600)
        {
            return false;
        }
        try
        {
            SlurmCommands.ValidatePlatform(new SlurmPlatformProfile(
                "windows-slurm",
                destination,
                destination,
                settings.Owner));
            SlurmCommands.ValidatePreset(new SlurmInteractivePreset(
                "windows-default",
                "交互环境",
                settings.Partition,
                1,
                settings.CpusPerTask,
                settings.MemoryMiB,
                new SlurmWallTime(checked(settings.WallTimeMinutes * 60)),
                settings.GpuCount == 0 ? null : new SlurmGpuRequest(null, settings.GpuCount)));
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (OverflowException)
        {
            return false;
        }
    }

    private static bool IsValidReceipt(SlurmLaunchReceipt? receipt)
    {
        if (receipt is null
            || receipt.RequestedAt <= DateTimeOffset.UnixEpoch
            || !Enum.IsDefined(receipt.Phase)
            || receipt.PhaseUpdatedAt is { } updatedAt
                && updatedAt <= DateTimeOffset.UnixEpoch)
        {
            return false;
        }
        try
        {
            var platform = new SlurmPlatformProfile(
                receipt.PlatformId,
                receipt.LoginDestination,
                receipt.LoginDestination,
                receipt.Owner);
            SlurmCommands.ValidatePlatform(platform);
            SlurmCommands.ValidateReceipt(receipt, platform);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static bool IsTerminalHistory(SlurmLaunchPhase phase) =>
        phase is SlurmLaunchPhase.LaunchFailed
            or SlurmLaunchPhase.NotFound
            or SlurmLaunchPhase.LeftQueue;

    private static DateTimeOffset StatusTimestamp(SlurmLaunchReceipt receipt) =>
        receipt.PhaseUpdatedAt ?? receipt.RequestedAt;

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

        public IDictionary<string, SlurmHostSettings>? SlurmSettings { get; set; }

        public SlurmLaunchReceipt[]? SlurmReceipts { get; set; }
    }
}
