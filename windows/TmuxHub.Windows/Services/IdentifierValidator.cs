using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace TmuxHub.Windows.Services;

public static class IdentifierValidator
{
    private const ulong FnvOffsetBasis = 14_695_981_039_346_656_037;
    private const ulong FnvPrime = 1_099_511_628_211;

    private static readonly Regex SshDestinationPattern = new(
        @"^[A-Za-z0-9\[][A-Za-z0-9@._:%+\-\[\]]{0,254}$",
        RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    private static readonly Regex TmuxSessionNamePattern = new(
        @"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
        RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    private static readonly Regex TmuxSessionIdPattern = new(
        @"^\$[0-9]+$",
        RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    private static readonly Regex TmuxWindowIdPattern = new(
        @"^@[0-9]+$",
        RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    private static readonly Regex TmuxPaneIdPattern = new(
        @"^%[0-9]+$",
        RegexOptions.CultureInvariant,
        TimeSpan.FromMilliseconds(100));

    public static bool IsSshDestination(string? value)
    {
        return !string.IsNullOrEmpty(value)
            && Encoding.UTF8.GetByteCount(value) <= 255
            && value[0] != '-'
            && SshDestinationPattern.IsMatch(value);
    }

    public static bool IsIpAddressDestination(string? value)
    {
        if (!IsSshDestination(value))
        {
            return false;
        }

        var host = value!;
        var separator = host.LastIndexOf('@');
        if (separator >= 0)
        {
            host = host[(separator + 1)..];
        }

        if (host.Length >= 2 && host[0] == '[' && host[^1] == ']')
        {
            host = host[1..^1];
        }

        var scope = host.IndexOf('%');
        if (scope >= 0)
        {
            host = host[..scope];
        }

        return IsStrictIpv4(host)
            || (IPAddress.TryParse(host, out var address)
                && address.AddressFamily == AddressFamily.InterNetworkV6);
    }

    public static bool IsTmuxSessionName(string? value)
    {
        return value is not null && TmuxSessionNamePattern.IsMatch(value);
    }

    public static string? NormalizeTmuxSessionName(string? value)
    {
        return IsTmuxSessionName(value)
            ? value!.Replace('.', '_')
            : null;
    }

    public static string? StableTmuxSessionName(string? destination)
    {
        if (!IsSshDestination(destination))
        {
            return null;
        }

        var normalized = new StringBuilder(capacity: 46);
        foreach (var character in destination!.ToLowerInvariant())
        {
            if (normalized.Length == 46)
            {
                break;
            }

            normalized.Append(IsStableNameCharacter(character) ? character : '-');
        }

        var compact = normalized.ToString().Trim('-');
        ulong hash = FnvOffsetBasis;
        foreach (var value in Encoding.UTF8.GetBytes(destination))
        {
            hash ^= value;
            hash = unchecked(hash * FnvPrime);
        }

        var hexadecimal = hash.ToString("x", CultureInfo.InvariantCulture);
        var suffix = hexadecimal.Length > 8 ? hexadecimal[^8..] : hexadecimal;
        var candidate = $"tmuxhub-{(compact.Length == 0 ? "shell" : compact)}-{suffix}";
        return NormalizeTmuxSessionName(candidate);
    }

    public static bool IsTmuxSessionId(string? value)
    {
        return value is not null && TmuxSessionIdPattern.IsMatch(value);
    }

    public static bool IsTmuxWindowId(string? value)
    {
        return value is not null && TmuxWindowIdPattern.IsMatch(value);
    }

    public static bool IsTmuxPaneId(string? value)
    {
        return value is not null && TmuxPaneIdPattern.IsMatch(value);
    }

    public static bool IsTmuxWindowIndex(int value) => value >= 0;

    private static bool IsStableNameCharacter(char value)
    {
        return value is >= 'a' and <= 'z'
            || value is >= '0' and <= '9'
            || value is '.' or '-' or '_';
    }

    private static bool IsStrictIpv4(string value)
    {
        var parts = value.Split('.', StringSplitOptions.None);
        if (parts.Length != 4)
        {
            return false;
        }

        foreach (var part in parts)
        {
            if (part.Length is < 1 or > 3
                || !part.All(static character => character is >= '0' and <= '9')
                || !byte.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out _))
            {
                return false;
            }
        }

        return true;
    }
}
