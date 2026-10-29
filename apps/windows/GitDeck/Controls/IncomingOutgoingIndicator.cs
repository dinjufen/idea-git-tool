using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Controls;

/// 分支的传入 / 传出提示（IDEA 分支名后的小箭头）：上游有本地没有的提交时显示蓝色 ↙，
/// 本地有尚未推送的提交时显示绿色 ↗；两者都有时都显示。数据来自最近一次 Fetch 后的 ahead / behind。
public sealed class IncomingOutgoingIndicator : StackPanel
{
    private static readonly Windows.UI.Color IncomingColor = Editor.SyntaxTheme.Rgb(0x3574F0);
    private static readonly Windows.UI.Color OutgoingColor = Editor.SyntaxTheme.Rgb(0x5FB865);

    private readonly FrameworkElement _incoming = Icons.Create(Icon.Update, 12, new SolidColorBrush(IncomingColor));
    private readonly FrameworkElement _outgoing = Icons.Create(Icon.Push, 12, new SolidColorBrush(OutgoingColor));
    private readonly TextBlock _incomingCount = Count(IncomingColor);
    private readonly TextBlock _outgoingCount = Count(OutgoingColor);
    private readonly bool _showCounts;
    private readonly StackPanel _incomingGroup;
    private readonly StackPanel _outgoingGroup;

    /// `showCounts`：箭头后显示提交数（分支弹窗中与 IDEA 一致；顶部分支组件只显示箭头）。
    public IncomingOutgoingIndicator(bool showCounts = false)
    {
        _showCounts = showCounts;
        Orientation = Orientation.Horizontal;
        Spacing = 6;
        VerticalAlignment = VerticalAlignment.Center;
        _incomingGroup = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { _incoming, _incomingCount } };
        _outgoingGroup = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Children = { _outgoing, _outgoingCount } };
        Children.Add(_incomingGroup);
        Children.Add(_outgoingGroup);
        Set(0, 0);
    }

    private static TextBlock Count(Windows.UI.Color color) => new()
    {
        FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = new SolidColorBrush(color),
    };

    /// `ahead`：本地领先上游的提交数（传出）；`behind`：落后上游的提交数（传入）。
    public void Set(uint ahead, uint behind)
    {
        _incomingGroup.Visibility = behind > 0 ? Visibility.Visible : Visibility.Collapsed;
        _outgoingGroup.Visibility = ahead > 0 ? Visibility.Visible : Visibility.Collapsed;
        _incomingCount.Text = behind.ToString(System.Globalization.CultureInfo.CurrentCulture);
        _outgoingCount.Text = ahead.ToString(System.Globalization.CultureInfo.CurrentCulture);
        _incomingCount.Visibility = _outgoingCount.Visibility = _showCounts ? Visibility.Visible : Visibility.Collapsed;
        Visibility = ahead > 0 || behind > 0 ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(_incomingGroup, behind > 0 ? L10n.Tr("branches.incoming", behind) : null);
        ToolTipService.SetToolTip(_outgoingGroup, ahead > 0 ? L10n.Tr("branches.outgoing", ahead) : null);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, Description(ahead, behind));
    }

    /// 提示文字（分支组件的工具提示与无障碍名称）。
    public static string Description(uint ahead, uint behind)
    {
        var parts = new List<string>();
        if (behind > 0) parts.Add(L10n.Tr("branches.incoming", behind));
        if (ahead > 0) parts.Add(L10n.Tr("branches.outgoing", ahead));
        return string.Join(", ", parts);
    }
}
