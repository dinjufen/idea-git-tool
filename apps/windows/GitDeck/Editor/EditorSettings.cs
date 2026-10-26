using GitDeck.Common;
using GitDeck.Core;
using Windows.UI;

namespace GitDeck.Editor;

/// 编辑器字体与行距设置（对应 IDEA 的 Settings > Editor > Font，与 mac 端 EditorSettings 一致）。
/// 与界面字体分开设置。修改后触发 <see cref="Changed"/>，所有编辑器立即更新。
public static class EditorSettings
{
    public const double DefaultSize = 13;
    public const double MinSize = 8;
    public const double MaxSize = 40;
    public static readonly double[] LineSpacingOptions = [1.0, 1.2, 1.4, 1.6];

    /// 未设置字体时依次尝试的等宽字体（Windows 11 自带 Cascadia Mono，Windows 10 自带 Consolas）。
    public static readonly string[] FallbackFamilies = ["Cascadia Mono", "Consolas", "Courier New"];

    private const string FamilyKey = "editor.fontFamily";
    private const string SizeKey = "editor.fontSize";
    private const string LineSpacingKey = "editor.lineSpacing";
    private const string InlineBlameKey = "editor.inlineBlame";

    public static event Action? Changed;

    /// 字体族；为空时使用默认等宽字体。
    public static string? FontFamily
    {
        get => Settings.GetString(FamilyKey);
        set
        {
            Settings.Set(FamilyKey, string.IsNullOrWhiteSpace(value) ? null : value.Trim());
            Changed?.Invoke();
        }
    }

    /// 字号（逻辑像素，与 IDEA 的字号含义一致）。
    public static double FontSize
    {
        get => Settings.GetDouble(SizeKey, DefaultSize) is var value && value > 0 ? value : DefaultSize;
        set
        {
            Settings.Set(SizeKey, Math.Clamp(Math.Round(value), MinSize, MaxSize));
            Changed?.Invoke();
        }
    }

    public static double LineSpacing
    {
        get => Settings.GetDouble(LineSpacingKey, 1.2) is var value && value > 0 ? value : 1.2;
        set
        {
            Settings.Set(LineSpacingKey, value);
            Changed?.Invoke();
        }
    }

    /// 在光标所在行的行尾显示该行最近一次提交（与 VSCode / GitLens 的 current line blame 一致），默认开启。
    public static bool InlineBlame
    {
        get => Settings.GetBool(InlineBlameKey, true);
        set
        {
            Settings.Set(InlineBlameKey, value);
            Changed?.Invoke();
        }
    }

    /// 实际使用的字体族：设置的字体未安装时回退到默认等宽字体。
    public static string EffectiveFamily =>
        FontFamily is { } family && FontCatalog.IsInstalled(family)
            ? family
            : FallbackFamilies.FirstOrDefault(FontCatalog.IsInstalled) ?? "Consolas";

    public static void Reset()
    {
        Settings.Remove(FamilyKey);
        Settings.Remove(SizeKey);
        Changed?.Invoke();
    }
}

/// 语法配色，对应 IDEA 默认配色方案：浅色主题为 IntelliJ Light，深色主题为 New UI Dark（与 mac 端 SyntaxTheme 一致）。
public static class SyntaxTheme
{
    public static Color Text(bool dark) => Rgb(dark ? 0xBCBEC4u : 0x080808u);

    public static Color Background(bool dark) => Rgb(dark ? 0x1E1F22u : 0xFFFFFFu);

    public static Color CurrentLine(bool dark) => Rgb(dark ? 0x26282Eu : 0xF5F8FEu);

    public static Color Selection(bool dark) => Rgb(dark ? 0x214283u : 0xA6D2FFu);

    public static Color LineNumber(bool dark) => Rgb(dark ? 0x4B5059u : 0xAEB3C2u);

    public static Color CurrentLineNumber(bool dark) => Rgb(dark ? 0xA1A3ABu : 0x767A8Au);

    /// 查找结果的背景（IDEA 的 Search result）。
    public static Color FindMatch(bool dark) => Rgb(dark ? 0x32593Du : 0xF6EA9Eu);

    public static Color Token(TokenKind kind, bool dark) => Rgb(kind switch
    {
        TokenKind.Keyword => dark ? 0xCF8E6Du : 0x0033B3u,
        TokenKind.String => dark ? 0x6AAB73u : 0x067D17u,
        TokenKind.StringSpecial => dark ? 0x42C3D4u : 0x264EFFu,
        TokenKind.Escape => dark ? 0xCF8E6Du : 0x0037A6u,
        TokenKind.Comment => dark ? 0x7A7E85u : 0x8C8C8Cu,
        TokenKind.Number => dark ? 0x2AACB8u : 0x1750EBu,
        TokenKind.Constant => dark ? 0xC77DBBu : 0x871094u,
        TokenKind.Function => dark ? 0x56A8F5u : 0x00627Au,
        TokenKind.Type => dark ? 0xBCBEC4u : 0x000000u,
        TokenKind.Parameter => dark ? 0xBCBEC4u : 0x080808u,
        TokenKind.Property => dark ? 0xC77DBBu : 0x871094u,
        TokenKind.Tag => dark ? 0xD5B778u : 0x0033B3u,
        TokenKind.Attribute => dark ? 0xBABABAu : 0x174AD4u,
        TokenKind.Namespace => dark ? 0xBCBEC4u : 0x000000u,
        TokenKind.Label => dark ? 0xB3AE60u : 0x9E880Du,
        TokenKind.Heading => dark ? 0xCF8E6Du : 0x0033B3u,
        _ => dark ? 0xBCBEC4u : 0x080808u,
    });

    /// 行状态标记颜色（IDEA 的 line status markers）。
    public static Color LineAdded(bool dark) => Rgb(dark ? 0x549159u : 0x9CCF94u);

    public static Color LineModified(bool dark) => Rgb(dark ? 0x375FADu : 0x99B6F2u);

    public static Color LineDeleted(bool dark) => Rgb(dark ? 0x868A91u : 0x9EA3AEu);

    public static Color Rgb(uint rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
}
