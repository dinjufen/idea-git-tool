using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// IDEA 的 “Git Remotes” 对话框：列表 + 添加 / 编辑 / 删除（与 mac 端 RemotesDialog 一致）。
public sealed class RemotesDialog : ToolDialog
{
    private static readonly (string, GridLength)[] Layout =
    [
        (L10n.Tr("remotes.name"), new GridLength(130)),
        (L10n.Tr("remotes.url"), new GridLength(1, GridUnitType.Star)),
    ];

    private readonly ProjectModel _model;
    private readonly GitOperations _operations;
    private readonly ListView _list;
    private Remote[] _remotes = [];

    public RemotesDialog(ProjectModel model, GitOperations operations) : base(L10n.Tr("remotes.title"), 620, 360)
    {
        _model = model;
        _operations = operations;
        var (view, list) = Table(Layout, ListViewSelectionMode.Single);
        _list = list;
        _list.DoubleTapped += (_, _) => _ = EditSelected();
        SetBody(view);
        AddButton(L10n.Tr("remotes.add"), () => _ = Act(() => _operations.EditRemote(null)));
        AddButton(L10n.Tr("remotes.edit"), () => _ = EditSelected());
        AddButton(L10n.Tr("remotes.remove"), () =>
        {
            if (Selected is { } remote) _ = Act(() => _operations.RemoveRemote(remote));
        });
        Reload();
    }

    private Remote? Selected => _list.SelectedIndex >= 0 && _list.SelectedIndex < _remotes.Length ? _remotes[_list.SelectedIndex] : null;

    private Task EditSelected() => Selected is { } remote ? Act(() => _operations.EditRemote(remote)) : Task.CompletedTask;

    /// 操作中的对话框显示在本窗口中，完成后刷新列表。
    private async Task Act(Func<Task> action)
    {
        await _operations.InRoot(DialogRoot, action);
        Reload();
    }

    private void Reload()
    {
        var repository = _model.Repository;
        Task.Run(() =>
        {
            try
            {
                return repository.Remotes();
            }
            catch (CoreException)
            {
                return [];
            }
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            _remotes = task.Result;
            _list.Items.Clear();
            foreach (var remote in _remotes)
            {
                var url = Themed.Foreground(new TextBlock { Text = remote.Url }, "SecondaryTextBrush");
                var name = Themed.Foreground(new TextBlock { Text = remote.Name }, "PrimaryTextBrush");
                _list.Items.Add(Columns(Layout, [name, url]));
            }
            if (_remotes.Length > 0) _list.SelectedIndex = 0;
        }), TaskScheduler.Default);
    }
}

/// 子模块列表：路径、状态与 URL，可初始化并更新或作为项目打开（与 mac 端 SubmodulesDialog 一致）。
public sealed class SubmodulesDialog : ToolDialog
{
    private static readonly (string, GridLength)[] Layout =
    [
        (L10n.Tr("submodules.path"), new GridLength(200)),
        (L10n.Tr("submodules.state"), new GridLength(110)),
        (L10n.Tr("remotes.url"), new GridLength(1, GridUnitType.Star)),
    ];

    private readonly ProjectModel _model;
    private readonly GitOperations _operations;
    private readonly ListView _list;
    private readonly TextBlock _empty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private Submodule[] _submodules = [];

    public SubmodulesDialog(ProjectModel model, GitOperations operations) : base(L10n.Tr("submodules.title"), 660, 360)
    {
        _model = model;
        _operations = operations;
        var (view, list) = Table(Layout, ListViewSelectionMode.Extended);
        _list = list;
        _list.DoubleTapped += (_, _) => OpenSelected();
        _empty.Text = L10n.Tr("submodules.empty");
        _empty.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var body = new Grid { Children = { view, _empty } };
        SetBody(body);
        // 更新选中的子模块；未选中时更新全部。
        AddButton(L10n.Tr("submodules.update"), () => _ = Update());
        AddButton(L10n.Tr("submodules.open"), OpenSelected);
        Reload();
    }

    private List<Submodule> Selected =>
        [.. _list.SelectedItems.Select(item => _list.Items.IndexOf(item)).Where(i => i >= 0 && i < _submodules.Length).Select(i => _submodules[i])];

    private async Task Update()
    {
        var paths = Selected.Select(s => s.Path).ToList();
        await _operations.InRoot(DialogRoot, () => _operations.UpdateSubmodules(paths));
        Reload();
    }

    private void OpenSelected()
    {
        if (Selected.FirstOrDefault() is not { State: not SubmoduleState.Uninitialized } submodule) return;
        AppController.Shared.OpenProject(Path.Combine(_model.RootPath, submodule.Path), this);
    }

    private void Reload()
    {
        var repository = _model.Repository;
        Task.Run(() =>
        {
            try
            {
                return repository.Submodules();
            }
            catch (CoreException)
            {
                return [];
            }
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            _submodules = task.Result;
            _list.Items.Clear();
            foreach (var submodule in _submodules)
            {
                var (state, brush) = submodule.State switch
                {
                    SubmoduleState.UpToDate => (L10n.Tr("submodules.state.upToDate"), "SecondaryTextBrush"),
                    SubmoduleState.Modified => (L10n.Tr("submodules.state.modified"), "StatusModifiedBrush"),
                    SubmoduleState.Uninitialized => (L10n.Tr("submodules.state.uninitialized"), "StatusUntrackedBrush"),
                    _ => (L10n.Tr("submodules.state.conflict"), "StatusConflictBrush"),
                };
                var row = Columns(Layout,
                [
                    Themed.Foreground(new TextBlock { Text = submodule.Path }, "PrimaryTextBrush"),
                    Themed.Foreground(new TextBlock { Text = state }, brush),
                    Themed.Foreground(new TextBlock { Text = submodule.Url ?? "" }, "SecondaryTextBrush"),
                ]);
                ToolTipService.SetToolTip(row, $"{submodule.Name}  {submodule.Head[..Math.Min(8, submodule.Head.Length)]}");
                _list.Items.Add(row);
            }
            _empty.Visibility = _submodules.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }), TaskScheduler.Default);
    }
}
