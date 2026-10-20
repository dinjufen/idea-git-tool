using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace GitDeck.Common;

/// 线条图标（16×16 视图，1.2 像素描边），风格接近 IDEA New UI 的图标。
/// 用矢量路径而不是系统字体图标，保证 Windows 10 / 11 显示一致。
public enum Icon
{
    Folder,
    Commit,
    Branch,
    Sparkles,
    Refresh,
    Update,
    Push,
    Menu,
    ChevronDown,
    Search,
    ChevronUp,
    Close,
    File,
    CollapseAll,
}

public static class Icons
{
    private static string PathData(Icon icon) => icon switch
    {
        Icon.Folder => "M1.5,3.5 L6,3.5 L7.5,5 L14.5,5 L14.5,13 L1.5,13 Z",
        Icon.Commit => "M8,2 A6,6 0 1 1 7.99,2 Z M5.2,8.2 L7.2,10.2 L11,6.2",
        Icon.Branch => "M4.5,4.5 L4.5,11.5 M4.5,10.5 C4.5,7.5 11.5,9 11.5,5.5 M4.5,1.5 A1.5,1.5 0 1 1 4.49,1.5 Z M4.5,11.5 A1.5,1.5 0 1 1 4.49,11.5 Z M11.5,2.5 A1.5,1.5 0 1 1 11.49,2.5 Z",
        Icon.Sparkles => "M7,1.5 L8.3,5.7 L12.5,7 L8.3,8.3 L7,12.5 L5.7,8.3 L1.5,7 L5.7,5.7 Z M12.5,10.5 L13,12 L14.5,12.5 L13,13 L12.5,14.5 L12,13 L10.5,12.5 L12,12 Z",
        Icon.Refresh => "M13,8 A5,5 0 1 1 11.6,4.5 M12,1.8 L12,4.8 L9,4.8",
        Icon.Update => "M12,4 L4.5,11.5 M4,6.5 L4,12 L9.5,12",
        Icon.Push => "M4,12 L11.5,4.5 M6.5,4 L12,4 L12,9.5",
        Icon.Menu => "M2.5,4 L13.5,4 M2.5,8 L13.5,8 M2.5,12 L13.5,12",
        Icon.ChevronDown => "M4.5,6.5 L8,10 L11.5,6.5",
        Icon.Search => "M7,2.5 A4.5,4.5 0 1 1 6.99,2.5 Z M10.3,10.3 L13.5,13.5",
        Icon.ChevronUp => "M4.5,9.5 L8,6 L11.5,9.5",
        Icon.Close => "M4.5,4.5 L11.5,11.5 M11.5,4.5 L4.5,11.5",
        Icon.File => "M3.5,1.5 L9.5,1.5 L12.5,4.5 L12.5,14.5 L3.5,14.5 Z M9.5,1.5 L9.5,4.5 L12.5,4.5",
        Icon.CollapseAll => "M4.5,2.5 L8,6 L11.5,2.5 M4.5,13.5 L8,10 L11.5,13.5 M2.5,8 L13.5,8",
        _ => "",
    };

    /// 创建图标元素；颜色默认取主题的主文本色。
    public static FrameworkElement Create(Icon icon, double size = 16, Brush? brush = null)
    {
        var path = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), PathData(icon)),
            StrokeThickness = 1.2,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        if (brush is not null)
        {
            path.Stroke = brush;
        }
        else
        {
            Themed.Brush(path, "PrimaryTextBrush", (p, b) => p.Stroke = b);
        }
        return new Viewbox
        {
            Width = size,
            Height = size,
            Child = new Grid { Width = 16, Height = 16, Children = { path } },
        };
    }

    /// 按元素当前的实际主题取主题画刷（ThemeDictionaries 中的条目）。
    public static Brush ThemeBrush(FrameworkElement element, string key)
    {
        var theme = element.ActualTheme == ElementTheme.Dark ? "Dark" : "Light";
        if (Application.Current.Resources.ThemeDictionaries.TryGetValue(theme, out var dictionary)
            && dictionary is ResourceDictionary resources && resources.TryGetValue(key, out var value) && value is Brush brush)
        {
            return brush;
        }
        return (Brush)Application.Current.Resources[key];
    }
}
