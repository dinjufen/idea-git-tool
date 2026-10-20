using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Common;

/// 管理类对话框（Remotes、Submodules）：独立的小窗口，内含列表与按钮行。
///
/// WinUI 同一窗口只能同时显示一个 ContentDialog；这类对话框中还要弹出编辑 / 确认对话框，
/// 因此用独立窗口承载（对应 mac 端以表单显示的面板，其中的提示框附着在面板上）。
public class ToolDialog : Window
{
    private const double TitleBarHeight = 32;

    private readonly Grid _root = new();
    private readonly StackPanel _leftButtons = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly StackPanel _rightButtons = new() { Orientation = Orientation.Horizontal, Spacing = 8 };

    protected ToolDialog(string title, double width, double height)
    {
        Title = title;
        ExtendsContentIntoTitleBar = true;
        WindowHelper.SetIcon(this);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
        Themed.Background(_root, "ToolWindowBackgroundBrush");
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBarHeight) });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var titleBar = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        titleBar.Children.Add(Themed.Foreground(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 0, 60, 0) }, "PrimaryTextBrush"));
        _root.Children.Add(titleBar);
        var buttons = new Grid { Margin = new Thickness(16, 12, 16, 16) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.Children.Add(_leftButtons);
        Grid.SetColumn(_rightButtons, 1);
        buttons.Children.Add(_rightButtons);
        Grid.SetRow(buttons, 2);
        _root.Children.Add(buttons);
        Content = _root;
        SetTitleBar(titleBar);
        Appearance.Register(this);
        WindowHelper.ResizeAndCenter(this, width, height);
        var close = AddButton(L10n.Tr("conflicts.close"), Close, right: true);
        close.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        close.MinWidth = 90;
    }

    protected XamlRoot DialogRoot => _root.XamlRoot;

    protected void SetBody(FrameworkElement body)
    {
        body.Margin = new Thickness(16, 8, 16, 0);
        Grid.SetRow(body, 1);
        _root.Children.Add(body);
    }

    protected Button AddButton(string title, Action action, bool right = false)
    {
        var button = new Button { Content = title };
        button.Click += (_, _) => action();
        (right ? _rightButtons : _leftButtons).Children.Add(button);
        return button;
    }

    /// 带表头的列表：每行由 `row` 生成，列宽与表头一致。
    protected static (FrameworkElement View, ListView List) Table(IReadOnlyList<(string Title, GridLength Width)> columns, ListViewSelectionMode mode)
    {
        var header = Columns(columns, [.. columns.Select(c => (FrameworkElement)new TextBlock
        {
            Text = c.Title,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
        })]);
        header.Margin = new Thickness(12, 0, 12, 4);
        var list = new ListView { SelectionMode = mode };
        var border = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Child = list };
        Themed.Brush(border, "SeparatorBrush", (b, brush) => b.BorderBrush = brush);
        Themed.Background(border, "EditorBackgroundBrush");
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(header);
        Grid.SetRow(border, 1);
        grid.Children.Add(border);
        return (grid, list);
    }

    protected static Grid Columns(IReadOnlyList<(string Title, GridLength Width)> columns, IReadOnlyList<FrameworkElement> cells)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        for (var i = 0; i < columns.Count; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = columns[i].Width });
            if (cells[i] is TextBlock text)
            {
                text.TextTrimming = TextTrimming.CharacterEllipsis;
                text.VerticalAlignment = VerticalAlignment.Center;
            }
            Grid.SetColumn(cells[i], i);
            grid.Children.Add(cells[i]);
        }
        return grid;
    }
}
