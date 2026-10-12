using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32.SafeHandles;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Runs in a hidden helper process attached to one ssh.exe console. It consumes
/// Ctrl+V only while that exact console is foreground. Text is written directly
/// to the console input buffer. Images are converted to PNG, uploaded over a
/// separate SFTP process, and replaced by a shell-quoted remote path.
/// </summary>
internal sealed class ConsoleClipboardPasteBridge : IDisposable
{
    internal const string Argument = "--clipboard-paste-bridge";
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int VkControl = 0x11;
    private const int VkMenu = 0x12;
    private const int VkV = 0x56;
    private const ushort KeyEvent = 0x0001;
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const int MaximumClipboardCharacters = 64 * 1024;
    private const long MaximumImagePixels = 50_000_000;

    private readonly int targetProcessId;
    private readonly Dispatcher dispatcher;
    private readonly Action shutdown;
    private readonly LowLevelKeyboardProc hookCallback;
    private readonly string destination;
    private readonly CancellationTokenSource lifetime = new();
    private RemoteClipboardImageTransfer? imageTransfer;
    private Process? targetProcess;
    private SafeFileHandle? consoleInput;
    private IntPtr consoleWindow;
    private IntPtr hook;
    private bool suppressVKeyUp;
    private bool pasteInProgress;
    private bool consoleAttached;
    private bool disposed;
    private string? pendingInsertion;
    private uint pendingClipboardSequence;

    internal ConsoleClipboardPasteBridge(
        int targetProcessId,
        string destination,
        Dispatcher dispatcher,
        Action shutdown)
    {
        if (targetProcessId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(targetProcessId));
        }
        this.targetProcessId = targetProcessId;
        this.destination = SshInvocation.RequireDestination(destination);
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.shutdown = shutdown ?? throw new ArgumentNullException(nameof(shutdown));
        hookCallback = KeyboardHook;
    }

    internal static bool TryParseArguments(
        IReadOnlyList<string> arguments,
        out int targetProcessId,
        out string destination)
    {
        targetProcessId = 0;
        destination = string.Empty;
        if (arguments.Count != 3
            || !string.Equals(arguments[0], Argument, StringComparison.Ordinal)
            || !int.TryParse(
                arguments[1],
                System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture,
                out targetProcessId)
            || targetProcessId <= 0)
        {
            return false;
        }
        destination = arguments[2];
        return IdentifierValidator.IsSshDestination(destination);
    }

    internal bool Start()
    {
        ThrowIfDisposed();
        targetProcess = Process.GetProcessById(targetProcessId);
        targetProcess.EnableRaisingEvents = true;
        targetProcess.Exited += TargetProcessOnExited;

        for (var attempt = 0; attempt < 40; attempt++)
        {
            if (AttachConsole((uint)targetProcessId))
            {
                consoleAttached = true;
                break;
            }
            if (targetProcess.HasExited)
            {
                return false;
            }
            Thread.Sleep(50);
        }
        if (!consoleAttached)
        {
            return false;
        }

        consoleWindow = GetConsoleWindow();
        if (consoleWindow == IntPtr.Zero)
        {
            return false;
        }

        consoleInput = CreateFile(
            "CONIN$",
            GenericRead | GenericWrite,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            OpenExisting,
            0,
            IntPtr.Zero);
        if (consoleInput.IsInvalid)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Unable to open the SSH console input buffer.");
        }

        hook = SetWindowsHookEx(
            WhKeyboardLl,
            hookCallback,
            GetModuleHandle(null),
            0);
        if (hook == IntPtr.Zero)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Unable to start the clipboard paste bridge.");
        }
        return true;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        lifetime.Cancel();
        if (hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
        consoleInput?.Dispose();
        consoleInput = null;
        if (consoleAttached)
        {
            FreeConsole();
            consoleAttached = false;
        }
        if (targetProcess is not null)
        {
            targetProcess.Exited -= TargetProcessOnExited;
            targetProcess.Dispose();
            targetProcess = null;
        }
        lifetime.Dispose();
    }

    private IntPtr KeyboardHook(int code, IntPtr message, IntPtr data)
    {
        if (code < 0 || disposed)
        {
            return CallNextHookEx(hook, code, message, data);
        }

        var keyboard = Marshal.PtrToStructure<KbdLlHookStruct>(data);
        var isV = keyboard.VirtualKeyCode == VkV;
        var isKeyDown = message == (IntPtr)WmKeyDown || message == (IntPtr)WmSysKeyDown;
        var isKeyUp = message == (IntPtr)WmKeyUp || message == (IntPtr)WmSysKeyUp;
        if (isV && suppressVKeyUp)
        {
            if (isKeyUp)
            {
                suppressVKeyUp = false;
            }
            return (IntPtr)1;
        }
        if (!isV
            || !isKeyDown
            || GetForegroundWindow() != consoleWindow
            || (GetAsyncKeyState(VkControl) & 0x8000) == 0
            || (GetAsyncKeyState(VkMenu) & 0x8000) != 0)
        {
            return CallNextHookEx(hook, code, message, data);
        }

        var clipboardSequence = GetClipboardSequenceNumber();
        if (pendingInsertion is not null)
        {
            if (clipboardSequence == pendingClipboardSequence
                && WriteText(pendingInsertion))
            {
                pendingInsertion = null;
                suppressVKeyUp = true;
                return (IntPtr)1;
            }
            pendingInsertion = null;
        }

        string text;
        bool hasImage;
        try
        {
            text = Clipboard.GetText(TextDataFormat.UnicodeText);
            hasImage = Clipboard.ContainsImage();
        }
        catch (ExternalException)
        {
            return CallNextHookEx(hook, code, message, data);
        }
        if (text.Length > 0
            && text.Length <= MaximumClipboardCharacters
            && text.IndexOf('\0') < 0)
        {
            if (!WriteText(text))
            {
                return CallNextHookEx(hook, code, message, data);
            }
            suppressVKeyUp = true;
            return (IntPtr)1;
        }
        if (!hasImage)
        {
            return CallNextHookEx(hook, code, message, data);
        }

        if (!pasteInProgress)
        {
            pasteInProgress = true;
            dispatcher.BeginInvoke(new Action(
                () => _ = PasteClipboardImageAsync(clipboardSequence)));
        }
        suppressVKeyUp = true;
        return (IntPtr)1;
    }

    private async Task PasteClipboardImageAsync(uint clipboardSequence)
    {
        try
        {
            var png = CaptureClipboardPng();
            imageTransfer ??= new RemoteClipboardImageTransfer(destination);
            var remotePath = await imageTransfer.UploadPngAsync(png, lifetime.Token);
            if (disposed)
            {
                return;
            }
            var insertion = RemoteClipboardImageTransfer.ShellQuote(remotePath) + " ";
            if (GetForegroundWindow() == consoleWindow && WriteText(insertion))
            {
                return;
            }
            pendingInsertion = insertion;
            pendingClipboardSequence = clipboardSequence;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception) when (!disposed)
        {
            SystemSounds.Exclamation.Play();
        }
        finally
        {
            pasteInProgress = false;
        }
    }

    private static byte[] CaptureClipboardPng()
    {
        var image = Clipboard.GetImage()
            ?? throw new InvalidDataException("The clipboard does not contain an image.");
        if (image.PixelWidth <= 0
            || image.PixelHeight <= 0
            || (long)image.PixelWidth * image.PixelHeight > MaximumImagePixels)
        {
            throw new InvalidDataException("The clipboard image dimensions are invalid.");
        }

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        if (stream.Length == 0
            || stream.Length > RemoteClipboardImageTransfer.MaximumImageBytes)
        {
            throw new InvalidDataException("The clipboard image is too large.");
        }
        return stream.ToArray();
    }

    private bool WriteText(string text)
    {
        if (consoleInput is null || consoleInput.IsInvalid)
        {
            return false;
        }

        var records = new List<InputRecord>(text.Length * 2);
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character == '\r' && index + 1 < text.Length && text[index + 1] == '\n')
            {
                continue;
            }
            if (character == '\n')
            {
                character = '\r';
            }
            records.Add(InputRecord.ForCharacter(character, keyDown: true));
            records.Add(InputRecord.ForCharacter(character, keyDown: false));
        }
        if (records.Count == 0)
        {
            return true;
        }
        return WriteConsoleInput(
            consoleInput,
            records.ToArray(),
            (uint)records.Count,
            out var written)
            && written == records.Count;
    }

    private void TargetProcessOnExited(object? sender, EventArgs e)
    {
        try
        {
            dispatcher.BeginInvoke(shutdown);
        }
        catch (InvalidOperationException)
        {
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
    }

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr message, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct KbdLlHookStruct
    {
        public readonly uint VirtualKeyCode;
        public readonly uint ScanCode;
        public readonly uint Flags;
        public readonly uint Time;
        public readonly nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputRecord
    {
        [FieldOffset(0)]
        public ushort EventType;

        [FieldOffset(4)]
        public KeyEventRecord KeyEvent;

        public static InputRecord ForCharacter(char character, bool keyDown) => new()
        {
            EventType = ConsoleClipboardPasteBridge.KeyEvent,
            KeyEvent = new KeyEventRecord
            {
                KeyDown = keyDown,
                RepeatCount = 1,
                UnicodeChar = character,
            },
        };
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct KeyEventRecord
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool KeyDown;
        public ushort RepeatCount;
        public ushort VirtualKeyCode;
        public ushort VirtualScanCode;
        public char UnicodeChar;
        public uint ControlKeyState;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteConsoleInput(
        SafeFileHandle consoleInput,
        InputRecord[] buffer,
        uint length,
        out uint written);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int hookId,
        LowLevelKeyboardProc callback,
        IntPtr module,
        uint threadId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(
        IntPtr hook,
        int code,
        IntPtr message,
        IntPtr data);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);
}
