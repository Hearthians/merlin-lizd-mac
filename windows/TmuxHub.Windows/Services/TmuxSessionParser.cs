using System.Globalization;
using System.IO;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

public static class TmuxSessionParser
{
    public static IReadOnlyList<TmuxSessionRecord> Parse(string output)
    {
        ArgumentNullException.ThrowIfNull(output);

        var sessions = new List<TmuxSessionRecord>();
        var seenIdentities = new HashSet<TmuxSessionIdentity>();
        var seenLegacyNames = new HashSet<string>(StringComparer.Ordinal);

        using var reader = new StringReader(output);
        while (reader.ReadLine() is { } rawLine)
        {
            var line = rawLine.Trim();
            if (TryParseStructured(line, out var structured))
            {
                if (seenIdentities.Add(structured.Identity!))
                {
                    sessions.Add(structured);
                }

                continue;
            }

            var legacyName = ParseLegacyName(line);
            if (legacyName is not null && seenLegacyNames.Add(legacyName))
            {
                sessions.Add(new TmuxSessionRecord(legacyName));
            }
        }

        return sessions;
    }

    public static bool IsAttachable(string? value)
    {
        return IdentifierValidator.IsTmuxSessionName(value);
    }

    private static bool TryParseStructured(
        string line,
        out TmuxSessionRecord record)
    {
        record = null!;
        var fields = line.Split(',', StringSplitOptions.None);
        if (fields.Length != 3
            || !IsAttachable(fields[0])
            || !IdentifierValidator.IsTmuxSessionId(fields[1])
            || fields[2].Length == 0
            || !fields[2].All(static value => value is >= '0' and <= '9')
            || !long.TryParse(
                fields[2],
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var createdAtEpoch))
        {
            return false;
        }

        record = new TmuxSessionRecord(
            fields[0],
            new TmuxSessionIdentity(fields[1], createdAtEpoch));
        return true;
    }

    private static string? ParseLegacyName(string line)
    {
        if (IsAttachable(line))
        {
            return line;
        }

        var colon = line.IndexOf(':');
        if (colon < 0
            || !line[(colon + 1)..].Contains(" window", StringComparison.Ordinal))
        {
            return null;
        }

        var candidate = line[..colon];
        return IsAttachable(candidate) ? candidate : null;
    }
}
