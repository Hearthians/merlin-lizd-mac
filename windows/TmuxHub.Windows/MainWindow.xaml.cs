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
    private SshProcessRunner? sshRunner;
    private TmuxService? tmuxService;
    private TmuxConfigurationService? tmuxConfigurationService;
    private HerdrService? herdrService;
    private SlurmService? slurmService;
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
            sshRunner = runner;
            terminalLauncher = new TerminalLauncher(sshExecutable);
            tmuxService = new TmuxService(runner, terminalLauncher);
            tmuxConfigurationService = new TmuxConfigurationService(runner);
            herdrService = new HerdrService(runner, terminalLauncher);
            slurmService = new SlurmService(runner, terminalLauncher);
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
                destination,
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

    private async void ConfigureTmuxButton_OnClick(object sender, RoutedEventArgs e) =>
        await ConfigureTmuxAsync();

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

    private async void RefreshSlurmButton_OnClick(object sender, RoutedEventArgs e) =>
        await RefreshSlurmAsync();

    private async void StartSlurmButton_OnClick(object sender, RoutedEventArgs e) =>
        await StartSlurmAsync();

    private void SlurmGrid_OnSelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateSlurmControls();

    private void SlurmGrid_OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (CanManageSlurmSelection(SelectedSlurmJob))
        {
            OpenSelectedSlurm();
            e.Handled = true;
        }
    }

    private void OpenSlurmButton_OnClick(object sender, RoutedEventArgs e) =>
        OpenSelectedSlurm();

    private async void CancelSlurmButton_OnClick(object sender, RoutedEventArgs e) =>
        await CancelSelectedSlurmAsync();

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
            SlurmGrid.ItemsSource = Array.Empty<SlurmJobDisplay>();
            SessionHint.Text = "选择会话后可连接、改名或终止。";
            HerdrHint.Text = "选择终端后可通过独立 SSH 控制台连接。";
            SlurmSummaryText.Text = "—";
            LoadSlurmSettings(destination);
        }
        UpdateHostControls();
        UpdateSessionControls();
        UpdateHerdrControls();
        UpdateSlurmControls();
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
        else if (WorkspaceTabs.SelectedIndex == 2)
        {
            await RefreshSlurmAsync();
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

    private async Task ConfigureTmuxAsync()
    {
        var destination = activeDestination;
        if (destination is null)
        {
            SetStatus("请选择 SSH 主机。", StatusKind.Warning);
            return;
        }

        TmuxConfigurationResult? result = null;
        var succeeded = await RunExclusiveAsync(
            $"正在配置 {destination} 的 tmux…",
            "无法配置 tmux",
            async cancellationToken =>
            {
                result = await RequireTmuxConfigurationService()
                    .ApplyAsync(destination, cancellationToken);
            },
            "tmux 配置完成。");

        if (!succeeded || result is null)
        {
            return;
        }

        var message = result.StatusMessage;
        if (result.BackupPath is { Length: > 0 })
        {
            message += $" 备份：{result.BackupPath}";
        }
        SetStatus(
            message,
            result.Activation == TmuxConfigurationActivation.ReloadFailed
                ? StatusKind.Warning
                : StatusKind.Ready);
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

    private async Task RefreshSlurmAsync()
    {
        var destination = activeDestination;
        if (destination is null)
        {
            SetStatus("请选择 SSH 主机。", StatusKind.Warning);
            return;
        }
        if (isExclusiveOperation)
        {
            SetStatus("请等待当前操作完成。", StatusKind.Warning);
            return;
        }

        SlurmService service;
        try
        {
            service = RequireSlurmService();
        }
        catch (Exception error)
        {
            ShowOperationError("无法刷新 Slurm", error);
            return;
        }

        var request = BeginInventory();
        SetStatus($"正在读取 {destination} 的 Slurm 任务…", StatusKind.Working);
        try
        {
            var owner = await ResolveSlurmOwnerAsync(destination, request.Token);
            var profile = BuildSlurmProfile(destination, owner);
            var queue = await service.ListJobsWithDiagnosticsAsync(profile, request.Token);
            var jobs = queue.Jobs;
            request.Token.ThrowIfCancellationRequested();
            if (!IsCurrentInventory(request, destination))
            {
                return;
            }
            SlurmOwnerBox.Text = owner;
            try
            {
                SaveSlurmSettings(destination, showDialog: false);
            }
            catch (ArgumentException)
            {
                // Resource inputs are validated when starting a task; an
                // invalid draft must not block read-only queue refresh.
            }
            BindSlurmJobs(destination, owner, jobs, queue.IgnoredRowCount);
            SetStatus(
                queue.IgnoredRowCount == 0
                    ? $"Slurm · {jobs.Count} 个任务"
                    : $"Slurm · {jobs.Count} 个任务 · 忽略 {queue.IgnoredRowCount} 条异常记录",
                queue.IgnoredRowCount == 0 ? StatusKind.Ready : StatusKind.Warning);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (IsCurrentInventory(request, destination))
            {
                SlurmGrid.ItemsSource = Array.Empty<SlurmJobDisplay>();
                SlurmSummaryText.Text = "—";
                SetStatus(FriendlyError(error), StatusKind.Error);
                UpdateSlurmControls();
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

    private async Task StartSlurmAsync()
    {
        var destination = activeDestination;
        if (destination is null)
        {
            SetStatus("请选择 SSH 主机。", StatusKind.Warning);
            return;
        }

        SlurmPlatformProfile? submittedPlatform = null;
        SlurmLaunchReceipt? submittedReceipt = null;
        Exception? confirmationError = null;
        var submitted = await RunExclusiveAsync(
            $"正在启动 {destination} 的 Slurm 交互环境…",
            "无法启动 Slurm 任务",
            async cancellationToken =>
            {
                var service = RequireSlurmService();
                var owner = await ResolveSlurmOwnerAsync(destination, cancellationToken);
                SlurmOwnerBox.Text = owner;
                var platform = BuildSlurmProfile(destination, owner);
                var preset = BuildSlurmPreset();
                if (!SaveSlurmSettings(destination, showDialog: false))
                {
                    throw new IOException("无法保存 Slurm 资源设置。");
                }

                var receipt = service.CreateLaunchReceipt(platform);
                state.SlurmReceipts.Insert(0, receipt);
                if (!TrySaveState("无法在提交前保存 Slurm 启动凭据。", showDialog: false))
                {
                    state.SlurmReceipts.Remove(receipt);
                    throw new IOException("未保存启动凭据，因此没有提交 Slurm 任务。");
                }

                submittedPlatform = platform;
                submittedReceipt = receipt;
                try
                {
                    await service.StartInteractiveAsync(
                        platform,
                        preset,
                        receipt,
                        cancellationToken);
                }
                catch (SlurmSubmissionOutcomeUnknownException)
                {
                    submittedReceipt = SetSlurmPhase(
                        receipt.RequestId,
                        SlurmLaunchPhase.LaunchOutcomeUnknown);
                    throw;
                }
                catch
                {
                    submittedReceipt = SetSlurmPhase(
                        receipt.RequestId,
                        SlurmLaunchPhase.LaunchFailed);
                    throw;
                }

                submittedReceipt = SetSlurmPhase(
                    receipt.RequestId,
                    SlurmLaunchPhase.AwaitingScheduler);
                RecordUse(destination);

                for (var attempt = 0; attempt < 5; attempt++)
                {
                    try
                    {
                        var reconciliation = await service.ReconcileAsync(
                            submittedReceipt,
                            platform,
                            cancellationToken);
                        if (reconciliation is SlurmReconciliation.Found)
                        {
                            submittedReceipt = SetSlurmPhase(
                                receipt.RequestId,
                                SlurmLaunchPhase.Active);
                            break;
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        throw;
                    }
                    catch (Exception error)
                    {
                        confirmationError = error;
                        break;
                    }
                    if (attempt < 4)
                    {
                        await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
                    }
                }
            },
            "启动请求已发出。");

        if (submittedPlatform is null || submittedReceipt is null)
        {
            return;
        }
        await RefreshSlurmAsync();
        submittedReceipt = FindSlurmReceipt(submittedReceipt.RequestId) ?? submittedReceipt;
        if (!submitted)
        {
            return;
        }
        if (submittedReceipt.Phase != SlurmLaunchPhase.Active)
        {
            SetStatus(
                confirmationError is null
                    ? "请求已发出，等待 Slurm 确认；请勿重复提交。"
                    : "请求已发出，暂时无法确认；请刷新，勿重复提交。",
                StatusKind.Warning);
            return;
        }

        // Submission and local terminal launch are separate outcomes. Once the
        // remote command succeeds, a local launch error must never imply that
        // submitting the allocation again is safe.
        try
        {
            var processId = RequireSlurmService().OpenInteractive(
                submittedPlatform,
                submittedReceipt);
            SetStatus($"Slurm 终端已打开（PID {processId}）。", StatusKind.Ready);
        }
        catch (Exception error)
        {
            ShowOperationError("Slurm 已确认，但无法打开终端", error);
        }
    }

    private void OpenSelectedSlurm()
    {
        var destination = activeDestination;
        var selected = SelectedSlurmJob;
        if (destination is null
            || selected?.Record is null
            || selected.Receipt is not { } displayedReceipt
            || isExclusiveOperation)
        {
            return;
        }
        var receipt = FindSlurmReceipt(displayedReceipt.RequestId);
        if (receipt?.Phase != SlurmLaunchPhase.Active)
        {
            UpdateSlurmControls();
            return;
        }
        try
        {
            var platform = PlatformForReceipt(receipt);
            var processId = RequireSlurmService().OpenInteractive(platform, receipt);
            RecordUse(destination);
            SetStatus($"Slurm 终端已打开（PID {processId}）。", StatusKind.Ready);
        }
        catch (Exception error)
        {
            ShowOperationError("无法连接 Slurm 任务", error);
        }
    }

    private async Task CancelSelectedSlurmAsync()
    {
        var destination = activeDestination;
        var selected = SelectedSlurmJob;
        if (destination is null
            || selected?.Record is not { } record
            || selected.Receipt is not { } displayedReceipt)
        {
            return;
        }
        var receipt = FindSlurmReceipt(displayedReceipt.RequestId);
        if (receipt?.Phase != SlurmLaunchPhase.Active)
        {
            UpdateSlurmControls();
            return;
        }
        var confirmation = MessageBox.Show(
            $"取消作业 {record.JobId.Value} 并释放资源？",
            "TmuxHub",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (confirmation != MessageBoxResult.Yes)
        {
            return;
        }

        receipt = FindSlurmReceipt(receipt.RequestId);
        if (receipt?.Phase != SlurmLaunchPhase.Active)
        {
            await RefreshSlurmAsync();
            SetStatus("任务状态已变化，请重新选择。", StatusKind.Warning);
            return;
        }
        var phaseBeforeCancellation = receipt.Phase;
        var managed = new SlurmManagedJob(receipt, record);
        await RunExclusiveAsync(
            $"正在取消作业 {record.JobId.Value}…",
            "无法取消 Slurm 任务",
            async cancellationToken =>
            {
                SetSlurmPhase(
                    receipt.RequestId,
                    SlurmLaunchPhase.CancellationOutcomeUnknown,
                    requireSaved: true);
                try
                {
                    await RequireSlurmService().CancelVerifiedAsync(
                        managed,
                        PlatformForReceipt(receipt),
                        cancellationToken);
                }
                catch (SlurmCancellationOutcomeUnknownException)
                {
                    SetSlurmPhase(
                        receipt.RequestId,
                        SlurmLaunchPhase.CancellationOutcomeUnknown);
                    throw;
                }
                catch
                {
                    SetSlurmPhase(receipt.RequestId, phaseBeforeCancellation);
                    throw;
                }
                SetSlurmPhase(
                    receipt.RequestId,
                    SlurmLaunchPhase.CancellationRequested);
            },
            "取消请求已发出。");
        await RefreshSlurmAsync();
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

    private void BindSlurmJobs(
        string destination,
        string owner,
        IReadOnlyList<SlurmJobSnapshot> jobs,
        int ignoredRowCount)
    {
        var now = DateTimeOffset.UtcNow;
        var stateChanged = false;
        for (var index = 0; index < state.SlurmReceipts.Count; index++)
        {
            var receipt = state.SlurmReceipts[index];
            if (receipt.LoginDestination != destination || receipt.Owner != owner)
            {
                continue;
            }
            // A partial queue can prove that a visible row exists, but it
            // cannot prove uniqueness or absence. Freeze all persisted phases
            // until a complete refresh is available.
            if (ignoredRowCount > 0)
            {
                continue;
            }

            var matchingJobs = jobs.Where(job => ReceiptMatchesJob(receipt, job)).ToArray();
            var phase = receipt.Phase;
            if (matchingJobs.Length > 1)
            {
                phase = SlurmLaunchPhase.Ambiguous;
            }
            else if (matchingJobs.Length == 1)
            {
                var matchedJob = matchingJobs[0];
                if (matchedJob.State.IsTerminal)
                {
                    phase = SlurmLaunchPhase.LeftQueue;
                }
                else if (phase is not SlurmLaunchPhase.CancellationRequested
                    and not SlurmLaunchPhase.CancellationOutcomeUnknown)
                {
                    phase = SlurmLaunchPhase.Active;
                }
            }
            else
            {
                phase = phase switch
                {
                    SlurmLaunchPhase.Active
                        or SlurmLaunchPhase.Ambiguous
                        or SlurmLaunchPhase.CancellationRequested
                        or SlurmLaunchPhase.CancellationOutcomeUnknown
                        => SlurmLaunchPhase.LeftQueue,
                    SlurmLaunchPhase.Submitting
                        or SlurmLaunchPhase.AwaitingScheduler
                        when now - receipt.RequestedAt >= TimeSpan.FromMinutes(2)
                        => SlurmLaunchPhase.NotFound,
                    _ => phase,
                };
            }

            if (phase != receipt.Phase)
            {
                state.SlurmReceipts[index] = receipt with
                {
                    Phase = phase,
                    PhaseUpdatedAt = now,
                };
                stateChanged = true;
            }
        }
        if (stateChanged)
        {
            TrySaveState("Slurm 状态已刷新，但无法保存。", showDialog: false);
        }

        var activeRows = jobs
            .OrderBy(static job => job.State.Kind switch
            {
                SlurmJobStateKind.Running => 0,
                SlurmJobStateKind.Pending => 1,
                SlurmJobStateKind.Completing => 2,
                _ => 3,
            })
            .ThenByDescending(static job => job.JobId.Value, StringComparer.Ordinal)
            .Select(job => new SlurmJobDisplay(
                job,
                ignoredRowCount == 0
                    ? FindUniqueSlurmReceipt(destination, job, jobs)
                    : null))
            .ToArray();
        var matched = activeRows
            .Where(static row => row.Receipt is not null)
            .Select(static row => row.Receipt!.RequestId)
            .ToHashSet();
        var historyRows = state.SlurmReceipts
            .Where(receipt =>
                receipt.LoginDestination == destination
                && receipt.Owner == owner
                && !matched.Contains(receipt.RequestId))
            .OrderByDescending(static receipt => receipt.RequestedAt)
            .Select(static receipt => new SlurmJobDisplay(receipt));
        SlurmGrid.ItemsSource = activeRows.Concat(historyRows).ToArray();

        var running = jobs.Count(static job => job.State.Kind == SlurmJobStateKind.Running);
        var pending = jobs.Count(static job => job.State.Kind == SlurmJobStateKind.Pending);
        var awaiting = state.SlurmReceipts.Count(receipt =>
            receipt.LoginDestination == destination
            && receipt.Owner == owner
            && receipt.Phase is SlurmLaunchPhase.Submitting
                or SlurmLaunchPhase.AwaitingScheduler);
        var uncertain = state.SlurmReceipts.Count(receipt =>
            receipt.LoginDestination == destination
            && receipt.Owner == owner
            && receipt.Phase == SlurmLaunchPhase.LaunchOutcomeUnknown);
        var ambiguous = state.SlurmReceipts.Count(receipt =>
            receipt.LoginDestination == destination
            && receipt.Owner == owner
            && receipt.Phase == SlurmLaunchPhase.Ambiguous);
        var summary = new List<string> { $"运行 {running}", $"排队 {pending}" };
        if (awaiting > 0)
        {
            summary.Add($"待确认 {awaiting}");
        }
        if (uncertain > 0)
        {
            summary.Add($"未知 {uncertain}");
        }
        if (ambiguous > 0)
        {
            summary.Add($"冲突 {ambiguous}");
        }
        if (ignoredRowCount > 0)
        {
            summary.Add($"异常 {ignoredRowCount}");
        }
        SlurmSummaryText.Text = string.Join(" · ", summary);
        UpdateSlurmControls();
    }

    private void LoadSlurmSettings(string? destination)
    {
        var settings = destination is not null
            && state.SlurmSettings.TryGetValue(destination, out var saved)
                ? saved
                : null;
        var at = destination?.IndexOf('@') ?? -1;
        SlurmOwnerBox.Text = settings?.Owner
            ?? (at > 0 ? destination![..at] : string.Empty);
        SlurmPartitionBox.Text = settings?.Partition ?? "debug";
        SlurmCpuBox.Text = (settings?.CpusPerTask ?? 4)
            .ToString(CultureInfo.InvariantCulture);
        SlurmMemoryBox.Text = (settings?.MemoryMiB ?? 16 * 1024)
            .ToString(CultureInfo.InvariantCulture);
        SlurmMinutesBox.Text = (settings?.WallTimeMinutes ?? 30)
            .ToString(CultureInfo.InvariantCulture);
        SlurmGpuBox.Text = (settings?.GpuCount ?? 1)
            .ToString(CultureInfo.InvariantCulture);
    }

    private bool SaveSlurmSettings(string destination, bool showDialog)
    {
        var settings = ReadSlurmSettings();
        var hadPrevious = state.SlurmSettings.TryGetValue(destination, out var previous);
        state.SlurmSettings[destination] = settings;
        if (TrySaveState("无法保存 Slurm 资源设置。", showDialog))
        {
            return true;
        }
        if (hadPrevious)
        {
            state.SlurmSettings[destination] = previous!;
        }
        else
        {
            state.SlurmSettings.Remove(destination);
        }
        return false;
    }

    private SlurmHostSettings ReadSlurmSettings()
    {
        var owner = SlurmOwnerBox.Text.Trim();
        var partition = SlurmPartitionBox.Text.Trim();
        var cpus = ParseResourceField(SlurmCpuBox.Text, "CPU", 1, 4_096);
        var memory = ParseResourceField(
            SlurmMemoryBox.Text,
            "内存",
            1,
            1_073_741_824);
        var minutes = ParseResourceField(SlurmMinutesBox.Text, "时限", 1, 525_600);
        var gpu = ParseResourceField(SlurmGpuBox.Text, "GPU", 0, 1_024);
        return new SlurmHostSettings(owner, partition, cpus, memory, minutes, gpu);
    }

    private async Task<string> ResolveSlurmOwnerAsync(
        string destination,
        CancellationToken cancellationToken)
    {
        var lockedOwner = LockedSlurmOwner(destination);
        if (lockedOwner is not null)
        {
            SlurmOwnerBox.Text = lockedOwner;
            return lockedOwner;
        }

        var owner = SlurmOwnerBox.Text.Trim();
        if (owner.Length > 0)
        {
            return owner;
        }

        var runner = sshRunner ?? throw RemoteUnavailable();
        var result = await runner.RunAsync(
            ["-G", SshInvocation.RequireDestination(destination)],
            TimeSpan.FromSeconds(5),
            cancellationToken);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(
                SshConnectionDiagnostics.FromResult(result).DisplayMessage);
        }
        foreach (var line in result.StandardOutput
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Split('\n'))
        {
            if (line.StartsWith("user ", StringComparison.OrdinalIgnoreCase))
            {
                owner = line[5..].Trim();
                if (owner.Length > 0)
                {
                    return owner;
                }
            }
        }
        throw new ArgumentException("请填写集群用户名。");
    }

    private string? LockedSlurmOwner(string destination) =>
        state.SlurmReceipts
            .Where(receipt =>
                receipt.LoginDestination == destination
                && LocksSlurmOwner(receipt.Phase))
            .OrderByDescending(static receipt => receipt.RequestedAt)
            .Select(static receipt => receipt.Owner)
            .FirstOrDefault();

    private static bool LocksSlurmOwner(SlurmLaunchPhase phase) =>
        phase is SlurmLaunchPhase.Submitting
            or SlurmLaunchPhase.AwaitingScheduler
            or SlurmLaunchPhase.Active
            or SlurmLaunchPhase.LaunchOutcomeUnknown
            or SlurmLaunchPhase.Ambiguous
            or SlurmLaunchPhase.CancellationRequested
            or SlurmLaunchPhase.CancellationOutcomeUnknown;

    private SlurmPlatformProfile BuildSlurmProfile(string destination, string owner)
    {
        var stable = IdentifierValidator.StableTmuxSessionName(destination)
            ?? throw new ArgumentException("SSH 目标格式无效。");
        var platform = new SlurmPlatformProfile(
            "slurm-" + stable,
            destination,
            destination,
            owner);
        SlurmCommands.ValidatePlatform(platform);
        return platform;
    }

    private SlurmInteractivePreset BuildSlurmPreset()
    {
        var settings = ReadSlurmSettings();
        var seconds = checked(settings.WallTimeMinutes * 60);
        var preset = new SlurmInteractivePreset(
            "windows-default",
            "交互环境",
            settings.Partition,
            1,
            settings.CpusPerTask,
            settings.MemoryMiB,
            new SlurmWallTime(seconds),
            settings.GpuCount == 0 ? null : new SlurmGpuRequest(null, settings.GpuCount));
        SlurmCommands.ValidatePreset(preset);
        return preset;
    }

    private static SlurmPlatformProfile PlatformForReceipt(SlurmLaunchReceipt receipt) =>
        new(
            receipt.PlatformId,
            receipt.LoginDestination,
            receipt.LoginDestination,
            receipt.Owner);

    private SlurmLaunchReceipt? FindUniqueSlurmReceipt(
        string destination,
        SlurmJobSnapshot job,
        IReadOnlyList<SlurmJobSnapshot> jobs) =>
        state.SlurmReceipts
            .Where(receipt =>
                receipt.LoginDestination == destination
                && ReceiptMatchesJob(receipt, job)
                && SlurmService.MatchCount(receipt, jobs) == 1)
            .OrderByDescending(static receipt => receipt.RequestedAt)
            .FirstOrDefault();

    private SlurmLaunchReceipt? FindSlurmReceipt(Guid requestId) =>
        state.SlurmReceipts.FirstOrDefault(receipt => receipt.RequestId == requestId);

    private SlurmLaunchReceipt SetSlurmPhase(
        Guid requestId,
        SlurmLaunchPhase phase,
        bool requireSaved = false)
    {
        var index = state.SlurmReceipts.FindIndex(
            receipt => receipt.RequestId == requestId);
        if (index < 0)
        {
            throw new InvalidOperationException("Slurm 启动凭据不存在。");
        }
        var current = state.SlurmReceipts[index];
        if (current.Phase == phase)
        {
            return current;
        }
        var updated = current with
        {
            Phase = phase,
            PhaseUpdatedAt = DateTimeOffset.UtcNow,
        };
        state.SlurmReceipts[index] = updated;
        if (!TrySaveState("Slurm 状态已更新，但无法保存。", showDialog: false)
            && requireSaved)
        {
            state.SlurmReceipts[index] = current;
            throw new IOException("未保存取消状态，因此没有发送取消请求。");
        }
        return updated;
    }

    private static bool ReceiptMatchesJob(
        SlurmLaunchReceipt receipt,
        SlurmJobSnapshot job) =>
        receipt.Owner == job.Owner
        && receipt.JobName == job.Name
        && receipt.Comment == job.Comment;

    private static int ParseResourceField(
        string value,
        string label,
        int minimum,
        int maximum)
    {
        if (!int.TryParse(
                value.Trim(),
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var parsed)
            || parsed < minimum
            || parsed > maximum)
        {
            throw new ArgumentException($"{label}必须是 {minimum}–{maximum} 的整数。");
        }
        return parsed;
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
        UpdateSlurmControls();
        SearchBox.IsEnabled = !isExclusiveOperation;
        AddHostBox.IsEnabled = !isExclusiveOperation;
        AddHostButton.IsEnabled = !isExclusiveOperation;
        RefreshHostsButton.IsEnabled = !isExclusiveOperation;
        EditSshConfigButton.IsEnabled = !isExclusiveOperation;
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
        PinButton.Content = host?.IsPinned == true ? "★" : "☆";
        PinButton.ToolTip = host?.IsPinned == true ? "取消固定" : "固定主机";
        System.Windows.Automation.AutomationProperties.SetName(
            PinButton,
            host?.IsPinned == true ? "取消固定主机" : "固定主机");
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
        ConfigureTmuxButton.IsEnabled = activeDestination is not null
            && tmuxConfigurationService is not null
            && !isExclusiveOperation;
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

    private void UpdateSlurmControls()
    {
        var hasHost = activeDestination is not null;
        var selected = SelectedSlurmJob;
        var canManage = CanManageSlurmSelection(selected)
            && slurmService is not null
            && !isExclusiveOperation;
        StartSlurmButton.IsEnabled = hasHost
            && slurmService is not null
            && !isExclusiveOperation;
        OpenSlurmButton.IsEnabled = canManage;
        CancelSlurmButton.IsEnabled = canManage;
        SlurmOwnerBox.IsEnabled = hasHost
            && activeDestination is { } destination
            && LockedSlurmOwner(destination) is null
            && !isExclusiveOperation;
        SlurmPartitionBox.IsEnabled = hasHost && !isExclusiveOperation;
        SlurmCpuBox.IsEnabled = hasHost && !isExclusiveOperation;
        SlurmMemoryBox.IsEnabled = hasHost && !isExclusiveOperation;
        SlurmMinutesBox.IsEnabled = hasHost && !isExclusiveOperation;
        SlurmGpuBox.IsEnabled = hasHost && !isExclusiveOperation;
    }

    private bool CanManageSlurmSelection(SlurmJobDisplay? selected)
    {
        if (selected?.Record is not { } record
            || record.State.IsTerminal
            || selected.Receipt is not { } displayedReceipt)
        {
            return false;
        }
        return FindSlurmReceipt(displayedReceipt.RequestId)?.Phase
            == SlurmLaunchPhase.Active;
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

    private TmuxConfigurationService RequireTmuxConfigurationService() =>
        tmuxConfigurationService ?? throw RemoteUnavailable();

    private HerdrService RequireHerdrService() => herdrService
        ?? throw RemoteUnavailable();

    private SlurmService RequireSlurmService() => slurmService
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
            TmuxConfigurationException
                or SlurmCommandException
                or SlurmConnectionException
                or SlurmSubmissionOutcomeUnknownException
                or SlurmCancellationOutcomeUnknownException
                or SlurmAmbiguousLaunchException
                or SlurmJobUnavailableException
                or SlurmIdentityMismatchException
                or SlurmValidationException => error.Message,
            FileNotFoundException
                or TimeoutException
                or TmuxServiceException => SshConnectionDiagnostics.Describe(error),
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

    private SlurmJobDisplay? SelectedSlurmJob =>
        SlurmGrid.SelectedItem as SlurmJobDisplay;

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

    private sealed class SlurmJobDisplay
    {
        public SlurmJobDisplay(
            SlurmJobSnapshot record,
            SlurmLaunchReceipt? receipt)
        {
            Record = record;
            Receipt = receipt;
        }

        public SlurmJobDisplay(SlurmLaunchReceipt receipt)
        {
            Receipt = receipt;
        }

        public SlurmJobSnapshot? Record { get; }
        public SlurmLaunchReceipt? Receipt { get; }
        public string Name => Record?.Name ?? Receipt?.JobName ?? "—";
        public string JobId => Record?.JobId.Value ?? "—";
        public string State => Record is null ? Receipt?.Phase switch
        {
            SlurmLaunchPhase.Submitting => "准备中",
            SlurmLaunchPhase.AwaitingScheduler => "待确认",
            SlurmLaunchPhase.LaunchOutcomeUnknown => "结果未知",
            SlurmLaunchPhase.Ambiguous => "匹配冲突",
            SlurmLaunchPhase.LaunchFailed => "启动失败",
            SlurmLaunchPhase.NotFound => "未找到",
            SlurmLaunchPhase.CancellationRequested => "取消中",
            SlurmLaunchPhase.CancellationOutcomeUnknown => "取消未知",
            SlurmLaunchPhase.LeftQueue => "已离队",
            _ => "—",
        } : Receipt?.Phase is SlurmLaunchPhase.CancellationRequested
            or SlurmLaunchPhase.CancellationOutcomeUnknown
            ? "取消中"
            : Record.State.Kind switch
        {
            SlurmJobStateKind.Pending => "排队",
            SlurmJobStateKind.Running => "运行",
            SlurmJobStateKind.Completing => "结束中",
            SlurmJobStateKind.Completed => "完成",
            SlurmJobStateKind.Cancelled => "取消",
            SlurmJobStateKind.Failed => "失败",
            SlurmJobStateKind.Timeout => "超时",
            SlurmJobStateKind.NodeFailure => "节点故障",
            SlurmJobStateKind.OutOfMemory => "内存不足",
            SlurmJobStateKind.Preempted => "抢占",
            SlurmJobStateKind.Suspended => "暂停",
            _ => Record.State.SchedulerValue,
        };
        public string Partition => Record?.Partition ?? "—";
        public string Time => Record is null ? "—" : $"{Record.Elapsed} / {Record.TimeLimit}";
        public string Nodes => Record is null
            ? "—"
            : Record.NodeList
                ?? (Record.ReasonOrNodeList.Length == 0 ? "—" : Record.ReasonOrNodeList);
        public string Source => Receipt is null ? "只读" : "TmuxHub";
    }
}
