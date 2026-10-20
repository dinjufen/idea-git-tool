using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace GitDeck.Welcome;

/// 欢迎页（对应 IDEA 的 Welcome to …）：左侧为产品信息与导航，右侧为搜索、新建 / 打开 / 克隆按钮与最近项目。
public sealed class WelcomeWindow : Window
{
    private const double TitleBarHeight = 32;

    private readonly AppController _app;
    private readonly TextBox _search = new() { PlaceholderText = L10n.Tr("welcome.search.placeholder") };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };

    public WelcomeWindow(AppController app)
    {
        _app = app;
        Title = L10n.Tr("welcome.title", AppInfo.ProductName);
        ExtendsContentIntoTitleBar = true;
        WindowHelper.SetIcon(this);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsResizable = false;
        }

        var dragRegion = new Grid
        {
            Height = TitleBarHeight,
            VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var divider = Themed.Background(new Border(), "SeparatorBrush");
        Grid.SetColumn(divider, 1);
        var main = BuildMain();
        Grid.SetColumn(main, 2);
        Grid.SetColumnSpan(dragRegion, 3);
        root.Children.Add(BuildSidebar());
        root.Children.Add(divider);
        root.Children.Add(main);
        root.Children.Add(dragRegion);
        Content = root;
        SetTitleBar(dragRegion);

        Appearance.Register(this);
        WindowHelper.ResizeAndCenter(this, 800, 520);
        root.Loaded += (_, _) => RunDebugAction();
    }

    public void Reload()
    {
        var query = _search.Text.Trim();
        _list.Items.Clear();
        foreach (var path in RecentProjects.Paths.Where(p => query.Length == 0 || p.Contains(query, StringComparison.OrdinalIgnoreCase)))
        {
            _list.Items.Add(Row(path));
        }
    }

    private FrameworkElement BuildSidebar()
    {
        var sidebar = Themed.Background(new Grid(), "ToolWindowBackgroundBrush");
        var logo = new Image
        {
            Source = new BitmapImage(new Uri(Path.Combine(AppInfo.AppDirectory, "Assets", "Logo.png"))),
            Width = 40,
            Height = 40,
        };
        var name = Themed.Foreground(new TextBlock
        {
            Text = AppInfo.ProductName,
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        }, "PrimaryTextBrush");
        var version = new TextBlock
        {
            Text = L10n.Tr("welcome.version", CoreApi.CoreVersion()),
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
        };
        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(14, 44, 10, 0),
            Children =
            {
                logo,
                new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2, Children = { name, version } },
            },
        };
        // 当前只有 “项目” 一个导航项，显示为选中状态。
        var nav = Themed.Background(new Border
        {
            Height = 30,
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(10, 24, 10, 0),
            Padding = new Thickness(10, 0, 10, 0),
            Child = Themed.Foreground(new TextBlock
            {
                Text = L10n.Tr("welcome.nav.projects"),
                VerticalAlignment = VerticalAlignment.Center,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            }, "PrimaryTextBrush"),
        }, "SelectedStripeBrush");
        sidebar.Children.Add(new StackPanel { Children = { header, nav } });
        return sidebar;
    }

    private FrameworkElement BuildMain()
    {
        var main = Themed.Background(new Grid { Padding = new Thickness(10, 0, 10, 10) }, "EditorBackgroundBrush");
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        main.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var newButton = new Button { Content = L10n.Tr("welcome.new") };
        newButton.Click += async (_, _) => await _app.NewProject(this);
        var openButton = new Button { Content = L10n.Tr("welcome.open") };
        openButton.Click += async (_, _) => await _app.OpenProjectWithPicker(this);
        var cloneButton = new Button { Content = L10n.Tr("welcome.clone") };
        cloneButton.Click += async (_, _) => await _app.CloneProject(this);

        var top = new Grid { Margin = new Thickness(10, 44, 10, 14), ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { newButton, openButton, cloneButton } };
        Grid.SetColumn(buttons, 1);
        top.Children.Add(_search);
        top.Children.Add(buttons);
        _search.TextChanged += (_, _) => Reload();

        _list.DoubleTapped += (_, _) => OpenSelected();
        _list.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) OpenSelected();
        };
        Grid.SetRow(_list, 1);
        main.Children.Add(top);
        main.Children.Add(_list);
        return main;
    }

    private ListViewItem Row(string path)
    {
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        var missing = !Directory.Exists(path);
        var badge = new ProjectBadge(28) { ProjectName = name, VerticalAlignment = VerticalAlignment.Center };
        var title = Themed.Foreground(new TextBlock
        {
            Text = name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        }, missing ? "SecondaryTextBrush" : "PrimaryTextBrush");
        var detail = new TextBlock
        {
            Text = path,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var content = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 6, 0, 6) };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1, Children = { title, detail } };
        Grid.SetColumn(texts, 1);
        content.Children.Add(badge);
        content.Children.Add(texts);
        var item = new ListViewItem { Content = content, Tag = path, MinHeight = 44 };
        ToolTipService.SetToolTip(item, path);
        item.ContextFlyout = RowMenu(path);
        return item;
    }

    private MenuFlyout RowMenu(string path)
    {
        var open = new MenuFlyoutItem { Text = L10n.Tr("welcome.recent.open") };
        open.Click += (_, _) => _app.OpenProject(path, this);
        var reveal = new MenuFlyoutItem { Text = L10n.Tr("welcome.recent.reveal") };
        reveal.Click += (_, _) => Shell.RevealInExplorer(path);
        var remove = new MenuFlyoutItem { Text = L10n.Tr("welcome.recent.remove") };
        remove.Click += (_, _) =>
        {
            RecentProjects.Remove(path);
            Reload();
        };
        return new MenuFlyout { Items = { open, reveal, new MenuFlyoutSeparator(), remove } };
    }

    private void OpenSelected()
    {
        if (_list.SelectedItem is ListViewItem { Tag: string path }) _app.OpenProject(path, this);
    }

    private void RunDebugAction()
    {
        switch (DebugOptions.Get("debug.action"))
        {
            case "clone":
                _ = _app.CloneProject(this);
                break;
            case "recentMenu" when _list.Items.FirstOrDefault() is ListViewItem first:
                first.ContextFlyout.ShowAt(first, new FlyoutShowOptions { Position = new Windows.Foundation.Point(40, 30) });
                break;
        }
        Snapshot.Schedule(this);
    }
}
