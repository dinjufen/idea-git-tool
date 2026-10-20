using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Git;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Commit;

/// 提交工具窗口的 “搁置” 标签（IDEA 的 Shelf，与 mac 端 ShelfView 一致）：搁置的改动列表，展开为文件；可取回全部或选中的文件。
public sealed class ShelfView : Grid
{
    private readonly ProjectModel _model;
    private readonly GitOperations _operations;
    private readonly SimpleTree _tree = new(ListViewSelectionMode.Extended, L10n.Tr("shelf.empty"));
    private readonly List<IconButton> _actionButtons = [];
    private int _loadToken;

    public ShelfView(ProjectModel model, GitOperations operations)
    {
        _model = model;
        _operations = operations;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Children.Add(BuildToolbar());
        SetRow(_tree, 1);
        Children.Add(_tree);
        _tree.SelectionChanged += UpdateButtons;
        _tree.Invoked += node =>
        {
            if (node is { Tag: PatchFile file, Parent.Tag: ShelfEntry entry }) ShowFileDiff?.Invoke(entry, file.Path);
        };
        _tree.MenuRequested += (target, point) => ContextMenu().ShowAt(target, point);
        // 搁置记录不在仓库状态中：显示时及每次刷新后重新读取。
        _model.Changed += () =>
        {
            if (!_model.IsRefreshing && Visibility == Visibility.Visible) Reload();
        };
        _operations.ShelfChanged += Reload;
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) =>
        {
            if (Visibility == Visibility.Visible) Reload();
        });
        UpdateButtons();
    }

    /// 双击文件查看搁置的改动。
    public event Action<ShelfEntry, string>? ShowFileDiff;

    private FrameworkElement BuildToolbar()
    {
        IconButton Button(Icon icon, string key, Action action, bool needsSelection = true)
        {
            var button = new IconButton(icon, L10n.Tr(key), 26, 13);
            button.Click += (_, _) => action();
            if (needsSelection) _actionButtons.Add(button);
            return button;
        }
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(6, 0, 0, 2),
            Children =
            {
                Button(Icon.Refresh, "git.action.refresh", Reload, needsSelection: false),
                Button(Icon.Unstash, "shelf.action.unshelve", () => WithTarget((entry, files) => _operations.Unshelve(entry, files, keep: false))),
                Button(Icon.Trash, "shelf.action.delete", () => WithTarget((entry, _) => _operations.DeleteShelf(entry))),
            },
        };
    }

    private MenuFlyout ContextMenu()
    {
        var menu = new MenuFlyout();
        foreach (var (key, action) in new (string, Func<ShelfEntry, List<string>, Task>)[]
                 {
                     ("shelf.action.unshelve", (entry, files) => _operations.Unshelve(entry, files, keep: false)),
                     ("shelf.action.unshelveKeep", (entry, files) => _operations.Unshelve(entry, files, keep: true)),
                     ("shelf.action.rename", (entry, _) => _operations.RenameShelf(entry)),
                     ("shelf.action.delete", (entry, _) => _operations.DeleteShelf(entry)),
                 })
        {
            var item = new MenuFlyoutItem { Text = L10n.Tr(key) };
            item.Click += (_, _) => WithTarget(action);
            menu.Items.Add(item);
        }
        return menu;
    }

    /// 目标条目及其中选中的文件（选中整个条目时文件为空，表示全部）。
    private (ShelfEntry Entry, List<string> Files)? Target
    {
        get
        {
            ShelfEntry? entry = null;
            var files = new List<string>();
            foreach (var node in _tree.SelectedNodes)
            {
                switch (node)
                {
                    case { Tag: ShelfEntry selected }:
                        return (selected, []);
                    case { Tag: PatchFile file, Parent.Tag: ShelfEntry parent }:
                        if (entry is not null && entry.Id != parent.Id) continue;
                        entry = parent;
                        files.Add(file.Path);
                        break;
                }
            }
            return entry is null ? null : (entry, files);
        }
    }

    private void WithTarget(Func<ShelfEntry, List<string>, Task> action)
    {
        if (Target is var (entry, files)) _ = action(entry, files);
    }

    private void UpdateButtons()
    {
        var enabled = Target is not null;
        foreach (var button in _actionButtons) button.IsEnabled = enabled;
    }

    public void Reload()
    {
        var token = ++_loadToken;
        var repository = _model.Repository;
        Task.Run(() =>
        {
            try
            {
                return repository.Shelves();
            }
            catch (CoreException)
            {
                return [];
            }
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _loadToken) return;
            var roots = task.Result.Select(entry =>
            {
                var count = entry.Files.Length == 1 ? L10n.Tr("commit.group.oneFile") : L10n.Tr("commit.group.files", entry.Files.Length);
                var node = new SimpleTree.Node(entry, Icon.Tray, entry.Name, $"{LogDates.Short(entry.Time)}  {count}") { CanExpand = true, IsBold = true };
                node.SetChildren(entry.Files.Select(file =>
                {
                    var directory = System.IO.Path.GetDirectoryName(file.Path)?.Replace('\\', '/') ?? "";
                    return new SimpleTree.Node(file, Icon.File, System.IO.Path.GetFileName(file.Path), $"{directory}  +{file.Added} −{file.Deleted}")
                    {
                        Tooltip = file.Path,
                    };
                }));
                return node;
            }).ToList();
            _tree.SetRoots(roots, node => ((ShelfEntry)node.Tag).Id);
        }), TaskScheduler.Default);
    }

    /// 仅调试：展开第一个条目。
    public void ExpandFirst()
    {
        if (_tree.Roots.FirstOrDefault() is not { } first) return;
        if (!first.IsExpanded) _tree.Toggle(first);
        // `-debug.unshelveFirst`：取回第一个条目（不保留），验证取回流程。
        if (DebugOptions.Has("debug.unshelveFirst") && first.Tag is ShelfEntry entry) _ = _operations.Unshelve(entry, [], keep: false);
    }
}
