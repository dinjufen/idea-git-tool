using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Project;

/// Git > 管理仓库（与 mac 端 RepositoriesDialog 一致）：列出本项目中的仓库，可加入、移除或重新检测嵌套仓库。
public sealed class RepositoriesDialog : ToolDialog
{
    private static readonly (string, GridLength)[] Layout =
    [
        (L10n.Tr("repositories.column.name"), new GridLength(180)),
        (L10n.Tr("repositories.column.branch"), new GridLength(140)),
        (L10n.Tr("repositories.column.path"), new GridLength(1, GridUnitType.Star)),
    ];

    private readonly Workspace _workspace;
    private readonly ListView _list;
    private readonly TextBlock _hint = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    private readonly Button _remove;

    public RepositoriesDialog(Workspace workspace) : base(L10n.Tr("repositories.title"), 660, 400)
    {
        _workspace = workspace;
        var (view, list) = Table(Layout, ListViewSelectionMode.Single);
        _list = list;
        _list.SelectionChanged += (_, _) => UpdateButtons();
        _hint.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var body = new Grid();
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.Children.Add(view);
        Grid.SetRow(_hint, 1);
        body.Children.Add(_hint);
        SetBody(body);
        AddButton(L10n.Tr("repositories.add"), () => _ = Add());
        _remove = AddButton(L10n.Tr("repositories.remove"), Remove);
        AddButton(L10n.Tr("repositories.detect"), Detect);
        _workspace.Changed += Reload;
        Closed += (_, _) => _workspace.Changed -= Reload;
        Reload();
    }

    private void Reload()
    {
        var selected = _list.SelectedIndex;
        _list.Items.Clear();
        var dark = _list.ActualTheme == ElementTheme.Dark;
        for (var i = 0; i < _workspace.Models.Count; i++)
        {
            var repository = _workspace.Models[i];
            var name = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2.5), VerticalAlignment = VerticalAlignment.Center, Background = new SolidColorBrush(_workspace.Color(repository, dark)) },
                    Themed.Foreground(new TextBlock
                    {
                        Text = i == 0 ? $"{_workspace.DisplayName(repository)}  {L10n.Tr("repositories.primary")}" : _workspace.DisplayName(repository),
                        VerticalAlignment = VerticalAlignment.Center,
                    }, "PrimaryTextBrush"),
                },
            };
            var branch = Themed.Foreground(new TextBlock { Text = repository.BranchWidgetTitle }, "SecondaryTextBrush");
            var path = Themed.Foreground(new TextBlock { Text = repository.RootPath }, "SecondaryTextBrush");
            var row = Columns(Layout, [name, branch, path]);
            ToolTipService.SetToolTip(row, repository.RootPath);
            _list.Items.Add(row);
        }
        if (selected >= 0 && selected < _list.Items.Count) _list.SelectedIndex = selected;
        var pending = _workspace.Candidates.Count;
        _hint.Text = pending == 0 ? L10n.Tr("repositories.hint") : L10n.Tr("repositories.pending", pending);
        UpdateButtons();
    }

    /// 主仓库不能移除。
    private void UpdateButtons() => _remove.IsEnabled = _list.SelectedIndex > 0;

    private async Task Add()
    {
        if (await Dialogs.PickFolder(this) is { } path) _workspace.Add([path]);
    }

    private void Remove()
    {
        var index = _list.SelectedIndex;
        if (index > 0 && index < _workspace.Models.Count) _workspace.Remove(_workspace.Models[index]);
    }

    /// 重新检测并加入所有找到的嵌套仓库（包括之前忽略的）。
    private void Detect()
    {
        var repository = _workspace.Primary.Repository;
        Task.Run(() =>
        {
            try
            {
                return repository.NestedRepositories(4);
            }
            catch (CoreException)
            {
                return [];
            }
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() => _workspace.Add([.. task.Result.Select(r => r.Path)])), TaskScheduler.Default);
    }
}
