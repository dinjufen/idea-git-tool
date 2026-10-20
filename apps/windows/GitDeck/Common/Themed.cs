using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Common;

/// 代码中创建的元素使用主题画刷：按元素的实际主题取值，加载和主题切换时重新应用（相当于 XAML 的 {ThemeResource}）。
public static class Themed
{
    public static T Brush<T>(T element, string key, Action<T, Brush> apply) where T : FrameworkElement
    {
        void Update() => apply(element, Icons.ThemeBrush(element, key));
        Update();
        element.Loaded += (_, _) => Update();
        element.ActualThemeChanged += (_, _) => Update();
        return element;
    }

    public static T Background<T>(T element, string key) where T : FrameworkElement => element switch
    {
        Microsoft.UI.Xaml.Controls.Panel => Brush(element, key, (e, b) => ((Microsoft.UI.Xaml.Controls.Panel)(object)e).Background = b),
        Microsoft.UI.Xaml.Controls.Border => Brush(element, key, (e, b) => ((Microsoft.UI.Xaml.Controls.Border)(object)e).Background = b),
        Microsoft.UI.Xaml.Controls.Control => Brush(element, key, (e, b) => ((Microsoft.UI.Xaml.Controls.Control)(object)e).Background = b),
        _ => element,
    };

    public static T Foreground<T>(T element, string key) where T : FrameworkElement => element switch
    {
        Microsoft.UI.Xaml.Controls.TextBlock => Brush(element, key, (e, b) => ((Microsoft.UI.Xaml.Controls.TextBlock)(object)e).Foreground = b),
        Microsoft.UI.Xaml.Controls.Control => Brush(element, key, (e, b) => ((Microsoft.UI.Xaml.Controls.Control)(object)e).Foreground = b),
        _ => element,
    };
}
