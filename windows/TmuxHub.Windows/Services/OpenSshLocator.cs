using System.IO;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Resolves the Windows inbox OpenSSH client without consulting the current
/// directory or PATH. This avoids launching a same-named binary from a writable
/// directory.
/// </summary>
public static class OpenSshLocator
{
    public static string Locate(string? explicitPath = null)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            return ValidateExplicitPath(explicitPath);
        }

        var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
        if (!string.IsNullOrWhiteSpace(systemDirectory))
        {
            var candidate = Path.Combine(systemDirectory, "OpenSSH", "ssh.exe");
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        // SpecialFolder.System may be unavailable in restricted test hosts.
        // Keep the fallback rooted in the Windows directory; never search PATH.
        var windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (!string.IsNullOrWhiteSpace(windowsDirectory))
        {
            var candidate = Path.Combine(windowsDirectory, "System32", "OpenSSH", "ssh.exe");
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        throw new FileNotFoundException(
            "Windows OpenSSH Client is not installed. Enable the OpenSSH Client optional feature."
        );
    }

    private static string ValidateExplicitPath(string value)
    {
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("The OpenSSH path contains a null character.", nameof(value));
        }

        if (!Path.IsPathFullyQualified(value))
        {
            throw new ArgumentException("The OpenSSH path must be fully qualified.", nameof(value));
        }

        var fullPath = Path.GetFullPath(value);
        if (!string.Equals(Path.GetFileName(fullPath), "ssh.exe", StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(fullPath))
        {
            throw new FileNotFoundException("The configured OpenSSH executable is invalid.", fullPath);
        }

        return fullPath;
    }
}
