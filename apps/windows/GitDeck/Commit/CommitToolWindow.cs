using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Diff;
using GitDeck.Project;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace GitDeck.Commit;

/// Commit 工具窗口（IDEA 非模态提交界面）：变更树 + 提交信息 + 提交按钮（与 mac 端 CommitToolWindow 一致）。
///
/// 变更树按 冲突 / 各 Changelist / 未跟踪文件 分组，复选框决定要提交的文件；在 Diff 中可只勾选部分改动（部分提交）。
/// 多仓库项目（同时显示多个仓库的改动）在 W8 中加入。
public sealed class CommitToolWindow : Grid
{
    private static readonly string DefaultChangelist = CoreApi.DefaultChangelistName();

    private readonly ProjectModel _model;
    private readonly LineSelectionStore _lineSelections;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Extended };
    private readonly TextBox _message = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        PlaceholderText = L10n.Tr("commit.message.placeholder"),
        BorderThickness = new Thickness(0),
        CornerRadius = new CornerRadius(0),
    };
    private readonly CheckBox _amend = new() { Content = L10n.Tr("commit.amend"), MinWidth = 0 };
    private readonly Button _commitButton = new() { Content = L10n.Tr("commit.button.commit"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
    // 面板较窄时优先截断 “提交并推送”，保证主按钮与 Amend 完整显示（与 mac 端一致）。
    private readonly Button _commitPushButton = new()
    {
        Content = new TextBlock { Text = L10n.Tr("commit.button.commitAndPush"), TextTrimming = TextTrimming.CharacterEllipsis },
        HorizontalAlignment = HorizontalAlignment.Left,
        MinWidth = 0,
    };
    private readonly IconButton _optionsButton = new(Icon.Gear, L10n.Tr("commit.options"), 26, 13);
    private readonly ProgressRing _spinner = new() { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
    private readonly Grid _commitContent = new();
    private readonly Grid _stashContent;
    private readonly Grid _shelfContent;
    private readonly List<Button> _tabButtons = [];

    private List<GroupRow> _groups = [];
    private readonly Dictionary<string, FileChange> _entries = [];
    /// 勾选要提交的文件。
    private readonly HashSet<string> _included = [];
    /// 已见过的路径；新出现的已跟踪变更默认勾选，未跟踪文件默认不勾选（与 IDEA 一致）。
    private HashSet<string> _known = [];
    private readonly HashSet<string> _collapsed = [];
    private Changelists? _changelists;
    private int _changelistLoad;

    // 提交选项（IDEA 提交区齿轮菜单中的 Sign-off 与 Run Git hooks），在会话内保留。
    private bool _signOff;
    private bool _runHooks = true;
    private bool _isCommitting;
    /// 勾选 Amend 时自动填入的上一次提交信息；取消勾选时若未被修改则清空。
    private string? _amendPrefill;
    /// 最近一次从 Changelist 说明自动填入的提交信息。
    private string? _autoMessage;

    public CommitToolWindow(ProjectModel model, LineSelectionStore lineSelections)
    {
        _model = model;
        _lineSelections = lineSelections;
        Themed.Background(this, "ToolWindowBackgroundBrush");
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Children.Add(BuildTabs());
        BuildCommitContent();
        _stashContent = Placeholder();
        _shelfContent = Placeholder();
        foreach (var content in new[] { _commitContent, _stashContent, _shelfContent })
        {
            SetRow(content, 1);
            Children.Add(content);
        }
        SelectTab(0);

        _model.Changed += StatusChanged;
        _lineSelections.Changed += () =>
        {
            Rebuild();
            UpdateCommitButtons();
        };
        StatusChanged();
    }

    /// 打开文件的本地 Diff（参数为变更）。
    public event Action<FileChange>? ShowDiff;

    /// 在编辑器中打开文件（完整路径）。
    public event Action<string>? OpenFile;

    /// “提交并推送” 成功提交后打开推送（W4 实现推送）。
    public event Action? PushAfterCommit;

    // MARK: - 布局

    private FrameworkElement BuildTabs()
    {
        var titles = new[] { "commit.tab.commit", "commit.tab.stash", "commit.tab.shelf" };
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < titles.Length; i++)
        {
            var index = i;
            var button = new Button { Content = L10n.Tr(titles[i]), Style = (Style)Application.Current.Resources["FlatButtonStyle"], Padding = new Thickness(8, 3, 8, 3) };
            button.Click += (_, _) => SelectTab(index);
            _tabButtons.Add(button);
            stack.Children.Add(button);
        }
        return stack;
    }

    private void SelectTab(int index)
    {
        _commitContent.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        _stashContent.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        _shelfContent.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        for (var i = 0; i < _tabButtons.Count; i++)
        {
            _tabButtons[i].FontWeight = i == index ? FontWeights.SemiBold : FontWeights.Normal;
            _tabButtons[i].Background = i == index ? Icons.ThemeBrush(_tabButtons[i], "SelectedStripeBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
    }

    /// 储藏与搁置在 W5 中实现。
    private static Grid Placeholder() => new()
    {
        Children =
        {
            new TextBlock
            {
                Text = L10n.Tr("common.notImplemented"),
                Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        },
    };

    private void BuildCommitContent()
    {
        var grid = _commitContent;
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 80 });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(140), MinHeight = 60 });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        grid.Children.Add(BuildToolbar());

        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        _list.ItemContainerStyle = RowStyle();
        _list.ContainerContentChanging += OnContainerContentChanging;
        _list.DoubleTapped += (_, e) => Activate(RowAt(e.OriginalSource) ?? SelectedRows.FirstOrDefault());
        _list.RightTapped += OnRightTapped;
        _list.KeyDown += OnListKey;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_list, L10n.Tr("commit.changes.accessibility"));
        SetRow(_list, 1);
        grid.Children.Add(_list);

        // 变更树与提交信息之间的分隔条可拖动，调整提交信息框的高度。
        var splitter = new Splitter(vertical: false);
        splitter.Dragged += delta =>
        {
            var row = grid.RowDefinitions[3];
            row.Height = new GridLength(Math.Clamp(row.ActualHeight - delta, 60, Math.Max(60, grid.ActualHeight - 160)));
        };
        SetRow(splitter, 2);
        grid.Children.Add(splitter);

        Themed.Background(_message, "EditorBackgroundBrush");
        _message.TextChanged += (_, _) => UpdateCommitButtons();
        _message.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && IsDown(VirtualKey.Control))
            {
                _ = Commit(pushAfter: false);
                e.Handled = true;
            }
        };
        SetRow(_message, 3);
        grid.Children.Add(_message);

        _commitButton.Click += (_, _) => _ = Commit(pushAfter: false);
        ToolTipService.SetToolTip(_commitButton, L10n.Tr("commit.button.commit.tooltip"));
        _commitPushButton.Click += (_, _) => _ = Commit(pushAfter: true);
        _amend.Click += (_, _) => AmendToggled();
        _optionsButton.Click += (_, _) => ShowOptions();
        var buttons = new Grid { Margin = new Thickness(10, 8, 10, 10), ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        foreach (var (element, column) in new (FrameworkElement, int)[] { (_commitButton, 0), (_commitPushButton, 1), (_spinner, 2), (_amend, 3), (_optionsButton, 4) })
        {
            element.VerticalAlignment = VerticalAlignment.Center;
            SetColumn(element, column);
            buttons.Children.Add(element);
        }
        SetRow(buttons, 4);
        grid.Children.Add(buttons);
    }

    private FrameworkElement BuildToolbar()
    {
        IconButton Button(Icon icon, string key, Action? action)
        {
            var button = new IconButton(icon, L10n.Tr(key), 26, 13) { IsEnabled = action is not null };
            if (action is not null) button.Click += (_, _) => action();
            return button;
        }
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(6, 0, 0, 2),
            Children =
            {
                Button(Icon.Refresh, "git.action.refresh", _model.Refresh),
                Button(Icon.Rollback, "commit.action.rollback", () => _ = RollbackSelected()),
                Button(Icon.Diff, "commit.action.showDiff", () => Activate(SelectedRows.FirstOrDefault())),
                // 搁置（W5）与 AI 评审（W7）在对应批次中启用。
                Button(Icon.Shelve, "commit.action.shelve", null),
                Button(Icon.Sparkles, "ai.action.reviewSelected", null),
                Button(Icon.ExpandAll, "tree.expandAll", () => { _collapsed.Clear(); Rebuild(); }),
                Button(Icon.CollapseAll, "tree.collapseAll", () => { foreach (var g in _groups) _collapsed.Add(g.Key); Rebuild(); }),
            },
        };
    }

    private static Style RowStyle()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 26.0));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 26.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(4, 0, 4, 0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        return style;
    }

    private static bool IsDown(VirtualKey key) =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    // MARK: - 数据

    /// 变更树的行：分组或文件。
    private abstract class Row;

    private sealed class GroupRow(string key, string title, bool bold, Changelist? changelist, bool isConflicts, bool isActive) : Row
    {
        public string Key { get; } = key;
        public string Title { get; } = title;
        public bool Bold { get; } = bold;
        public Changelist? Changelist { get; } = changelist;
        public bool IsConflicts { get; } = isConflicts;
        public bool IsActive { get; } = isActive;
        public List<FileChange> Files { get; } = [];
    }

    private sealed class FileRow(FileChange change, GroupRow group) : Row
    {
        public FileChange Change { get; } = change;
        public GroupRow Group { get; } = group;
    }

    private void StatusChanged()
    {
        if (_model.IsRefreshing) return;
        PrefillMergeMessage();
        _entries.Clear();
        foreach (var change in _model.Status.Changes.Where(c => !c.IsIgnored())) _entries[change.Path] = change;
        // 与 IDEA 一致：新出现的已跟踪改动只在活动 Changelist 中默认勾选。
        var current = _entries.Keys.ToHashSet();
        var active = ActiveChangelist;
        foreach (var change in _entries.Values)
        {
            if (_known.Contains(change.Path) || change.IsUntracked() || change.Conflict is not null) continue;
            if (ChangelistName(change.Path) == active) _included.Add(change.Path);
        }
        _included.IntersectWith(current);
        _known = current;
        Rebuild();
        LoadChangelists();
    }

    private string ActiveChangelist => _changelists?.Active ?? DefaultChangelist;

    private IReadOnlyList<Changelist> DisplayedChangelists =>
        _changelists is { Lists.Length: > 0 } state ? state.Lists : [new Changelist(DefaultChangelist, "", [])];

    /// 文件所在的 Changelist（未记录时为活动列表）。
    private string ChangelistName(string path) =>
        _changelists?.Lists.FirstOrDefault(l => l.Paths.Contains(path))?.Name ?? ActiveChangelist;

    private static string DisplayName(Changelist list) =>
        list.Name == DefaultChangelist ? L10n.Tr("commit.group.changes") : list.Name;

    /// 从核心加载 Changelist（会与工作区同步并保存），完成后重新分组。
    private void LoadChangelists()
    {
        var token = ++_changelistLoad;
        var repository = _model.Repository;
        Task.Run(repository.Changelists).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _changelistLoad || task.IsFaulted) return;
            if (_changelists is not null && SameChangelists(_changelists, task.Result)) return;
            _changelists = task.Result;
            Rebuild();
        }), TaskScheduler.Default);
    }

    private static bool SameChangelists(Changelists a, Changelists b) =>
        a.Active == b.Active && a.Lists.Length == b.Lists.Length
        && a.Lists.Zip(b.Lists).All(p => p.First.Name == p.Second.Name && p.First.Comment == p.Second.Comment && p.First.Paths.SequenceEqual(p.Second.Paths));

    /// 在仓库上执行 Changelist 操作，完成后重新分组。
    private void ChangelistAction(Func<Repository, Changelists> work)
    {
        var repository = _model.Repository;
        Task.Run(() => work(repository)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (task.Exception?.InnerException is { } error) _model.Post(L10n.Message(error), isError: true);
            else _changelists = task.Result;
            Rebuild();
        }), TaskScheduler.Default);
    }

    /// 按 Changelist 分组：冲突、各 Changelist、未跟踪文件；冲突与未跟踪分组为空时隐藏。
    private void Rebuild()
    {
        var conflicts = new GroupRow("conflicts", L10n.Tr("commit.group.conflicts"), true, null, true, false);
        var unversioned = new GroupRow("unversioned", L10n.Tr("commit.group.unversioned"), true, null, false, false);
        var active = ActiveChangelist;
        var lists = DisplayedChangelists
            .Select(l => new GroupRow("list:" + l.Name, DisplayName(l), l.Name == active, l, false, l.Name == active))
            .ToList();
        foreach (var change in _entries.Values)
        {
            if (change.Conflict is not null) conflicts.Files.Add(change);
            else if (change.IsUntracked()) unversioned.Files.Add(change);
            else (lists.FirstOrDefault(g => g.Changelist!.Name == ChangelistName(change.Path)) ?? lists[0]).Files.Add(change);
        }
        _groups = [.. new[] { conflicts }.Concat(lists).Append(unversioned).Where(g => g.Changelist is not null || g.Files.Count > 0)];
        var rows = new List<Row>();
        foreach (var group in _groups)
        {
            group.Files.Sort((a, b) => string.Compare(a.Path, b.Path, StringComparison.OrdinalIgnoreCase));
            rows.Add(group);
            if (_collapsed.Contains(group.Key)) continue;
            rows.AddRange(group.Files.Select(f => new FileRow(f, group)));
        }
        var selected = SelectedRows.Select(KeyOf).ToHashSet();
        _list.ItemsSource = rows;
        foreach (var row in rows.Where(r => selected.Contains(KeyOf(r)))) _list.SelectedItems.Add(row);
        ApplyChangelistComment();
        UpdateCommitButtons();
    }

    private static string KeyOf(Row row) => row switch
    {
        GroupRow group => "group:" + group.Key,
        FileRow file => "file:" + file.Change.Path,
        _ => "",
    };

    private IEnumerable<Row> SelectedRows => _list.SelectedItems.OfType<Row>();

    /// 选中的文件（选中分组时为其全部文件）。
    private List<FileChange> SelectedFiles()
    {
        var files = new List<FileChange>();
        foreach (var row in SelectedRows)
        {
            if (row is FileRow file) files.Add(file.Change);
            else if (row is GroupRow group) files.AddRange(group.Files);
        }
        return files.DistinctBy(f => f.Path).ToList();
    }

    // MARK: - 行

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not Row row) return;
        if (root.Children.Count == 0) root.Children.Add(new RowView(this));
        ((RowView)root.Children[0]).Bind(row);
        args.Handled = true;
    }

    private static Row? RowAt(object source)
    {
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element is RowView view) return view.Row;
        }
        return null;
    }

    private bool? CheckState(IReadOnlyCollection<FileChange> files)
    {
        var count = files.Count(f => _included.Contains(f.Path));
        return count == 0 ? false : count == files.Count ? true : null;
    }

    private void Toggle(Row row)
    {
        switch (row)
        {
            case GroupRow group:
                var on = CheckState(group.Files) != true;
                foreach (var file in group.Files.Where(f => f.Conflict is null))
                {
                    if (on) _included.Add(file.Path);
                    else _included.Remove(file.Path);
                }
                break;
            case FileRow { Change: var change }:
                if (_lineSelections.IsPartial(change.Path) && _included.Contains(change.Path))
                {
                    // 半选的文件再次点击：改为提交整个文件。
                    _lineSelections.Remove([change.Path]);
                    _included.Add(change.Path);
                }
                else if (!_included.Remove(change.Path))
                {
                    _included.Add(change.Path);
                }
                break;
        }
        Rebuild();
    }

    private void ToggleCollapsed(GroupRow group)
    {
        if (!_collapsed.Remove(group.Key)) _collapsed.Add(group.Key);
        Rebuild();
    }

    /// 双击：文件打开 Diff（冲突文件在 W5 打开合并工具），分组展开 / 收起。
    private void Activate(Row? row)
    {
        switch (row)
        {
            case GroupRow group: ToggleCollapsed(group); break;
            case FileRow { Change.Conflict: not null }: _model.Post(L10n.Tr("git.action.resolveConflicts").TrimEnd('…') + ": " + L10n.Tr("common.notImplemented")); break;
            case FileRow file: ShowDiff?.Invoke(file.Change); break;
        }
    }

    private void OnListKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Space when SelectedRows.FirstOrDefault() is { } row:
                Toggle(row);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                Activate(SelectedRows.FirstOrDefault());
                e.Handled = true;
                break;
        }
    }

    /// 一行：缩进 + 展开箭头（分组）+ 复选框 + 图标 + 名称 + 灰色附加信息。随行容器回收重复使用。
    private sealed class RowView : Grid
    {
        private readonly CommitToolWindow _owner;
        private readonly Grid _chevronArea = new() { Width = 16, Height = 16, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        private readonly FrameworkElement _chevron = Icons.Create(Icon.ChevronDown, 12);
        private readonly TriStateBox _check = new() { VerticalAlignment = VerticalAlignment.Center };
        private readonly FrameworkElement _fileIcon = Icons.Create(Icon.File, 14);
        private readonly TextBlock _name = new() { VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _detail = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        private string _brushKey = "PrimaryTextBrush";

        public RowView(CommitToolWindow owner)
        {
            _owner = owner;
            ColumnSpacing = 4;
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _chevron.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            _chevronArea.Children.Add(_chevron);
            _chevronArea.Tapped += (_, e) =>
            {
                if (Row is GroupRow group) _owner.ToggleCollapsed(group);
                e.Handled = true;
            };
            // 复选框的状态由数据决定：点击时只切换数据，再由重建刷新显示。
            _check.Toggled += () =>
            {
                if (Row is { } row) _owner.Toggle(row);
            };
            _detail.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
            var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _fileIcon, _name, _detail } };
            SetColumn(_check, 1);
            SetColumn(label, 2);
            Children.Add(_chevronArea);
            Children.Add(_check);
            Children.Add(label);
            ActualThemeChanged += (_, _) => _name.Foreground = Icons.ThemeBrush(_name, _brushKey);
        }

        public Row? Row { get; private set; }

        public void Bind(Row row)
        {
            Row = row;
            ToolTipService.SetToolTip(this, null);
            switch (row)
            {
                case GroupRow group:
                    Margin = new Thickness(0);
                    _chevronArea.Visibility = Visibility.Visible;
                    _chevron.RenderTransform = new RotateTransform { Angle = _owner._collapsed.Contains(group.Key) ? -90 : 0 };
                    SetCheck(_owner.CheckState(group.Files));
                    _check.Enabled = group.Files.Count > 0 && !group.IsConflicts;
                    _fileIcon.Visibility = Visibility.Collapsed;
                    _name.Text = group.Title;
                    _name.FontWeight = group.Bold ? FontWeights.SemiBold : FontWeights.Normal;
                    _name.TextDecorations = Windows.UI.Text.TextDecorations.None;
                    _detail.Text = group.Files.Count == 1 ? L10n.Tr("commit.group.oneFile") : L10n.Tr("commit.group.files", group.Files.Count);
                    SetColor("PrimaryTextBrush");
                    if (group.IsActive) ToolTipService.SetToolTip(this, L10n.Tr("changelist.active.tooltip"));
                    break;
                case FileRow { Change: var change }:
                    Margin = new Thickness(20, 0, 0, 0);
                    _chevronArea.Visibility = Visibility.Collapsed;
                    var partial = _owner._lineSelections.IsPartial(change.Path);
                    var included = _owner._included.Contains(change.Path);
                    SetCheck(included ? (partial ? null : true) : false);
                    _check.Enabled = change.Conflict is null;
                    _fileIcon.Visibility = Visibility.Visible;
                    _name.Text = Path.GetFileName(change.Path);
                    _name.FontWeight = FontWeights.Normal;
                    _name.TextDecorations = change.IsDeleted() ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None;
                    var directory = Path.GetDirectoryName(change.Path)?.Replace('\\', '/') ?? "";
                    _detail.Text = change.Conflict is { } conflict
                        ? string.Join("  ", new[] { directory, conflict.Title() }.Where(s => s.Length > 0))
                        : change.OrigPath is { } orig ? L10n.Tr("commit.renamedFrom", orig) : directory;
                    SetColor(change.BrushKey());
                    ToolTipService.SetToolTip(this, partial ? L10n.Tr("commit.partial.tooltip") : change.Path);
                    break;
            }
        }

        private void SetCheck(bool? value)
        {
            _check.State = value;
        }

        private void SetColor(string key)
        {
            _brushKey = key;
            _name.Foreground = Icons.ThemeBrush(_name, key);
        }
    }

    // MARK: - 右键菜单

    /// 右键菜单随点击的行变化：文件行可移到其他 Changelist，Changelist 行可编辑、设为活动或删除。
    private void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var row = RowAt(e.OriginalSource);
        if (row is null) return;
        // 右键点击的行不在选中范围内时只作用于该行。
        if (!_list.SelectedItems.Contains(row))
        {
            _list.SelectedItems.Clear();
            _list.SelectedItems.Add(row);
        }
        var menu = new MenuFlyout();
        MenuFlyoutItem Add(MenuFlyout target, string text, Action action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            target.Items.Add(item);
            return item;
        }
        var notImplemented = (string key) => (Action)(() => _model.Post(L10n.Tr(key).TrimEnd('…') + ": " + L10n.Tr("common.notImplemented")));

        if (row is GroupRow { Changelist: { } list } group)
        {
            Add(menu, L10n.Tr("changelist.new"), () => _ = NewChangelist());
            Add(menu, L10n.Tr("changelist.edit"), () => _ = EditChangelist(list));
            Add(menu, L10n.Tr("changelist.setActive"), () => SetActive(list.Name), enabled: !group.IsActive);
            Add(menu, L10n.Tr("changelist.delete"), () => DeleteChangelist(list.Name), enabled: DisplayedChangelists.Count > 1);
            menu.Items.Add(new MenuFlyoutSeparator());
            Add(menu, L10n.Tr("commit.action.rollback"), () => _ = RollbackSelected(), enabled: group.Files.Count > 0);
            Add(menu, L10n.Tr("commit.action.shelve"), notImplemented("commit.action.shelve"), enabled: false);
        }
        else
        {
            var file = row as FileRow;
            Add(menu, L10n.Tr("commit.action.showDiff"), () => Activate(row), enabled: file is not null);
            Add(menu, L10n.Tr("commit.action.jumpToSource"), JumpToSource, enabled: file is { Change: var c } && !c.IsDeleted());
            if (file is { Change: var change } && !change.IsUntracked() && change.Conflict is null)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                var move = new MenuFlyoutSubItem { Text = L10n.Tr("changelist.move") };
                var current = ChangelistName(change.Path);
                foreach (var target in DisplayedChangelists.Where(l => l.Name != current))
                {
                    var name = target.Name;
                    var item = new MenuFlyoutItem { Text = DisplayName(target) };
                    item.Click += (_, _) => Move(SelectedFiles(), name);
                    move.Items.Add(item);
                }
                if (move.Items.Count > 0) move.Items.Add(new MenuFlyoutSeparator());
                var newItem = new MenuFlyoutItem { Text = L10n.Tr("changelist.new") };
                newItem.Click += (_, _) => _ = MoveToNewChangelist();
                move.Items.Add(newItem);
                menu.Items.Add(move);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            // 以下操作在后续批次中启用：历史（W5）、搁置与储藏（W5）、补丁（W6）、冲突解决（W5）。
            Add(menu, L10n.Tr("git.action.showHistory"), notImplemented("git.action.showHistory"), enabled: false);
            Add(menu, L10n.Tr("commit.action.rollback"), () => _ = RollbackSelected());
            Add(menu, L10n.Tr("commit.action.shelve"), notImplemented("commit.action.shelve"), enabled: false);
            Add(menu, L10n.Tr("stash.action.stashSelected"), notImplemented("stash.action.stashSelected"), enabled: false);
            Add(menu, L10n.Tr("patch.menu.createSelected"), notImplemented("patch.menu.createSelected"), enabled: false);
            menu.Items.Add(new MenuFlyoutSeparator());
            Add(menu, L10n.Tr("git.action.resolveConflicts"), notImplemented("git.action.resolveConflicts"), enabled: false);
        }
        menu.ShowAt(_list, e.GetPosition(_list));
        e.Handled = true;
    }

    private void JumpToSource()
    {
        if (SelectedRows.OfType<FileRow>().FirstOrDefault() is { Change: var change } && !change.IsDeleted())
        {
            OpenFile?.Invoke(Path.Combine(_model.RootPath, change.Path));
        }
    }

    // MARK: - Changelist 操作

    private IReadOnlySet<string> ChangelistNames => DisplayedChangelists.Select(l => l.Name).ToHashSet();

    private async Task NewChangelist()
    {
        if (await ChangelistDialog.Show(XamlRoot, L10n.Tr("changelist.new.title"), L10n.Tr("changelist.new.confirm"), "", "", ChangelistNames) is not { } result) return;
        ChangelistAction(repo => repo.AddChangelist(result.Name, result.Comment, false));
    }

    private async Task EditChangelist(Changelist list)
    {
        var display = DisplayName(list);
        var existing = ChangelistNames.Except([list.Name, display]).ToHashSet();
        if (await ChangelistDialog.Show(XamlRoot, L10n.Tr("changelist.edit.title"), L10n.Tr("changelist.edit.confirm"), display, list.Comment, existing) is not { } result) return;
        // 默认列表保持存储名称不变，只更新说明（除非用户真的改了显示名称）。
        var stored = list.Name == DefaultChangelist && result.Name == display ? list.Name : result.Name;
        ChangelistAction(repo => repo.EditChangelist(list.Name, stored, result.Comment));
    }

    private void SetActive(string name) => ChangelistAction(repo => repo.SetActiveChangelist(name));

    private void DeleteChangelist(string name) => ChangelistAction(repo =>
    {
        var state = repo.Changelists();
        return state.Lists.Any(l => l.Name == name) && state.Lists.Length > 1 ? repo.RemoveChangelist(name) : state;
    });

    /// 把选中的文件移到列表中。
    private void Move(IReadOnlyList<FileChange> files, string name, string comment = "")
    {
        var paths = files.Where(f => !f.IsUntracked() && f.Conflict is null).Select(f => f.Path).ToArray();
        if (paths.Length == 0) return;
        ChangelistAction(repo =>
        {
            if (!repo.Changelists().Lists.Any(l => l.Name == name)) repo.AddChangelist(name, comment, false);
            return repo.MoveToChangelist(paths, name);
        });
    }

    private async Task MoveToNewChangelist()
    {
        var files = SelectedFiles();
        if (await ChangelistDialog.Show(XamlRoot, L10n.Tr("changelist.new.title"), L10n.Tr("changelist.new.confirm"), "", "", ChangelistNames) is not { } result) return;
        Move(files, result.Name, result.Comment);
    }

    /// IDEA 用 Changelist 的说明作为提交信息：勾选的文件都属于同一个有说明的列表、且提交信息为空
    /// （或仍是上次自动填入的说明）时，自动填入该说明。
    private void ApplyChangelistComment()
    {
        var chosen = _included.ToList();
        if (chosen.Count == 0) return;
        var owners = chosen.Select(ChangelistName).ToHashSet();
        var comment = owners.Count == 1 ? DisplayedChangelists.FirstOrDefault(l => owners.Contains(l.Name))?.Comment ?? "" : "";
        var current = _message.Text;
        if (!(current.Length == 0 || current == _autoMessage) || comment == current) return;
        _message.Text = comment;
        _autoMessage = comment.Length == 0 ? null : comment;
    }

    // MARK: - 回滚

    /// 回滚选中的文件（选中分组时为该组全部文件）；未选中时对话框中全选。
    private async Task RollbackSelected()
    {
        var changes = _model.Status.Changes.Where(c => !c.IsUntracked() && c.Conflict is null && !c.IsIgnored()).ToList();
        if (changes.Count == 0) return;
        var selected = SelectedFiles().Select(f => f.Path).ToHashSet();
        if (await RollbackDialog.Show(XamlRoot, changes, selected) is not { } result) return;
        var repository = _model.Repository;
        try
        {
            await Task.Run(() => repository.Rollback(result.Paths, result.DeleteAdded));
            _lineSelections.Remove(result.Paths);
            _model.Post(L10n.Tr("rollback.done", result.Paths.Length));
        }
        catch (CoreException error)
        {
            await Dialogs.ShowMessage(XamlRoot, L10n.Tr("rollback.failed"), L10n.Message(error));
        }
        _model.Refresh();
    }

    // MARK: - 提交

    /// 合并进行中且提交信息为空时，填入 git 准备好的合并提交信息（与 IDEA 一致）。
    private void PrefillMergeMessage()
    {
        if (_model.Status.State != RepositoryState.Merging || _message.Text.Length > 0 || _isCommitting) return;
        var repository = _model.Repository;
        Task.Run(repository.MergeMessage).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (!task.IsFaulted && task.Result is { } message && _message.Text.Length == 0) _message.Text = message;
        }), TaskScheduler.Default);
    }

    private void UpdateCommitButtons()
    {
        var hasMessage = _message.Text.Trim().Length > 0;
        var hasFiles = _included.Count > 0 || _amend.IsChecked == true;
        _commitButton.IsEnabled = hasMessage && hasFiles && !_isCommitting;
        _commitPushButton.IsEnabled = _commitButton.IsEnabled;
    }

    private void AmendToggled()
    {
        UpdateCommitButtons();
        if (_amend.IsChecked == true)
        {
            if (_message.Text.Trim().Length > 0) return;
            var repository = _model.Repository;
            Task.Run(repository.LastCommitMessage).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
            {
                if (task.IsFaulted || task.Result is not { } message || _amend.IsChecked != true || _message.Text.Length > 0) return;
                _message.Text = message;
                _amendPrefill = message;
            }), TaskScheduler.Default);
        }
        else if (_amendPrefill is { } prefill && _message.Text == prefill)
        {
            _message.Text = "";
            _amendPrefill = null;
        }
    }

    private void ShowOptions()
    {
        var signOff = new ToggleMenuFlyoutItem { Text = L10n.Tr("commit.option.signOff"), IsChecked = _signOff };
        signOff.Click += (_, _) => _signOff = !_signOff;
        var hooks = new ToggleMenuFlyoutItem { Text = L10n.Tr("commit.option.runHooks"), IsChecked = _runHooks };
        hooks.Click += (_, _) => _runHooks = !_runHooks;
        var menu = new MenuFlyout { Items = { signOff, hooks } };
        menu.ShowAt(_optionsButton, new FlyoutShowOptions { Placement = FlyoutPlacementMode.TopEdgeAlignedRight });
    }

    public void FocusMessage()
    {
        SelectTab(0);
        _message.Focus(FocusState.Programmatic);
    }

    /// 以指定提交信息提交勾选的文件（调试用，验证提交流程）。
    public Task DebugCommit(string message)
    {
        _message.Text = message;
        UpdateCommitButtons();
        return Commit(pushAfter: false);
    }

    private void SetCommitting(bool committing)
    {
        _isCommitting = committing;
        _spinner.IsActive = committing;
        _spinner.Visibility = committing ? Visibility.Visible : Visibility.Collapsed;
        UpdateCommitButtons();
    }

    /// 提交勾选的文件；部分提交的文件只提交选中的行。
    private async Task Commit(bool pushAfter)
    {
        if (!_commitButton.IsEnabled) return;
        var paths = _included.OrderBy(p => p, StringComparer.Ordinal).ToList();
        var message = _message.Text;
        var amend = _amend.IsChecked == true;
        var selections = paths.Select(p => (Path: p, Selection: _lineSelections.Get(p))).Where(s => s.Selection is not null).ToList();
        var repository = _model.Repository;
        var root = _model.RootPath;
        SetCommitting(true);
        try
        {
            var partial = new List<PartialFile>();
            if (selections.Count > 0)
            {
                // 部分提交：确认选择之后文件没有变化，再计算要提交的内容。
                var stale = await Task.Run(() => selections.Where(s =>
                {
                    var text = File.Exists(Path.Combine(root, s.Path)) ? File.ReadAllText(Path.Combine(root, s.Path)) : "";
                    string baseText;
                    try
                    {
                        baseText = repository.FileAtRevision("HEAD", s.Path) ?? "";
                    }
                    catch (CoreException)
                    {
                        baseText = "";
                    }
                    return text != s.Selection!.Text || baseText != s.Selection.Base;
                }).Select(s => s.Path).ToList());
                if (stale.Count > 0)
                {
                    _lineSelections.Remove(stale);
                    await Dialogs.ShowMessage(XamlRoot, L10n.Tr("commit.partial.stale"), L10n.Tr("commit.partial.stale.message", string.Join("\n", stale)));
                    return;
                }
                foreach (var (path, selection) in selections)
                {
                    var content = await Task.Run(() => selection!.Content);
                    if (content == selection!.Base) paths.Remove(path); // 文件的改动全部不提交。
                    else partial.Add(new PartialFile(path, content));
                }
                if (paths.Count == 0 && !amend)
                {
                    _model.Post(L10n.Tr("commit.partial.nothing"), isError: true);
                    return;
                }
            }

            var options = new CommitOptions(message, [.. paths], amend, _signOff, !_runHooks, null, [.. partial]);
            CommitResult result;
            try
            {
                result = await Task.Run(() => repository.Commit(options));
            }
            catch (CoreException error)
            {
                // 钩子输出等错误信息较长，用对话框完整展示。
                await Dialogs.ShowMessage(XamlRoot, L10n.Tr("commit.failed"), L10n.Message(error));
                _model.Post(L10n.Tr("commit.failed"), isError: true);
                return;
            }
            _lineSelections.Remove(_included.ToList());
            _message.Text = "";
            _amend.IsChecked = false;
            _amendPrefill = null;
            _autoMessage = null;
            _model.Post(result.FileCount == 1
                ? L10n.Tr("commit.done.one", result.Subject)
                : L10n.Tr("commit.done.many", result.FileCount, result.Subject));
            if (pushAfter) PushAfterCommit?.Invoke();
        }
        finally
        {
            SetCommitting(false);
            _model.Refresh();
        }
    }
}
