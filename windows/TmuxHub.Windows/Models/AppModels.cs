using System.Text.Json.Serialization;

namespace TmuxHub.Windows.Models;

public enum SshHostSource
{
    Configuration,
    Custom,
}

public sealed record SshHost(string Destination, SshHostSource Source)
{
    [JsonIgnore]
    public string Id => Destination;
}

public sealed record TmuxSessionIdentity(string ServerSessionId, long CreatedAtEpoch)
{
    [JsonIgnore]
    public string StableDisplayString => $"{ServerSessionId}@{CreatedAtEpoch}";
}

public sealed record TmuxSessionRecord(
    string Name,
    TmuxSessionIdentity? Identity = null)
{
    [JsonIgnore]
    public string Id => Identity?.StableDisplayString ?? Name;
}

public sealed class AppState
{
    public const int CurrentVersion = 3;

    public int Version { get; set; } = CurrentVersion;

    public HashSet<string> CustomDestinations { get; set; } =
        new(StringComparer.Ordinal);

    public HashSet<string> PinnedDestinations { get; set; } =
        new(StringComparer.Ordinal);

    public Dictionary<string, DateTimeOffset> LastUsedAt { get; set; } =
        new(StringComparer.Ordinal);

    public Dictionary<string, SlurmHostSettings> SlurmSettings { get; set; } =
        new(StringComparer.Ordinal);

    public List<SlurmLaunchReceipt> SlurmReceipts { get; set; } = [];
}

public sealed record SlurmHostSettings(
    string Owner,
    string Partition,
    int CpusPerTask,
    int MemoryMiB,
    int WallTimeMinutes,
    int GpuCount);
