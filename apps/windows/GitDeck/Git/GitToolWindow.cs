using GitDeck.Common;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Git;

/// 底部 Git 工具窗口：Log、Console、Worktrees 标签页（与 mac 端 GitToolWindow 一致）。
/// Console 与 Worktrees 在 W6 中实现，文件历史标签在 W5 中加入。
public sealed class GitToolWindow : Grid
{
    private readonly List<Button> _tabButtons = [];
    private readonly List<FrameworkElement> _pages = [];
    private int _selected;

    public GitToolWindow(ProjectModel model, GitOperations operations)
    {
        Log = new LogView(model, operations);
        Themed.Background(this, "ToolWindowBackgroundBrush");
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = L10n.Tr("toolwindow.git"),
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 14, 0),
        }, "PrimaryTextBrush"));
        AddTab(header, "git.tab.log", Log);
        AddTab(header, "git.tab.console", Placeholder());
        AddTab(header, "git.tab.worktrees", Placeholder());
        Children.Add(header);
        Select(0);
        // 选中页签的背景取自主题资源，元素进入可视树或主题切换后重新取色。
        Loaded += (_, _) => Select(_selected);
        ActualThemeChanged += (_, _) => Select(_selected);
    }

    public LogView Log { get; }

    private void AddTab(StackPanel header, string key, FrameworkElement page)
    {
        var index = _tabButtons.Count;
        var button = new Button { Content = L10n.Tr(key), Style = (Style)Application.Current.Resources["FlatButtonStyle"], Padding = new Thickness(8, 3, 8, 3) };
        button.Click += (_, _) => Select(index);
        _tabButtons.Add(button);
        header.Children.Add(button);
        SetRow(page, 1);
        Children.Add(page);
        _pages.Add(page);
    }

    private void Select(int index)
    {
        _selected = index;
        for (var i = 0; i < _pages.Count; i++)
        {
            _pages[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
            _tabButtons[i].FontWeight = i == index ? FontWeights.SemiBold : FontWeights.Normal;
            _tabButtons[i].Background = i == index ? Icons.ThemeBrush(_tabButtons[i], "SelectedStripeBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
    }

    /// 在 Log 标签页中定位某个提交。
    public void Reveal(string hash)
    {
        Select(0);
        Log.Reveal(hash);
    }

    private static Grid Placeholder() => new()
    {
        Children =
        {
            new TextBlock
            {
                Text = L10n.Tr("common.notImplemented"),
                Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        },
    };
}
