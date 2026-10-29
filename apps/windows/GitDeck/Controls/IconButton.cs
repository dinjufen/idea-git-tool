using GitDeck.Common;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Controls;

/// IDEA New UI 风格的图标按钮：无边框、悬停时出现圆角底色，可切换选中态（工具窗口图标条）。
public sealed class IconButton : Button
{
    private bool _isSelected;

    public IconButton(Icon icon, string tooltip, double size = 30, double iconSize = 16)
    {
        Style = (Style)Application.Current.Resources["FlatButtonStyle"];
        Width = size;
        Height = size;
        Padding = new Thickness(0);
        HorizontalContentAlignment = HorizontalAlignment.Center;
        VerticalContentAlignment = VerticalAlignment.Center;
        Content = Icons.Create(icon, iconSize);
        ToolTipService.SetToolTip(this, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, tooltip);
        ActualThemeChanged += (_, _) => UpdateBackground();
        FastToolTip.Attach(this);
    }

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            _isSelected = value;
            UpdateBackground();
        }
    }

    private void UpdateBackground() =>
        Background = _isSelected ? Icons.ThemeBrush(this, "SelectedStripeBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
}
