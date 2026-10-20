using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Common;

/// 界面字体（IDEA 的 设置 > 外观 > “使用自定义字体”）：作用于菜单、工具窗口、树、对话框等，编辑器字体单独设置。
/// 默认跟随系统字体（Segoe UI Variable）；勾选自定义后可选字体与字号，立即生效。
public static class UiFont
{
    public const double DefaultSize = 14;
    public const double MinSize = 10;
    public const double MaxSize = 24;

    private const string CustomKey = "ui.font.custom";
    private const string FamilyKey = "ui.font.family";
    private const string SizeKey = "ui.font.size";

    private static readonly List<WeakReference<UserControl>> Hosts = [];
    private static FontFamily? _systemFamily;
    private static double? _systemSize;

    public static event Action? Changed;

    public static bool UseCustom
    {
        get => Settings.GetBool(CustomKey);
        set
        {
            Settings.Set(CustomKey, value);
            Apply();
        }
    }

    public static string? Family
    {
        get => Settings.GetString(FamilyKey) is { Length: > 0 } family ? family : null;
        set
        {
            Settings.Set(FamilyKey, value ?? "");
            Apply();
        }
    }

    public static double Size
    {
        get => Math.Clamp(Settings.GetDouble(SizeKey, DefaultSize), MinSize, MaxSize);
        set
        {
            Settings.Set(SizeKey, Math.Clamp(Math.Round(value), MinSize, MaxSize));
            Apply();
        }
    }

    /// 当前生效的字体与字号；未启用自定义时为系统默认。
    private static (FontFamily Family, double Size) Effective()
    {
        var resources = Application.Current.Resources;
        _systemFamily ??= resources["ContentControlThemeFontFamily"] as FontFamily ?? new FontFamily("Segoe UI Variable");
        _systemSize ??= resources["ControlContentThemeFontSize"] is double size ? size : DefaultSize;
        if (!UseCustom) return (_systemFamily, _systemSize.Value);
        return (Family is { } family ? new FontFamily(family) : _systemFamily, Size);
    }

    /// 包装窗口内容：字体由外层的 UserControl 继承给其中的文字与控件（与在 Page 上设置字体相同）。
    public static FrameworkElement Host(UIElement content)
    {
        var (family, size) = Effective();
        var host = new UserControl
        {
            Content = content,
            IsTabStop = false,
            FontFamily = family,
            FontSize = size,
        };
        Hosts.Add(new WeakReference<UserControl>(host));
        return host;
    }

    /// 启动时调用：按设置更新控件模板使用的主题资源（之后创建的控件直接使用）。
    public static void Initialize() => UpdateResources();

    private static double _appliedSize;

    private static void UpdateResources()
    {
        var (family, size) = Effective();
        var resources = Application.Current.Resources;
        resources["ContentControlThemeFontFamily"] = family;
        resources["ControlContentThemeFontSize"] = size;
        // 默认的 TextBlock 样式使用固定字号：用隐式样式设置正文字号（之后创建的文字使用）。
        var style = new Style(typeof(TextBlock));
        style.Setters.Add(new Setter(TextBlock.FontSizeProperty, size));
        resources[typeof(TextBlock)] = style;
        _appliedSize = size;
    }

    /// 已创建的正文文字（字号等于原先的正文字号）改为新字号；单独设置过字号的文字（例如说明文字）保持不变。
    private static void Resize(DependencyObject element, double from, double to)
    {
        if (element is TextBlock text && text.FontSize == from) text.FontSize = to;
        var count = VisualTreeHelper.GetChildrenCount(element);
        for (var i = 0; i < count; i++) Resize(VisualTreeHelper.GetChild(element, i), from, to);
    }

    private static void Apply()
    {
        var previous = _appliedSize;
        UpdateResources();
        var (family, size) = Effective();
        Hosts.RemoveAll(reference => !reference.TryGetTarget(out _));
        foreach (var reference in Hosts)
        {
            if (!reference.TryGetTarget(out var host)) continue;
            host.FontFamily = family;
            host.FontSize = size;
            if (previous != size) Resize(host, previous, size);
        }
        // 控件模板中的 ThemeResource 在主题变化时重新取值：刷新已打开窗口中的按钮、输入框等。
        Appearance.Refresh();
        Changed?.Invoke();
    }
}
