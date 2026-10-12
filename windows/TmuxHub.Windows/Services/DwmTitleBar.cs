using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace TmuxHub.Windows.Services;

/// <summary>
/// Applies the app palette to the native non-client title bar. Unsupported
/// DWM attributes are deliberately ignored so older Windows builds retain
/// their system-managed chrome.
/// </summary>
internal static class DwmTitleBar
{
    private const int UseImmersiveDarkModeBefore20H1 = 19;
    private const int UseImmersiveDarkMode = 20;
    private const int BorderColor = 34;
    private const int CaptionColor = 35;
    private const int TextColor = 36;

    internal static void Apply(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (!OperatingSystem.IsWindows() || SystemParameters.HighContrast)
        {
            return;
        }

        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        try
        {
            var enabled = 1;
            if (SetAttribute(handle, UseImmersiveDarkMode, enabled) != 0)
            {
                _ = SetAttribute(handle, UseImmersiveDarkModeBefore20H1, enabled);
            }

            var caption = ResolveColor(window, "WindowColor", Color.FromRgb(0x10, 0x18, 0x22));
            var text = ResolveColor(window, "TextColor", Color.FromRgb(0xF5, 0xF8, 0xFC));
            var border = ResolveColor(window, "BorderColor", Color.FromRgb(0x3A, 0x4D, 0x64));
            _ = SetAttribute(handle, CaptionColor, ToColorRef(caption));
            _ = SetAttribute(handle, TextColor, ToColorRef(text));
            _ = SetAttribute(handle, BorderColor, ToColorRef(border));
        }
        catch (DllNotFoundException)
        {
        }
        catch (EntryPointNotFoundException)
        {
        }
        catch (BadImageFormatException)
        {
        }
    }

    private static Color ResolveColor(Window window, string resourceKey, Color fallback)
    {
        return window.TryFindResource(resourceKey) switch
        {
            Color color => color,
            SolidColorBrush brush => brush.Color,
            _ => fallback,
        };
    }

    private static int ToColorRef(Color color) =>
        color.R | color.G << 8 | color.B << 16;

    private static int SetAttribute(IntPtr handle, int attribute, int value) =>
        DwmSetWindowAttribute(handle, attribute, ref value, sizeof(int));

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr windowHandle,
        int attribute,
        ref int value,
        int valueSize);
}
