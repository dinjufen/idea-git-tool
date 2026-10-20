using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Project;

/// 多仓库项目中工具窗口工具栏上的仓库选择（Stash、Shelf、Worktrees 等按仓库显示的内容，与 mac 端 RepositoryPopup 一致）。
/// 只有一个仓库时隐藏。
public sealed class RepositoryPicker : ComboBox
{
    private Workspace? _workspace;
    private Action<ProjectModel>? _changed;
    private bool _rebuilding;
    private List<string> _names = [];

    public RepositoryPicker()
    {
        MinWidth = 0;
        Visibility = Visibility.Collapsed;
        VerticalAlignment = VerticalAlignment.Center;
        Margin = new Thickness(6, 0, 4, 0);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, L10n.Tr("workspace.repository"));
        SelectionChanged += (_, _) => Changed();
    }

    public ProjectModel? Selected { get; private set; }

    public void Configure(Workspace workspace, ProjectModel selected, Action<ProjectModel> changed)
    {
        _workspace = workspace;
        Selected = selected;
        _changed = changed;
        workspace.Changed += Rebuild;
        ActualThemeChanged += (_, _) =>
        {
            _names = [];
            Rebuild();
        };
        Rebuild();
    }

    private void Rebuild()
    {
        if (_workspace is not { } workspace) return;
        Visibility = workspace.IsMultiRoot ? Visibility.Visible : Visibility.Collapsed;
        // 选中的仓库被移除时回到主仓库。
        if (Selected is not null && !workspace.Models.Contains(Selected))
        {
            Selected = workspace.Primary;
            _changed?.Invoke(workspace.Primary);
        }
        var names = workspace.Models.Select(workspace.DisplayName).ToList();
        _rebuilding = true;
        if (!names.SequenceEqual(_names))
        {
            _names = names;
            Items.Clear();
            var dark = ActualTheme == ElementTheme.Dark;
            foreach (var repository in workspace.Models)
            {
                Items.Add(new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Children =
                    {
                        new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2.5), VerticalAlignment = VerticalAlignment.Center, Background = new SolidColorBrush(workspace.Color(repository, dark)) },
                        new TextBlock { Text = workspace.DisplayName(repository), VerticalAlignment = VerticalAlignment.Center },
                    },
                });
            }
        }
        SelectedIndex = Selected is null ? -1 : workspace.Models.ToList().IndexOf(Selected);
        _rebuilding = false;
    }

    /// 选择某个仓库（与用户在列表中选择相同）。
    public void Select(ProjectModel repository)
    {
        if (_workspace is { } workspace && workspace.Models.ToList().IndexOf(repository) is >= 0 and var index) SelectedIndex = index;
    }

    private void Changed()
    {
        if (_rebuilding || _workspace is not { } workspace || SelectedIndex < 0 || SelectedIndex >= workspace.Models.Count) return;
        var repository = workspace.Models[SelectedIndex];
        if (repository == Selected) return;
        Selected = repository;
        _changed?.Invoke(repository);
    }
}
