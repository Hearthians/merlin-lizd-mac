using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

public sealed class SshConfigCatalog
{
    public const int MaximumFiles = 256;
    public const long MaximumFileBytes = 1_048_576;

    private const int MaximumDirectoriesScannedPerInclude = 4_096;
    private const int MaximumEntriesScannedPerInclude = 32_768;

    private readonly string homeDirectory;
    private readonly string sshDirectory;
    private readonly string rootConfigPath;

    public SshConfigCatalog(
        string? homeDirectory = null,
        string? rootConfigPath = null)
    {
        this.homeDirectory = Path.GetFullPath(
            string.IsNullOrWhiteSpace(homeDirectory)
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                : homeDirectory);
        sshDirectory = Path.Combine(this.homeDirectory, ".ssh");
        this.rootConfigPath = Path.GetFullPath(
            string.IsNullOrWhiteSpace(rootConfigPath)
                ? Path.Combine(sshDirectory, "config")
                : rootConfigPath);
    }

    public IReadOnlyList<SshHost> Load()
    {
        var state = new LoadState();
        LoadFile(rootConfigPath, state);
        return state.Destinations
            .OrderBy(static value => value, StringComparer.OrdinalIgnoreCase)
            .ThenBy(static value => value, StringComparer.Ordinal)
            .Select(static value => new SshHost(value, SshHostSource.Configuration))
            .ToArray();
    }

    public static IReadOnlyList<string> ParseHostDeclarations(string contents)
    {
        ArgumentNullException.ThrowIfNull(contents);

        var result = new List<string>();
        foreach (var line in EnumerateLines(contents))
        {
            var fields = SplitFields(line);
            if (fields.Count == 0
                || !fields[0].Equals("host", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            foreach (var value in fields.Skip(1).Where(IsConcreteHost))
            {
                result.Add(value);
            }
        }

        return result;
    }

    private void LoadFile(string path, LoadState state)
    {
        if (state.Visited.Count >= MaximumFiles)
        {
            return;
        }

        string canonical;
        try
        {
            canonical = CanonicalPath(path);
        }
        catch (Exception error) when (IsFileSystemError(error))
        {
            return;
        }

        if (!state.Visited.Add(canonical))
        {
            return;
        }

        string contents;
        try
        {
            var information = new FileInfo(canonical);
            if (!information.Exists || information.Length > MaximumFileBytes)
            {
                return;
            }

            contents = File.ReadAllText(
                canonical,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true));
        }
        catch (Exception error) when (IsFileSystemError(error) || error is DecoderFallbackException)
        {
            return;
        }

        state.Destinations.UnionWith(ParseHostDeclarations(contents));
        foreach (var pattern in ParseIncludePatterns(contents))
        {
            foreach (var includedPath in ExpandInclude(pattern))
            {
                if (state.Visited.Count >= MaximumFiles)
                {
                    return;
                }

                LoadFile(includedPath, state);
            }
        }
    }

    private IEnumerable<string> ExpandInclude(string value)
    {
        string expanded;
        try
        {
            expanded = ExpandPath(value);
        }
        catch (Exception error) when (IsFileSystemError(error))
        {
            return [];
        }

        if (!ContainsGlob(expanded))
        {
            return [expanded];
        }

        var searchRoot = FindSearchRoot(expanded);
        if (searchRoot is null || !Directory.Exists(searchRoot))
        {
            return [];
        }

        Regex expression;
        try
        {
            expression = new Regex(
                GlobToRegexPattern(expanded),
                RegexOptions.CultureInvariant
                    | RegexOptions.IgnoreCase
                    | RegexOptions.NonBacktracking);
        }
        catch (ArgumentException)
        {
            // A malformed character class is an invalid Include glob, not an
            // application-fatal regular expression.
            return [];
        }

        var matches = new List<string>();
        foreach (var candidate in EnumerateFilesBounded(searchRoot!))
        {
            string fullPath;
            try
            {
                fullPath = Path.GetFullPath(candidate);
            }
            catch (Exception error) when (IsFileSystemError(error))
            {
                continue;
            }

            if (expression.IsMatch(fullPath))
            {
                matches.Add(fullPath);
                if (matches.Count >= MaximumFiles)
                {
                    break;
                }
            }
        }

        matches.Sort(StringComparer.OrdinalIgnoreCase);
        return matches;
    }

    private string ExpandPath(string value)
    {
        var expanded = Environment.ExpandEnvironmentVariables(value);
        if (expanded == "~")
        {
            return homeDirectory;
        }

        if (expanded.StartsWith("~/", StringComparison.Ordinal)
            || expanded.StartsWith("~\\", StringComparison.Ordinal))
        {
            expanded = Path.Combine(homeDirectory, expanded[2..]);
        }
        else if (!Path.IsPathRooted(expanded))
        {
            // OpenSSH resolves relative user-config Includes below ~/.ssh,
            // including Includes found in another included file.
            expanded = Path.Combine(sshDirectory, expanded);
        }

        return Path.GetFullPath(expanded);
    }

    private static string CanonicalPath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var information = new FileInfo(fullPath);
        try
        {
            var target = information.ResolveLinkTarget(returnFinalTarget: true);
            return target is null ? fullPath : Path.GetFullPath(target.FullName);
        }
        catch (IOException)
        {
            return fullPath;
        }
        catch (UnauthorizedAccessException)
        {
            return fullPath;
        }
    }

    private static IReadOnlyList<string> ParseIncludePatterns(string contents)
    {
        var result = new List<string>();
        foreach (var line in EnumerateLines(contents))
        {
            var fields = SplitFields(line);
            if (fields.Count == 0
                || !fields[0].Equals("include", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            result.AddRange(fields.Skip(1));
        }

        return result;
    }

    private static IEnumerable<string> EnumerateLines(string contents)
    {
        using var reader = new StringReader(contents);
        while (reader.ReadLine() is { } line)
        {
            yield return line;
        }
    }

    private static List<string> SplitFields(string line)
    {
        var fields = new List<string>();
        var current = new StringBuilder();
        var quoted = false;

        void FinishField()
        {
            if (current.Length == 0)
            {
                return;
            }

            fields.Add(current.ToString());
            current.Clear();
        }

        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (character == '#' && !quoted)
            {
                break;
            }

            if (character == '"')
            {
                quoted = !quoted;
                continue;
            }

            if (character == '\\' && index + 1 < line.Length
                && IsEscapable(line[index + 1]))
            {
                current.Append(line[++index]);
                continue;
            }

            if (char.IsWhiteSpace(character) && !quoted)
            {
                FinishField();
                continue;
            }

            current.Append(character);
        }

        FinishField();
        return fields;
    }

    private static bool IsEscapable(char value)
    {
        // Keep doubled leading separators intact for UNC paths. A backslash is
        // otherwise a normal Windows path separator; only use it to escape
        // syntax that would split or truncate an OpenSSH config token.
        return char.IsWhiteSpace(value) || value is '"' or '#';
    }

    private static bool IsConcreteHost(string value)
    {
        return !value.StartsWith('!')
            && value.IndexOfAny(['*', '?', '!']) < 0
            && IdentifierValidator.IsSshDestination(value);
    }

    private static bool ContainsGlob(string value)
    {
        return value.IndexOfAny(['*', '?', '[']) >= 0;
    }

    private static string? FindSearchRoot(string pattern)
    {
        var wildcardIndex = pattern.IndexOfAny(['*', '?', '[']);
        if (wildcardIndex < 0)
        {
            return Path.GetDirectoryName(pattern);
        }

        var separatorIndex = pattern.LastIndexOfAny(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
            wildcardIndex);
        if (separatorIndex < 0)
        {
            return null;
        }

        var root = pattern[..(separatorIndex + 1)];
        try
        {
            return Path.GetFullPath(root);
        }
        catch (Exception error) when (IsFileSystemError(error))
        {
            return null;
        }
    }

    private static IEnumerable<string> EnumerateFilesBounded(string root)
    {
        var pending = new Stack<string>();
        pending.Push(root);
        var directoriesScanned = 0;
        var entriesScanned = 0;

        while (pending.Count > 0
            && directoriesScanned < MaximumDirectoriesScannedPerInclude
            && entriesScanned < MaximumEntriesScannedPerInclude)
        {
            var directory = pending.Pop();
            directoriesScanned++;

            string[] files;
            string[] directories;
            try
            {
                files = Directory.GetFiles(directory);
                directories = Directory.GetDirectories(directory);
            }
            catch (Exception error) when (IsFileSystemError(error))
            {
                continue;
            }

            foreach (var file in files)
            {
                if (++entriesScanned > MaximumEntriesScannedPerInclude)
                {
                    yield break;
                }

                if (!IsHidden(file))
                {
                    yield return file;
                }
            }

            foreach (var child in directories.Reverse())
            {
                if (++entriesScanned > MaximumEntriesScannedPerInclude)
                {
                    yield break;
                }

                if (!IsHidden(child) && !IsReparsePoint(child))
                {
                    pending.Push(child);
                }
            }
        }
    }

    private static bool IsHidden(string path)
    {
        if (Path.GetFileName(path).StartsWith(".", StringComparison.Ordinal))
        {
            return true;
        }

        try
        {
            return (File.GetAttributes(path) & FileAttributes.Hidden) != 0;
        }
        catch (Exception error) when (IsFileSystemError(error))
        {
            return true;
        }
    }

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (Exception error) when (IsFileSystemError(error))
        {
            return true;
        }
    }

    private static string GlobToRegexPattern(string glob)
    {
        var pattern = new StringBuilder("^");
        for (var index = 0; index < glob.Length; index++)
        {
            var character = glob[index];
            if (character is '\\' or '/')
            {
                pattern.Append(@"[\\/]");
                continue;
            }

            if (character == '*')
            {
                pattern.Append(@"[^\\/]*");
                continue;
            }

            if (character == '?')
            {
                pattern.Append(@"[^\\/]");
                continue;
            }

            if (character == '[')
            {
                var closing = glob.IndexOf(']', index + 1);
                if (closing < 0)
                {
                    pattern.Append(@"\[");
                    continue;
                }

                AppendCharacterClass(pattern, glob[(index + 1)..closing]);
                index = closing;
                continue;
            }

            pattern.Append(Regex.Escape(character.ToString()));
        }

        pattern.Append('$');
        return pattern.ToString();
    }

    private static void AppendCharacterClass(StringBuilder pattern, string value)
    {
        if (value.Length == 0)
        {
            pattern.Append(@"\[\]");
            return;
        }

        pattern.Append('[');
        var index = 0;
        if (value[0] is '!' or '^')
        {
            pattern.Append('^');
            index++;
        }

        for (; index < value.Length; index++)
        {
            var character = value[index];
            if (character is '\\' or ']')
            {
                pattern.Append('\\');
            }

            pattern.Append(character);
        }

        pattern.Append(']');
    }

    private static bool IsFileSystemError(Exception error)
    {
        return error is IOException
            or UnauthorizedAccessException
            or ArgumentException
            or NotSupportedException
            or System.Security.SecurityException;
    }

    private sealed class LoadState
    {
        public HashSet<string> Visited { get; } =
            new(StringComparer.OrdinalIgnoreCase);

        public HashSet<string> Destinations { get; } =
            new(StringComparer.Ordinal);
    }
}
