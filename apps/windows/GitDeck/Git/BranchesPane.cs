using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Git;

/// Git 日志左侧的分支面板（IDEA Log 标签页的 Branches 面板）：左边一列操作按钮，右边是搜索框与分支树
/// （HEAD、本地分支、远程分支；名称中的 `/` 分组为文件夹，当前分支与收藏的分支排在前面）。
/// 选中分支时按该分支筛选日志，选中分组时取消分支筛选；右键为与分支弹窗相同的操作菜单。
public sealed class BranchesPane : Grid
{
    private const double Indent = 14;
    private const string CollapsedKey = "log.branchesPane.collapsed";
    private static readonly Windows.UI.Color Yellow = Editor.SyntaxTheme.Rgb(0xE2A93C);

    private enum NodeKind { Head, Group, Folder, Branch }

    private sealed class Node(NodeKind kind, string title, string key, int depth, BranchRef? branch = null)
    {
        public NodeKind Kind { get; } = kind;
        public string Title { get; } = title;
        /// 展开状态的键（分组与文件夹）。
        public string Key { get; } = key;
        public int Depth { get; } = depth;
        public BranchRef? Branch { get; } = branch;
        public List<Node> Children { get; } = [];
        public bool IsExpandable => Kind is NodeKind.Group or NodeKind.Folder;
    }

    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBox _search = new() { PlaceholderText = L10n.Tr("branchesPane.search"), Margin = new Thickness(6, 6, 6, 4) };
    private readonly Grid _content = new() { Width = 200 };
    private readonly IconButton _toggle;
    private readonly IconButton _newBranch = new(Icon.Plus, L10n.Tr("branches.action.new"), 26, 13);
    private readonly IconButton _update = new(Icon.Update, L10n.Tr("branchesPane.update"), 26, 13);
    private readonly IconButton _delete = new(Icon.Trash, L10n.Tr("branchesPane.delete"), 26, 13);
    private readonly IconButton _compare = new(Icon.Diff, L10n.Tr("branchesPane.compare"), 26, 13);
    private readonly IconButton _fetch = new(Icon.Refresh, L10n.Tr("git.action.fetch"), 26, 13);
    private readonly IconButton _favorite = new(Icon.Star, L10n.Tr("branchesPane.favorite"), 26, 13);
    private readonly IconButton _navigate = new(Icon.Target, L10n.Tr("branchesPane.navigate"), 26, 13);
    /// 折叠的分组与文件夹（默认全部展开，与 IDEA 一致）。
    private readonly HashSet<string> _collapsed = [];
    private ProjectModel? _model;
    private GitOperations? _operations;
    private List<Node> _roots = [];
    private bool _rebuilding;

    public BranchesPane()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Themed.Background(this, "ToolWindowBackgroundBrush");

        _toggle = new IconButton(Icon.ChevronsLeft, L10n.Tr("branchesPane.hide"), 26, 13);
        _toggle.Click += (_, _) => IsCollapsed = !IsCollapsed;
        var toolbar = new StackPanel { Spacing = 2, Margin = new Thickness(2, 4, 2, 4) };
        foreach (var button in new[] { _toggle, _newBranch, _update, _delete, _compare, _fetch, _favorite, _navigate }) toolbar.Children.Add(button);
        // Git 工具窗口较矮时按钮列可以滚动，最后几个按钮不会被裁掉。
        Children.Add(new ScrollViewer
        {
            Content = toolbar,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });

        var toolbarDivider = Themed.Background(new Border { Width = 1 }, "SeparatorBrush");
        SetColumn(toolbarDivider, 1);
        Children.Add(toolbarDivider);

        _content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 24.0));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 24.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(4, 0, 4, 0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = style;
        _list.ContainerContentChanging += OnContainerContentChanging;
        _list.SelectionChanged += (_, _) => SelectionChanged();
        _list.DoubleTapped += (_, _) =>
        {
            if (Selected is { IsExpandable: true } node) Toggle(node);
            else if (Selected?.Branch is { } branch) NavigateRequested?.Invoke(branch.Target);
        };
        _list.RightTapped += (_, e) =>
        {
            if (RowNode(e.OriginalSource) is not { Branch: { } branch } target || _model is null || _operations is null) return;
            _list.SelectedItem = target;
            BranchMenus.ForBranch(branch, _model, _operations, reviewBranch: ReviewBranch).ShowAt(_list, e.GetPosition(_list));
            e.Handled = true;
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_list, L10n.Tr("branchesPane.title"));
        _search.TextChanged += (_, _) => Rebuild();
        SetRow(_list, 1);
        _content.Children.Add(_search);
        _content.Children.Add(_list);
        SetColumn(_content, 2);
        Children.Add(_content);

        _newBranch.Click += (_, _) => _ = _operations?.NewBranch(Selected?.Branch?.Name);
        _update.Click += (_, _) =>
        {
            if (Selected?.Branch is { Kind: BranchKind.Local } branch) _ = _operations?.UpdateBranch(branch.Name);
        };
        _delete.Click += (_, _) =>
        {
            if (Selected?.Branch is not { IsCurrent: false } branch || _operations is null) return;
            _ = branch.Kind == BranchKind.Local ? _operations.Delete(branch.Name) : _operations.DeleteRemoteBranch(branch.Name);
        };
        _compare.Click += (_, _) =>
        {
            if (Selected?.Branch is { IsCurrent: false } branch) _ = _operations?.CompareWithCurrent(branch.Name);
        };
        _fetch.Click += (_, _) => _ = _operations?.Fetch();
        _favorite.Click += (_, _) =>
        {
            if (Selected?.Branch is not { } branch) return;
            ToggleFavorite(branch);
        };
        _navigate.Click += (_, _) =>
        {
            if (Selected?.Branch is { } branch) NavigateRequested?.Invoke(branch.Target);
            else if (Selected?.Kind == NodeKind.Head && _model?.Status.Branch.Oid is { } head) NavigateRequested?.Invoke(head);
        };
        ApplyCollapsed(Settings.GetBool(CollapsedKey));
        UpdateButtons();
    }

    /// 选中项对应的日志分支筛选：分支的完整引用名、`HEAD`，或 null（取消分支筛选）。
    public event Action<string?>? FilterRequested;

    /// 在日志中定位到某个提交（分支头）。
    public event Action<string>? NavigateRequested;

    /// AI 评审某个分支相对当前分支的改动（右键菜单）。
    public Func<ProjectModel, string, Task>? ReviewBranch { get; set; }

    /// 面板宽度（分隔条拖动时调整）。
    public double ContentWidth
    {
        get => _content.Width;
        set => _content.Width = Math.Clamp(value, 160, 600);
    }

    /// 折叠后只保留左侧的按钮列（与 IDEA 一致）。
    public bool IsCollapsed
    {
        get => _content.Visibility == Visibility.Collapsed;
        set
        {
            ApplyCollapsed(value);
            Settings.Set(CollapsedKey, value);
            CollapsedChanged?.Invoke();
        }
    }

    public event Action? CollapsedChanged;

    private void ApplyCollapsed(bool collapsed)
    {
        _content.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        _toggle.Content = Icons.Create(collapsed ? Icon.ChevronsRight : Icon.ChevronsLeft, 13);
        var tip = L10n.Tr(collapsed ? "branchesPane.show" : "branchesPane.hide");
        ToolTipService.SetToolTip(_toggle, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_toggle, tip);
    }

    /// 显示某个仓库的分支（仓库或其分支变化时调用）。
    public void Update(ProjectModel model, GitOperations operations)
    {
        _model = model;
        _operations = operations;
        Rebuild();
    }

    private Node? Selected => _list.SelectedItem as Node;

    private HashSet<string> Favorites => _model is { } model ? BranchFavorites.Get(model) : [];

    private void ToggleFavorite(BranchRef branch)
    {
        if (_model is null) return;
        BranchFavorites.Toggle(_model, branch.FullRef);
        Rebuild();
    }

    // MARK: - 树

    /// `incremental`：展开 / 收起时只增删变化的行，其余行保持不动（避免整个列表闪一下）。
    private void Rebuild(bool incremental = false)
    {
        if (_model is not { } model) return;
        var query = _search.Text.Trim();
        var favorites = Favorites;
        bool Matches(BranchRef b) => query.Length == 0 || b.Name.Contains(query, StringComparison.OrdinalIgnoreCase);

        var roots = new List<Node>();
        if (query.Length == 0) roots.Add(new Node(NodeKind.Head, L10n.Tr("branchesPane.head"), "head", 0));
        foreach (var (kind, key, title) in new[] { (BranchKind.Local, "local", L10n.Tr("branches.section.local")), (BranchKind.Remote, "remote", L10n.Tr("branches.section.remote")) })
        {
            var group = new BranchTreeNode(BranchTreeNode.NodeKind.Group, title, key);
            BranchTree.AddBranches(group, model.Branches.Where(b => b.Kind == kind && Matches(b)), favorites);
            if (group.Children.Count > 0) roots.Add(Convert(group, 0));
        }
        _roots = roots;

        var selectedKey = Selected is { } node ? NodeIdentity(node) : null;
        var rows = new List<Node>();
        foreach (var root in roots) Collect(root, rows, expandAll: query.Length > 0);
        _rebuilding = true;
        if (incremental && _list.ItemsSource is System.Collections.ObjectModel.ObservableCollection<Node> current)
        {
            string Id(Node n) => NodeIdentity(n) + "@" + n.Depth;
            var prefix = 0;
            while (prefix < current.Count && prefix < rows.Count && Id(current[prefix]) == Id(rows[prefix])) prefix++;
            var suffix = 0;
            while (suffix < current.Count - prefix && suffix < rows.Count - prefix && Id(current[current.Count - 1 - suffix]) == Id(rows[rows.Count - 1 - suffix])) suffix++;
            for (var i = current.Count - suffix - 1; i >= prefix; i--) current.RemoveAt(i);
            for (var i = prefix; i < rows.Count - suffix; i++) current.Insert(i, rows[i]);
            // 展开箭头的方向变了：刷新已显示的行。
            for (var i = 0; i < current.Count; i++)
            {
                if (_list.ContainerFromIndex(i) is ListViewItem { ContentTemplateRoot: Grid { Children.Count: > 0 } root } && root.Children[0] is RowView view) view.Bind(current[i], favorites);
            }
            if (selectedKey is not null && current.FirstOrDefault(r => NodeIdentity(r) == selectedKey) is { } kept) _list.SelectedItem = kept;
        }
        else
        {
            _list.ItemsSource = new System.Collections.ObjectModel.ObservableCollection<Node>(rows);
            if (selectedKey is not null && rows.FirstOrDefault(r => NodeIdentity(r) == selectedKey) is { } again) _list.SelectedItem = again;
        }
        _rebuilding = false;
        UpdateButtons();
    }

    private static string NodeIdentity(Node node) => node.Branch?.FullRef ?? node.Kind + ":" + node.Key;

    /// 共用的分支树（排序规则与分支弹窗一致）转换为本面板的节点。
    private static Node Convert(BranchTreeNode node, int depth)
    {
        var kind = node.Kind switch
        {
            BranchTreeNode.NodeKind.Group => NodeKind.Group,
            BranchTreeNode.NodeKind.Folder => NodeKind.Folder,
            _ => NodeKind.Branch,
        };
        var result = new Node(kind, node.Title, node.Key, depth, node.Branch);
        foreach (var child in node.Children) result.Children.Add(Convert(child, depth + 1));
        return result;
    }

    private void Collect(Node node, List<Node> rows, bool expandAll)
    {
        rows.Add(node);
        if (!node.IsExpandable || (!expandAll && _collapsed.Contains(node.Key))) return;
        foreach (var child in node.Children) Collect(child, rows, expandAll);
    }

    private void Toggle(Node node)
    {
        if (!_collapsed.Remove(node.Key)) _collapsed.Add(node.Key);
        Rebuild(incremental: true);
    }

    private void SelectionChanged()
    {
        UpdateButtons();
        if (_rebuilding) return;
        switch (Selected)
        {
            case { Kind: NodeKind.Head }:
                FilterRequested?.Invoke("HEAD");
                break;
            case { Branch: { } branch }:
                FilterRequested?.Invoke(branch.FullRef);
                break;
            case not null:
                FilterRequested?.Invoke(null);
                break;
        }
    }

    private void UpdateButtons()
    {
        var branch = Selected?.Branch;
        _update.IsEnabled = branch is { Kind: BranchKind.Local, Upstream: not null };
        _delete.IsEnabled = branch is { IsCurrent: false };
        _compare.IsEnabled = branch is { IsCurrent: false };
        _favorite.IsEnabled = branch is not null;
        // 选中的分支已收藏时星标按钮显示为实心。
        var isFavorite = branch is not null && Favorites.Contains(branch.FullRef);
        _favorite.Content = Icons.Create(Icon.Star, 13, isFavorite ? new SolidColorBrush(Yellow) : null);
        _navigate.IsEnabled = branch is not null || Selected?.Kind == NodeKind.Head;
    }

    private static Node? RowNode(object source)
    {
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element is ListViewItem { Content: Node node }) return node;
            if (element is RowView { Node: { } row }) return row;
        }
        return null;
    }

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not Node node) return;
        if (root.Children.Count == 0) root.Children.Add(new RowView(this));
        ((RowView)root.Children[0]).Bind(node, Favorites);
        ToolTipService.SetToolTip(args.ItemContainer, node.Branch?.Subject);
        args.Handled = true;
    }

    /// 一行：缩进 + 展开箭头 + 图标 + 名称 + 传入 / 传出箭头。随行容器回收重复使用。
    private sealed class RowView : Grid
    {
        private readonly BranchesPane _pane;
        private readonly Grid _chevronArea = new() { Width = 14, Height = 16, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        private readonly Grid _icon = new() { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _name = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        private readonly IncomingOutgoingIndicator _indicator = new();

        public RowView(BranchesPane pane)
        {
            _pane = pane;
            ColumnSpacing = 4;
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _chevronArea.Tapped += (_, e) =>
            {
                if (Node is { IsExpandable: true } node) _pane.Toggle(node);
                e.Handled = true;
            };
            var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _icon, _name, _indicator } };
            SetColumn(label, 1);
            Children.Add(_chevronArea);
            Children.Add(label);
        }

        public Node? Node { get; private set; }

        public void Bind(Node node, HashSet<string> favorites)
        {
            Node = node;
            Margin = new Thickness(node.Depth * Indent, 0, 0, 0);
            _chevronArea.Children.Clear();
            if (node.IsExpandable)
            {
                var chevron = Icons.Create(Icon.ChevronDown, 11);
                chevron.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
                chevron.RenderTransform = new RotateTransform { Angle = _pane._collapsed.Contains(node.Key) && _pane._search.Text.Trim().Length == 0 ? -90 : 0 };
                _chevronArea.Children.Add(chevron);
            }
            _icon.Children.Clear();
            var yellow = new SolidColorBrush(Yellow);
            FrameworkElement? icon = node.Kind switch
            {
                NodeKind.Folder => Icons.Create(Icon.Folder, 14),
                NodeKind.Branch when node.Branch!.IsCurrent => Icons.Create(Icon.Tag, 14, yellow),
                NodeKind.Branch when favorites.Contains(node.Branch!.FullRef) => Icons.Create(Icon.Star, 14, yellow),
                NodeKind.Branch => Icons.Create(Icon.Branch, 14),
                _ => null,
            };
            if (icon is not null) _icon.Children.Add(icon);
            _icon.Visibility = icon is null ? Visibility.Collapsed : Visibility.Visible;
            _name.Text = node.Title;
            _name.FontWeight = node.Kind == NodeKind.Group ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
            var branch = node.Branch;
            if (branch is { Kind: BranchKind.Local }) _indicator.Set(branch.Ahead, branch.Behind);
            else _indicator.Set(0, 0);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, node.Branch?.Name ?? node.Title);
        }
    }
}
