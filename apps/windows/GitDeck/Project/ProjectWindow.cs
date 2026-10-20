using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Editor;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;

namespace GitDeck.Project;

/// 项目主窗口，布局对齐 IDEA New UI（Windows 上主菜单收在标题栏左侧的汉堡按钮里）：
///
/// ```
/// ┌ ≡ 项目组件 · VCS 分支组件 ……………… 更新 提交 推送 刷新 ─ □ × ┐
/// │ 图标条 │ 左侧工具窗口 │ 编辑器区域          │ 右侧工具窗口 │ 图标条 │
/// │        ├──────────────┴─────────────────────┴──────────────┤        │
/// │        │ 底部工具窗口（Git）                                  │        │
/// └ 状态栏 ──────────────────────────────────────────────────────┘
/// ```
public sealed class ProjectWindow : Window
{
    public const double ToolbarHeight = 40;

    private readonly AppController _app;
    private readonly Grid _root = new();
    private readonly Grid _toolbar = new() { Height = ToolbarHeight };
    private readonly IconButton _menuButton = new(Icon.Menu, L10n.Tr("toolbar.mainMenu.tooltip"), 30);
    private readonly ProjectBadge _badge = new();
    private readonly ToolbarWidget _projectWidget;
    private readonly ToolbarWidget _vcsWidget = new(Icons.Create(Icon.Branch, 14), L10n.Tr("toolbar.vcs.tooltip"));
    private readonly IconButton _updateButton = new(Icon.Update, L10n.Tr("git.action.update") + " (Ctrl+T)", 28, 14);
    private readonly IconButton _commitButton = new(Icon.Commit, L10n.Tr("git.action.commit") + " (Ctrl+K)", 28, 14);
    private readonly IconButton _pushButton = new(Icon.Push, L10n.Tr("git.action.push") + " (Ctrl+Shift+K)", 28, 14);
    private readonly IconButton _refreshButton = new(Icon.Refresh, L10n.Tr("git.action.refresh"), 28, 14);
    private readonly StackPanel _toolbarLeft = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _toolbarRight = new() { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };

    private readonly ToolWindowStripe _stripe = new([ToolWindowId.Project, ToolWindowId.Commit], [ToolWindowId.Git]);
    private readonly ToolWindowStripe _rightStripe = new([ToolWindowId.AiReview], []);
    private readonly StatusBar _statusBar = new();

    private readonly Grid _workArea = new();
    private readonly Grid _mainRow = new();
    private readonly Border _leftPanel = new();
    private readonly Border _rightPanel = new();
    private readonly Border _bottomPanel = new();
    private readonly Splitter _leftSplitter = new(vertical: true);
    private readonly Splitter _rightSplitter = new(vertical: true);
    private readonly Splitter _bottomSplitter = new(vertical: false);
    private readonly Dictionary<ToolWindowId, ToolWindowPanel> _toolWindows = [];

    private readonly FileWatcher _fileWatcher;
    private readonly EditorArea _editor;
    private readonly ProjectTree _projectTree;
    private MenuFlyout? _mainMenu;
    private bool _closeConfirmed;

    public ProjectWindow(AppController app, Repository repository)
    {
        _app = app;
        Model = new ProjectModel(repository);
        _editor = new EditorArea(Model);
        _projectTree = new ProjectTree(Model);
        _projectWidget = new ToolbarWidget(_badge, L10n.Tr("toolbar.project.tooltip"));
        Title = $"{Model.ProjectName} – {Model.RootPath}";
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
        WindowHelper.SetIcon(this);

        BuildLayout();
        WireActions();
        Content = _root;
        SetTitleBar(_toolbar);
        Appearance.Register(this);
        WindowHelper.SetMinimumSize(this, 720, 480);
        RestorePlacement();

        foreach (var id in Enum.GetValues<ToolWindowId>()) _toolWindows[id] = new ToolWindowPanel(id.Title());
        _toolWindows[ToolWindowId.Project] = _projectTree.View;
        ApplyToolWindowState();
        Model.Changed += ModelChanged;
        Model.Refresh();
        _fileWatcher = new FileWatcher(Model.RootPath, paths =>
        {
            Model.Refresh();
            _editor.ReloadFromDisk(paths);
        });
        _fileWatcher.Start();
        _editor.RestoreSession();

        // 有未保存的文件时，关闭窗口前逐个询问。
        AppWindow.Closing += async (_, e) =>
        {
            if (_closeConfirmed || !_editor.HasModifiedDocuments) return;
            e.Cancel = true;
            if (await _editor.ConfirmCloseAll())
            {
                _closeConfirmed = true;
                Close();
            }
        };

        Closed += (_, _) =>
        {
            SavePlacement();
            _fileWatcher.Dispose();
            Model.Changed -= ModelChanged;
        };
        _root.Loaded += (_, _) => RunDebugAction();
    }

    public ProjectModel Model { get; }

    // MARK: - 布局

    private void BuildLayout()
    {
        _badge.ProjectName = Model.ProjectName;
        _projectWidget.Title = Model.ProjectName;

        // 主工具栏：左侧为主菜单、项目组件与 VCS 分支组件，右侧为常用 Git 操作；右侧留出系统标题栏按钮的位置。
        Themed.Background(_toolbar, "HeaderBackgroundBrush");
        _toolbarLeft.Margin = new Thickness(6, 0, 0, 0);
        _toolbarLeft.Children.Add(_menuButton);
        _toolbarLeft.Children.Add(_projectWidget);
        _toolbarLeft.Children.Add(_vcsWidget);
        foreach (var button in new[] { _updateButton, _commitButton, _pushButton, _refreshButton }) _toolbarRight.Children.Add(button);
        _toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
        Grid.SetColumn(_toolbarRight, 2);
        _toolbar.Children.Add(_toolbarLeft);
        _toolbar.Children.Add(_toolbarRight);
        var toolbarBottom = Themed.Background(new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom }, "SeparatorBrush");
        Grid.SetColumnSpan(toolbarBottom, 4);
        _toolbar.Children.Add(toolbarBottom);

        // 中间：左侧面板 | 编辑器 | 右侧面板，下方为底部面板。
        _mainRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        _mainRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _mainRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 120 });
        _mainRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _mainRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(380) });
        var editor = _editor;
        Grid.SetColumn(_leftSplitter, 1);
        Grid.SetColumn(editor, 2);
        Grid.SetColumn(_rightSplitter, 3);
        Grid.SetColumn(_rightPanel, 4);
        foreach (var element in new UIElement[] { _leftPanel, _leftSplitter, editor, _rightSplitter, _rightPanel }) _mainRow.Children.Add(element);

        _workArea.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 80 });
        _workArea.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _workArea.RowDefinitions.Add(new RowDefinition { Height = new GridLength(260) });
        Grid.SetRow(_bottomSplitter, 1);
        Grid.SetRow(_bottomPanel, 2);
        _workArea.Children.Add(_mainRow);
        _workArea.Children.Add(_bottomSplitter);
        _workArea.Children.Add(_bottomPanel);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var leftDivider = Themed.Background(new Border(), "SeparatorBrush");
        var rightDivider = Themed.Background(new Border(), "SeparatorBrush");
        Grid.SetColumn(leftDivider, 1);
        Grid.SetColumn(_workArea, 2);
        Grid.SetColumn(rightDivider, 3);
        Grid.SetColumn(_rightStripe, 4);
        foreach (var element in new UIElement[] { _stripe, leftDivider, _workArea, rightDivider, _rightStripe }) body.Children.Add(element);

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(body, 1);
        Grid.SetRow(_statusBar, 2);
        _root.Children.Add(_toolbar);
        _root.Children.Add(body);
        _root.Children.Add(_statusBar);
        Themed.Background(_root, "HeaderBackgroundBrush");

        // 标题栏中的按钮需要声明为可点击区域，其余部分用于拖动窗口。
        _toolbar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        _toolbarLeft.SizeChanged += (_, _) => UpdateTitleBarRegions();
        _toolbarRight.SizeChanged += (_, _) => UpdateTitleBarRegions();
    }

    private void UpdateTitleBarRegions()
    {
        if (_toolbar.XamlRoot is null) return;
        var scale = _toolbar.XamlRoot.RasterizationScale;
        // 为系统的最小化 / 最大化 / 关闭按钮留出位置。
        _toolbar.ColumnDefinitions[3].Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
        var rects = new List<RectInt32>();
        foreach (var element in _toolbarLeft.Children.Concat(_toolbarRight.Children).OfType<FrameworkElement>())
        {
            if (element.ActualWidth <= 0) continue;
            var bounds = element.TransformToVisual(null).TransformBounds(new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            rects.Add(new RectInt32((int)(bounds.X * scale), (int)(bounds.Y * scale), (int)Math.Ceiling(bounds.Width * scale), (int)Math.Ceiling(bounds.Height * scale)));
        }
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, [.. rects]);
    }

    private void WireActions()
    {
        _stripe.Toggled += Toggle;
        _rightStripe.Toggled += Toggle;
        _menuButton.Click += (_, _) => ShowMainMenu();
        _projectWidget.Click += (_, _) => ShowProjectMenu();
        _vcsWidget.Click += (_, _) => NotImplemented(L10n.Tr("git.action.branches"));
        _refreshButton.Click += (_, _) => Model.Refresh();
        _commitButton.Click += (_, _) => Show(ToolWindowId.Commit);
        _updateButton.Click += (_, _) => NotImplemented(L10n.Tr("git.action.update"));
        _pushButton.Click += (_, _) => NotImplemented(L10n.Tr("git.action.push"));

        _projectTree.OpenFile += path => _editor.Open(path);
        _editor.CaretInfoChanged += _statusBar.SetEditorInfo;
        _editor.Message += (text, isError) => _statusBar.SetMessage(text, isError);

        _leftSplitter.Dragged += delta => Resize(_mainRow.ColumnDefinitions[0], delta, 120);
        _rightSplitter.Dragged += delta => Resize(_mainRow.ColumnDefinitions[4], -delta, 160);
        _bottomSplitter.Dragged += delta => ResizeRow(_workArea.RowDefinitions[2], -delta, 80);
        _leftSplitter.DragCompleted += SaveSizes;
        _rightSplitter.DragCompleted += SaveSizes;
        _bottomSplitter.DragCompleted += SaveSizes;

        // IDEA Windows 键位。
        AddAccelerator(VirtualKey.Number1, VirtualKeyModifiers.Menu, () => Toggle(ToolWindowId.Project));
        AddAccelerator(VirtualKey.Number0, VirtualKeyModifiers.Menu, () => Toggle(ToolWindowId.Commit));
        AddAccelerator(VirtualKey.Number9, VirtualKeyModifiers.Menu, () => Toggle(ToolWindowId.Git));
        AddAccelerator(VirtualKey.K, VirtualKeyModifiers.Control, () => Show(ToolWindowId.Commit));
        AddAccelerator(VirtualKey.K, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => NotImplemented(L10n.Tr("git.action.push")));
        AddAccelerator(VirtualKey.T, VirtualKeyModifiers.Control, () => NotImplemented(L10n.Tr("git.action.update")));
        AddAccelerator(VirtualKey.R, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, Model.Refresh);
        AddAccelerator(VirtualKey.W, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, Close);
        AddAccelerator(VirtualKey.S, VirtualKeyModifiers.Control, SaveActive);
        AddAccelerator(VirtualKey.F4, VirtualKeyModifiers.Control, CloseActiveTab);
        AddAccelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => _editor.ActiveEditor?.ShowFindBar());
        AddAccelerator(VirtualKey.R, VirtualKeyModifiers.Control, () => _editor.ActiveEditor?.ShowFindBar(replace: true));
        AddAccelerator(VirtualKey.F3, VirtualKeyModifiers.None, () => _editor.ActiveEditor?.FindNext());
        AddAccelerator(VirtualKey.F3, VirtualKeyModifiers.Shift, () => _editor.ActiveEditor?.FindPrevious());
        AddAccelerator((VirtualKey)187, VirtualKeyModifiers.Control, () => EditorSettings.FontSize += 1);
        AddAccelerator((VirtualKey)189, VirtualKeyModifiers.Control, () => EditorSettings.FontSize -= 1);
        AddAccelerator(VirtualKey.Number0, VirtualKeyModifiers.Control, EditorSettings.Reset);
    }

    private void AddAccelerator(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, e) =>
        {
            action();
            e.Handled = true;
        };
        _root.KeyboardAccelerators.Add(accelerator);
    }

    private void NotImplemented(string action) =>
        _statusBar.SetMessage($"{action.TrimEnd('…')}: {L10n.Tr("common.notImplemented")}");

    // MARK: - 工具窗口（布局在各项目间共用并持久化，与 IDEA 重启后恢复布局的行为一致）

    private static ToolWindowId? LeftToolWindow
    {
        // 未设置过时默认打开 Project；显式关闭时保存为空串。
        get => Settings.GetString("toolWindow.left") is { } raw
            ? Enum.TryParse<ToolWindowId>(raw, ignoreCase: true, out var id) ? id : null
            : ToolWindowId.Project;
        set => Settings.Set("toolWindow.left", value?.ToString().ToLowerInvariant() ?? "");
    }

    private static bool BottomVisible
    {
        get => Settings.GetBool("toolWindow.bottomVisible");
        set => Settings.Set("toolWindow.bottomVisible", value);
    }

    private static bool RightVisible
    {
        get => Settings.GetBool("toolWindow.rightVisible");
        set => Settings.Set("toolWindow.rightVisible", value);
    }

    /// 点击图标条：同一位置只显示一个工具窗口，再次点击已激活的按钮则隐藏。
    private void Toggle(ToolWindowId id)
    {
        switch (id.Anchor())
        {
            case ToolWindowAnchor.Left: LeftToolWindow = LeftToolWindow == id ? null : id; break;
            case ToolWindowAnchor.Bottom: BottomVisible = !BottomVisible; break;
            default: RightVisible = !RightVisible; break;
        }
        ApplyToolWindowState();
    }

    private void Show(ToolWindowId id)
    {
        switch (id.Anchor())
        {
            case ToolWindowAnchor.Left: LeftToolWindow = id; break;
            case ToolWindowAnchor.Bottom: BottomVisible = true; break;
            default: RightVisible = true; break;
        }
        ApplyToolWindowState();
    }

    private void ApplyToolWindowState()
    {
        var left = LeftToolWindow;
        var bottom = BottomVisible;
        var right = RightVisible;
        _leftPanel.Child = left is { } id ? _toolWindows[id] : null;
        _bottomPanel.Child = bottom ? _toolWindows[ToolWindowId.Git] : null;
        _rightPanel.Child = right ? _toolWindows[ToolWindowId.AiReview] : null;

        var columns = _mainRow.ColumnDefinitions;
        columns[0].Width = new GridLength(left is null ? 0 : Settings.GetDouble("toolWindow.leftWidth", 300));
        columns[4].Width = new GridLength(right ? Settings.GetDouble("toolWindow.rightWidth", 380) : 0);
        _workArea.RowDefinitions[2].Height = new GridLength(bottom ? Settings.GetDouble("toolWindow.bottomHeight", 260) : 0);
        _leftPanel.Visibility = _leftSplitter.Visibility = left is null ? Visibility.Collapsed : Visibility.Visible;
        _rightPanel.Visibility = _rightSplitter.Visibility = right ? Visibility.Visible : Visibility.Collapsed;
        _bottomPanel.Visibility = _bottomSplitter.Visibility = bottom ? Visibility.Visible : Visibility.Collapsed;

        var active = new HashSet<ToolWindowId>();
        if (left is { } leftId) active.Add(leftId);
        if (bottom) active.Add(ToolWindowId.Git);
        _stripe.SetActive(active);
        _rightStripe.SetActive(right ? new HashSet<ToolWindowId> { ToolWindowId.AiReview } : []);
    }

    private static void Resize(ColumnDefinition column, double delta, double minimum) =>
        column.Width = new GridLength(Math.Max(minimum, column.ActualWidth + delta));

    private static void ResizeRow(RowDefinition row, double delta, double minimum) =>
        row.Height = new GridLength(Math.Max(minimum, row.ActualHeight + delta));

    private void SaveSizes()
    {
        if (LeftToolWindow is not null) Settings.Set("toolWindow.leftWidth", _mainRow.ColumnDefinitions[0].ActualWidth);
        if (RightVisible) Settings.Set("toolWindow.rightWidth", _mainRow.ColumnDefinitions[4].ActualWidth);
        if (BottomVisible) Settings.Set("toolWindow.bottomHeight", _workArea.RowDefinitions[2].ActualHeight);
    }

    // MARK: - 菜单

    private void ShowMainMenu()
    {
        _mainMenu = MainMenu.Build(this, _app);
        _mainMenu.ShowAt(_menuButton, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    /// 项目组件菜单：最近项目 + 新建 / 打开（与 mac 端一致）。
    private void ShowProjectMenu()
    {
        var menu = new MenuFlyout();
        foreach (var path in RecentProjects.Paths.Where(p => !RecentProjects.SamePath(p, Model.RootPath)).Take(10))
        {
            var item = new MenuFlyoutItem { Text = Path.GetFileName(Path.TrimEndingDirectorySeparator(path)) };
            ToolTipService.SetToolTip(item, path);
            item.Click += (_, _) => _app.OpenProject(path, this);
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
        var newProject = new MenuFlyoutItem { Text = L10n.Tr("menu.file.new") };
        newProject.Click += async (_, _) => await _app.NewProject(this);
        var open = new MenuFlyoutItem { Text = L10n.Tr("menu.file.open") };
        open.Click += async (_, _) => await _app.OpenProjectWithPicker(this);
        menu.Items.Add(newProject);
        menu.Items.Add(open);
        menu.ShowAt(_projectWidget, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    public void ToggleToolWindow(ToolWindowId id) => Toggle(id);

    public bool IsToolWindowVisible(ToolWindowId id) => id.Anchor() switch
    {
        ToolWindowAnchor.Left => LeftToolWindow == id,
        ToolWindowAnchor.Bottom => BottomVisible,
        _ => RightVisible,
    };

    public void RefreshStatus() => Model.Refresh();

    public CodeEditor? ActiveEditor => _editor.ActiveEditor;

    public void SaveActive() => _editor.SaveActive();

    public void CloseActiveTab() => _ = _editor.CloseActive();

    public void ShowEditorFontDialog() => _ = EditorFontDialog.Show(_root.XamlRoot);

    // MARK: - 模型变化

    private void ModelChanged()
    {
        _vcsWidget.Title = Model.BranchWidgetTitle;
        _statusBar.SetBusy(Model.IsRefreshing);
        if (Model.LastError is { } error) _statusBar.SetMessage(error, isError: true);
        else if (Model.Notification is { } notification) _statusBar.SetMessage(notification.Text, notification.IsError);
    }

    // MARK: - 窗口位置（按项目保存，与 mac 端的 frameAutosaveName 一致）

    private string PlacementKey => "window:" + Model.RootPath.ToLowerInvariant();

    private void RestorePlacement()
    {
        var parts = Settings.GetString(PlacementKey)?.Split(',').Select(p => int.TryParse(p, out var v) ? v : (int?)null).ToArray();
        if (parts is { Length: 5 } && parts.All(p => p is not null))
        {
            var rect = new RectInt32(parts[0]!.Value, parts[1]!.Value, parts[2]!.Value, parts[3]!.Value);
            var area = DisplayArea.GetFromRect(rect, DisplayAreaFallback.None);
            if (area is not null)
            {
                AppWindow.MoveAndResize(rect);
                if (parts[4] == 1 && AppWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
                return;
            }
        }
        WindowHelper.ResizeAndCenter(this, 1280, 820);
    }

    private void SavePlacement()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
        var maximized = presenter.State == OverlappedPresenterState.Maximized;
        if (presenter.State == OverlappedPresenterState.Minimized) return;
        // 最大化时保存还原后的大小需要额外的 Win32 调用；这里沿用上次的普通位置，只更新最大化标记。
        var previous = Settings.GetString(PlacementKey)?.Split(',');
        if (maximized && previous is { Length: 5 })
        {
            Settings.Set(PlacementKey, string.Join(',', previous[..4]) + ",1");
            return;
        }
        var (position, size) = (AppWindow.Position, AppWindow.Size);
        Settings.Set(PlacementKey, $"{position.X},{position.Y},{size.Width},{size.Height},{(maximized ? 1 : 0)}");
    }

    // MARK: - 调试

    private void RunDebugAction()
    {
        UpdateTitleBarRegions();
        var action = DebugOptions.Get("debug.action");
        if (action is not null)
        {
            // 等状态加载后执行，与 mac 端一致。
            // 注意：编辑器组件加载后 DispatcherQueueTimer 会停止触发（WinUIEdit 的问题），这里用 XAML 的 DispatcherTimer。
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                switch (action)
                {
                    case "mainMenu": ShowMainMenu(); break;
                    case "projectMenu": ShowProjectMenu(); break;
                    case "toolWindows":
                        Show(ToolWindowId.Commit);
                        Show(ToolWindowId.Git);
                        Show(ToolWindowId.AiReview);
                        break;
                    case "clone": _ = _app.CloneProject(this); break;
                    case "expandTree": _projectTree.ExpandAll(); break;
                    case "openFile" when DebugOptions.Get("debug.file") is { } file:
                        _projectTree.ExpandAll(1);
                        _editor.Open(Path.Combine(Model.RootPath, file), (int)DebugOptions.Double("debug.line", 0));
                        if (DebugOptions.Get("debug.query") is { } query)
                        {
                            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _editor.ActiveEditor?.ShowFindBar());
                            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _editor.ActiveEditor?.SetFindQuery(query));
                        }
                        break;
                    case "editorFont": ShowEditorFontDialog(); break;
                }
            };
            timer.Start();
        }
        Snapshot.Schedule(this);
    }
}
