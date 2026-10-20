using System.Runtime.InteropServices;
using GitDeck.Common;
using GitDeck.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace GitDeck.Project;

/// Project 工具窗口：仓库文件树，按 git 状态着色，双击在编辑器中打开（与 mac 端 ProjectToolWindow 一致）。
/// 目录在展开时才读取子项；文件变化后重新扫描已展开的目录，并保留展开状态。
///
/// 用扁平的虚拟化 ListView 实现树（每行带缩进与展开箭头）：只为可见行创建界面元素，
/// 展开 `target/`、`node_modules/` 这类包含上万个文件的目录也不会卡顿。行的内容在 ContainerContentChanging 中按数据填充。
public sealed partial class ProjectTree
{
    private const double Indent = 16;

    private readonly ProjectModel _model;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly FileNode _root;

    public ProjectTree(ProjectModel model)
    {
        _model = model;
        _root = new FileNode(model.RootPath, isDirectory: true, relativePath: "", depth: 0);
        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid /></DataTemplate>");
        _list.ItemContainerStyle = RowStyle();
        _list.ContainerContentChanging += OnContainerContentChanging;
        _list.DoubleTapped += (_, _) => OpenSelected();
        _list.KeyDown += (_, e) =>
        {
            var node = Selected;
            switch (e.Key)
            {
                case VirtualKey.Enter:
                    OpenSelected();
                    e.Handled = true;
                    break;
                case VirtualKey.Right when node is { IsDirectory: true, IsExpanded: false }:
                    Toggle(node);
                    e.Handled = true;
                    break;
                case VirtualKey.Left when node is { IsDirectory: true, IsExpanded: true }:
                    Toggle(node);
                    e.Handled = true;
                    break;
            }
        };
        _root.IsExpanded = true;
        Rebuild();

        var collapse = new IconButton(Icon.CollapseAll, L10n.Tr("tree.collapseAll"), 24, 12);
        collapse.Click += (_, _) => CollapseAll();
        View = new ToolWindowPanel(L10n.Tr("toolwindow.project"), _list, [collapse]);
        model.Changed += () =>
        {
            if (!model.IsRefreshing) Reload();
        };
    }

    /// 双击文件时打开（参数为完整路径）。
    public event Action<string>? OpenFile;

    public ToolWindowPanel View { get; }

    private FileNode? Selected => _list.SelectedItem as FileNode;

    /// 重新扫描文件系统（新增 / 删除的文件），并刷新着色。
    public void Reload()
    {
        _root.Reload();
        Rebuild();
    }

    /// 展开前几层目录（调试截图用）。
    public void ExpandAll(int depth = 2)
    {
        _root.Expand(depth);
        Rebuild();
    }

    private void CollapseAll()
    {
        _root.CollapseChildren();
        Rebuild();
    }

    private Workspace? _workspace;

    /// 多仓库项目：嵌套仓库的根目录显示仓库标识色与分支，其中的文件按所属仓库的状态着色。
    public Workspace? Workspace
    {
        get => _workspace;
        set
        {
            _workspace = value;
            // 工作区的变化通知在界面线程上发出。
            if (value is not null) value.Changed += Rebuild;
            Rebuild();
        }
    }

    /// 按展开状态重建可见行，保持选中项与滚动位置。
    private void Rebuild()
    {
        var selected = Selected;
        var rows = new List<FileNode>();
        _root.Collect(rows);
        foreach (var node in rows)
        {
            node.BrushKey = BrushKey(node);
            node.Repository = RepositoryRootedAt(node);
            node.Detail = Detail(node);
        }
        _list.ItemsSource = rows;
        if (selected is not null && rows.Contains(selected)) _list.SelectedItem = selected;
    }

    private void Toggle(FileNode node)
    {
        node.IsExpanded = !node.IsExpanded;
        Rebuild();
    }

    private void OpenSelected()
    {
        if (Selected is not { } node) return;
        if (node.IsDirectory) Toggle(node);
        else OpenFile?.Invoke(node.FullPath);
    }

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Grid root || args.Item is not FileNode node) return;
        if (root.Children.Count == 0) root.Children.Add(new RowView(this));
        ((RowView)root.Children[0]).Bind(node);
        ToolTipService.SetToolTip(args.ItemContainer, node.FullPath);
        args.Handled = true;
    }

    private static Style RowStyle()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 24.0));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 24.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(4, 0, 4, 0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        return style;
    }

    /// 文件或目录的状态颜色：有变更的文件按状态着色，包含变更的目录显示为 “已修改” 颜色
    /// （IDEA 的 “Highlight directories that contain modified files”）。
    private string BrushKey(FileNode node)
    {
        // 文件所属的仓库（嵌套仓库中的文件使用嵌套仓库的状态）。
        var (owner, relative) = _workspace is { IsMultiRoot: true } workspace ? workspace.Locate(node.FullPath) : (_model, node.RelativePath);
        if (owner.ChangesByPath.TryGetValue(relative, out var change)) return change.BrushKey();
        if (node.IsDirectory && (relative.Length > 0 || owner != _model))
        {
            var prefix = relative.Length == 0 ? "" : relative + "/";
            if (owner.Status.Changes.Any(c => c.Path.StartsWith(prefix, StringComparison.Ordinal) && !c.IsIgnored())) return "StatusModifiedBrush";
        }
        return "PrimaryTextBrush";
    }

    /// 以该目录为根目录的其他仓库。
    private ProjectModel? RepositoryRootedAt(FileNode node)
    {
        if (!node.IsDirectory || node.IsRoot || _workspace is not { IsMultiRoot: true } workspace) return null;
        return workspace.Models.FirstOrDefault(m => m != _model && RecentProjects.SamePath(m.RootPath, node.FullPath));
    }

    /// 根节点显示完整路径；多仓库项目中仓库根目录显示当前分支（IDEA 多仓库项目中的仓库根标记）。
    private string Detail(FileNode node)
    {
        if (node.Repository is { } repository) return $"[{repository.BranchWidgetTitle}]";
        if (!node.IsRoot) return "";
        return _workspace is { IsMultiRoot: true } ? $"[{_model.BranchWidgetTitle}]  {node.FullPath}" : node.FullPath;
    }

    /// 与资源管理器相同的排序（数字按数值比较，不区分大小写）。
    [LibraryImport("shlwapi.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int StrCmpLogicalW(string a, string b);

    /// 文件树节点（纯数据），子节点按需加载。
    private sealed class FileNode
    {
        private List<FileNode>? _children;
        private bool _isExpanded;

        public FileNode(string fullPath, bool isDirectory, string relativePath, int depth)
        {
            FullPath = fullPath;
            IsDirectory = isDirectory;
            RelativePath = relativePath;
            Depth = depth;
        }

        public string FullPath { get; }

        public bool IsDirectory { get; }

        /// 相对仓库根目录的路径（`/` 分隔，根节点为空串）。
        public string RelativePath { get; }

        public int Depth { get; }

        public bool IsRoot => RelativePath.Length == 0;

        public string Name => IsRoot
            ? Path.GetFileName(Path.TrimEndingDirectorySeparator(FullPath))
            : RelativePath[(RelativePath.LastIndexOf('/') + 1)..];

        public string BrushKey { get; set; } = "PrimaryTextBrush";

        /// 以本目录为根的其他仓库（多仓库项目）。
        public ProjectModel? Repository { get; set; }

        public string Detail { get; set; } = "";

        public bool IsExpanded
        {
            get => _isExpanded;
            set
            {
                _isExpanded = value && IsDirectory;
                if (_isExpanded) _children ??= Scan([]);
            }
        }

        /// 按顺序收集可见行。
        public void Collect(List<FileNode> rows)
        {
            rows.Add(this);
            if (!_isExpanded) return;
            foreach (var child in _children ?? []) child.Collect(rows);
        }

        /// 重新扫描已加载的目录，按名称复用节点以保留展开状态。
        public void Reload()
        {
            if (_children is null) return;
            var existing = new Dictionary<string, FileNode>(StringComparer.OrdinalIgnoreCase);
            foreach (var child in _children) existing.TryAdd(child.Name, child);
            _children = Scan(existing);
            foreach (var child in _children) child.Reload();
        }

        public void Expand(int depth)
        {
            if (!IsDirectory || depth < 0) return;
            IsExpanded = true;
            foreach (var child in _children ?? []) child.Expand(depth - 1);
        }

        public void CollapseChildren()
        {
            foreach (var child in _children ?? [])
            {
                child.CollapseChildren();
                child.IsExpanded = false;
            }
        }

        private List<FileNode> Scan(Dictionary<string, FileNode> existing)
        {
            var nodes = new List<FileNode>();
            try
            {
                foreach (var entry in new DirectoryInfo(FullPath).EnumerateFileSystemInfos())
                {
                    if (entry.Name.Equals(".git", StringComparison.OrdinalIgnoreCase)) continue;
                    var isDirectory = entry.Attributes.HasFlag(FileAttributes.Directory);
                    if (existing.TryGetValue(entry.Name, out var reused) && reused.IsDirectory == isDirectory)
                    {
                        nodes.Add(reused);
                        continue;
                    }
                    var relative = IsRoot ? entry.Name : RelativePath + "/" + entry.Name;
                    nodes.Add(new FileNode(entry.FullName, isDirectory, relative, Depth + 1));
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // 无法读取的目录显示为空。
            }
            // 与 IDEA 一致：目录在前，名称按资源管理器的规则排序。
            nodes.Sort((a, b) => a.IsDirectory != b.IsDirectory ? (a.IsDirectory ? -1 : 1) : StrCmpLogicalW(a.Name, b.Name));
            return nodes;
        }
    }

    /// 一行的界面：缩进 + 展开箭头 + 图标 + 名称（根节点另显示完整路径）。随行容器回收重复使用。
    private sealed class RowView : Grid
    {
        private readonly ProjectTree _tree;
        private readonly Grid _chevronArea = new() { Width = 16, Height = 16, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        private readonly FrameworkElement _chevron = Icons.Create(Icon.ChevronDown, 12);
        private readonly Grid _folderIcon = new() { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        private readonly FrameworkElement _fileIcon = Icons.Create(Icon.File, 14);
        private readonly TextBlock _name = new() { VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _detail = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        private FileNode? _node;

        public RowView(ProjectTree tree)
        {
            _tree = tree;
            ColumnSpacing = 4;
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _chevron.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            _chevronArea.Children.Add(_chevron);
            _chevronArea.Tapped += (_, e) =>
            {
                if (_node is { IsDirectory: true } node) _tree.Toggle(node);
                e.Handled = true;
            };
            _detail.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
            var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { _folderIcon, _fileIcon, _name, _detail } };
            SetColumn(label, 1);
            Children.Add(_chevronArea);
            Children.Add(label);
            ActualThemeChanged += (_, _) => UpdateColor();
        }

        public void Bind(FileNode node)
        {
            _node = node;
            Margin = new Thickness(node.Depth * Indent, 0, 0, 0);
            _chevronArea.Visibility = node.IsDirectory ? Visibility.Visible : Visibility.Collapsed;
            _chevron.RenderTransform = new RotateTransform { Angle = node.IsExpanded ? 0 : -90 };
            _folderIcon.Visibility = node.IsDirectory ? Visibility.Visible : Visibility.Collapsed;
            _fileIcon.Visibility = node.IsDirectory ? Visibility.Collapsed : Visibility.Visible;
            _name.Text = node.Name;
            _name.FontWeight = node.IsRoot || node.Repository is not null ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
            _detail.Text = node.Detail;
            _detail.Visibility = node.Detail.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateColor();
        }

        private void UpdateColor()
        {
            if (_node is not { } node) return;
            _name.Foreground = Icons.ThemeBrush(_name, node.BrushKey);
            // 其他仓库的根目录：图标使用仓库标识色。
            var brush = node.Repository is { } repository && _tree._workspace is { } workspace
                ? new SolidColorBrush(workspace.Color(repository, ActualTheme == ElementTheme.Dark))
                : null;
            _folderIcon.Children.Clear();
            _folderIcon.Children.Add(Icons.Create(Icon.Folder, 14, brush));
        }
    }
}
