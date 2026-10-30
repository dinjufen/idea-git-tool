using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Vcs;

/// VCS 分支组件弹出的 Branches 弹窗：搜索框、常用操作、本地分支、远程分支与标签（与 mac 端 BranchesPopover 一致）。
/// 多仓库项目中顶部可选择仓库（带标识色与当前分支）并开启同步分支控制（与 mac 端 RepositoryBranchesPopover 一致）。
public sealed class BranchesPopup
{
    private readonly Workspace _workspace;
    private readonly Func<ProjectModel, GitOperations> _operationsFor;
    private ProjectModel _model;
    private GitOperations _operations;
    private readonly Action _commit;
    private readonly ComboBox _repositories = new() { MinWidth = 220 };
    private readonly CheckBox _sync = new() { Content = L10n.Tr("workspace.sync"), MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid _header = new() { ColumnSpacing = 8 };
    private bool _loadingRepositories;
    // 弹窗限制在窗口内绘制（与 IDEA 一致），也便于调试截图。
    private readonly Flyout _flyout = new() { ShouldConstrainToRootBounds = true };
    private readonly TextBox _search = new() { PlaceholderText = L10n.Tr("branches.search.placeholder") };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    /// 列表的行（数据绑定、虚拟化：只为可见的行生成界面，分支很多时展开 / 收起也不会卡顿或整块重绘）。
    private readonly System.Collections.ObjectModel.ObservableCollection<Row> _rows = [];
    private HashSet<string> _favorites = [];
    private readonly Controls.IconButton _fetch = new(Common.Icon.Update, L10n.Tr("git.action.fetch"), 30, 14);
    /// 最近签出过的本地分支（“最近”分组），打开弹窗时在后台读取。
    private string[] _recent = [];
    private int _recentToken;

    public BranchesPopup(Workspace workspace, Func<ProjectModel, GitOperations> operationsFor, Action commit)
    {
        _workspace = workspace;
        _operationsFor = operationsFor;
        _model = workspace.Primary;
        _operations = operationsFor(_model);
        _commit = commit;
        var root = new Grid { Width = 400, Height = 480, RowSpacing = 8 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _header.Children.Add(_repositories);
        Grid.SetColumn(_sync, 1);
        _header.Children.Add(_sync);
        ToolTipService.SetToolTip(_sync, L10n.Tr("workspace.sync.tooltip"));
        _sync.Click += (_, _) => SyncBranchControl.IsEnabled = _sync.IsChecked == true;
        _repositories.SelectionChanged += (_, _) =>
        {
            if (_loadingRepositories || _repositories.SelectedIndex < 0) return;
            _model = _workspace.Models[_repositories.SelectedIndex];
            _operations = _operationsFor(_model);
            LoadRecent();
            Rebuild(full: true);
        };
        // 搜索框右侧的 Fetch 按钮（与 IDEA 分支弹窗一致），用于刷新传入 / 传出提示。
        var searchRow = new Grid { ColumnSpacing = 4 };
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_fetch, 1);
        searchRow.Children.Add(_search);
        searchRow.Children.Add(_fetch);
        _fetch.Click += (_, _) =>
        {
            _flyout.Hide();
            _ = _operations.Fetch();
        };
        Grid.SetRow(searchRow, 1);
        Grid.SetRow(_list, 2);
        root.Children.Add(_header);
        root.Children.Add(searchRow);
        root.Children.Add(_list);
        _list.ItemsSource = _rows;
        _list.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        var rowStyle = new Style(typeof(ListViewItem));
        rowStyle.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 28.0));
        rowStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = rowStyle;
        _list.ContainerContentChanging += (_, args) =>
        {
            if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid cell || args.Item is not Row row) return;
            Fill(args.ItemContainer, cell, row);
            args.Handled = true;
        };
        _flyout.Content = root;
        var presenter = new Style(typeof(FlyoutPresenter));
        presenter.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(8)));
        presenter.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, 480.0));
        _flyout.FlyoutPresenterStyle = presenter;
        _search.TextChanged += (_, _) => Rebuild();
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Down && _rows.Count > 0)
            {
                _list.Focus(FocusState.Keyboard);
                e.Handled = true;
            }
        };
        _list.ItemClick += (_, e) => Activate(e.ClickedItem as Row);
        _list.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Activate(_list.SelectedItem as Row);
            // 右方向键展开、左方向键收起（与文件树一致）。
            else if (e.Key is Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Left
                     && _list.SelectedItem is TreeRow { Node.IsExpandable: true } row
                     && (e.Key == Windows.System.VirtualKey.Right) != IsExpanded(row.Node.Key))
            {
                Toggle(row.Node.Key);
                e.Handled = true;
            }
        };
        _flyout.Opened += (_, _) => _search.Focus(FocusState.Programmatic);
    }

    /// AI 评审某个分支相对当前分支的改动（分支菜单）。
    public Func<ProjectModel, string, Task>? ReviewBranch { get; set; }

    /// 显示弹窗；多仓库项目中默认选中 `selected`（当前编辑的文件所在的仓库）。
    public void ShowAt(FrameworkElement anchor, ProjectModel? selected = null)
    {
        _model = selected is not null && _workspace.Models.Contains(selected) ? selected : _workspace.Primary;
        _operations = _operationsFor(_model);
        _header.Visibility = _workspace.IsMultiRoot ? Visibility.Visible : Visibility.Collapsed;
        if (_workspace.IsMultiRoot)
        {
            _loadingRepositories = true;
            _repositories.Items.Clear();
            var dark = anchor.ActualTheme == ElementTheme.Dark;
            foreach (var model in _workspace.Models)
            {
                _repositories.Items.Add(new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Children =
                    {
                        new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2.5), VerticalAlignment = VerticalAlignment.Center, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(_workspace.Color(model, dark)) },
                        new TextBlock { Text = $"{_workspace.DisplayName(model)}  —  {model.CurrentBranchTitle}", VerticalAlignment = VerticalAlignment.Center },
                    },
                });
            }
            _repositories.SelectedIndex = Math.Max(0, _workspace.Models.ToList().IndexOf(_model));
            _sync.IsChecked = SyncBranchControl.IsEnabled;
            _loadingRepositories = false;
        }
        _search.Text = "";
        _recent = [];
        LoadRecent();
        Rebuild(full: true);
        _flyout.ShowAt(anchor, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    /// 后台读取最近签出过的分支，读到后刷新列表。
    private void LoadRecent()
    {
        var token = ++_recentToken;
        var model = _model;
        var repository = model.Repository;
        Task.Run(() => repository.RecentBranches(5)).ContinueWith(task => _list.DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _recentToken || model != _model || task.IsFaulted) return;
            _recent = task.Result;
            Rebuild();
        }), TaskScheduler.Default);
    }

    private abstract record Row;

    private sealed record ActionRow(string Title, Common.Icon Icon, string? Shortcut, Func<Task> Run) : Row;

    /// 分支树中的一行：分组、文件夹、分支或标签（与 IDEA 分支弹窗一样可以展开、收起）。
    private sealed record TreeRow(BranchTreeNode Node, int Depth) : Row;

    /// 展开的分组与文件夹：默认展开“最近”和“本地”，远程、标签与文件夹收起（与 IDEA 一致）；在本次运行中保持。
    private static readonly HashSet<string> Expanded = ["recent", "local"];

    /// 收起的“最近”分组内的文件夹（这些文件夹默认展开，因为“最近”只列出少量分支）。
    private static readonly HashSet<string> CollapsedRecent = [];

    private static bool IsExpanded(string key) => key.StartsWith("recent/", StringComparison.Ordinal) ? !CollapsedRecent.Contains(key) : Expanded.Contains(key);

    private static readonly Windows.UI.Color Yellow = Editor.SyntaxTheme.Rgb(0xE2A93C);

    /// 重新生成行。`full` 为 true 时（打开弹窗、切换仓库）整体替换；否则只增删前后不同的部分，
    /// 展开 / 收起时其余的行保持不动（不闪烁、不跳动）。
    private void Rebuild(bool full = false)
    {
        var query = _search.Text.Trim();
        bool Matches(string name) => query.Length == 0 || name.Contains(query, StringComparison.OrdinalIgnoreCase);
        var rows = new List<Row>();
        void Add(Row row) => rows.Add(row);
        var ops = _operations;
        if (query.Length == 0)
        {
            // 合并 / 变基等进行中时，与 IDEA 一样在最上方提供继续与中止操作。
            switch (_model.Status.State)
            {
                case RepositoryState.Rebasing:
                    Add(new ActionRow(L10n.Tr("git.action.continueRebase"), Common.Icon.Refresh, null, ops.ContinueRebase));
                    Add(new ActionRow(L10n.Tr("git.action.abortRebase"), Common.Icon.Close, null, ops.AbortRebase));
                    break;
                case RepositoryState.Merging:
                    Add(new ActionRow(L10n.Tr("git.action.abortMerge"), Common.Icon.Close, null, ops.AbortMerge));
                    break;
                case RepositoryState.CherryPicking:
                    Add(new ActionRow(L10n.Tr("git.action.continueCherryPick"), Common.Icon.Refresh, null, ops.ContinueCherryPick));
                    Add(new ActionRow(L10n.Tr("git.action.abortCherryPick"), Common.Icon.Close, null, ops.AbortCherryPick));
                    break;
                case RepositoryState.Reverting:
                    Add(new ActionRow(L10n.Tr("git.action.continueRevert"), Common.Icon.Refresh, null, ops.ContinueRevert));
                    Add(new ActionRow(L10n.Tr("git.action.abortRevert"), Common.Icon.Close, null, ops.AbortRevert));
                    break;
            }
            Add(new ActionRow(L10n.Tr("git.action.update"), Common.Icon.Update, "Ctrl+T", ops.UpdateProject));
            Add(new ActionRow(L10n.Tr("git.action.commit"), Common.Icon.Commit, "Ctrl+K", () =>
            {
                _commit();
                return Task.CompletedTask;
            }));
            Add(new ActionRow(L10n.Tr("git.action.push"), Common.Icon.Push, "Ctrl+Shift+K", ops.Push));
            Add(new ActionRow(L10n.Tr("branches.action.new"), Common.Icon.Branch, "Ctrl+Alt+N", () => ops.NewBranch()));
            Add(new ActionRow(L10n.Tr("branches.action.checkoutRevision"), Common.Icon.Commit, null, ops.CheckoutRevisionDialog));
        }

        var favorites = BranchFavorites.Get(_model);
        var roots = new List<BranchTreeNode>();
        // “最近”分组：最近签出过的本地分支，同样按 `/` 分文件夹，保持签出顺序；搜索时只保留匹配项（与 IDEA 一致）。
        // 未搜索且只有当前分支时不显示。
        var recent = _recent.Select(name => _model.Branches.FirstOrDefault(b => b.Kind == BranchKind.Local && b.Name == name)).OfType<BranchRef>().ToList();
        if (query.Length == 0 ? recent.Count > 1 : recent.Any(b => Matches(b.Name)))
        {
            var group = new BranchTreeNode(BranchTreeNode.NodeKind.Group, L10n.Tr("branches.section.recent"), "recent");
            BranchTree.AddBranches(group, recent.Where(b => Matches(b.Name)), favorites, keepOrder: true);
            roots.Add(group);
        }
        foreach (var (kind, key, title) in new[] { (BranchKind.Local, "local", L10n.Tr("branches.section.local")), (BranchKind.Remote, "remote", L10n.Tr("branches.section.remote")) })
        {
            var group = new BranchTreeNode(BranchTreeNode.NodeKind.Group, title, key);
            BranchTree.AddBranches(group, _model.Branches.Where(b => b.Kind == kind && Matches(b.Name)), favorites);
            if (group.Children.Count > 0) roots.Add(group);
        }
        var tags = new BranchTreeNode(BranchTreeNode.NodeKind.Group, L10n.Tr("branches.section.tags"), "tags");
        BranchTree.AddTags(tags, _model.Tags.Where(t => Matches(t.Name)));
        if (tags.Children.Count > 0) roots.Add(tags);

        foreach (var (node, depth) in BranchTree.Flatten(roots, n => IsExpanded(n.Key), expandAll: query.Length > 0))
        {
            Add(new TreeRow(node, depth));
        }
        _favorites = favorites;
        if (full)
        {
            _rows.Clear();
            foreach (var row in rows) _rows.Add(row);
            return;
        }
        var prefix = 0;
        while (prefix < _rows.Count && prefix < rows.Count && RowKey(_rows[prefix]) == RowKey(rows[prefix])) prefix++;
        var suffix = 0;
        while (suffix < _rows.Count - prefix && suffix < rows.Count - prefix && RowKey(_rows[_rows.Count - 1 - suffix]) == RowKey(rows[rows.Count - 1 - suffix])) suffix++;
        for (var i = _rows.Count - suffix - 1; i >= prefix; i--) _rows.RemoveAt(i);
        for (var i = prefix; i < rows.Count - suffix; i++) _rows.Insert(i, rows[i]);
        // 保留下来的行（例如被展开 / 收起的那一行，箭头方向变了；搜索时的高亮）在原来的容器里重新填充。
        for (var i = 0; i < _rows.Count; i++)
        {
            if (_list.ContainerFromIndex(i) is ListViewItem { ContentTemplateRoot: Grid cell } container) Fill(container, cell, _rows[i]);
        }
    }

    private static string RowKey(Row row) => row switch
    {
        ActionRow action => "action:" + action.Title,
        TreeRow tree => tree.Node.Key + "@" + tree.Depth,
        _ => "",
    };

    /// 填充一行的界面（随行容器回收重复使用）。
    private void Fill(SelectorItem container, Grid cell, Row row)
    {
        cell.Children.Clear();
        cell.Children.Add(Build(row, _favorites));
        ToolTipService.SetToolTip(container, row is TreeRow { Node.Branch: { } branch } ? branch.Subject : null);
    }

    private FrameworkElement Build(Row row, ISet<string>? favorites)
    {
        var content = new Grid { ColumnSpacing = 8 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        var name = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var secondary = new TextBlock { Style = (Style)Application.Current.Resources["SecondaryTextStyle"], VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 };
        Grid.SetColumn(secondary, 2);
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { name } };
        Grid.SetColumn(label, 1);
        FrameworkElement leading;
        switch (row)
        {
            case ActionRow action:
                leading = Icons.Create(action.Icon, 14);
                name.Text = action.Title;
                secondary.Text = action.Shortcut ?? "";
                break;
            case TreeRow { Node: var node, Depth: var depth }:
            {
                // 缩进 + 展开箭头 + 图标，与编辑器的文件树一样。
                var chevronArea = new Grid { Width = 12, Height = 14 };
                if (node.IsExpandable)
                {
                    var chevron = Icons.Create(Common.Icon.ChevronDown, 11);
                    chevron.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
                    chevron.RenderTransform = new RotateTransform { Angle = IsExpanded(node.Key) || _search.Text.Trim().Length > 0 ? 0 : -90 };
                    chevronArea.Children.Add(chevron);
                }
                var yellow = new SolidColorBrush(Yellow);
                FrameworkElement? icon = node.Kind switch
                {
                    BranchTreeNode.NodeKind.Folder => Icons.Create(Common.Icon.Folder, 14),
                    BranchTreeNode.NodeKind.Branch when node.Branch!.IsCurrent => Icons.Create(Common.Icon.Tag, 14, yellow),
                    BranchTreeNode.NodeKind.Branch when favorites?.Contains(node.Branch!.FullRef) == true => Icons.Create(Common.Icon.Star, 14, yellow),
                    BranchTreeNode.NodeKind.Branch => Icons.Create(Common.Icon.Branch, 14),
                    BranchTreeNode.NodeKind.Tag => Icons.Create(Common.Icon.Tag, 14),
                    _ => null,
                };
                var lead = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(depth * 14, 0, 0, 0), Children = { chevronArea } };
                if (icon is not null) lead.Children.Add(icon);
                leading = lead;
                SetHighlighted(name, node.Title, node.Kind == BranchTreeNode.NodeKind.Group ? "" : _search.Text.Trim());
                name.FontWeight = node.Kind == BranchTreeNode.NodeKind.Group || node.Branch?.IsCurrent == true ? FontWeights.SemiBold : FontWeights.Normal;
                if (node.Branch is { } branch)
                {
                    secondary.Text = BranchDetail(branch);
                    if (branch.Kind == BranchKind.Local && (branch.Ahead > 0 || branch.Behind > 0))
                    {
                        // 本地分支名后的传入 / 传出箭头与数量（IDEA 分支弹窗中的小箭头）。
                        var indicator = new Controls.IncomingOutgoingIndicator(showCounts: true);
                        indicator.Set(branch.Ahead, branch.Behind);
                        label.Children.Add(indicator);
                    }
                }
                else if (node.Tag is { } tag)
                {
                    secondary.Text = tag.Message ?? tag.Target[..Math.Min(8, tag.Target.Length)];
                }
                if (node.Kind is BranchTreeNode.NodeKind.Branch or BranchTreeNode.NodeKind.Tag)
                {
                    // 分支与标签行右侧的 ›：点击展开操作子菜单（与 IDEA 一致）。
                    var arrow = Icons.Create(Common.Icon.ChevronRight, 12);
                    arrow.Opacity = 0.7;
                    arrow.VerticalAlignment = VerticalAlignment.Center;
                    Grid.SetColumn(arrow, 3);
                    content.Children.Add(arrow);
                }
                break;
            }
            default:
                return content;
        }
        content.Children.Add(leading);
        content.Children.Add(label);
        content.Children.Add(secondary);
        return content;
    }

    /// 显示文字并高亮其中与搜索内容匹配的部分（与 IDEA 一样以黄色底色标出）。
    private static void SetHighlighted(TextBlock block, string text, string query)
    {
        block.Text = text;
        block.TextHighlighters.Clear();
        if (query.Length == 0) return;
        var highlighter = new Microsoft.UI.Xaml.Documents.TextHighlighter
        {
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x90, 0xE2, 0xA9, 0x3C)),
        };
        for (var index = text.IndexOf(query, StringComparison.OrdinalIgnoreCase); index >= 0; index = text.IndexOf(query, index + query.Length, StringComparison.OrdinalIgnoreCase))
        {
            highlighter.Ranges.Add(new Microsoft.UI.Xaml.Documents.TextRange { StartIndex = index, Length = query.Length });
        }
        if (highlighter.Ranges.Count > 0) block.TextHighlighters.Add(highlighter);
    }

    private static string BranchDetail(BranchRef branch)
    {
        // 与 IDEA 一致只显示上游分支；领先 / 落后由分支名后的箭头表示（悬停显示提交数）。
        var parts = new List<string>();
        if (branch.Upstream is { } upstream) parts.Add(upstream);
        if (branch.UpstreamGone) parts.Add(L10n.Tr("branches.upstreamGone"));
        return string.Join("  ", parts);
    }

    private void Activate(Row? row)
    {
        FrameworkElement target = row is null ? _list : _list.ContainerFromItem(row) as FrameworkElement ?? _list;
        switch (row)
        {
            case ActionRow action:
                _flyout.Hide();
                _ = action.Run();
                break;
            case TreeRow { Node.IsExpandable: true } group:
                Toggle(group.Node.Key);
                break;
            case TreeRow { Node.Branch: { } branch }:
                BranchMenu(branch).ShowAt(target, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
                break;
            case TreeRow { Node.Tag: { } tag }:
                TagMenu(tag).ShowAt(target, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
                break;
        }
    }

    /// 展开或收起分组 / 文件夹（搜索中全部展开，不改变保存的状态），之后保持选中该行以便继续用键盘操作。
    private void Toggle(string key)
    {
        if (_search.Text.Trim().Length > 0) return;
        var set = key.StartsWith("recent/", StringComparison.Ordinal) ? CollapsedRecent : Expanded;
        if (!set.Remove(key)) set.Add(key);
        Rebuild();
        _list.SelectedItem = _rows.FirstOrDefault(r => r is TreeRow t && t.Node.Key == key);
    }

    private MenuFlyoutItem Item(string text, Func<Task>? action, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled && action is not null };
        if (action is not null)
        {
            item.Click += (_, _) =>
            {
                _flyout.Hide();
                _ = action();
            };
        }
        return item;
    }

    /// 分支操作菜单（与 Git 日志左侧分支面板的右键菜单共用）。
    private MenuFlyout BranchMenu(BranchRef branch) => BranchMenus.ForBranch(branch, _model, _operations, _flyout.Hide, ReviewBranch);

    private MenuFlyout TagMenu(TagInfo tag)
    {
        var ops = _operations;
        var name = tag.Name;
        var menu = new MenuFlyout();
        menu.Items.Add(Item(L10n.Tr("tags.menu.checkout"), () => ops.Checkout(GitOperations.TargetKind.Revision, name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.newFrom", name), () => ops.NewBranch(name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.mergeInto", name, _model.CurrentBranchTitle), () => ops.Merge(name)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("tags.menu.push"), () => ops.PushTag(name)));
        menu.Items.Add(Item(L10n.Tr("tags.menu.delete"), () => ops.DeleteTag(name)));
        return menu;
    }
}
