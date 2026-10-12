using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TmuxHub.Windows.Models;
using TmuxHub.Windows.Services;
using TmuxHub.Windows.Views;

namespace TmuxHub.Windows;

public partial class MainWindow : Window
{
    private const int RecentHostLimit = 6;
    private static readonly TimeSpan RecentHostWindow = TimeSpan.FromDays(7);

    private readonly AppStateStore stateStore = new();
    private readonly SshConfigCatalog sshCatalog = new();
    private readonly CancellationTokenSource lifetimeCancellation = new();
    private AppState state = new();
    private IReadOnlyList<SshHost> configuredHosts = [];
    private IReadOnlyList<HostDisplay> hostItems = [];
    private TmuxService? tmuxService;
    private HerdrService? herdrService;
    private TerminalLauncher? terminalLauncher;
    private Exception? remoteInitializationError;
    private CancellationTokenSource? inventoryCancellation;
    private CancellationTokenSource? operationCancellation;
    private string? activeDestination;
    private bool isLoaded;
    private bool isUpdatingHostSelection;
    private bool isExclusiveOperation;
    private bool suppressSearchRefresh;

    public MainWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => DwmTitleBar.Apply(this);
        InitializeRemoteServices();
        Loaded += MainWindow_OnLoaded;
        Closed += MainWindow_OnClosed;
    }

    private void InitializeRemoteServices()
    {
        try
        {
            var sshExecutable = OpenSshLocator.Locate();
            var runner = new SshProcessRunner(sshExecutable);
            terminalLauncher = new TerminalLauncher(sshExecutable);
            tmuxService = new TmuxService(runner, terminalLauncher);
            herdrService = new HerdrService(runner, terminalLauncher);
        }
        catch (Exception error)
        {
            remoteInitializationError = error;
        }
    }

    private async void MainWindow_OnLoaded(object sender, RoutedEventArgs e)
    {
        if (isLoaded)
        {
            return;
        }
        isLoaded = true;
        state = stateStore.Load();
        await RefreshHostsAsync();
        if (remoteInitializationError is not null)
        {
            SetStatus(FriendlyError(remoteInitializationError), StatusKind.Error);
        }
    }

    private void MainWindow_OnClosed(object? sender, EventArgs e)
    {
        lifetimeCancellation.Cancel();
        CancelInventory();
        operationCancellation?.Cancel();
    }

    private void SearchBox_OnTextChanged(object sender, TextChangedEventArgs e)
    {
        if (isLoaded && !suppressSearchRefresh && !isExclusiveOperation)
        {
            ApplyHostFilter(activeDestination);
        }
    }

    private void HostsList_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isLoaded && !isUpdatingHostSelection)
        {
            ActivateHost(SelectedHost);
        }
    }

    private void AddHostBox_OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            AddHost();
            e.Handled = true;
        }
    }

    private void AddHostButton_OnClick(object sender, RoutedEventArgs e) => AddHost();

    private async void RefreshHostsButton_OnClick(object sender, RoutedEventArgs e) =>
        await RefreshHostsAsync();

    private void EditSshConfigButton_OnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (string.IsNullOrWhiteSpace(home))
            {
                throw new DirectoryNotFoundException("无法确定当前 Windows 用户目录。");
            }
            var sshDirectory = Path.Combine(home, ".ssh");
            var configPath = Path.Combine(sshDirectory, "config");
            Directory.CreateDirectory(sshDirectory);
            using (File.Open(configPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read))
            {
            }

            var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var notepad = Path.Combine(systemDirectory, "notepad.exe");
            ProcessStartInfo startInfo;
            if (File.Exists(notepad))
            {
                startInfo = new ProcessStartInfo { FileName = notepad, UseShellExecute = false };
                startInfo.ArgumentList.Add(configPath);
            }
            else
            {
                startInfo = new ProcessStartInfo { FileName = configPath, UseShellExecute = true };
            }
            _ = Process.Start(startInfo)
                ?? throw new InvalidOperationException("无法启动 SSH 配置编辑器。");
            SetStatus("已打开 SSH 配置；保存后请刷新主机库。", StatusKind.Ready);
        }
        catch (Exception error)
        {
            ShowOperationError("无法编辑 SSH 配置", error);
        }
    }

    private void PinButton_OnClick(object sender, RoutedEventArgs e)
    {
        var host = SelectedHost;
        if (host is null || isExclusiveOperation)
        {
            return;
        }
        var wasPinned = state.PinnedDestinations.Contains(host.Destination);
        if (wasPinned)
        {
            state.PinnedDestinations.Remove(host.Destination);
        }
        else
        {
            state.PinnedDestinations.Add(host.Destination);
        }
        if (!TrySaveState("无法保存固定主机设置。", showDialog: true))
        {
            if (wasPinned)
            {
                state.PinnedDestinations.Add(host.Destination);
            }
            else
            {
                state.PinnedDestinations.Remove(host.Destination);
            }
            return;
        }
        RebuildHostItems(host.Destination);
        SetStatus(wasPinned ? "已取消固定。" : "已固定主机。", StatusKind.Ready);
    }

    private void RemoveHostButton_OnClick(object sender, RoutedEventArgs e)
    {
        var host = SelectedHost;
        if (host is null || !host.IsCustom || isExclusiveOperation)
        {
            return;
        }
        var answer = MessageBox.Show(
            $"从手动主机中移除“{host.Destination}”？", "移除主机",
            MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
        if (answer != MessageBoxResult.Yes)
        {
            return;
        }
        var wasPinned = state.PinnedDestinations.Remove(host.Destination);
        var hadUsage = state.LastUsedAt.Remove(host.Destination, out var lastUsed);
        state.CustomDestinations.Remove(host.Destination);
        if (!TrySaveState("无法保存主机移除结果。", showDialog: true))
        {
            state.CustomDestinations.Add(host.Destination);
            if (wasPinned)
            {
                state.PinnedDestinations.Add(host.Destination);
            }
            if (hadUsage)
            {
                state.LastUsedAt[host.Destination] = lastUsed;
            }
            return;
        }
        RebuildHostItems(host.Destination);
        SetStatus("已移除手动主机。", StatusKind.Ready);
    }

    private void OpenShellButton_OnClick(object sender, RoutedEventArgs e)
    {
        var destination = activeDestination;
        if (destination is null || isExclusiveOperation)
        {
            return;
        }
        try
        {
            var processId = RequireTerminalLauncher().Launch(
            [
                "-tt", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
                destination,
            ]);
            if (RecordUse(destination))
            {
                SetStatus($"SSH Shell 已在独立控制台打开（PID {processId}）。", StatusKind.Ready);
            }
        }
        catch (Exception error)
        {
            ShowOperationError("无法打开 SSH Shell", error);
        }
    }

    private void QuickConnectButton_OnClick(object sender, RoutedEventArgs e)
    {
        var destination = activeDestination;
        if (destination is null || isExclusiveOperation)
        {
            return;
        }
        var sessionName = IdentifierValidator.StableTmuxSessionName(destination);
        if (sessionName is null)
        {
            ShowOperationError("无法快速连接", new ArgumentException("SSH 目标格式无效。"));
            return;
        }
        OpenTmux(destination, sessionName, "快速连接");
    }

    private void WorkspaceTabs_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!isLoaded || !ReferenceEquals(e.OriginalSource, WorkspaceTabs))
        {
            return;
        }
        CancelInventory();
        if (activeDestination is not null && !isExclusiveOperation)
        {
            _ = RefreshActiveWorkspaceAsync();
        }
    }

    private void SessionNameBox_OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            ConnectNamedSession();
            e.Handled = true;
        }
    }

    private void ConnectNamedSessionButton_OnClick(object sender, RoutedEventArgs e) =>
        ConnectNamedSession();

    private async void RefreshSessionsButton_OnClick(object sender, RoutedEventArgs e) =>
        await RefreshSessionsAsync();

    private void SessionGrid_OnSelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateSessionControls();

    private void SessionGrid_OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (SelectedSession is not null)
        {
            OpenSelectedSession();
            e.Handled = true;
        }
    }

    private void OpenSessionButton_OnClick(object sender, RoutedEventArgs e) => OpenSelectedSession();

    private async void RenameSessionButton_OnClick(object sender, RoutedEventArgs e) =>
        await RenameSelectedSessionAsync();

    private async void TerminateSessionButton_OnClick(object sender, RoutedEventArgs e) =>
        await TerminateSelectedSessionAsync();

    private async void RefreshHerdrButton_OnClick(object sender, RoutedEventArgs e) =>
        await RefreshHerdrAsync();

    private void HerdrGrid_OnSelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateHerdrControls();

    private async void HerdrGrid_OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (SelectedHerdrPane is not null)
        {
            await OpenSelectedHerdrAsync();
            e.Handled = true;
        }
    }

    private async void OpenHerdrButton_OnClick(object sender, RoutedEventArgs e) =>
        await OpenSelectedHerdrAsync();

    private void AddHost()
    {
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return;
        }
        var destination = AddHostBox.Text.Trim();
        if (!IdentifierValidator.IsSshDestination(destination))
        {
            MessageBox.Show(
                "SSH 目标格式无效。可使用 config 别名、主机名、IP 或 user@host。",
                "无法添加主机", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        var customAdded = state.CustomDestinations.Add(destination);
        var pinAdded = state.PinnedDestinations.Add(destination);
        if ((customAdded || pinAdded)
            && !TrySaveState("无法保存手动主机。", showDialog: true))
        {
            if (customAdded)
            {
                state.CustomDestinations.Remove(destination);
            }
            if (pinAdded)
            {
                state.PinnedDestinations.Remove(destination);
            }
            return;
        }
        AddHostBox.Clear();
        suppressSearchRefresh = true;
        SearchBox.Clear();
        suppressSearchRefresh = false;
        RebuildHostItems(destination);
        SetStatus("主机已添加并固定。", StatusKind.Ready);
    }

    private async Task RefreshHostsAsync()
    {
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return;
        }
        var destination = activeDestination;
        var request = BeginInventory();
        SetStatus("正在读取 SSH 主机库…", StatusKind.Working);
        try
        {
            var loadedHosts = await Task.Run(() => sshCatalog.Load(), request.Token);
            request.Token.ThrowIfCancellationRequested();
            if (!IsCurrentInventory(request))
            {
                return;
            }
            configuredHosts = loadedHosts;
            RebuildHostItems(destination);
            SetStatus($"已载入 {hostItems.Count} 台 SSH 主机。", StatusKind.Ready);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (IsCurrentInventory(request))
            {
                SetStatus(FriendlyError(error), StatusKind.Error);
            }
        }
        finally
        {
            FinishInventory(request);
        }
    }

    private void RebuildHostItems(string? preferredDestination)
    {
        var byDestination = new Dictionary<string, SshHost>(StringComparer.Ordinal);
        foreach (var host in configuredHosts)
        {
            byDestination[host.Destination] = host;
        }
        foreach (var destination in state.CustomDestinations.Where(IdentifierValidator.IsSshDestination))
        {
            byDestination.TryAdd(destination, new SshHost(destination, SshHostSource.Custom));
        }

        var now = DateTimeOffset.UtcNow;
        var recentDestinations = byDestination.Keys
            .Where(destination => !state.PinnedDestinations.Contains(destination))
            .Select(destination => new
            {
                Destination = destination,
                UsedAt = state.LastUsedAt.TryGetValue(destination, out var usedAt)
                    ? usedAt
                    : (DateTimeOffset?)null,
            })
            .Where(value => value.UsedAt is not null
                && RecentAge(now, value.UsedAt.Value) < RecentHostWindow)
            .OrderByDescending(static value => value.UsedAt)
            .Take(RecentHostLimit)
            .Select(static value => value.Destination)
            .ToHashSet(StringComparer.Ordinal);

        hostItems = byDestination.Values
            .Select(host => new HostDisplay(
                host,
                state.CustomDestinations.Contains(host.Destination),
                state.PinnedDestinations.Contains(host.Destination),
                recentDestinations.Contains(host.Destination),
                state.LastUsedAt.TryGetValue(host.Destination, out var usedAt) ? usedAt : null))
            .OrderBy(static host => host.IsPinned ? 0 : host.IsRecent ? 1 : 2)
            .ThenByDescending(static host => host.LastUsedAt ?? DateTimeOffset.MinValue)
            .ThenBy(static host => host.Destination, StringComparer.OrdinalIgnoreCase)
            .ThenBy(static host => host.Destination, StringComparer.Ordinal)
            .ToArray();
        ApplyHostFilter(preferredDestination);
    }

    private void ApplyHostFilter(string? preferredDestination)
    {
        var query = SearchBox.Text.Trim();
        // Match the macOS navigation model: the sidebar stays deliberately
        // small, while typing searches the complete SSH config catalog.
        var visible = string.IsNullOrEmpty(query)
            ? hostItems.Where(static host => host.IsPinned || host.IsRecent).ToArray()
            : hostItems.Where(host => host.Destination.Contains(
                    query, StringComparison.OrdinalIgnoreCase))
                .ToArray();
        var selected = preferredDestination is null
            ? null
            : visible.FirstOrDefault(host => string.Equals(
                host.Destination, preferredDestination, StringComparison.Ordinal));
        isUpdatingHostSelection = true;
        try
        {
            HostsList.ItemsSource = visible;
            HostsList.SelectedItem = selected;
            if (selected is not null)
            {
                HostsList.ScrollIntoView(selected);
            }
        }
        finally
        {
            isUpdatingHostSelection = false;
        }
        if (!string.Equals(activeDestination, selected?.Destination, StringComparison.Ordinal))
        {
            ActivateHost(selected);
        }
        else
        {
            UpdateHostControls();
        }
    }

    private void ActivateHost(HostDisplay? host)
    {
        var destination = host?.Destination;
        var changed = !string.Equals(activeDestination, destination, StringComparison.Ordinal);
        activeDestination = destination;
        if (changed)
        {
            CancelInventory();
            SessionGrid.ItemsSource = Array.Empty<TmuxSessionDisplay>();
            HerdrGrid.ItemsSource = Array.Empty<HerdrPaneDisplay>();
            SessionHint.Text = "选择会话后可连接、改名或终止。";
            HerdrHint.Text = "选择终端后可通过独立 SSH 控制台连接。";
        }
        UpdateHostControls();
        UpdateSessionControls();
        UpdateHerdrControls();
        if (changed && destination is not null && !isExclusiveOperation)
        {
            _ = RefreshActiveWorkspaceAsync();
        }
    }

    private async Task RefreshActiveWorkspaceAsync()
    {
        if (WorkspaceTabs.SelectedIndex == 1)
        {
            await RefreshHerdrAsync();
        }
        else
        {
            await RefreshSessionsAsync();
        }
    }

    private async Task RefreshSessionsAsync()
    {
        var destination = activeDestination;
        if (destination is null)
        {
            SetStatus("请先选择 SSH 主机。", StatusKind.Warning);
            return;
        }
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return;
        }
        TmuxService service;
        try
        {
            service = RequireTmuxService();
        }
        catch (Exception error)
        {
            ShowOperationError("无法刷新 tmux", error);
            return;
        }
        var request = BeginInventory();
        SetStatus($"正在读取 {destination} 的 tmux 会话…", StatusKind.Working);
        try
        {
            var sessions = await service.ListAsync(destination, request.Token);
            request.Token.ThrowIfCancellationRequested();
            if (!IsCurrentInventory(request, destination))
            {
                return;
            }
            BindSessions(sessions);
            SetStatus(
                sessions.Count == 0 ? "远端当前没有 tmux 会话。" : $"已找到 {sessions.Count} 个 tmux 会话。",
                StatusKind.Ready);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (IsCurrentInventory(request, destination))
            {
                SessionGrid.ItemsSource = Array.Empty<TmuxSessionDisplay>();
                SessionHint.Text = FriendlyError(error);
                SetStatus(FriendlyError(error), StatusKind.Error);
                UpdateSessionControls();
            }
        }
        finally
        {
            FinishInventory(request);
        }
    }

    private async Task RefreshHerdrAsync()
    {
        var destination = activeDestination;
        if (destination is null)
        {
            SetStatus("请先选择 SSH 主机。", StatusKind.Warning);
            return;
        }
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return;
        }
        HerdrService service;
        try
        {
            service = RequireHerdrService();
        }
        catch (Exception error)
        {
            ShowOperationError("无法刷新 Herdr", error);
            return;
        }
        var request = BeginInventory();
        SetStatus($"正在读取 {destination} 的 Herdr 工作区…", StatusKind.Working);
        try
        {
            var snapshots = await service.DiscoverAsync(destination, request.Token);
            request.Token.ThrowIfCancellationRequested();
            if (!IsCurrentInventory(request, destination))
            {
                return;
            }
            var panes = snapshots.SelectMany(snapshot =>
                snapshot.Workspaces.SelectMany(workspace =>
                    workspace.Panes.Select(pane => new HerdrPaneDisplay(snapshot, workspace, pane))))
                .ToArray();
            HerdrGrid.ItemsSource = panes;
            HerdrHint.Text = panes.Length == 0
                ? "运行中的 Herdr 会话里没有终端。"
                : "选择终端后可通过独立 SSH 控制台连接。";
            SetStatus(
                panes.Length == 0 ? "没有可连接的 Herdr 终端。" : $"已找到 {panes.Length} 个 Herdr 终端。",
                StatusKind.Ready);
            UpdateHerdrControls();
        }
        catch (OperationCanceledException)
        {
        }
        catch (HerdrException error) when (error.Error == HerdrError.NoRunningSessions)
        {
            if (IsCurrentInventory(request, destination))
            {
                HerdrGrid.ItemsSource = Array.Empty<HerdrPaneDisplay>();
                HerdrHint.Text = error.Message;
                SetStatus(error.Message, StatusKind.Warning);
                UpdateHerdrControls();
            }
        }
        catch (Exception error)
        {
            if (IsCurrentInventory(request, destination))
            {
                HerdrGrid.ItemsSource = Array.Empty<HerdrPaneDisplay>();
                HerdrHint.Text = FriendlyError(error);
                SetStatus(FriendlyError(error), StatusKind.Error);
                UpdateHerdrControls();
            }
        }
        finally
        {
            FinishInventory(request);
        }
    }

    private void ConnectNamedSession()
    {
        var destination = activeDestination;
        if (destination is null)
        {
            SetStatus("请先选择 SSH 主机。", StatusKind.Warning);
            return;
        }
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return;
        }
        var proposedName = SessionNameBox.Text.Trim();
        var normalizedName = IdentifierValidator.NormalizeTmuxSessionName(proposedName);
        if (normalizedName is null)
        {
            MessageBox.Show(
                "会话名必须以字母或数字开头，最长 64 个字符，只能包含字母、数字、点、短横线和下划线。",
                "会话名无效", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        SessionNameBox.Text = normalizedName;
        OpenTmux(destination, normalizedName, "命名连接");
    }

    private void OpenSelectedSession()
    {
        var destination = activeDestination;
        var session = SelectedSession;
        if (destination is null || session is null || isExclusiveOperation)
        {
            return;
        }
        OpenTmux(destination, session.Record.Name, "打开会话");
    }

    private void OpenTmux(string destination, string sessionName, string action)
    {
        try
        {
            var processId = RequireTmuxService().OpenOrAttach(destination, sessionName);
            if (RecordUse(destination))
            {
                SetStatus($"{action}已在独立控制台启动（PID {processId}）。", StatusKind.Ready);
            }
        }
        catch (Exception error)
        {
            ShowOperationError($"无法{action}", error);
        }
    }

    private async Task RenameSelectedSessionAsync()
    {
        var destination = activeDestination;
        var selected = SelectedSession;
        if (destination is null || selected is null || isExclusiveOperation)
        {
            return;
        }
        if (selected.Record.Identity is null)
        {
            ShowOperationError("无法重命名", new TmuxSessionChangedException());
            return;
        }
        var dialog = new PromptDialog(
            this, "重命名 tmux 会话", "新的会话名", selected.Record.Name,
            "提交前会重新读取远端会话，并核对服务器 ID 与创建时间。点号会按 tmux 规则转为下划线。");
        if (dialog.ShowDialog() != true)
        {
            return;
        }
        var normalizedName = IdentifierValidator.NormalizeTmuxSessionName(dialog.Value);
        if (normalizedName is null)
        {
            MessageBox.Show("新会话名格式无效。", "无法重命名", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (string.Equals(normalizedName, selected.Record.Name, StringComparison.Ordinal))
        {
            SetStatus("会话名没有变化。", StatusKind.Warning);
            return;
        }

        var succeeded = await RunExclusiveAsync(
            "正在刷新并验证远端会话…", "无法重命名会话",
            async cancellationToken =>
            {
                var current = await RefreshAndRequireSessionAsync(
                    destination, selected.Record, cancellationToken);
                await RequireTmuxService().RenameAsync(
                    destination, current.Name, normalizedName,
                    current.Identity, cancellationToken);
            },
            $"会话已重命名为 {normalizedName}。");
        if (succeeded)
        {
            await RefreshSessionsAsync();
        }
    }

    private async Task TerminateSelectedSessionAsync()
    {
        var destination = activeDestination;
        var selected = SelectedSession;
        if (destination is null || selected is null || isExclusiveOperation)
        {
            return;
        }
        if (selected.Record.Identity is null)
        {
            ShowOperationError("无法终止", new TmuxSessionChangedException());
            return;
        }
        var answer = MessageBox.Show(
            $"终止 {destination} 上的 tmux 会话“{selected.Record.Name}”？\n\n远端会话中的进程会停止。",
            "终止 tmux 会话", MessageBoxButton.YesNo, MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (answer != MessageBoxResult.Yes)
        {
            return;
        }

        var succeeded = await RunExclusiveAsync(
            "正在刷新并验证远端会话…", "无法终止会话",
            async cancellationToken =>
            {
                var current = await RefreshAndRequireSessionAsync(
                    destination, selected.Record, cancellationToken);
                await RequireTmuxService().KillVerifiedAsync(
                    destination, current.Name, current.Identity!, cancellationToken);
            },
            "远端 tmux 会话已终止。");
        if (succeeded)
        {
            await RefreshSessionsAsync();
        }
    }

    private async Task<TmuxSessionRecord> RefreshAndRequireSessionAsync(
        string destination,
        TmuxSessionRecord displayed,
        CancellationToken cancellationToken)
    {
        var identity = displayed.Identity ?? throw new TmuxSessionChangedException();
        var sessions = await RequireTmuxService().ListAsync(destination, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (!string.Equals(activeDestination, destination, StringComparison.Ordinal))
        {
            throw new OperationCanceledException(cancellationToken);
        }
        BindSessions(sessions, identity);
        var current = sessions.FirstOrDefault(session =>
            session.Identity == identity
            && string.Equals(session.Name, displayed.Name, StringComparison.Ordinal));
        return current ?? throw new TmuxSessionChangedException();
    }

    private async Task OpenSelectedHerdrAsync()
    {
        var destination = activeDestination;
        var selected = SelectedHerdrPane;
        if (destination is null || selected is null || isExclusiveOperation)
        {
            return;
        }
        await RunExclusiveAsync(
            "正在确认 Herdr 终端仍然存在…", "无法打开 Herdr 终端",
            async cancellationToken =>
            {
                var service = RequireHerdrService();
                var current = await service.ResolveAsync(
                    destination, selected.Record.Reference, cancellationToken);
                var processId = service.OpenTerminal(destination, current.Reference);
                RecordUse(destination);
                SetStatus($"Herdr 终端已在独立控制台启动（PID {processId}）。", StatusKind.Ready);
            },
            "Herdr 终端已打开。");
    }

    private async Task<bool> RunExclusiveAsync(
        string progressMessage,
        string errorTitle,
        Func<CancellationToken, Task> operation,
        string successMessage)
    {
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return false;
        }
        isExclusiveOperation = true;
        CancelInventory();
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            lifetimeCancellation.Token);
        operationCancellation = cancellation;
        UpdateAllControls();
        SetStatus(progressMessage, StatusKind.Working);
        try
        {
            await operation(cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!lifetimeCancellation.IsCancellationRequested)
            {
                SetStatus(successMessage, StatusKind.Ready);
            }
            return true;
        }
        catch (OperationCanceledException)
        {
            if (!lifetimeCancellation.IsCancellationRequested)
            {
                SetStatus("操作已取消。", StatusKind.Warning);
            }
            return false;
        }
        catch (Exception error)
        {
            if (!lifetimeCancellation.IsCancellationRequested)
            {
                ShowOperationError(errorTitle, error);
            }
            return false;
        }
        finally
        {
            if (ReferenceEquals(operationCancellation, cancellation))
            {
                operationCancellation = null;
            }
            cancellation.Dispose();
            isExclusiveOperation = false;
            if (!lifetimeCancellation.IsCancellationRequested)
            {
                UpdateAllControls();
            }
        }
    }

    private void BindSessions(
        IReadOnlyList<TmuxSessionRecord> sessions,
        TmuxSessionIdentity? preferredIdentity = null)
    {
        var rows = sessions.Select(static session => new TmuxSessionDisplay(session)).ToArray();
        SessionGrid.ItemsSource = rows;
        if (preferredIdentity is not null)
        {
            SessionGrid.SelectedItem = rows.FirstOrDefault(row =>
                row.Record.Identity == preferredIdentity);
        }
        SessionHint.Text = rows.Length == 0
            ? "远端当前没有 tmux 会话，可输入名称新建。"
            : "选择会话后可连接、改名或终止。";
        UpdateSessionControls();
    }

    private void UpdateAllControls()
    {
        UpdateHostControls();
        UpdateSessionControls();
        UpdateHerdrControls();
        SearchBox.IsEnabled = !isExclusiveOperation;
        AddHostBox.IsEnabled = !isExclusiveOperation;
        SessionNameBox.IsEnabled = !isExclusiveOperation;
        WorkspaceTabs.IsEnabled = !isExclusiveOperation;
        HostsList.IsEnabled = !isExclusiveOperation;
    }

    private void UpdateHostControls()
    {
        var host = SelectedHost;
        if (host is null)
        {
            SelectedHostTitle.Text = "选择一台 SSH 主机";
            SelectedHostSubtitle.Text = "从左侧主机库选择目标，或手动添加一个 OpenSSH 地址。";
        }
        else
        {
            SelectedHostTitle.Text = host.Destination;
            SelectedHostSubtitle.Text = host.Detail;
        }
        PinButton.Content = host?.IsPinned == true ? "取消固定" : "固定";
        PinButton.IsEnabled = host is not null && !isExclusiveOperation;
        RemoveHostButton.IsEnabled = host?.IsCustom == true && !isExclusiveOperation;
        OpenShellButton.IsEnabled = host is not null
            && terminalLauncher is not null && !isExclusiveOperation;
        QuickConnectButton.IsEnabled = host is not null
            && tmuxService is not null && !isExclusiveOperation;
    }

    private void UpdateSessionControls()
    {
        var selected = SelectedSession;
        var canOpen = selected is not null && tmuxService is not null && !isExclusiveOperation;
        var canMutate = canOpen && selected!.Record.Identity is not null;
        OpenSessionButton.IsEnabled = canOpen;
        RenameSessionButton.IsEnabled = canMutate;
        TerminateSessionButton.IsEnabled = canMutate;
        if (selected is null)
        {
            return;
        }
        SessionHint.Text = selected.Record.Identity is { } identity
            ? $"已选择 {selected.Record.Name}（{identity.StableDisplayString}）。变更前会重新核对身份。"
            : "这是旧格式会话记录；为避免误操作，只允许打开，不允许改名或终止。";
    }

    private void UpdateHerdrControls()
    {
        var selected = SelectedHerdrPane;
        OpenHerdrButton.IsEnabled = selected is not null
            && selected.Record.Reference.IsValid
            && herdrService is not null
            && !isExclusiveOperation;
        if (selected is not null)
        {
            HerdrHint.Text = $"将重新确认终端 {selected.Record.Reference.TerminalId} 后再打开。";
        }
    }

    private CancellationTokenSource BeginInventory()
    {
        CancelInventory();
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            lifetimeCancellation.Token);
        inventoryCancellation = cancellation;
        return cancellation;
    }

    private void CancelInventory()
    {
        var cancellation = inventoryCancellation;
        inventoryCancellation = null;
        if (cancellation is null)
        {
            return;
        }
        try
        {
            cancellation.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private bool IsCurrentInventory(
        CancellationTokenSource request,
        string? destination = null)
    {
        return !lifetimeCancellation.IsCancellationRequested
            && ReferenceEquals(inventoryCancellation, request)
            && (destination is null
                || string.Equals(activeDestination, destination, StringComparison.Ordinal));
    }

    private void FinishInventory(CancellationTokenSource request)
    {
        if (ReferenceEquals(inventoryCancellation, request))
        {
            inventoryCancellation = null;
        }
        request.Dispose();
    }

    private TmuxService RequireTmuxService() => tmuxService
        ?? throw RemoteUnavailable();

    private HerdrService RequireHerdrService() => herdrService
        ?? throw RemoteUnavailable();

    private TerminalLauncher RequireTerminalLauncher() => terminalLauncher
        ?? throw RemoteUnavailable();

    private Exception RemoteUnavailable()
    {
        return new InvalidOperationException(
            "Windows OpenSSH Client 不可用。请在 Windows 可选功能中启用 OpenSSH 客户端。",
            remoteInitializationError);
    }

    private bool RecordUse(string destination)
    {
        var hadPrevious = state.LastUsedAt.TryGetValue(destination, out var previous);
        state.LastUsedAt[destination] = DateTimeOffset.UtcNow;
        if (!TrySaveState("终端已打开，但无法保存最近使用记录。", showDialog: false))
        {
            if (hadPrevious)
            {
                state.LastUsedAt[destination] = previous;
            }
            else
            {
                state.LastUsedAt.Remove(destination);
            }
            return false;
        }
        RebuildHostItems(destination);
        return true;
    }

    private bool TrySaveState(string failureMessage, bool showDialog)
    {
        try
        {
            stateStore.Save(state);
            return true;
        }
        catch (Exception error)
        {
            var message = $"{failureMessage} {FriendlyError(error)}";
            SetStatus(message, StatusKind.Error);
            if (showDialog)
            {
                MessageBox.Show(message, "TmuxHub", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            return false;
        }
    }

    private void ShowOperationError(string title, Exception error)
    {
        var message = FriendlyError(error);
        SetStatus(message, StatusKind.Error);
        MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Error);
    }

    private void SetStatus(string message, StatusKind kind)
    {
        StatusText.Text = message;
        var brushKey = kind switch
        {
            StatusKind.Error => "DangerBrush",
            StatusKind.Warning or StatusKind.Working => "WarningBrush",
            _ => "SuccessBrush",
        };
        StatusDot.Fill = (Brush)FindResource(brushKey);
    }

    private static string FriendlyError(Exception error)
    {
        var message = error switch
        {
            TmuxSessionChangedException => "远端会话已变化或已消失；为避免操作错误目标，已取消本次操作。请刷新后重试。",
            FileNotFoundException => "未找到 Windows OpenSSH Client。请在 Windows 可选功能中启用 OpenSSH 客户端。",
            TimeoutException => "SSH 操作超时，请检查网络、主机配置与认证方式。",
            OperationCanceledException => "操作已取消。",
            _ => error.Message,
        };
        var safe = new string(message.Where(static character => !char.IsControl(character)).ToArray())
            .Trim();
        if (safe.Length == 0)
        {
            return "操作失败。";
        }
        return safe.Length <= 600 ? safe : safe[..600] + "…";
    }

    private static TimeSpan RecentAge(DateTimeOffset now, DateTimeOffset usedAt) =>
        usedAt > now ? TimeSpan.Zero : now - usedAt;

    private HostDisplay? SelectedHost => HostsList.SelectedItem as HostDisplay;

    private TmuxSessionDisplay? SelectedSession =>
        SessionGrid.SelectedItem as TmuxSessionDisplay;

    private HerdrPaneDisplay? SelectedHerdrPane =>
        HerdrGrid.SelectedItem as HerdrPaneDisplay;

    private enum StatusKind
    {
        Ready,
        Working,
        Warning,
        Error,
    }

    private sealed class HostDisplay
    {
        public HostDisplay(
            SshHost host,
            bool isCustom,
            bool isPinned,
            bool isRecent,
            DateTimeOffset? lastUsedAt)
        {
            Host = host;
            IsCustom = isCustom;
            IsPinned = isPinned;
            IsRecent = isRecent;
            LastUsedAt = lastUsedAt;
        }

        public SshHost Host { get; }
        public string Destination => Host.Destination;
        public bool IsCustom { get; }
        public bool IsPinned { get; }
        public bool IsRecent { get; }
        public DateTimeOffset? LastUsedAt { get; }
        public string Badge => IsPinned
            ? "固定"
            : IsRecent
                ? "最近"
                : Host.Source == SshHostSource.Configuration ? "SSH 配置" : "手动";
        public string Detail
        {
            get
            {
                var source = Host.Source == SshHostSource.Configuration
                    ? "来自 %USERPROFILE%\\.ssh\\config（含 Include）"
                    : "手动添加";
                return LastUsedAt is null
                    ? source
                    : $"{source} · 最近使用 {LastUsedAt.Value.ToLocalTime():yyyy-MM-dd HH:mm}";
            }
        }
    }

    private sealed class TmuxSessionDisplay
    {
        public TmuxSessionDisplay(TmuxSessionRecord record)
        {
            Record = record;
        }

        public TmuxSessionRecord Record { get; }
        public string Name => Record.Name;
        public string ServerSessionIdDisplay => Record.Identity?.ServerSessionId ?? "旧格式";
        public string CreatedAtDisplay
        {
            get
            {
                if (Record.Identity is not { } identity)
                {
                    return "—";
                }
                try
                {
                    return DateTimeOffset.FromUnixTimeSeconds(identity.CreatedAtEpoch)
                        .ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.CurrentCulture);
                }
                catch (ArgumentOutOfRangeException)
                {
                    return identity.CreatedAtEpoch.ToString(CultureInfo.InvariantCulture);
                }
            }
        }
    }

    private sealed class HerdrPaneDisplay
    {
        public HerdrPaneDisplay(
            HerdrSessionSnapshot snapshot,
            HerdrWorkspaceRecord workspace,
            HerdrPaneRecord record)
        {
            Record = record;
            SessionDisplay = snapshot.Name;
            WorkspaceLabel = workspace.Label;
            Label = record.Label;
            AgentDisplay = string.IsNullOrWhiteSpace(record.Agent)
                ? "—"
                : string.IsNullOrWhiteSpace(record.AgentStatus)
                    ? record.Agent
                    : $"{record.Agent} · {record.AgentStatus}";
            WorkingDirectoryDisplay = record.WorkingDirectory ?? workspace.Cwd ?? "—";
        }

        public HerdrPaneRecord Record { get; }
        public string SessionDisplay { get; }
        public string WorkspaceLabel { get; }
        public string Label { get; }
        public string AgentDisplay { get; }
        public string WorkingDirectoryDisplay { get; }
    }
}
