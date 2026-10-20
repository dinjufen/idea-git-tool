using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Git;

/// Git 工具窗口的 Worktrees 标签（与 mac 端 WorktreesView 一致）：列出工作树，可新建、在新窗口中打开、删除。
public sealed class WorktreesView : Grid
{
    private ProjectModel _model;
    private GitOperations _operations;
    /// 多仓库项目中选择显示哪个仓库。
    private readonly RepositoryPicker _repositories = new();

    /// 调试：选择显示的仓库。
    public void DebugSelect(ProjectModel repository) => _repositories.Select(repository);
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly IconButton _open;
    private readonly IconButton _remove;
    private Worktree[] _worktrees = [];

    public WorktreesView(ProjectModel model, GitOperations operations)
    {
        _model = model;
        _operations = operations;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var refresh = new IconButton(Icon.Refresh, L10n.Tr("git.action.refresh"), 26, 13);
        refresh.Click += (_, _) => Reload();
        var add = new IconButton(Icon.Plus, L10n.Tr("worktree.new"), 26, 13);
        add.Click += (_, _) => _ = _operations.NewWorktree();
        _open = new IconButton(Icon.OpenWindow, L10n.Tr("worktree.open"), 26, 13);
        _open.Click += (_, _) => OpenSelected();
        _remove = new IconButton(Icon.Trash, L10n.Tr("worktree.remove"), 26, 13);
        _remove.Click += (_, _) => _ = RemoveSelected();
        _status.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var toolbar = new Grid { Margin = new Thickness(6, 2, 12, 2) };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { _repositories, refresh, add, _open, _remove } });
        SetColumn(_status, 1);
        toolbar.Children.Add(_status);
        Children.Add(toolbar);

        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 26.0));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 26.0));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = style;
        _list.SelectionChanged += (_, _) => UpdateButtons();
        _list.DoubleTapped += (_, _) => OpenSelected();
        Themed.Background(_list, "EditorBackgroundBrush");
        SetRow(_list, 1);
        Children.Add(_list);

        // 分支或 HEAD 变化（例如新建了工作树）后刷新。
        _model.Changed += ModelChanged;
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) =>
        {
            if (Visibility == Visibility.Visible) Reload();
        });
        UpdateButtons();
    }

    private void ModelChanged()
    {
        if (!_model.IsRefreshing && Visibility == Visibility.Visible) Reload();
    }

    /// 多仓库项目：在工具栏显示仓库选择，切换后显示所选仓库的工作树。
    public void Attach(Workspace workspace, Func<ProjectModel, GitOperations> operationsFor) =>
        _repositories.Configure(workspace, _model, repository =>
        {
            _model.Changed -= ModelChanged;
            _model = repository;
            _operations = operationsFor(repository);
            _model.Changed += ModelChanged;
            Reload();
        });

    public void Reload()
    {
        var repository = _model.Repository;
        Task.Run(repository.Worktrees).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (task.Exception?.InnerException is { } error)
            {
                _status.Text = L10n.Message(error);
                return;
            }
            _worktrees = task.Result;
            _list.Items.Clear();
            foreach (var worktree in _worktrees) _list.Items.Add(Row(worktree));
            _status.Text = L10n.Tr("worktree.count", _worktrees.Length);
            UpdateButtons();
        }), TaskScheduler.Default);
    }

    private Worktree? Selected => _list.SelectedIndex >= 0 && _list.SelectedIndex < _worktrees.Length ? _worktrees[_list.SelectedIndex] : null;

    private void UpdateButtons()
    {
        var worktree = Selected;
        _open.IsEnabled = worktree is { IsCurrent: false };
        // 主工作树不能删除。
        _remove.IsEnabled = worktree is { IsMain: false, IsCurrent: false };
    }

    private void OpenSelected()
    {
        if (Selected is not { IsCurrent: false } worktree) return;
        AppController.Shared.OpenProject(worktree.Path, null);
    }

    private async Task RemoveSelected()
    {
        if (Selected is not { IsMain: false } worktree) return;
        if (await _operations.RemoveWorktree(worktree)) Reload();
    }

    private static Grid Row(Worktree worktree)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        var branchText = worktree.Branch ?? L10n.Tr("worktree.detached");
        if (worktree.IsMain) branchText += "  " + L10n.Tr("worktree.main");
        var branch = Themed.Foreground(new TextBlock
        {
            Text = branchText,
            FontWeight = worktree.IsCurrent ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        }, "PrimaryTextBrush");
        var pathText = worktree.Path;
        if (worktree.Prunable) pathText += "  " + L10n.Tr("worktree.prunable");
        if (worktree.Locked) pathText += "  🔒";
        var path = Themed.Foreground(new TextBlock { Text = pathText }, worktree.Prunable ? "StatusConflictBrush" : "SecondaryTextBrush");
        var head = Themed.Foreground(new TextBlock
        {
            Text = worktree.Head is { } h ? h[..Math.Min(8, h.Length)] : "",
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        }, "SecondaryTextBrush");
        var column = 0;
        foreach (var cell in new[] { branch, path, head })
        {
            cell.VerticalAlignment = VerticalAlignment.Center;
            cell.TextTrimming = TextTrimming.CharacterEllipsis;
            SetColumn(cell, column++);
            grid.Children.Add(cell);
        }
        ToolTipService.SetToolTip(grid, worktree.Path);
        return grid;
    }
}
