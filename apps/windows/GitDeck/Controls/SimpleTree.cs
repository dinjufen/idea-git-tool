using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Controls;

/// 两级的简单树列表（储藏、搁置等条目 → 文件）：条目可展开，文件缩进显示。
/// 条目较少，按行创建元素即可，不需要虚拟化的行复用。
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
    private readonly List<Node> _visible = [];

    public SimpleTree(ListViewSelectionMode mode, string emptyText)
    {
        _list = new ListView { SelectionMode = mode };
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 26.0));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 26.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(4, 0, 4, 0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = style;
        _list.SelectionChanged += (_, _) => SelectionChanged?.Invoke();
        _list.DoubleTapped += (_, _) =>
        {
            if (SelectedNodes.FirstOrDefault() is not { } node) return;
            if (node.CanExpand) Toggle(node);
            else Invoked?.Invoke(node);
        };
        _list.RightTapped += (_, e) =>
        {
            if (NodeAt(e.OriginalSource) is { } node && !SelectedNodes.Contains(node))
            {
                _list.SelectedItems.Clear();
                _list.SelectedIndex = _visible.IndexOf(node);
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
        [.. _list.SelectedItems.Select(item => _list.Items.IndexOf(item)).Where(i => i >= 0 && i < _visible.Count).Select(i => _visible[i])];

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
        Refresh();
    }

    public void Toggle(Node node)
    {
        node.IsExpanded = !node.IsExpanded;
        if (node.IsExpanded && node.Children is null) Expanding?.Invoke(node);
        Refresh();
    }

    public void Refresh()
    {
        var selected = SelectedNodes.ToHashSet();
        _visible.Clear();
        foreach (var root in _roots)
        {
            _visible.Add(root);
            if (root.IsExpanded && root.Children is { } children) _visible.AddRange(children);
        }
        _list.Items.Clear();
        foreach (var node in _visible) _list.Items.Add(Row(node));
        for (var i = 0; i < _visible.Count; i++)
        {
            if (selected.Contains(_visible[i])) _list.SelectRange(new Microsoft.UI.Xaml.Data.ItemIndexRange(i, 1));
        }
        _empty.Visibility = _roots.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectionChanged?.Invoke();
    }

    private Node? NodeAt(object source)
    {
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (element is FrameworkElement { Tag: Node node }) return node;
        }
        return null;
    }

    private Grid Row(Node node)
    {
        var row = new Grid { ColumnSpacing = 4, Tag = node, Margin = new Thickness(node.Parent is null ? 0 : 22, 0, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (node.CanExpand)
        {
            var chevron = Icons.Create(Icon.ChevronDown, 12);
            chevron.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            chevron.RenderTransform = new RotateTransform { Angle = node.IsExpanded ? 0 : -90 };
            var area = new Grid { Width = 16, Height = 16, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Children = { chevron } };
            area.Tapped += (_, e) =>
            {
                Toggle(node);
                e.Handled = true;
            };
            row.Children.Add(area);
        }
        var icon = Icons.Create(node.Icon, 14, Icons.ThemeBrush(this, "SecondaryTextBrush"));
        icon.VerticalAlignment = VerticalAlignment.Center;
        SetColumn(icon, 1);
        row.Children.Add(icon);
        var name = Themed.Foreground(new TextBlock
        {
            Text = node.Name,
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = node.IsBold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
            TextDecorations = node.Strikethrough ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None,
        }, node.NameBrushKey);
        SetColumn(name, 2);
        row.Children.Add(name);
        var detail = new TextBlock
        {
            Text = node.Detail,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            Margin = new Thickness(4, 0, 0, 0),
        };
        SetColumn(detail, 3);
        row.Children.Add(detail);
        if (node.Tooltip is { } tooltip) ToolTipService.SetToolTip(row, tooltip);
        return row;
    }
}
