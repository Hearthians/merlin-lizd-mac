using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Starts Windows OpenSSH in its own interactive console. CreateProcessW is
/// called directly with CREATE_NEW_CONSOLE; cmd.exe, PowerShell and WSL are not
/// involved.
/// </summary>
public sealed class TerminalLauncher
{
    private const uint CreateNewConsole = 0x00000010;
    private const int MaximumCommandLineCharacters = 32_766;
    private readonly string _sshExecutable;

    public TerminalLauncher(string? sshExecutable = null)
    {
        _sshExecutable = OpenSshLocator.Locate(sshExecutable);
    }

    public uint OpenShell(string destination)
    {
        return Launch(new[]
        {
            "-tt",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            SshInvocation.RequireDestination(destination),
        });
    }

    public uint Launch(IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);

        var commandLine = new StringBuilder(QuoteWindowsArgument(_sshExecutable));
        foreach (var argument in arguments)
        {
            ArgumentNullException.ThrowIfNull(argument);
            if (argument.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("An OpenSSH argument contains a null character.", nameof(arguments));
            }
            commandLine.Append(' ').Append(QuoteWindowsArgument(argument));
        }

        if (commandLine.Length > MaximumCommandLineCharacters)
        {
            throw new ArgumentException("The OpenSSH command line is too long.", nameof(arguments));
        }

        var startupInfo = new StartupInfo
        {
            Size = Marshal.SizeOf<StartupInfo>(),
        };
        var currentDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!Directory.Exists(currentDirectory))
        {
            currentDirectory = null;
        }

        if (!CreateProcess(
                _sshExecutable,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                CreateNewConsole,
                IntPtr.Zero,
                currentDirectory,
                ref startupInfo,
                out var processInformation))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows OpenSSH could not be launched.");
        }

        try
        {
            return processInformation.ProcessId;
        }
        finally
        {
            CloseHandle(processInformation.ThreadHandle);
            CloseHandle(processInformation.ProcessHandle);
        }
    }

    internal static string QuoteWindowsArgument(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("A process argument contains a null character.", nameof(value));
        }

        if (value.Length > 0 && !value.Any(character => char.IsWhiteSpace(character) || character == '"'))
        {
            return value;
        }

        var result = new StringBuilder(value.Length + 2).Append('"');
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1).Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes).Append(character);
            backslashes = 0;
        }

        // Backslashes before the closing quote must be doubled.
        return result.Append('\\', backslashes * 2).Append('"').ToString();
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string? currentDirectory,
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string? Reserved;
        public string? Desktop;
        public string? Title;
        public uint X;
        public uint Y;
        public uint XSize;
        public uint YSize;
        public uint XCountChars;
        public uint YCountChars;
        public uint FillAttribute;
        public uint Flags;
        public ushort ShowWindow;
        public ushort Reserved2Size;
        public IntPtr Reserved2;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public uint ProcessId;
        public uint ThreadId;
    }
}
