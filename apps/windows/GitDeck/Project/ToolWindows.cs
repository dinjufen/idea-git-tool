using GitDeck.Common;
using GitDeck.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Project;

/// 工具窗口标识。顺序与 IDEA 默认布局一致（与 mac 端 ToolWindowID 一致）。
public enum ToolWindowId
{
    Project,
    Commit,
    Git,
    AiReview,
}

public enum ToolWindowAnchor
{
    Left,
    Bottom,
    Right,
}

public static class ToolWindowIds
{
    public static string Title(this ToolWindowId id) => id switch
    {
        ToolWindowId.Project => L10n.Tr("toolwindow.project"),
        ToolWindowId.Commit => L10n.Tr("toolwindow.commit"),
        ToolWindowId.Git => L10n.Tr("toolwindow.git"),
        _ => L10n.Tr("toolwindow.aiReview"),
    };

    public static Icon Icon(this ToolWindowId id) => id switch
    {
        ToolWindowId.Project => Common.Icon.Folder,
        ToolWindowId.Commit => Common.Icon.Commit,
        ToolWindowId.Git => Common.Icon.Branch,
        _ => Common.Icon.Sparkles,
    };

    /// 停靠位置：Project / Commit 在左侧面板，Git 在底部面板，AI Review 在右侧面板。
    public static ToolWindowAnchor Anchor(this ToolWindowId id) => id switch
    {
        ToolWindowId.Project or ToolWindowId.Commit => ToolWindowAnchor.Left,
        ToolWindowId.Git => ToolWindowAnchor.Bottom,
        _ => ToolWindowAnchor.Right,
    };

    /// IDEA Windows 键位：Alt+1 Project、Alt+0 Commit、Alt+9 Git。
    public static string? Shortcut(this ToolWindowId id) => id switch
    {
        ToolWindowId.Project => "Alt+1",
        ToolWindowId.Commit => "Alt+0",
        ToolWindowId.Git => "Alt+9",
        _ => null,
    };
}

/// 窗口侧边的工具窗口图标条。左侧图标条：上半部分为左侧面板，下半部分为底部面板；右侧图标条对应右侧面板。
public sealed class ToolWindowStripe : Grid
{
    public const double StripeWidth = 40;

    private readonly Dictionary<ToolWindowId, IconButton> _buttons = [];

    public event Action<ToolWindowId>? Toggled;

    public ToolWindowStripe(ToolWindowId[] top, ToolWindowId[] bottom)
    {
        Width = StripeWidth;
        Themed.Background(this, "ToolWindowBackgroundBrush");
        var topStack = new StackPanel { Spacing = 6, Margin = new Thickness(0, 6, 0, 0), VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center };
        var bottomStack = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var id in top) topStack.Children.Add(MakeButton(id));
        foreach (var id in bottom) bottomStack.Children.Add(MakeButton(id));
        Children.Add(topStack);
        Children.Add(bottomStack);
    }

    public IReadOnlyDictionary<ToolWindowId, IconButton> Buttons => _buttons;

    public void SetActive(IReadOnlySet<ToolWindowId> active)
    {
        foreach (var (id, button) in _buttons) button.IsSelected = active.Contains(id);
    }

    private IconButton MakeButton(ToolWindowId id)
    {
        var tooltip = id.Shortcut() is { } shortcut ? $"{id.Title()} ({shortcut})" : id.Title();
        var button = new IconButton(id.Icon(), tooltip);
        button.Click += (_, _) => Toggled?.Invoke(id);
        _buttons[id] = button;
        return button;
    }
}

/// 工具窗口外框：标题栏（标题 + 右侧操作按钮）+ 内容。尚未实现的工具窗口显示占位文字。
public sealed class ToolWindowPanel : Grid
{
    public ToolWindowPanel(string title, UIElement? body = null, IEnumerable<UIElement>? actions = null)
    {
        Themed.Background(this, "ToolWindowBackgroundBrush");
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(12, 0, 6, 0) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        }, "PrimaryTextBrush"));
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        foreach (var action in actions ?? []) toolbar.Children.Add(action);
        SetColumn(toolbar, 1);
        header.Children.Add(toolbar);
        Children.Add(header);
        var content = body ?? new TextBlock
        {
            Text = L10n.Tr("common.notImplemented"),
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        SetRow((FrameworkElement)content, 1);
        Children.Add(content);
    }
}
