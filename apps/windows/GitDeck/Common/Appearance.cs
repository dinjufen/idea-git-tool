using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace GitDeck.Common;

/// 界面主题，对应 IDEA 设置中的 Theme（含 “Sync with OS”）。各窗口的根元素随设置切换。
public enum AppearanceSetting
{
    System,
    Light,
    Dark,
}

public static class Appearance
{
    private const string Key = "appearance";
    private static readonly List<Window> Windows = [];

    public static AppearanceSetting Current
    {
        get => Enum.TryParse<AppearanceSetting>(Settings.GetString(Key), ignoreCase: true, out var value) ? value : AppearanceSetting.System;
        set
        {
            Settings.Set(Key, value.ToString().ToLowerInvariant());
            foreach (var window in Windows.ToList()) Apply(window);
        }
    }

    /// 调试参数 `-debug.theme light|dark` 临时覆盖（不写入设置）。
    public static AppearanceSetting? Override { get; set; }

    public static string Title(AppearanceSetting setting) => setting switch
    {
        AppearanceSetting.Light => L10n.Tr("theme.light"),
        AppearanceSetting.Dark => L10n.Tr("theme.dark"),
        _ => L10n.Tr("theme.system"),
    };

    /// 登记窗口：应用当前主题，并在主题变化时同步标题栏按钮颜色。
    public static void Register(Window window)
    {
        Windows.Add(window);
        window.Closed += (_, _) => Windows.Remove(window);
        if (window.Content is FrameworkElement root)
        {
            root.ActualThemeChanged += (_, _) => UpdateCaptionButtons(window);
        }
        Apply(window);
    }

    private static void Apply(Window window)
    {
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = (Override ?? Current) switch
            {
                AppearanceSetting.Light => ElementTheme.Light,
                AppearanceSetting.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default,
            };
        }
        UpdateCaptionButtons(window);
    }

    /// 标题栏扩展到内容区后，最小化 / 最大化 / 关闭按钮的颜色需要按主题手动设置。
    private static void UpdateCaptionButtons(Window window)
    {
        if (window.Content is not FrameworkElement root || !AppWindowTitleBar.IsCustomizationSupported()) return;
        var dark = root.ActualTheme == ElementTheme.Dark;
        var bar = window.AppWindow.TitleBar;
        var foreground = dark ? Color.FromArgb(255, 0xDF, 0xE1, 0xE5) : Color.FromArgb(255, 0, 0, 0);
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = foreground;
        bar.ButtonInactiveForegroundColor = dark ? Color.FromArgb(255, 0x6F, 0x73, 0x7A) : Color.FromArgb(255, 0x81, 0x85, 0x94);
        bar.ButtonHoverForegroundColor = foreground;
        bar.ButtonHoverBackgroundColor = dark ? Color.FromArgb(255, 0x39, 0x3B, 0x40) : Color.FromArgb(255, 0xDF, 0xE1, 0xE5);
        bar.ButtonPressedForegroundColor = foreground;
        bar.ButtonPressedBackgroundColor = dark ? Color.FromArgb(255, 0x43, 0x45, 0x4A) : Color.FromArgb(255, 0xC9, 0xCC, 0xD6);
    }
}
