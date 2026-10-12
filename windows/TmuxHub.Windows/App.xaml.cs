using System.Windows;
using TmuxHub.Windows.Services;

namespace TmuxHub.Windows;

public partial class App : Application
{
    private const string SingleInstanceMutexName =
        @"Local\TmuxHub.Windows.SingleInstance.v1";
    private Mutex? singleInstanceMutex;
    private ConsoleClipboardPasteBridge? clipboardPasteBridge;

    protected override void OnStartup(StartupEventArgs e)
    {
        if (ConsoleClipboardPasteBridge.TryParseArguments(
                e.Args,
                out var targetProcessId,
                out var destination))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            base.OnStartup(e);
            clipboardPasteBridge = new ConsoleClipboardPasteBridge(
                targetProcessId,
                destination,
                Dispatcher,
                Shutdown);
            try
            {
                if (!clipboardPasteBridge.Start())
                {
                    Shutdown(2);
                }
            }
            catch
            {
                Shutdown(2);
            }
            return;
        }

        singleInstanceMutex = new Mutex(
            initiallyOwned: true,
            SingleInstanceMutexName,
            out var createdNew);
        if (!createdNew)
        {
            singleInstanceMutex.Dispose();
            singleInstanceMutex = null;
            MessageBox.Show(
                "TmuxHub 已经在运行。",
                "TmuxHub",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(
                args.Exception.Message,
                "TmuxHub 遇到错误",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            args.Handled = true;
        };
        base.OnStartup(e);
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        clipboardPasteBridge?.Dispose();
        clipboardPasteBridge = null;
        if (singleInstanceMutex is not null)
        {
            singleInstanceMutex.ReleaseMutex();
            singleInstanceMutex.Dispose();
            singleInstanceMutex = null;
        }
        base.OnExit(e);
    }
}
