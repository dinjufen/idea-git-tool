using System.Collections.ObjectModel;
using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Controls;

/// 两级的简单树列表（储藏、搁置等条目 → 文件）：条目可展开，文件缩进显示。
/// 与 ProjectTree / BranchesPane 一样用扁平 ListView + ObservableCollection 增量更新：
/// 展开时只插入子行、收起时只移除子行，避免 Items.Clear 整表拆掉视觉树（WinUI 重入崩溃）。
public sealed class SimpleTree : Grid
{
    public sealed class Node(object tag, Icon icon, string name, string detail)
    {
        public object Tag { get; } = tag;
        public Icon Icon { get; } = icon;
        public string Name { get; } = name;
        public string Detail { get; } = detail;
        public string NameBrushKey { get; init; } = "PrimaryTextBrush";
        public bool IsBold { get; init; }
        public bool Strikethrough { get; init; }
        public string? Tooltip { get; init; }

        /// 图标颜色；为空时使用次要文字颜色。
        public Windows.UI.Color? IconColor { get; init; }
        public Node? Parent { get; private set; }

        /// 子节点；null 表示尚未加载（首次展开时通过 Expanding 加载）。
        public List<Node>? Children { get; private set; }

        public bool CanExpand { get; init; }
        public bool IsExpanded { get; set; }

        public void SetChildren(IEnumerable<Node> children)
        {
            Children = [.. children];
            foreach (var child in Children) child.Parent = this;
        }
    }

    private readonly ListView _list;
    private readonly TextBlock _empty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private List<Node> _roots = [];
    private ObservableCollection<Node> _rows = [];
    private bool _rebuilding;

    public SimpleTree(ListViewSelectionMode mode, string emptyText)
    {
        _list = new ListView { SelectionMode = mode };
        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 26.0));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 26.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(4, 0, 4, 0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = style;
        _list.ItemsSource = _rows;
        _list.ContainerContentChanging += OnContainerContentChanging;
        _list.SelectionChanged += (_, _) =>
        {
            if (!_rebuilding) SelectionChanged?.Invoke();
        };
        _list.DoubleTapped += (_, _) =>
        {
            if (SelectedNodes.FirstOrDefault() is not { } node) return;
            if (node.CanExpand)
            {
                // 推迟 Toggle，避免在输入事件栈内改 ItemsSource（WinUI 重入风险）。
                DispatcherQueue.TryEnqueue(() => Toggle(node));
            }
            else Invoked?.Invoke(node);
        };
        _list.RightTapped += (_, e) =>
        {
            if (NodeAt(e.OriginalSource) is { } node && !SelectedNodes.Contains(node))
            {
                _list.SelectedItems.Clear();
                _list.SelectedItem = node;
            }
            if (SelectedNodes.Count > 0) MenuRequested?.Invoke(_list, e.GetPosition(_list));
            e.Handled = true;
        };
        _empty.Text = emptyText;
        _empty.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        Children.Add(_list);
        Children.Add(_empty);
    }

    public event Action? SelectionChanged;

    /// 双击文件节点。
    public event Action<Node>? Invoked;

    /// 节点首次展开（Children 为 null）时加载子节点，加载后调用 Refresh。
    public event Action<Node>? Expanding;

    public event Action<FrameworkElement, Windows.Foundation.Point>? MenuRequested;

    public IReadOnlyList<Node> Roots => _roots;

    public List<Node> SelectedNodes =>
        [.. _list.SelectedItems.OfType<Node>()];

    /// 设置根节点；按 key 保留原来的展开状态与已加载的子节点。
    public void SetRoots(List<Node> roots, Func<Node, string> key)
    {
        var old = _roots.ToDictionary(key, n => n);
        foreach (var root in roots)
        {
            if (!old.TryGetValue(key(root), out var previous)) continue;
            root.IsExpanded = previous.IsExpanded;
            if (root.Children is null && previous.Children is not null) root.SetChildren(previous.Children);
        }
        _roots = roots;
        Refresh(full: true);
    }

    /// 选中并滚动到某个可见节点。
    public void SelectNode(Node node)
    {
        if (!_rows.Contains(node)) return;
        _list.SelectedItem = node;
        _list.ScrollIntoView(node);
    }

    public void Toggle(Node node)
    {
        node.IsExpanded = !node.IsExpanded;
        if (node.IsExpanded && node.Children is null) Expanding?.Invoke(node);
        Refresh();
    }

    /// 按展开状态重建可见行。默认增量更新（展开 / 收起只增删子行）；`full` 时整体替换（SetRoots）。
    public void Refresh(bool full = false)
    {
        var selected = SelectedNodes.ToHashSet();
        var visible = new List<Node>();
        foreach (var root in _roots)
        {
            visible.Add(root);
            if (root.IsExpanded && root.Children is { } children) visible.AddRange(children);
        }

        _rebuilding = true;
        if (full || !ReferenceEquals(_list.ItemsSource, _rows))
        {
            _rows = new ObservableCollection<Node>(visible);
            _list.ItemsSource = _rows;
        }
        else
        {
            // 与 ProjectTree 一致：只增删前后不同的中间段，展开时插入子行、收起时移除，不 Items.Clear。
            var prefix = 0;
            while (prefix < _rows.Count && prefix < visible.Count && ReferenceEquals(_rows[prefix], visible[prefix])) prefix++;
            var suffix = 0;
            while (suffix < _rows.Count - prefix && suffix < visible.Count - prefix
                   && ReferenceEquals(_rows[_rows.Count - 1 - suffix], visible[visible.Count - 1 - suffix]))
            {
                suffix++;
            }
            for (var i = _rows.Count - suffix - 1; i >= prefix; i--) _rows.RemoveAt(i);
            for (var i = prefix; i < visible.Count - suffix; i++) _rows.Insert(i, visible[i]);
            // 展开箭头方向变了：刷新已显示的行（不重建 ItemsSource）。
            for (var i = 0; i < _rows.Count; i++)
            {
                if (_list.ContainerFromIndex(i) is ListViewItem { ContentTemplateRoot: Grid { Children.Count: > 0 } root }
                    && root.Children[0] is RowView view)
                {
                    view.Bind(_rows[i]);
                }
            }
        }

        if (_list.SelectionMode == ListViewSelectionMode.Single)
        {
            _list.SelectedItem = _rows.FirstOrDefault(selected.Contains);
        }
        else
        {
            _list.SelectedItems.Clear();
            foreach (var node in _rows)
            {
                if (selected.Contains(node)) _list.SelectedItems.Add(node);
            }
        }
        _rebuilding = false;

        _empty.Visibility = _roots.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectionChanged?.Invoke();
    }

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not Node node) return;
        if (root.Children.Count == 0) root.Children.Add(new RowView(this));
        ((RowView)root.Children[0]).Bind(node);
        if (node.Tooltip is { } tooltip) ToolTipService.SetToolTip(args.ItemContainer, tooltip);
        else ToolTipService.SetToolTip(args.ItemContainer, null);
        args.Handled = true;
    }

    private Node? NodeAt(object source)
    {
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element is ListViewItem { Content: Node node }) return node;
            if (element is RowView { Node: { } row }) return row;
        }
        return null;
    }

    /// 一行的界面：展开箭头 + 图标 + 名称 + 详情。随行容器回收重复使用。
    private sealed class RowView : Grid
    {
        private readonly SimpleTree _tree;
        private readonly Grid _chevronArea = new() { Width = 16, Height = 16, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        private readonly FrameworkElement _chevron = Icons.Create(Icon.ChevronDown, 12);
        private readonly Grid _iconHost = new() { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _name = new() { VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _detail = new()
        {
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(4, 0, 0, 0),
        };
        private Node? _node;

        public RowView(SimpleTree tree)
        {
            _tree = tree;
            ColumnSpacing = 4;
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _chevron.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            _chevronArea.Children.Add(_chevron);
            _chevronArea.Tapped += (_, e) =>
            {
                e.Handled = true;
                if (_node is not { CanExpand: true } node) return;
                // 推迟 Toggle，避免在 Tapped 中同步改集合（WinUI 重入风险）。
                _tree.DispatcherQueue.TryEnqueue(() => _tree.Toggle(node));
            };
            _detail.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
            SetColumn(_iconHost, 1);
            SetColumn(_name, 2);
            SetColumn(_detail, 3);
            Children.Add(_chevronArea);
            Children.Add(_iconHost);
            Children.Add(_name);
            Children.Add(_detail);
            ActualThemeChanged += (_, _) => UpdateIcon();
        }

        public Node? Node => _node;

        public void Bind(Node node)
        {
            _node = node;
            Margin = new Thickness(node.Parent is null ? 0 : 22, 0, 0, 0);
            _chevronArea.Visibility = node.CanExpand ? Visibility.Visible : Visibility.Collapsed;
            _chevron.RenderTransform = new RotateTransform { Angle = node.IsExpanded ? 0 : -90 };
            _name.Text = node.Name;
            _name.FontWeight = node.IsBold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
            _name.TextDecorations = node.Strikethrough ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None;
            _name.Foreground = Icons.ThemeBrush(_name, node.NameBrushKey);
            _detail.Text = node.Detail;
            UpdateIcon();
        }

        private void UpdateIcon()
        {
            if (_node is not { } node) return;
            _name.Foreground = Icons.ThemeBrush(_name, node.NameBrushKey);
            _iconHost.Children.Clear();
            var brush = node.IconColor is { } color
                ? new SolidColorBrush(color)
                : Icons.ThemeBrush(this, "SecondaryTextBrush");
            _iconHost.Children.Add(Icons.Create(node.Icon, 14, brush));
        }
    }
}
