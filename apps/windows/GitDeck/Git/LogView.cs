using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace GitDeck.Git;

/// Git 工具窗口的 Log 标签页：筛选栏 + 提交图列表 + 提交详情，布局对齐 IDEA（与 mac 端 LogView 一致）。
/// 多仓库合并显示在 W8 中加入。
public sealed class LogView : Grid
{
    private const uint PageSize = 2000;
    private const double RowHeight = 24;
    private const double LaneWidth = 14;

    /// Date 筛选的预设范围（秒）。
    private static readonly (string Key, long? Seconds)[] DateRanges =
    [
        ("log.filter.date.all", null),
        ("log.filter.date.day", 86_400),
        ("log.filter.date.week", 7 * 86_400),
        ("log.filter.date.month", 30 * 86_400),
        ("log.filter.date.year", 365 * 86_400),
    ];

    private readonly ProjectModel _model;
    private readonly GitOperations _operations;
    private readonly TextBox _search = new() { PlaceholderText = L10n.Tr("log.filter.search"), Width = 200 };
    private readonly ComboBox _branch = new() { MinWidth = 0 };
    private readonly ComboBox _user = new() { MinWidth = 0 };
    private readonly ComboBox _date = new() { MinWidth = 0 };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Extended };
    private readonly CommitDetailsView _details = new();
    private readonly DispatcherTimer _searchDebounce = new() { Interval = TimeSpan.FromMilliseconds(300) };

    private LogCommit[] _commits = [];
    private bool _hasMore;
    private uint _maxCount = PageSize;
    private bool _isLoading;
    private bool _hasLoaded;
    private string? _pendingReveal;
    private int _loadGeneration;
    private int _detailsGeneration;
    private string? _lastSignature;
    private List<string> _knownAuthors = [];
    private bool _updatingFilters;

    public LogView(ProjectModel model, GitOperations operations)
    {
        _model = model;
        _operations = operations;
        BuildLayout();
        _details.OpenFile += path => OpenFile?.Invoke(System.IO.Path.Combine(_model.RootPath, path));
        _details.ShowDiff += (commit, file) => ShowCommitDiff?.Invoke(commit.Hash, commit.Parents.FirstOrDefault(), file);
        _model.Changed += ModelChanged;
        ModelChanged();
    }

    public event Action<string>? OpenFile;

    /// 打开历史提交中某个文件的 Diff：提交哈希、第一个父提交、文件。
    public event Action<string, string?, ChangedFile>? ShowCommitDiff;

    // MARK: - 布局

    private void BuildLayout()
    {
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        foreach (var (key, _) in DateRanges) _date.Items.Add(L10n.Tr(key));
        _date.SelectedIndex = 0;
        RebuildBranchFilter();
        RebuildUserFilter();
        foreach (var combo in new[] { _branch, _user, _date })
        {
            combo.SelectionChanged += (_, _) =>
            {
                if (!_updatingFilters) FilterChanged();
            };
        }
        _search.TextChanged += (_, _) =>
        {
            // 输入停顿后再查询，避免每个按键都触发 git log。
            _searchDebounce.Stop();
            _searchDebounce.Start();
        };
        _searchDebounce.Tick += (_, _) =>
        {
            _searchDebounce.Stop();
            FilterChanged();
        };
        var refresh = new IconButton(Icon.Refresh, L10n.Tr("git.action.refresh"), 26, 13);
        refresh.Click += (_, _) =>
        {
            _model.Refresh();
            Reload();
        };
        _status.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var filterBar = new Grid { Margin = new Thickness(8, 4, 10, 4), ColumnSpacing = 6 };
        filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        filterBar.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _search, _branch, _user, _date, refresh } });
        SetColumn(_status, 2);
        filterBar.Children.Add(_status);
        Children.Add(filterBar);

        var divider = Themed.Background(new Border(), "SeparatorBrush");
        SetRow(divider, 1);
        Children.Add(divider);

        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, RowHeight));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, RowHeight));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = style;
        _list.ContainerContentChanging += OnContainerContentChanging;
        _list.SelectionChanged += (_, _) => LoadDetails();
        _list.RightTapped += (_, e) =>
        {
            if (RowAt(e.OriginalSource) is { } commit && !_list.SelectedItems.Contains(commit))
            {
                _list.SelectedItems.Clear();
                _list.SelectedItems.Add(commit);
            }
            ContextMenu().ShowAt(_list, e.GetPosition(_list));
            e.Handled = true;
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_list, L10n.Tr("git.tab.log"));
        Themed.Background(_list, "EditorBackgroundBrush");

        var split = new Grid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 200 });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(360), MinWidth = 260 });
        var splitter = new Splitter(vertical: true);
        splitter.Dragged += delta =>
        {
            var column = split.ColumnDefinitions[2];
            column.Width = new GridLength(Math.Clamp(column.ActualWidth - delta, 260, Math.Max(260, split.ActualWidth - 260)));
        };
        SetColumn(splitter, 1);
        SetColumn(_details, 2);
        split.Children.Add(_list);
        split.Children.Add(splitter);
        split.Children.Add(_details);
        SetRow(split, 2);
        Children.Add(split);
    }

    // MARK: - 筛选

    private void RebuildBranchFilter()
    {
        _updatingFilters = true;
        var selected = (_branch.SelectedItem as ComboBoxItem)?.Tag as string;
        _branch.Items.Clear();
        _branch.Items.Add(new ComboBoxItem { Content = L10n.Tr("log.filter.branch.all") });
        foreach (var (kind, title) in new[] { (BranchKind.Local, L10n.Tr("branches.section.local")), (BranchKind.Remote, L10n.Tr("branches.section.remote")) })
        {
            var branches = _model.Branches.Where(b => b.Kind == kind).ToList();
            if (branches.Count == 0) continue;
            _branch.Items.Add(new ComboBoxItem { Content = title, IsEnabled = false, FontWeight = FontWeights.SemiBold });
            foreach (var branch in branches)
            {
                _branch.Items.Add(new ComboBoxItem { Content = L10n.Tr("log.filter.branch.value", branch.Name), Tag = branch.FullRef });
            }
        }
        _branch.SelectedItem = _branch.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag as string == selected && selected is not null) ?? _branch.Items[0];
        _updatingFilters = false;
    }

    private void RebuildUserFilter()
    {
        _updatingFilters = true;
        var selected = (_user.SelectedItem as ComboBoxItem)?.Tag as string;
        _user.Items.Clear();
        _user.Items.Add(new ComboBoxItem { Content = L10n.Tr("log.filter.user.all") });
        foreach (var author in _knownAuthors) _user.Items.Add(new ComboBoxItem { Content = L10n.Tr("log.filter.user.value", author), Tag = author });
        _user.SelectedItem = _user.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag as string == selected && selected is not null) ?? _user.Items[0];
        _updatingFilters = false;
    }

    private LogFilter CurrentFilter
    {
        get
        {
            var text = _search.Text.Trim();
            var range = DateRanges[Math.Max(0, _date.SelectedIndex)].Seconds;
            return new LogFilter(
                (_branch.SelectedItem as ComboBoxItem)?.Tag is string branch ? [branch] : [],
                (_user.SelectedItem as ComboBoxItem)?.Tag is string author ? [author] : [],
                range is { } seconds ? DateTimeOffset.UtcNow.ToUnixTimeSeconds() - seconds : null,
                null,
                [],
                text.Length == 0 ? null : text,
                LogOrder.Topological,
                _maxCount);
        }
    }

    private bool IsFiltered => CurrentFilter is var f && (f.Revisions.Length > 0 || f.Authors.Length > 0 || f.Since is not null || f.Text is not null);

    private void FilterChanged()
    {
        _maxCount = PageSize;
        Reload();
    }

    // MARK: - 加载

    private void ModelChanged()
    {
        if (_model.IsRefreshing) return;
        var signature = _model.RefsSignature;
        if (signature == _lastSignature) return;
        _lastSignature = signature;
        RebuildBranchFilter();
        Reload();
    }

    private void Reload()
    {
        var generation = ++_loadGeneration;
        var filter = CurrentFilter;
        var filtered = IsFiltered;
        var repository = _model.Repository;
        _isLoading = true;
        _status.Text = L10n.Tr("log.loading");
        Task.Run(() => repository.Log(filter)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _loadGeneration) return;
            _isLoading = false;
            if (task.Exception?.InnerException is { } error)
            {
                _commits = [];
                _list.ItemsSource = null;
                _status.Text = L10n.Message(error);
                return;
            }
            var page = task.Result;
            var selectedHash = SelectedCommits.FirstOrDefault()?.Hash;
            _commits = page.Commits;
            _hasMore = page.HasMore;
            if (!filtered) CollectAuthors();
            _list.ItemsSource = _commits;
            // 保持原有选中；首次加载时选中 HEAD 所在提交（与 IDEA 一致）。
            var target = _pendingReveal ?? selectedHash ?? (_hasLoaded ? null : _model.Status.Branch.Oid);
            _pendingReveal = null;
            // 状态尚未加载（还不知道 HEAD）时，下次加载仍尝试选中 HEAD。
            _hasLoaded = _hasLoaded || _model.Status.Branch.Oid is not null;
            if (target is not null && _commits.FirstOrDefault(c => c.Hash == target) is { } commit)
            {
                _list.SelectedItem = commit;
                _list.ScrollIntoView(commit);
            }
            else
            {
                _details.Show(null);
            }
            _status.Text = page.HasMore ? L10n.Tr("log.count.more", page.Commits.Length) : L10n.Tr("log.count", page.Commits.Length);
        }), TaskScheduler.Default);
    }

    /// 从未筛选的结果中收集作者，按提交数排序，供 User 筛选使用。
    private void CollectAuthors()
    {
        _knownAuthors = _commits.GroupBy(c => c.AuthorName)
            .OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal)
            .Take(50).Select(g => g.Key).ToList();
        RebuildUserFilter();
    }

    private void LoadMoreIfNeeded(int index)
    {
        if (!_hasMore || _isLoading || index < _commits.Length - 50) return;
        _maxCount += PageSize;
        Reload();
    }

    private IEnumerable<LogCommit> SelectedCommits => _list.SelectedItems.OfType<LogCommit>();

    private void LoadDetails()
    {
        var generation = ++_detailsGeneration;
        if (_list.SelectedItems.Count != 1 || _list.SelectedItem is not LogCommit commit)
        {
            _details.Show(null);
            return;
        }
        var repository = _model.Repository;
        var hash = commit.Hash;
        Task.Run(() => repository.CommitDetails(hash)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _detailsGeneration || task.IsFaulted) return;
            var details = task.Result;
            _details.Show(details);
            // 查询所在分支较慢，详情先显示，分支信息随后补上。
            Task.Run(() => repository.BranchesContaining(hash)).ContinueWith(branches => DispatcherQueue.TryEnqueue(() =>
            {
                if (generation == _detailsGeneration && !branches.IsFaulted) _details.Show(details, branches.Result);
            }), TaskScheduler.Default);
        }), TaskScheduler.Default);
    }

    /// 选中并滚动到某个提交；当前筛选条件下不可见时清空筛选后重新加载。
    public void Reveal(string hash)
    {
        if (_commits.FirstOrDefault(c => c.Hash == hash) is { } commit)
        {
            _list.SelectedItem = commit;
            _list.ScrollIntoView(commit);
            return;
        }
        _updatingFilters = true;
        _search.Text = "";
        _branch.SelectedIndex = 0;
        _user.SelectedIndex = 0;
        _date.SelectedIndex = 0;
        _updatingFilters = false;
        _pendingReveal = hash;
        FilterChanged();
    }

    // MARK: - 右键菜单

    private MenuFlyout ContextMenu()
    {
        var targets = SelectedCommits.ToList();
        var single = targets.Count == 1 ? targets[0] : null;
        var menu = new MenuFlyout();
        void Add(string key, Action? action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = L10n.Tr(key), IsEnabled = enabled && action is not null && !_operations.IsRunning };
            if (action is not null) item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("log.menu.copyHash", () =>
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(string.Join("\n", targets.Select(c => c.Hash)));
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        }, targets.Count > 0);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("log.menu.checkout", () => _ = _operations.Checkout(GitOperations.TargetKind.Revision, single!.Hash), single is not null);
        Add("log.menu.newBranch", () => _ = _operations.NewBranch(single!.Hash), single is not null);
        Add("log.menu.newTag", () => _ = _operations.NewTag(single!.Hash), single is not null);
        menu.Items.Add(new MenuFlyoutSeparator());
        // 补丁按从旧到新排列。
        Add("log.menu.createPatch", () => _ = _operations.CreatePatchFromCommits([.. Enumerable.Reverse(targets).Select(c => c.Hash)]), targets.Count > 0);
        // AI 评审在 W7 中启用。
        Add("log.menu.aiReview", null);
        menu.Items.Add(new MenuFlyoutSeparator());
        // 拣选按从旧到新应用；还原按从新到旧进行，与 IDEA 一致。
        Add("log.menu.cherryPick", () => _ = _operations.CherryPick([.. Enumerable.Reverse(targets).Select(c => c.Hash)]), targets.Count > 0);
        Add("log.menu.revert", () => _ = _operations.Revert([.. targets.Select(c => c.Hash)]), targets.Count > 0);
        Add("log.menu.reset", () => _ = _operations.ResetDialog(single!.Hash, single.Subject), single is not null);
        menu.Items.Add(new MenuFlyoutSeparator());
        // 与 IDEA 一致：只能撤销当前分支的最新提交；改写历史只适用于当前分支上的提交。
        var head = _model.Status.Branch.Oid;
        bool OnCurrentBranch(LogCommit commit)
        {
            try
            {
                return _model.Repository.IsAncestor(commit.Hash, "HEAD");
            }
            catch (CoreException)
            {
                return false;
            }
        }
        var singleOnBranch = single is not null && OnCurrentBranch(single);
        Add("log.menu.undoCommit", () => _ = _operations.UndoCommit(single!.Hash), single is not null && single.Hash == head);
        Add("log.menu.editMessage", () => _ = EditMessage(single!), singleOnBranch);
        Add("log.menu.drop", () => _ = _operations.DropCommits([.. targets.Select(c => c.Hash)]), targets.Count > 0 && targets.All(OnCurrentBranch));
        Add("log.menu.interactiveRebase", () => _ = _operations.InteractiveRebase(single!.Hash), singleOnBranch);
        return menu;
    }

    private async Task EditMessage(LogCommit commit)
    {
        var repository = _model.Repository;
        string? message = null;
        try
        {
            message = (await Task.Run(() => repository.CommitDetails(commit.Hash))).Message;
        }
        catch (CoreException)
        {
        }
        await _operations.EditMessage(commit.Hash, message ?? commit.Subject);
    }

    // MARK: - 行

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not LogCommit commit) return;
        if (root.Children.Count == 0) root.Children.Add(new LogRow());
        ((LogRow)root.Children[0]).Bind(commit, commit.Hash == _model.Status.Branch.Oid);
        LoadMoreIfNeeded(args.ItemIndex);
        args.Handled = true;
    }

    private static LogCommit? RowAt(object source)
    {
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element is LogRow row) return row.Commit;
        }
        return null;
    }

    /// 一行：提交图 + 引用标签 + 标题 | 作者 | 日期。随行容器回收重复使用。
    private sealed class LogRow : Grid
    {
        private readonly Canvas _graph = new() { Height = RowHeight, VerticalAlignment = VerticalAlignment.Center };
        private readonly StackPanel _refs = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _subject = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        private readonly TextBlock _author = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(6, 0, 6, 0) };
        private readonly TextBlock _date = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(6, 0, 6, 0) };

        public LogRow()
        {
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            var subject = new Grid();
            subject.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            subject.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            subject.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetColumn(_refs, 1);
            SetColumn(_subject, 2);
            _subject.Margin = new Thickness(6, 0, 4, 0);
            subject.Children.Add(_graph);
            subject.Children.Add(_refs);
            subject.Children.Add(_subject);
            Themed.Foreground(_subject, "PrimaryTextBrush");
            Themed.Foreground(_author, "SecondaryTextBrush");
            Themed.Foreground(_date, "SecondaryTextBrush");
            SetColumn(_author, 1);
            SetColumn(_date, 2);
            Children.Add(subject);
            Children.Add(_author);
            Children.Add(_date);
            ActualThemeChanged += (_, _) =>
            {
                if (Commit is { } commit) BuildRefs(commit);
            };
        }

        public LogCommit? Commit { get; private set; }

        public void Bind(LogCommit commit, bool isHead)
        {
            Commit = commit;
            DrawGraph(commit.Graph);
            BuildRefs(commit);
            _subject.Text = commit.Subject;
            // 当前 HEAD 所在提交标题加粗，与 IDEA 一致。
            _subject.FontWeight = isHead ? FontWeights.SemiBold : FontWeights.Normal;
            _author.Text = commit.AuthorName;
            _date.Text = LogDates.Short(commit.AuthorTime);
            ToolTipService.SetToolTip(_subject, commit.Subject);
            ToolTipService.SetToolTip(_author, $"{commit.AuthorName} <{commit.AuthorEmail}>");
            ToolTipService.SetToolTip(_date, LogDates.Detailed(commit.AuthorTime));
        }

        private void DrawGraph(GraphRow graph)
        {
            _graph.Children.Clear();
            _graph.Width = graph.Width * LaneWidth + 8;
            const double h = RowHeight;
            static double X(uint lane) => lane * LaneWidth + LaneWidth / 2 + 4;
            foreach (var edge in graph.Edges)
            {
                var (y1, y2) = edge.Part switch
                {
                    EdgePart.Top => (0.0, h / 2),
                    EdgePart.Bottom => (h / 2, h),
                    _ => (0.0, h),
                };
                _graph.Children.Add(new Line
                {
                    X1 = X(edge.FromLane),
                    Y1 = y1,
                    X2 = X(edge.ToLane),
                    Y2 = y2,
                    Stroke = new SolidColorBrush(GraphPalette.Color(edge.Color)),
                    StrokeThickness = 1.6,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                });
            }
            const double r = 3.5;
            var node = new Ellipse { Width = r * 2, Height = r * 2, Fill = new SolidColorBrush(GraphPalette.Color(graph.Color)) };
            Canvas.SetLeft(node, X(graph.Lane) - r);
            Canvas.SetTop(node, h / 2 - r);
            _graph.Children.Add(node);
        }

        private void BuildRefs(LogCommit commit)
        {
            _refs.Children.Clear();
            var dark = ActualTheme == ElementTheme.Dark;
            foreach (var label in commit.Refs)
            {
                _refs.Children.Add(new Border
                {
                    Height = 16,
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(6, 0, 6, 0),
                    Background = new SolidColorBrush(RefStyle.Background(label.Kind, dark)),
                    Child = new TextBlock
                    {
                        Text = label.Name,
                        FontSize = 11,
                        FontWeight = label.IsCurrent ? FontWeights.SemiBold : FontWeights.Normal,
                        VerticalAlignment = VerticalAlignment.Center,
                        Foreground = Icons.ThemeBrush(this, "PrimaryTextBrush"),
                    },
                });
            }
        }
    }
}
