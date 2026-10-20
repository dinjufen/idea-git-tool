using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Git;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Commit;

/// 提交工具窗口的 “储藏” 标签（IDEA New UI 的 Stash 标签，与 mac 端 StashesView 一致）：储藏列表，展开为改动的文件。
public sealed class StashesView : Grid
{
    private ProjectModel _model;
    private GitOperations _operations;
    /// 多仓库项目中选择显示哪个仓库。
    private readonly RepositoryPicker _repositories = new();

    /// 调试：选择显示的仓库。
    public void DebugSelect(ProjectModel repository) => _repositories.Select(repository);
    private readonly SimpleTree _tree = new(ListViewSelectionMode.Single, L10n.Tr("stash.empty"));
    private readonly List<IconButton> _actionButtons = [];

    public StashesView(ProjectModel model, GitOperations operations)
    {
        _model = model;
        _operations = operations;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Children.Add(BuildToolbar());
        SetRow(_tree, 1);
        Children.Add(_tree);
        _tree.SelectionChanged += UpdateButtons;
        _tree.Expanding += LoadFiles;
        _tree.Invoked += node =>
        {
            if (node is { Tag: ChangedFile file, Parent.Tag: StashEntry stash }) ShowFileDiff?.Invoke(_model, stash, file);
        };
        _tree.MenuRequested += (target, point) => ContextMenu().ShowAt(target, point);
        _model.Changed += Reload;
        Reload();
    }

    /// 打开储藏中文件的 Diff（参数含储藏所在的仓库）。
    public event Action<ProjectModel, StashEntry, ChangedFile>? ShowFileDiff;

    /// 多仓库项目：在工具栏显示仓库选择，切换后显示所选仓库的储藏。
    public void Attach(Workspace workspace, Func<ProjectModel, GitOperations> operationsFor) =>
        _repositories.Configure(workspace, _model, repository =>
        {
            _model.Changed -= Reload;
            _model = repository;
            _operations = operationsFor(repository);
            _model.Changed += Reload;
            _tree.SetRoots([], _ => "");
            Reload();
        });

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
                _repositories,
                Button(Icon.Refresh, "git.action.refresh", () => _model.Refresh(), needsSelection: false),
                Button(Icon.Unstash, "stash.action.apply", () => WithSelected(s => _operations.ApplyStash(s, pop: false))),
                Button(Icon.Pop, "stash.action.pop", () => WithSelected(s => _operations.ApplyStash(s, pop: true))),
                Button(Icon.Branch, "stash.action.branch", () => WithSelected(_operations.UnstashAsBranch)),
                Button(Icon.Trash, "stash.action.drop", () => WithSelected(_operations.DropStash)),
                Button(Icon.ClearAll, "stash.action.clear", () => _ = _operations.ClearStashes(), needsSelection: false),
            },
        };
    }

    private MenuFlyout ContextMenu()
    {
        var menu = new MenuFlyout();
        foreach (var (key, action) in new (string, Func<StashEntry, Task>)[]
                 {
                     ("stash.action.apply", s => _operations.ApplyStash(s, pop: false)),
                     ("stash.action.pop", s => _operations.ApplyStash(s, pop: true)),
                     ("stash.action.applyIndex", s => _operations.ApplyStash(s, pop: false, reinstateIndex: true)),
                     ("stash.action.branch", _operations.UnstashAsBranch),
                     ("stash.action.drop", _operations.DropStash),
                 })
        {
            var item = new MenuFlyoutItem { Text = L10n.Tr(key) };
            item.Click += (_, _) => WithSelected(action);
            menu.Items.Add(item);
        }
        return menu;
    }

    private StashEntry? SelectedStash => _tree.SelectedNodes.FirstOrDefault() switch
    {
        { Tag: StashEntry stash } => stash,
        { Parent.Tag: StashEntry stash } => stash,
        _ => null,
    };

    private void WithSelected(Func<StashEntry, Task> action)
    {
        if (SelectedStash is { } stash) _ = action(stash);
    }

    private void UpdateButtons()
    {
        var enabled = SelectedStash is not null;
        foreach (var button in _actionButtons) button.IsEnabled = enabled;
    }

    /// 储藏列表变化时重建（保留已展开节点与已加载的文件）。
    private void Reload()
    {
        if (_model.IsRefreshing) return;
        var roots = _model.Stashes.Select(entry =>
        {
            var detail = new List<string> { LogDates.Short(entry.Time) };
            if (entry.Branch is { } branch) detail.Insert(0, branch);
            return new SimpleTree.Node(entry, Icon.Tray, entry.Message, string.Join(" · ", detail))
            {
                CanExpand = true,
                Tooltip = $"stash@{{{entry.Index}}}  {entry.Hash[..Math.Min(8, entry.Hash.Length)]}",
            };
        }).ToList();
        // 下标可能因删除而变化，以提交哈希识别同一储藏。
        _tree.SetRoots(roots, node => ((StashEntry)node.Tag).Hash);
    }

    private void LoadFiles(SimpleTree.Node node)
    {
        if (node.Tag is not StashEntry stash) return;
        var repository = _model.Repository;
        Task.Run(() =>
        {
            try
            {
                return repository.StashFiles(stash.Index);
            }
            catch (CoreException)
            {
                return [];
            }
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            node.SetChildren(task.Result.OrderBy(f => f.Path, StringComparer.OrdinalIgnoreCase).Select(file =>
            {
                var directory = System.IO.Path.GetDirectoryName(file.Path)?.Replace('\\', '/') ?? "";
                return new SimpleTree.Node(file, Icon.File, System.IO.Path.GetFileName(file.Path), directory)
                {
                    NameBrushKey = file.Kind == ChangeKind.Untracked ? "StatusUntrackedBrush" : file.Kind.BrushKey(),
                    Strikethrough = file.Kind == ChangeKind.Deleted,
                    Tooltip = file.Path,
                };
            }));
            _tree.Refresh();
        }), TaskScheduler.Default);
    }

    /// 仅调试：展开第一条储藏。
    public void ExpandFirst()
    {
        if (_tree.Roots.FirstOrDefault() is not { } first) return;
        if (!first.IsExpanded) _tree.Toggle(first);
        // `-debug.popFirst`：弹出第一条储藏，验证取消储藏流程。
        if (DebugOptions.Has("debug.popFirst") && first.Tag is StashEntry stash) _ = _operations.ApplyStash(stash, pop: true);
    }
}
