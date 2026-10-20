using GitDeck.AI;
using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Commit;
using GitDeck.Core;
using GitDeck.Diff;
using GitDeck.Editor;
using GitDeck.Git;
using GitDeck.Merge;
using GitDeck.Vcs;
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
    private readonly Dictionary<ToolWindowId, FrameworkElement> _toolWindows = [];
    private readonly LineSelectionStore _lineSelections = new();
    private readonly CommitToolWindow _commitWindow;
    private readonly GitOperations _operations;
    private readonly GitToolWindow _gitWindow;
    private readonly BranchesPopup _branchesPopup;
    private readonly ConflictResolver _conflicts;
    /// 本窗口中的所有仓库（主仓库 + 加入的嵌套仓库 / 子模块）。
    private readonly Workspace _workspace;
    private readonly WorkspaceOperations _workspaceOperations;
    private readonly WorkspaceBanner _banner = new();
    /// 非主仓库的操作对象（按仓库缓存）。
    private readonly Dictionary<ProjectModel, GitOperations> _extraOperations = [];
    private readonly StashesView _stashes;
    private readonly AIReviewController _aiReview;
    private readonly AIReviewToolWindow _aiWindow;
    private readonly ShelfView _shelf;

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
        _commitWindow = new CommitToolWindow(Model, _lineSelections);
        _operations = new GitOperations(Model, () => _root.XamlRoot);
        _workspace = new Workspace(Model);
        _workspaceOperations = new WorkspaceOperations(_workspace, OperationsFor, () => _root.XamlRoot);
        _operations.Peers = () => AllOperations;
        _gitWindow = new GitToolWindow(Model, _operations);
        _branchesPopup = new BranchesPopup(_workspace, OperationsFor, ShowCommit);
        _conflicts = new ConflictResolver(Model, () => _root.XamlRoot);
        _stashes = new StashesView(Model, _operations);
        _aiReview = new AIReviewController(Model, () => _root.XamlRoot);
        _aiWindow = new AIReviewToolWindow(_aiReview);
        _shelf = new ShelfView(Model, _operations);
        _commitWindow.AttachStashAndShelf(_stashes, _shelf);
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
        _toolWindows[ToolWindowId.Commit] = _commitWindow;
        _toolWindows[ToolWindowId.Git] = _gitWindow;
        _toolWindows[ToolWindowId.AiReview] = _aiWindow;
        _aiReview.Reveal += () => Show(ToolWindowId.AiReview);
        _aiWindow.ReviewLocalChanges += ReviewLocalChanges;
        _aiWindow.OpenFinding += OpenFinding;
        _aiWindow.ApplySuggestion += ApplySuggestion;
        _commitWindow.AiReview = _aiReview;
        _editor.AiReview = _aiReview;
        _editor.ShowFinding += index =>
        {
            Show(ToolWindowId.AiReview);
            _aiWindow.Select(index);
        };
        _gitWindow.Log.AiReview = _aiReview;
        ApplyToolWindowState();
        Model.Changed += ModelChanged;
        Model.Refresh();
        _projectTree.Workspace = _workspace;
        _workspace.Changed += WorkspaceChanged;
        _workspace.Load();
        _fileWatcher = new FileWatcher(Model.RootPath, paths =>
        {
            _workspace.RefreshAll();
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
        _root.RowDefinitions.Insert(1, new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_banner, 1);
        Grid.SetRow(body, 2);
        Grid.SetRow(_statusBar, 3);
        _root.Children.Add(_toolbar);
        _root.Children.Add(_banner);
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
        _vcsWidget.Click += (_, _) => ShowBranches();
        _refreshButton.Click += (_, _) => _workspace.RefreshAll();
        // AI 评审分支（批次 C 中改为评审所选仓库）。
        _branchesPopup.ReviewBranch = (_, name) => _aiReview.ReviewBranch(name);
        _banner.AddClicked += () => _workspace.Add([.. _workspace.Candidates.Select(c => c.Path)]);
        _banner.IgnoreClicked += () => _workspace.Ignore([.. _workspace.Candidates.Select(c => c.Path)]);
        _workspaceOperations.Progress += title =>
        {
            _statusBar.SetBusy(title is not null || _workspace.IsRefreshing);
            if (title is not null) _statusBar.SetMessage(title);
        };
        _commitButton.Click += (_, _) => ShowCommit();
        _updateButton.Click += (_, _) => UpdateAll();
        _pushButton.Click += (_, _) => PushAll();

        _projectTree.OpenFile += path => _editor.Open(path);
        _commitWindow.OpenFile += path => _editor.Open(path);
        _commitWindow.ShowDiff += change => ShowLocalDiff(change);
        _commitWindow.PushAfterCommit += PushAll;
        _commitWindow.ResolveConflict += change =>
        {
            if (change is not null) _conflicts.OpenMerge(change);
            else _ = _conflicts.ShowConflicts();
        };
        _operations.Conflicts += _conflicts.RequestConflicts;
        _operations.Progress += title =>
        {
            _statusBar.SetBusy(title is not null || Model.IsRefreshing);
            if (title is not null) _statusBar.SetMessage(title);
        };
        _operations.RevealCommit += hash =>
        {
            Show(ToolWindowId.Git);
            _gitWindow.Reveal(hash);
        };
        _operations.ShowRevisionFileDiff += ShowRevisionAgainstWorkingTree;
        _gitWindow.Log.OpenFile += path => _editor.Open(path);
        _gitWindow.Log.ShowCommitDiff += ShowCommitFile;
        _editor.CaretInfoChanged += _statusBar.SetEditorInfo;
        _editor.ShowCommit += hash =>
        {
            Show(ToolWindowId.Git);
            _gitWindow.Reveal(hash);
        };
        _editor.ShowHistory += ShowFileHistory;
        _commitWindow.ShowHistory += ShowFileHistory;
        _commitWindow.ShelveRequested += (paths, name) => _ = _operations.Shelve(paths, name);
        _commitWindow.StashRequested += paths => _ = _operations.StashChanges(paths);
        _commitWindow.CreatePatchRequested += paths => _ = _operations.CreatePatch(paths);
        _stashes.ShowFileDiff += ShowStashFile;
        _shelf.ShowFileDiff += ShowShelfFile;
        _gitWindow.OpenHistoryDiff += ShowCommitFile;
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
        AddAccelerator(VirtualKey.K, VirtualKeyModifiers.Control, ShowCommit);
        AddAccelerator(VirtualKey.F7, VirtualKeyModifiers.None, NextDifference);
        AddAccelerator(VirtualKey.F7, VirtualKeyModifiers.Shift, PreviousDifference);
        AddAccelerator(VirtualKey.K, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, PushAll);
        AddAccelerator(VirtualKey.T, VirtualKeyModifiers.Control, UpdateAll);
        AddAccelerator(VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => _ = _operations.NewBranch());
        AddAccelerator(VirtualKey.Z, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, RollbackChanges);
        AddAccelerator(VirtualKey.S, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => SettingsWindow.Show());
        // IDEA Windows 键位：Ctrl+Shift+` 打开分支弹窗。
        AddAccelerator((VirtualKey)192, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, ShowBranches);
        AddAccelerator(VirtualKey.R, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, _workspace.RefreshAll);
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

    public void RefreshStatus() => _workspace.RefreshAll();

    // MARK: - 多仓库

    public Workspace Workspace => _workspace;

    /// 某个仓库的操作对象：主仓库用窗口的操作对象，其他仓库按需创建并共享窗口的回调。
    public GitOperations OperationsFor(ProjectModel model)
    {
        if (model == Model) return _operations;
        if (_extraOperations.TryGetValue(model, out var existing)) return existing;
        var operations = new GitOperations(model, () => _root.XamlRoot) { Peers = () => AllOperations };
        operations.Progress += title =>
        {
            _statusBar.SetBusy(title is not null || _workspace.IsRefreshing);
            if (title is not null) _statusBar.SetMessage(title);
        };
        operations.RevealCommit += hash =>
        {
            Show(ToolWindowId.Git);
            _gitWindow.Reveal(hash);
        };
        _extraOperations[model] = operations;
        return operations;
    }

    private IEnumerable<GitOperations> AllOperations => _workspace.Models.Select(OperationsFor);

    public void FetchAll() => _ = _workspaceOperations.FetchAll();

    public void UpdateAll() => _ = _workspaceOperations.UpdateAll();

    public void PushAll() => _ = _workspaceOperations.PushAll();

    /// 把选择的目录作为仓库加入本项目（Git > 将仓库加入项目）。
    public async void AddRepository()
    {
        if (await Dialogs.PickFolder(this) is { } path) _workspace.Add([path]);
    }

    private readonly Dictionary<ProjectModel, (string Text, bool IsError)?> _shownNotifications = [];

    /// 仓库列表或任一仓库状态变化：更新分支组件、提示条与状态栏。
    private void WorkspaceChanged()
    {
        _vcsWidget.Title = _workspace.BranchWidgetTitle;
        _statusBar.SetBusy(_workspace.IsRefreshing || _operations.IsRunning || _workspaceOperations.IsRunning);
        _banner.Show(_workspace.Candidates);
        // 其他仓库的操作结果显示在状态栏（主仓库的由 ModelChanged 处理）。
        foreach (var model in _workspace.Models.Where(m => m != Model))
        {
            var notification = model.Notification;
            if (_shownNotifications.TryGetValue(model, out var shown) && shown == notification) continue;
            _shownNotifications[model] = notification;
            if (notification is { } n) _statusBar.SetMessage(n.Text, n.IsError);
        }
    }

    public CodeEditor? ActiveEditor => _editor.ActiveEditor;

    public void NextDifference() => _editor.ActiveDiff?.NextDifference();

    public void PreviousDifference() => _editor.ActiveDiff?.PreviousDifference();

    /// 打开提交工具窗口并聚焦提交信息（Ctrl+K，与 IDEA 一致）。
    public void ShowCommit()
    {
        Show(ToolWindowId.Commit);
        _commitWindow.FocusMessage();
    }

    /// 本地变更：HEAD 与工作区文件比较（提交工具窗口中的 Show Diff），可选择要提交的改动。
    public GitOperations Operations => _operations;

    /// 分支弹窗；多仓库时默认选中当前编辑的文件所在的仓库。
    public void ShowBranches() =>
        _branchesPopup.ShowAt(_vcsWidget, _editor.ActivePath is { } path ? _workspace.ModelContaining(path) : Model);

    public bool HasConflicts => _conflicts.HasConflicts;

    public bool HasActiveFile => _editor.ActiveRelativePath is not null;

    public bool IsActiveAnnotated => _editor.IsActiveAnnotated;

    /// IDEA 的 “Annotate with Git Blame”：打开或关闭当前文件的注释列。
    public void ToggleAnnotations() => _editor.ToggleAnnotations();

    /// 在底部 Git 工具窗口中打开文件历史标签页。
    public void ShowFileHistory(string path)
    {
        Show(ToolWindowId.Git);
        _gitWindow.ShowHistory(path);
    }

    public void ShowHistoryForCurrentFile()
    {
        if (_editor.ActiveRelativePath is { } path) ShowFileHistory(path);
    }

    public void StashChanges() => _ = _operations.StashChanges();

    public bool IsAiReviewRunning => _aiReview.IsRunning;

    /// AI 评审本地改动：Commit 工具窗口中勾选了文件时只评审勾选的文件。
    public void ReviewLocalChanges() => _ = _aiReview.ReviewLocalChanges(_commitWindow.IncludedPaths);

    /// 跳转到发现所在位置：工作区版本在编辑器中打开，历史版本打开该提交中文件的 Diff。
    private void OpenFinding(int index)
    {
        if (_aiReview.Result is not { } result || index >= result.Findings.Length) return;
        var finding = result.Findings[index];
        var line = Math.Max(0, (int)finding.Line - 1);
        if (_aiReview.IsWorkingTreeResult(finding.File))
        {
            var path = Path.Combine(Model.RootPath, finding.File);
            if (File.Exists(path)) _editor.Open(path, line);
        }
        else if (result.Revision is { } revision)
        {
            ShowCommitFile(revision, revision + "^", new ChangedFile(finding.File, null, ChangeKind.Modified));
        }
    }

    /// 预览并应用修改建议：在当前内容（含未保存的编辑）中定位原文，确认后写入。
    private async void ApplySuggestion(int index)
    {
        if (_aiReview.Result is not { } result || index >= result.Findings.Length) return;
        var finding = result.Findings[index];
        if (finding.Suggestion is not { } suggestion || !_aiReview.IsWorkingTreeResult(finding.File)) return;
        var path = Path.Combine(Model.RootPath, finding.File);
        var current = _editor.TextOf(path) ?? (File.Exists(path) ? await File.ReadAllTextAsync(path) : null);
        if (current is null) return;
        if (CoreApi.ApplyReviewSuggestion(current, finding.Line, suggestion.Original, suggestion.Replacement) is not { } updated)
        {
            await Dialogs.ShowMessage(_root.XamlRoot, L10n.Tr("ai.apply.notFound"), L10n.Tr("ai.apply.notFound.message"));
            return;
        }
        if (DebugOptions.Has("debug.aiApplyNow"))
        {
            WriteSuggestion(index, path, updated);
            return;
        }
        var preview = SuggestionPreview.Present(finding.File, finding.Title, current, updated, () => WriteSuggestion(index, path, updated));
        // 调试截图：截取预览窗口。
        if (DebugOptions.Has("debug.aiApply")) Snapshot.Schedule(preview);
    }

    private void WriteSuggestion(int index, string path, string text)
    {
        try
        {
            _editor.ApplyEdit(path, text);
            _aiReview.MarkApplied(index);
            Model.Refresh();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _statusBar.SetMessage(e.Message, true);
        }
    }

    public void RollbackChanges()
    {
        Show(ToolWindowId.Commit);
        _ = _commitWindow.RollbackSelected();
    }

    public void NewTag() => _ = _operations.NewTag(null);

    public void CreatePatch() => _ = _operations.CreatePatch([]);

    public void ApplyPatch() => _ = _operations.ApplyPatch();

    public void ManageRemotes() => Present(new RemotesDialog(Model, _operations));

    public void ManageSubmodules() => Present(new SubmodulesDialog(Model, _operations));

    private void Present(Window dialog)
    {
        dialog.Activate();
        // 调试截图：管理窗口是独立窗口，截取该窗口。
        if (DebugOptions.Get("debug.action") is "remotes" or "submodules") Snapshot.Schedule(dialog);
    }

    public void NewWorktree()
    {
        Show(ToolWindowId.Git);
        _gitWindow.ShowWorktrees();
        _ = _operations.NewWorktree();
    }

    public void ShowGitConsole()
    {
        Show(ToolWindowId.Git);
        _gitWindow.ShowConsole();
    }

    /// IDEA 的 “Unstash Changes”：打开提交工具窗口的储藏标签。
    public void UnstashChanges()
    {
        Show(ToolWindowId.Commit);
        _commitWindow.ShowStashTab();
    }

    public void ShelveChanges() => _commitWindow.ShelveSelected();

    public void ShowShelf()
    {
        Show(ToolWindowId.Commit);
        _commitWindow.ShowShelfTab();
    }

    /// 储藏中的文件：已跟踪文件相对储藏时的 HEAD，未跟踪文件与空内容比较。
    public void ShowStashFile(StashEntry stash, ChangedFile file)
    {
        var repository = Model.Repository;
        var revisions = CoreApi.StashRevisions(stash.Index, file.Kind == ChangeKind.Untracked);
        var basePath = file.OrigPath ?? file.Path;
        Task.Run(() =>
        {
            var baseText = revisions.Base is { } baseRevision && file.Kind != ChangeKind.Added ? TryRead(() => repository.FileAtRevision(baseRevision, basePath)) : null;
            var text = file.Kind == ChangeKind.Deleted ? null : TryRead(() => repository.FileAtRevision(revisions.Changed, file.Path));
            return (baseText, text);
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            var (baseText, text) = task.Result;
            _editor.OpenDiff($"stash:{stash.Hash}:{file.Path}", Path.GetFileName(file.Path), L10n.Tr("diff.tooltip.stash", file.Path, stash.Message), () => new DiffView(
                new DiffSide(L10n.Tr("diff.title.stashBase"), baseText),
                new DiffSide(L10n.Tr("diff.title.stash", stash.Message), text),
                file.Path));
        }), TaskScheduler.Default);
    }

    /// 搁置中的文件：搁置时的基准内容与搁置的改动。
    public void ShowShelfFile(ShelfEntry entry, string path)
    {
        var repository = Model.Repository;
        Task.Run(() => repository.ShelfFileVersions(entry.Id, path)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (task.IsFaulted) return;
            var versions = task.Result;
            _editor.OpenDiff($"shelf:{entry.Id}:{path}", Path.GetFileName(path), L10n.Tr("diff.tooltip.shelf", path, entry.Name), () => new DiffView(
                new DiffSide(L10n.Tr("diff.title.shelfBase"), versions.Base),
                new DiffSide(L10n.Tr("diff.title.shelved", entry.Name), versions.Text),
                path));
        }), TaskScheduler.Default);
    }

    public void ResolveConflicts() => _ = _conflicts.ShowConflicts();

    /// 历史提交中的文件：与第一个父提交比较（Log 详情中双击文件）。
    public void ShowCommitFile(string hash, string? parent, ChangedFile file)
    {
        var repository = Model.Repository;
        var basePath = file.OrigPath ?? file.Path;
        Task.Run(() =>
        {
            var baseText = parent is null || file.Kind == ChangeKind.Added ? null : TryRead(() => repository.FileAtRevision(parent, basePath));
            var text = file.Kind == ChangeKind.Deleted ? null : TryRead(() => repository.FileAtRevision(hash, file.Path));
            return (baseText, text);
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            var (baseText, text) = task.Result;
            var shortHash = hash[..Math.Min(8, hash.Length)];
            _editor.OpenDiff($"commit:{hash}:{file.Path}", Path.GetFileName(file.Path), L10n.Tr("diff.tooltip.commit", file.Path, shortHash), () => new DiffView(
                new DiffSide(parent is null ? L10n.Tr("diff.title.empty") : parent[..Math.Min(8, parent.Length)], baseText),
                new DiffSide(shortHash, text),
                file.Path));
        }), TaskScheduler.Default);
    }

    /// 某个修订（分支）中的文件与工作区文件比较（分支菜单的 Show Diff with Working Tree）。
    public void ShowRevisionAgainstWorkingTree(string revision, ChangedFile file)
    {
        var repository = Model.Repository;
        var root = Model.RootPath;
        var basePath = file.OrigPath ?? file.Path;
        Task.Run(() =>
        {
            var baseText = file.Kind == ChangeKind.Added ? null : TryRead(() => repository.FileAtRevision(revision, basePath));
            var text = file.Kind == ChangeKind.Deleted ? null : ReadWorkingFile(Path.Combine(root, file.Path));
            return (baseText, text);
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            var (baseText, text) = task.Result;
            _editor.OpenDiff($"revision:{revision}:{file.Path}", Path.GetFileName(file.Path), L10n.Tr("diff.tooltip.revision", file.Path, revision), () => new DiffView(
                new DiffSide(revision, baseText),
                new DiffSide(L10n.Tr("diff.title.local"), text),
                file.Path));
        }), TaskScheduler.Default);
    }

    private static string? TryRead(Func<string?> read)
    {
        try
        {
            return read();
        }
        catch (CoreException)
        {
            return null;
        }
    }

    public void ShowLocalDiff(FileChange change)
    {
        var repository = Model.Repository;
        var root = Model.RootPath;
        var basePath = change.OrigPath ?? change.Path;
        var headTitle = Model.Status.Branch.Oid is { } oid ? L10n.Tr("diff.title.head", oid[..Math.Min(8, oid.Length)]) : "HEAD";
        Task.Run(() =>
        {
            string? baseText;
            try
            {
                baseText = repository.FileAtRevision("HEAD", basePath);
            }
            catch (CoreException)
            {
                baseText = null;
            }
            var text = change.IsDeleted() ? null : ReadWorkingFile(Path.Combine(root, change.Path));
            return (baseText, text);
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            var (baseText, text) = task.Result;
            _editor.OpenDiff("local:" + change.Path, Path.GetFileName(change.Path), L10n.Tr("diff.tooltip.local", change.Path), () => new DiffView(
                new DiffSide(headTitle, baseText),
                new DiffSide(L10n.Tr("diff.title.local"), text),
                change.Path,
                change.Conflict is null ? new DiffInclusion(_lineSelections, change.Path) : null));
        }), TaskScheduler.Default);
    }

    /// 读取工作区文件；非 UTF-8 内容按有损方式解码，与核心读取历史版本的处理一致。
    private static string? ReadWorkingFile(string path)
    {
        try
        {
            return File.Exists(path) ? System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void SaveActive() => _editor.SaveActive();

    public void CloseActiveTab() => _ = _editor.CloseActive();

    public void ShowEditorFontDialog() => _ = EditorFontDialog.Show(_root.XamlRoot);

    // MARK: - 模型变化

    private void ModelChanged()
    {
        _vcsWidget.Title = Model.BranchWidgetTitle;
        _statusBar.SetBusy(Model.IsRefreshing || _operations.IsRunning);
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
                    case "commit": ShowCommit(); break;
                    case "log": Show(ToolWindowId.Git); break;
                    case "branches":
                        // 等加入的仓库加载完成（多仓库时显示带仓库选择的弹窗）。
                        var branchesTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
                        branchesTimer.Tick += (_, _) =>
                        {
                            branchesTimer.Stop();
                            ShowBranches();
                        };
                        branchesTimer.Start();
                        break;
                    case "push": PushAll(); break;
                    case "update": UpdateAll(); break;
                    case "addRepos":
                        // 等检测完成后加入检测到的仓库，再展开 Project 工具窗口。
                        Show(ToolWindowId.Project);
                        var addTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
                        addTimer.Tick += (_, _) =>
                        {
                            addTimer.Stop();
                            _workspace.Add([.. _workspace.Candidates.Select(c => c.Path)]);
                        };
                        addTimer.Start();
                        break;
                    case "checkoutBranch" when DebugOptions.Get("debug.branch") is { } syncBranch:
                        // 等加入的仓库加载后在主仓库签出 `-debug.branch`（验证同步分支控制）。
                        var syncTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
                        syncTimer.Tick += (_, _) =>
                        {
                            syncTimer.Stop();
                            _ = _operations.Checkout(GitOperations.TargetKind.Local, syncBranch);
                        };
                        syncTimer.Start();
                        break;
                    case "newBranch": _ = _operations.NewBranch(); break;
                    case "conflicts": ResolveConflicts(); break;
                    case "stash": StashChanges(); break;
                    case "remotes": ManageRemotes(); break;
                    case "submodules": ManageSubmodules(); break;
                    case "settings":
                        var settings = SettingsWindow.Show(Enum.TryParse<SettingsWindow.Page>(DebugOptions.Get("debug.page") ?? "", true, out var page) ? page : SettingsWindow.Page.General);
                        // `-debug.uiFont <字体>` 与 `-debug.uiFontSize <字号>`：验证界面字体立即生效（`-debug.uiFont off` 恢复默认）。
                        if (DebugOptions.Get("debug.uiFont") is { } uiFont)
                        {
                            UiFont.UseCustom = uiFont != "off";
                            if (uiFont != "off") UiFont.Family = uiFont;
                            if (DebugOptions.Get("debug.uiFontSize") is { } uiSize && double.TryParse(uiSize, out var uiValue)) UiFont.Size = uiValue;
                        }
                        Snapshot.Schedule(settings);
                        break;
                    case "aiReview":
                        Show(ToolWindowId.AiReview);
                        // `-debug.aiStart`：评审本地改动，完成后跳转到第一个发现并应用其建议（配合 `-debug.aiApplyNow` 直接写入）。
                        if (DebugOptions.Has("debug.aiStart"))
                        {
                            _ = _aiReview.Start(new ReviewScope.LocalChanges([]), L10n.Tr("ai.scope.local", Model.Status.Changes.Length), completion: result =>
                            {
                                if (result is not { Findings.Length: > 0 }) return;
                                var target = Math.Max(0, Array.FindIndex(result.Findings, f => f.Suggestion is not null));
                                OpenFinding(target);
                                if (DebugOptions.Has("debug.aiApply")) ApplySuggestion(target);
                            });
                        }
                        break;
                    case "console":
                        ShowGitConsole();
                        _gitWindow.Console.ShowBackgroundCommands();
                        break;
                    case "worktrees":
                        Show(ToolWindowId.Git);
                        _gitWindow.ShowWorktrees();
                        break;
                    case "newTag": NewTag(); break;
                    case "reset" when Model.Status.Branch.Oid is { } resetHead: _ = _operations.ResetDialog(resetHead, ""); break;
                    case "applyPatch" when DebugOptions.Get("debug.file") is { } patchFile: _ = _operations.ApplyPatchFile(patchFile); break;
                    case "cherryPick" when DebugOptions.Get("debug.hash") is { } pickHash: _ = _operations.CherryPick([pickHash]); break;
                    case "revert" when DebugOptions.Get("debug.hash") is { } revertHash: _ = _operations.Revert([revertHash]); break;
                    case "rebase" when DebugOptions.Get("debug.hash") is { } rebaseHash: _ = _operations.InteractiveRebase(rebaseHash); break;
                    case "shelve": ShelveChanges(); break;
                    case "stashes":
                        UnstashChanges();
                        _stashes.ExpandFirst();
                        break;
                    case "shelf":
                        ShowShelf();
                        var shelfTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
                        shelfTimer.Tick += (_, _) =>
                        {
                            shelfTimer.Stop();
                            _shelf.ExpandFirst();
                        };
                        shelfTimer.Start();
                        break;
                    case "history" when DebugOptions.Get("debug.file") is { } historyPath: ShowFileHistory(historyPath); break;
                    case "annotate" when DebugOptions.Get("debug.file") is { } annotatePath:
                        _editor.Open(Path.Combine(Model.RootPath, annotatePath));
                        var annotateTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
                        annotateTimer.Tick += (_, _) =>
                        {
                            annotateTimer.Stop();
                            ToggleAnnotations();
                        };
                        annotateTimer.Start();
                        break;
                    case "merge" when Model.Status.Changes.FirstOrDefault(c => c.Conflict is not null) is { } conflict:
                        _conflicts.OpenMerge(conflict);
                        break;
                    case "partialCommit" when DebugOptions.Get("debug.file") is { } partialPath
                                              && Model.ChangesByPath.TryGetValue(partialPath, out var partialChange):
                        // 打开 Diff（配合 -debug.excludeBlock 把某块移出提交），稍后以 -debug.message 提交。
                        ShowCommit();
                        ShowLocalDiff(partialChange);
                        var commitTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                        commitTimer.Tick += (_, _) =>
                        {
                            commitTimer.Stop();
                            _ = _commitWindow.DebugCommit(DebugOptions.Get("debug.message") ?? "debug commit");
                        };
                        commitTimer.Start();
                        break;
                    case "localDiff" when DebugOptions.Get("debug.file") is { } diffPath
                                          && Model.ChangesByPath.TryGetValue(diffPath, out var diffChange):
                        ShowCommit();
                        ShowLocalDiff(diffChange);
                        break;
                }
            };
            timer.Start();
        }
        if (action is "remotes" or "submodules" or "settings") return;
        if (action == "aiReview" && DebugOptions.Has("debug.aiApply") && !DebugOptions.Has("debug.aiApplyNow")) return;
        if (action == "merge")
        {
            // 合并窗口打开后截取该窗口。
            _conflicts.MergeOpened += window =>
            {
                window.Ready += () =>
                {
                    if (DebugOptions.Has("debug.mergeApplyNonConflicting"))
                    {
                        window.ApplyNonConflicting();
                        // `-debug.mergeUndo`：随后撤销一次，验证被撤销的块恢复为可应用。
                        if (DebugOptions.Has("debug.mergeUndo")) window.DebugUndo();
                    }
                    // `-debug.mergeResolve`：冲突块两侧都应用后写入结果，验证完整的解决流程。
                    if (DebugOptions.Has("debug.mergeResolve")) window.DebugResolve();
                };
                Snapshot.Schedule(window);
            };
            return;
        }
        Snapshot.Schedule(this);
    }
}
