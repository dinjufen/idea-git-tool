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

    public IncomingOutgoingIndicator()
    {
        Orientation = Orientation.Horizontal;
        Spacing = 1;
        VerticalAlignment = VerticalAlignment.Center;
        Children.Add(_incoming);
        Children.Add(_outgoing);
        Set(0, 0);
    }

    /// `ahead`：本地领先上游的提交数（传出）；`behind`：落后上游的提交数（传入）。
    public void Set(uint ahead, uint behind)
    {
        _incoming.Visibility = behind > 0 ? Visibility.Visible : Visibility.Collapsed;
        _outgoing.Visibility = ahead > 0 ? Visibility.Visible : Visibility.Collapsed;
        Visibility = ahead > 0 || behind > 0 ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(_incoming, behind > 0 ? L10n.Tr("branches.incoming", behind) : null);
        ToolTipService.SetToolTip(_outgoing, ahead > 0 ? L10n.Tr("branches.outgoing", ahead) : null);
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
