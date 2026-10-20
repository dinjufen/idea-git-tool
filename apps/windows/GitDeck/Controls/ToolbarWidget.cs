using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Controls;

/// 主工具栏中的下拉组件（项目组件、VCS 分支组件）：图标 + 标题 + 下拉箭头。
public sealed class ToolbarWidget : Button
{
    private readonly TextBlock _label = new() { VerticalAlignment = VerticalAlignment.Center, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };

    public ToolbarWidget(FrameworkElement? leading, string tooltip)
    {
        Style = (Style)Application.Current.Resources["FlatButtonStyle"];
        Height = 30;
        Padding = new Thickness(6, 0, 6, 0);
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (leading is not null) stack.Children.Add(leading);
        stack.Children.Add(_label);
        stack.Children.Add(Icons.Create(Icon.ChevronDown, 12));
        Content = stack;
        ToolTipService.SetToolTip(this, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, tooltip);
    }

    public string Title
    {
        get => _label.Text;
        set => _label.Text = value;
    }
}
