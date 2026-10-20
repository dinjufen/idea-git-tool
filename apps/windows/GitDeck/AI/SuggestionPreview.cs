using GitDeck.Common;
using GitDeck.Diff;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.AI;

/// 应用 AI 修改建议前的 Diff 预览（与 mac 端 SuggestionPreview 一致）：用户确认后才写入文件。
/// 预览中的 Diff 较大，用独立窗口显示。
public sealed class SuggestionPreview : Window
{
    private const double TitleBarHeight = 32;

    private SuggestionPreview(string path, string title, string before, string after, Action onApply)
    {
        Title = L10n.Tr("ai.apply.title", Path.GetFileName(path));
        ExtendsContentIntoTitleBar = true;
        WindowHelper.SetIcon(this);
        var root = new Grid();
        Themed.Background(root, "ToolWindowBackgroundBrush");
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBarHeight) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var titleBar = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        titleBar.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = Title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(14, 0, 140, 0),
        }, "PrimaryTextBrush"));
        root.Children.Add(titleBar);
        SetTitleBar(titleBar);

        var subtitle = new TextBlock
        {
            Text = title,
            Margin = new Thickness(14, 0, 14, 8),
            TextTrimming = TextTrimming.CharacterEllipsis,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
        };
        Grid.SetRow(subtitle, 1);
        root.Children.Add(subtitle);

        var diff = new DiffView(new DiffSide(L10n.Tr("ai.apply.before"), before), new DiffSide(L10n.Tr("ai.apply.after"), after), path);
        Grid.SetRow(diff, 2);
        root.Children.Add(diff);

        var apply = new Button { Content = L10n.Tr("ai.apply.confirm"), MinWidth = 90, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        apply.Click += (_, _) =>
        {
            onApply();
            Close();
        };
        var cancel = new Button { Content = L10n.Tr("common.cancel"), MinWidth = 90 };
        cancel.Click += (_, _) => Close();
        // Windows 的按钮顺序：确定在前、取消在后。
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(14, 12, 14, 14),
            Children = { apply, cancel },
        };
        Grid.SetRow(buttons, 3);
        root.Children.Add(buttons);

        Content = root;
        Appearance.Register(this);
        WindowHelper.ResizeAndCenter(this, 980, 640);
        WindowHelper.SetMinimumSize(this, 640, 400);
    }

    public static Window Present(string path, string title, string before, string after, Action onApply)
    {
        var window = new SuggestionPreview(path, title, before, after, onApply);
        window.Activate();
        return window;
    }
}
