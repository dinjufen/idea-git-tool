using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Project;

/// 主工具栏下方的提示条（与 mac 端 WorkspaceBanner 一致）：检测到项目中有尚未加入的 git 仓库时提示加入
/// （IDEA 的 “Unregistered VCS roots detected”）。
public sealed class WorkspaceBanner : Grid
{
    private readonly TextBlock _label = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };

    public WorkspaceBanner()
    {
        Height = 36;
        Visibility = Visibility.Collapsed;
        ColumnSpacing = 8;
        Padding = new Thickness(14, 0, 14, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Icons.Create(Icon.Branch, 14);
        icon.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(icon);
        SetColumn(_label, 1);
        Themed.Foreground(_label, "PrimaryTextBrush");
        Children.Add(_label);
        var ignore = new Button { Content = L10n.Tr("workspace.banner.ignore"), Padding = new Thickness(10, 2, 10, 3), VerticalAlignment = VerticalAlignment.Center };
        ignore.Click += (_, _) => IgnoreClicked?.Invoke();
        SetColumn(ignore, 2);
        Children.Add(ignore);
        var add = new Button { Content = L10n.Tr("workspace.banner.add"), Padding = new Thickness(10, 2, 10, 3), VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        add.Click += (_, _) => AddClicked?.Invoke();
        SetColumn(add, 3);
        Children.Add(add);
        var bottom = Themed.Background(new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(-14, 0, -14, 0) }, "SeparatorBrush");
        SetColumnSpan(bottom, 4);
        Children.Add(bottom);
        UpdateBackground();
        ActualThemeChanged += (_, _) => UpdateBackground();
    }

    public event Action? AddClicked;

    public event Action? IgnoreClicked;

    private void UpdateBackground() =>
        Background = new SolidColorBrush(Editor.SyntaxTheme.Rgb(ActualTheme == ElementTheme.Dark ? 0x25324Du : 0xEDF3FFu));

    /// 显示检测到的仓库；为空时隐藏。
    public void Show(IReadOnlyList<NestedRepository> candidates)
    {
        Visibility = candidates.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (candidates.Count == 0) return;
        var names = string.Join(", ", candidates.Take(4).Select(c => c.RelativePath)) + (candidates.Count > 4 ? " …" : "");
        _label.Text = L10n.Tr("workspace.banner.message", candidates.Count, names);
        ToolTipService.SetToolTip(_label, string.Join("\n", candidates.Select(c => c.RelativePath)));
    }
}
