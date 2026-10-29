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
    ExpandAll,
    Rollback,
    Diff,
    Shelve,
    Gear,
    ArrowUp,
    ArrowDown,
    Wand,
    ChevronsRight,
    ChevronsLeft,
    Tray,
    Stop,
    SeverityError,
    SeverityWarning,
    SeveritySuggestion,
    Plus,
    OpenWindow,
    Unstash,
    Pop,
    Trash,
    ClearAll,
    Edit,
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
        Icon.ExpandAll => "M4.5,5.5 L8,2 L11.5,5.5 M4.5,10.5 L8,14 L11.5,10.5",
        Icon.Rollback => "M3,6.5 L11,6.5 A3.5,3.5 0 0 1 11,13.5 L6,13.5 M5.5,3.5 L2.5,6.5 L5.5,9.5",
        Icon.Diff => "M5,2.5 L5,8.5 M2,5.5 L8,5.5 M8,12.5 L14,12.5",
        Icon.Shelve => "M2,9.5 L2,13.5 L14,13.5 L14,9.5 M8,2 L8,10 M5,7 L8,10 L11,7",
        Icon.Gear => "M8,5.5 A2.5,2.5 0 1 1 7.99,5.5 Z M8,1.5 L8,3.5 M8,12.5 L8,14.5 M1.5,8 L3.5,8 M12.5,8 L14.5,8 M3.4,3.4 L4.8,4.8 M11.2,11.2 L12.6,12.6 M3.4,12.6 L4.8,11.2 M11.2,4.8 L12.6,3.4",
        Icon.ArrowUp => "M8,13.5 L8,2.5 M3.5,7 L8,2.5 L12.5,7",
        Icon.ArrowDown => "M8,2.5 L8,13.5 M3.5,9 L8,13.5 L12.5,9",
        Icon.Wand => "M2.5,13.5 L9.5,6.5 M11,1.5 L11.5,3 L13,3.5 L11.5,4 L11,5.5 L10.5,4 L9,3.5 L10.5,3 Z M13.5,7.5 L13.8,8.2 L14.5,8.5 L13.8,8.8 L13.5,9.5 L13.2,8.8 L12.5,8.5 L13.2,8.2 Z",
        Icon.ChevronsRight => "M3.5,4 L7.5,8 L3.5,12 M8.5,4 L12.5,8 L8.5,12",
        Icon.ChevronsLeft => "M12.5,4 L8.5,8 L12.5,12 M7.5,4 L3.5,8 L7.5,12",
        Icon.Plus => "M8,3 L8,13 M3,8 L13,8",
        Icon.OpenWindow => "M1.5,3.5 L10.5,3.5 L10.5,12.5 L1.5,12.5 Z M1.5,5.5 L10.5,5.5 M13,7 L13,11 M11,9 L15,9",
        Icon.Stop => "M8,1.5 A6.5,6.5 0 1 1 7.99,1.5 Z M6,6 L10,6 L10,10 L6,10 Z",
        Icon.SeverityError => "M5.5,1.5 L10.5,1.5 L14.5,5.5 L14.5,10.5 L10.5,14.5 L5.5,14.5 L1.5,10.5 L1.5,5.5 Z M6,6 L10,10 M10,6 L6,10",
        Icon.SeverityWarning => "M8,1.5 L15,14 L1,14 Z M8,6 L8,9.5 M8,11.5 L8,11.8",
        Icon.SeveritySuggestion => "M8,1.5 A4.5,4.5 0 0 1 10.5,9.8 L10.5,12 L5.5,12 L5.5,9.8 A4.5,4.5 0 0 1 8,1.5 Z M6,14.2 L10,14.2",
        Icon.Tray => "M2,9.5 L2,13.5 L14,13.5 L14,9.5 L10.5,9.5 L9.8,11 L6.2,11 L5.5,9.5 Z M2,9.5 L3.8,3 L12.2,3 L14,9.5",
        Icon.Unstash => "M2,9.5 L2,13.5 L14,13.5 L14,9.5 M8,10.5 L8,2.5 M5,5.5 L8,2.5 L11,5.5",
        Icon.Pop => "M3.5,1.5 L9.5,1.5 L12.5,4.5 L12.5,14.5 L3.5,14.5 Z M8,12 L8,6.5 M5.8,8.7 L8,6.5 L10.2,8.7",
        Icon.Edit => "M10.5,2.5 L13.5,5.5 L5.5,13.5 L2.5,13.5 L2.5,10.5 Z M9,4 L12,7",
        Icon.Trash => "M2.5,4.5 L13.5,4.5 M6,4.5 L6,2.5 L10,2.5 L10,4.5 M4,4.5 L4.8,13.5 L11.2,13.5 L12,4.5",
        Icon.ClearAll => "M2.5,4.5 L13.5,4.5 M6,4.5 L6,2.5 L10,2.5 L10,4.5 M4,4.5 L4.8,13.5 L11.2,13.5 L12,4.5 M6.5,7.5 L9.5,10.5 M9.5,7.5 L6.5,10.5",
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
