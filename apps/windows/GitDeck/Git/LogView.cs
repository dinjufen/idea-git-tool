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
/// 多仓库项目中可显示全部仓库（按时间合并、行首色条标识仓库）或只显示其中一个（与 mac 端一致）。
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

    /// 当前显示的仓库（显示全部仓库时为主仓库，用于分支筛选等）。
    private ProjectModel _model;
    private readonly ProjectModel _primary;
    private readonly GitOperations _operations;
    private readonly ComboBox _repository = new() { MinWidth = 0, Visibility = Visibility.Collapsed };
    private Workspace? _workspace;
    /// 显示全部仓库的提交。
    private bool _showsAll;
    /// 提交所属的仓库（合并显示时使用）。
    private Dictionary<LogCommit, ProjectModel> _owners = new(ReferenceEqualityComparer.Instance);
    private bool _updatingRepositories;
    private readonly TextBox _search = new() { PlaceholderText = L10n.Tr("log.filter.search"), Width = 200 };
    private readonly ComboBox _branch = new() { MinWidth = 0 };
    private readonly ComboBox _user = new() { MinWidth = 0 };
    private readonly ComboBox _date = new() { MinWidth = 0 };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Extended };
    private readonly CommitDetailsView _details = new();
    private readonly BranchesPane _branchesPane = new();
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
        _primary = model;
        _operations = operations;
        BuildLayout();
        _details.OpenFile += path => OpenFile?.Invoke(System.IO.Path.Combine(SelectedOwner.RootPath, path));
        _details.ShowDiff += (commit, file) => ShowCommitDiff?.Invoke(commit.Hash, commit.Parents.FirstOrDefault(), file, SelectedOwner);
        _model.Changed += ModelChanged;
        ModelChanged();
    }

    public event Action<string>? OpenFile;

    /// 打开历史提交中某个文件的 Diff：提交哈希、第一个父提交、文件、提交所在的仓库。
    public event Action<string, string?, ChangedFile, ProjectModel>? ShowCommitDiff;

    /// AI 评审某个分支相对当前分支的改动（左侧分支面板的右键菜单）。
    public Func<ProjectModel, string, Task>? ReviewBranch
    {
        get => _branchesPane.ReviewBranch;
        set => _branchesPane.ReviewBranch = value;
    }

    /// 多仓库：取得某个仓库的操作对象（右键菜单作用于提交所在的仓库）。
    public Func<ProjectModel, GitOperations>? OperationsFor { get; set; }

    /// 多仓库项目：Log 可以显示全部仓库或只显示其中一个。
    public Workspace? Workspace
    {
        get => _workspace;
        set
        {
            if (_workspace is not null) _workspace.Changed -= WorkspaceChanged;
            else _model.Changed -= ModelChanged;
            _workspace = value;
            if (value is not null) value.Changed += WorkspaceChanged;
            else _model.Changed += ModelChanged;
            WorkspaceChanged();
        }
    }

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
        _repository.SelectionChanged += (_, _) =>
        {
            if (!_updatingRepositories) RepositoryChanged();
        };
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
            if (_workspace is not null) _workspace.RefreshAll();
            else _model.Refresh();
            Reload();
        };
        _status.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var filterBar = new Grid { Margin = new Thickness(8, 4, 10, 4), ColumnSpacing = 6 };
        filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filterBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        filterBar.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _search, _repository, _branch, _user, _date, refresh } });
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

        // 左侧分支面板 | 分隔条 | 提交列表 | 分隔条 | 提交详情（与 IDEA 的 Log 标签页布局一致）。
        var split = new Grid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 200 });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(360), MinWidth = 260 });
        var paneSplitter = new Splitter(vertical: true);
        paneSplitter.Dragged += delta => _branchesPane.ContentWidth += delta;
        paneSplitter.Visibility = _branchesPane.IsCollapsed ? Visibility.Collapsed : Visibility.Visible;
        _branchesPane.CollapsedChanged += () => paneSplitter.Visibility = _branchesPane.IsCollapsed ? Visibility.Collapsed : Visibility.Visible;
        _branchesPane.FilterRequested += FilterBranch;
        _branchesPane.NavigateRequested += hash => Reveal(hash);
        var splitter = new Splitter(vertical: true);
        splitter.Dragged += delta =>
        {
            var column = split.ColumnDefinitions[4];
            column.Width = new GridLength(Math.Clamp(column.ActualWidth - delta, 260, Math.Max(260, split.ActualWidth - 260)));
        };
        SetColumn(paneSplitter, 1);
        SetColumn(_list, 2);
        SetColumn(splitter, 3);
        SetColumn(_details, 4);
        split.Children.Add(_branchesPane);
        split.Children.Add(paneSplitter);
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
        _branch.Items.Add(new ComboBoxItem { Content = L10n.Tr("log.filter.branch.value", "HEAD"), Tag = "HEAD" });
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

    /// 按分支筛选（左侧分支面板选中分支时）：`revision` 为完整引用名或 `HEAD`，null 表示不按分支筛选。
    public void FilterBranch(string? revision)
    {
        var item = _branch.Items.OfType<ComboBoxItem>().FirstOrDefault(i => revision is not null && i.Tag as string == revision) ?? _branch.Items[0];
        if (_branch.SelectedItem != item) _branch.SelectedItem = item;
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

    // MARK: - 仓库

    /// 仓库列表变化时重建仓库筛选；任一仓库的引用变化时重新加载。
    private void WorkspaceChanged()
    {
        if (_workspace is not { } workspace) return;
        _repository.Visibility = workspace.IsMultiRoot ? Visibility.Visible : Visibility.Collapsed;
        if (workspace.IsMultiRoot)
        {
            var names = workspace.Models.Select(workspace.DisplayName).ToList();
            var current = _repository.Items.OfType<ComboBoxItem>().Skip(1).Select(i => i.Tag as string).ToList();
            if (!names.SequenceEqual(current))
            {
                _updatingRepositories = true;
                _repository.Items.Clear();
                _repository.Items.Add(new ComboBoxItem { Content = L10n.Tr("log.filter.repo.all") });
                var dark = ActualTheme == ElementTheme.Dark;
                foreach (var repository in workspace.Models)
                {
                    _repository.Items.Add(new ComboBoxItem
                    {
                        Tag = workspace.DisplayName(repository),
                        Content = new StackPanel
                        {
                            Orientation = Orientation.Horizontal,
                            Spacing = 6,
                            Children =
                            {
                                new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2.5), VerticalAlignment = VerticalAlignment.Center, Background = new SolidColorBrush(workspace.Color(repository, dark)) },
                                new TextBlock { Text = workspace.DisplayName(repository), VerticalAlignment = VerticalAlignment.Center },
                            },
                        },
                    });
                }
                if (!workspace.Models.Contains(_model)) _model = workspace.Primary;
                _repository.SelectedIndex = _showsAll ? 0 : workspace.Models.ToList().IndexOf(_model) + 1;
                _updatingRepositories = false;
            }
        }
        else if (_showsAll || _model != workspace.Primary)
        {
            _showsAll = false;
            _model = workspace.Primary;
        }
        ModelChanged();
    }

    private void RepositoryChanged()
    {
        if (_workspace is not { } workspace) return;
        var index = _repository.SelectedIndex;
        _showsAll = index == 0;
        _model = index >= 1 && index - 1 < workspace.Models.Count ? workspace.Models[index - 1] : workspace.Primary;
        _lastSignature = null;
        _maxCount = PageSize;
        _hasLoaded = false;
        ModelChanged();
    }

    /// 显示全部仓库（多仓库项目中选择 “所有仓库”）。
    private bool IsCombined => _showsAll && _workspace is { IsMultiRoot: true };

    /// 调试：切换到 “所有仓库”。
    public void DebugShowAll()
    {
        if (_repository.Items.Count > 0) _repository.SelectedIndex = 0;
    }

    /// 提交所属的仓库。
    private ProjectModel Owner(LogCommit commit) => _owners.TryGetValue(commit, out var owner) ? owner : _model;

    /// 选中提交所在的仓库。
    private ProjectModel SelectedOwner => _list.SelectedItem is LogCommit commit ? Owner(commit) : _model;

    private GitOperations OperationsOf(ProjectModel repository) => OperationsFor?.Invoke(repository) ?? _operations;

    // MARK: - 加载

    private void ModelChanged()
    {
        var repositories = IsCombined ? _workspace!.Models.ToList() : [_model];
        if (repositories.Any(r => r.IsRefreshing)) return;
        var signature = (IsCombined ? "all\n" : "") + string.Join("\u001e", repositories.Select(r => r.RefsSignature));
        if (signature == _lastSignature) return;
        _lastSignature = signature;
        RebuildBranchFilter();
        _branchesPane.Update(_model, OperationsOf(_model));
        Reload();
    }

    private void Reload()
    {
        var generation = ++_loadGeneration;
        var filter = CurrentFilter;
        var filtered = IsFiltered;
        var combined = IsCombined;
        var sources = combined ? _workspace!.Models.ToList() : [_model];
        var repositories = sources.Select(s => s.Repository).ToList();
        _isLoading = true;
        _status.Text = L10n.Tr("log.loading");
        Task.Run(() =>
        {
            if (!combined) return new List<(int Index, LogPage Page)> { (0, repositories[0].Log(filter)) };
            // 合并显示：分支筛选只对含有该分支的仓库生效，其他仓库跳过。
            var pages = new List<(int Index, LogPage Page)>();
            for (var i = 0; i < repositories.Count; i++)
            {
                try
                {
                    pages.Add((i, repositories[i].Log(filter)));
                }
                catch (CoreException)
                {
                }
            }
            return pages;
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _loadGeneration) return;
            _isLoading = false;
            if (task.Exception?.InnerException is { } error)
            {
                _commits = [];
                _owners.Clear();
                _list.ItemsSource = null;
                _status.Text = L10n.Message(error);
                return;
            }
            var page = Merge(task.Result, sources, combined, (int)filter.MaxCount);
            var selectedHash = SelectedCommits.FirstOrDefault()?.Hash;
            _commits = page.Commits;
            _owners = page.Owners;
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

    /// 合并各仓库的日志：按提交时间从新到旧排列，提交图改为单个节点（不同仓库的分支线无法画在同一张图中）。
    private static (LogCommit[] Commits, Dictionary<LogCommit, ProjectModel> Owners, bool HasMore) Merge(
        List<(int Index, LogPage Page)> pages, List<ProjectModel> sources, bool combined, int limit)
    {
        var owners = new Dictionary<LogCommit, ProjectModel>(ReferenceEqualityComparer.Instance);
        if (!combined)
        {
            var page = pages[0].Page;
            foreach (var commit in page.Commits) owners[commit] = sources[0];
            return (page.Commits, owners, page.HasMore);
        }
        var rows = pages
            .SelectMany(p => p.Page.Commits.Select(c => (Commit: c with { Graph = new GraphRow(0, 0, [], 1) }, Owner: sources[p.Index])))
            .OrderByDescending(r => r.Commit.CommitterTime)
            .ToList();
        var hasMore = pages.Any(p => p.Page.HasMore) || rows.Count > limit;
        rows = [.. rows.Take(limit)];
        foreach (var (commit, owner) in rows) owners[commit] = owner;
        return ([.. rows.Select(r => r.Commit)], owners, hasMore);
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
        var repository = Owner(commit).Repository;
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
    /// 多仓库项目中 `repository` 为提交所在的仓库：当前显示的不是该仓库（也不是全部仓库）时切换过去。
    public void Reveal(string hash, ProjectModel? repository = null)
    {
        if (repository is not null && _workspace is { IsMultiRoot: true } workspace && !_showsAll && repository != _model
            && workspace.Models.Contains(repository))
        {
            _pendingReveal = hash;
            _repository.SelectedIndex = workspace.Models.ToList().IndexOf(repository) + 1;
            return;
        }
        if (_commits.FirstOrDefault(c => c.Hash == hash && (repository is null || Owner(c) == repository)) is { } commit)
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

    /// AI 评审（右键菜单中评审选中的提交）。
    public AI.AIReviewController? AiReview { get; set; }

    // MARK: - 右键菜单

    private MenuFlyout ContextMenu()
    {
        var targets = SelectedCommits.ToList();
        var single = targets.Count == 1 ? targets[0] : null;
        var menu = new MenuFlyout();
        // 右键菜单作用于提交所在的仓库；选中的提交跨多个仓库时只能复制哈希。
        var owners = targets.Select(Owner).Distinct().ToList();
        var owner = owners.Count == 1 ? owners[0] : owners.Count == 0 ? _model : null;
        var operations = owner is null ? null : OperationsOf(owner);
        void Add(string key, Action? action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = L10n.Tr(key), IsEnabled = enabled && action is not null && operations is { IsRunning: false } };
            if (action is not null) item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        var copy = new MenuFlyoutItem { Text = L10n.Tr("log.menu.copyHash"), IsEnabled = targets.Count > 0 };
        copy.Click += (_, _) =>
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(string.Join("\n", targets.Select(c => c.Hash)));
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        };
        menu.Items.Add(copy);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("log.menu.checkout", () => _ = operations!.Checkout(GitOperations.TargetKind.Revision, single!.Hash), single is not null);
        Add("log.menu.newBranch", () => _ = operations!.NewBranch(single!.Hash), single is not null);
        Add("log.menu.newTag", () => _ = operations!.NewTag(single!.Hash), single is not null);
        menu.Items.Add(new MenuFlyoutSeparator());
        // 补丁按从旧到新排列。
        Add("log.menu.createPatch", () => _ = operations!.CreatePatchFromCommits([.. Enumerable.Reverse(targets).Select(c => c.Hash)]), targets.Count > 0);
        // AI 评审选中的提交（按从旧到新传入），评审提交所在的仓库。
        Add("log.menu.aiReview", () => _ = AiReview?.ReviewCommits([.. Enumerable.Reverse(targets).Select(c => c.Hash)], single?.Subject, owner),
            targets.Count > 0 && AiReview is { IsRunning: false });
        menu.Items.Add(new MenuFlyoutSeparator());
        // 拣选按从旧到新应用；还原按从新到旧进行，与 IDEA 一致。
        Add("log.menu.cherryPick", () => _ = operations!.CherryPick([.. Enumerable.Reverse(targets).Select(c => c.Hash)]), targets.Count > 0);
        Add("log.menu.revert", () => _ = operations!.Revert([.. targets.Select(c => c.Hash)]), targets.Count > 0);
        Add("log.menu.reset", () => _ = operations!.ResetDialog(single!.Hash, single.Subject), single is not null);
        menu.Items.Add(new MenuFlyoutSeparator());
        // 与 IDEA 一致：只能撤销当前分支的最新提交；改写历史只适用于所在仓库当前分支上的提交。
        var head = owner?.Status.Branch.Oid;
        bool OnCurrentBranch(LogCommit commit)
        {
            if (owner is null) return false;
            try
            {
                return owner.Repository.IsAncestor(commit.Hash, "HEAD");
            }
            catch (CoreException)
            {
                return false;
            }
        }
        var singleOnBranch = single is not null && OnCurrentBranch(single);
        Add("log.menu.undoCommit", () => _ = operations!.UndoCommit(single!.Hash), single is not null && single.Hash == head);
        Add("log.menu.editMessage", () => _ = EditMessage(single!, owner!), singleOnBranch);
        Add("log.menu.drop", () => _ = operations!.DropCommits([.. targets.Select(c => c.Hash)]), targets.Count > 0 && targets.All(OnCurrentBranch));
        Add("log.menu.interactiveRebase", () => _ = operations!.InteractiveRebase(single!.Hash), singleOnBranch);
        return menu;
    }

    private async Task EditMessage(LogCommit commit, ProjectModel owner)
    {
        var repository = owner.Repository;
        string? message = null;
        try
        {
            message = (await Task.Run(() => repository.CommitDetails(commit.Hash))).Message;
        }
        catch (CoreException)
        {
        }
        await OperationsOf(owner).EditMessage(commit.Hash, message ?? commit.Subject);
    }

    // MARK: - 行

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not LogCommit commit) return;
        if (root.Children.Count == 0) root.Children.Add(new LogRow());
        // 合并显示时行首色条与节点使用所属仓库的标识色。
        var owner = Owner(commit);
        var stripe = IsCombined ? _workspace!.Color(owner, ActualTheme == ElementTheme.Dark) : (Windows.UI.Color?)null;
        ((LogRow)root.Children[0]).Bind(commit, commit.Hash == owner.Status.Branch.Oid, stripe);
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
        private readonly Border _stripe = new() { Width = 3, HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
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
            Children.Add(_stripe);
            ActualThemeChanged += (_, _) =>
            {
                if (Commit is { } commit) BuildRefs(commit);
            };
        }

        public LogCommit? Commit { get; private set; }

        public void Bind(LogCommit commit, bool isHead, Windows.UI.Color? stripe = null)
        {
            Commit = commit;
            _stripe.Visibility = stripe is null ? Visibility.Collapsed : Visibility.Visible;
            if (stripe is { } color) _stripe.Background = new SolidColorBrush(color);
            DrawGraph(commit.Graph, stripe);
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

        private void DrawGraph(GraphRow graph, Windows.UI.Color? stripe)
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
            var node = new Ellipse { Width = r * 2, Height = r * 2, Fill = new SolidColorBrush(stripe ?? GraphPalette.Color(graph.Color)) };
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
