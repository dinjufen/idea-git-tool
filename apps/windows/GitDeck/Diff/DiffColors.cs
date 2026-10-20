using GitDeck.Core;
using GitDeck.Editor;
using Windows.UI;

namespace GitDeck.Diff;

/// Diff 着色，对应 IDEA 的 Diff Inserted / Modified / Deleted 配色；单词级变化使用更深的同色系（与 mac 端 DiffColors 一致）。
public static class DiffColors
{
    public static Color Block(LineChangeKind kind, bool dark) => SyntaxTheme.Rgb(kind switch
    {
        LineChangeKind.Added => dark ? 0x294436u : 0xE3F5E1u,
        LineChangeKind.Modified => dark ? 0x2B3B57u : 0xE3ECFCu,
        _ => dark ? 0x3A3D41u : 0xEBEBEBu,
    });

    public static Color Inline(LineChangeKind kind, bool dark) => SyntaxTheme.Rgb(kind switch
    {
        LineChangeKind.Added => dark ? 0x375E46u : 0xC3E8BFu,
        LineChangeKind.Modified => dark ? 0x36507Au : 0xC3D5F5u,
        _ => dark ? 0x4E5157u : 0xD6D6D6u,
    });

    /// 一侧没有对应行时（新增块的左侧、删除块的右侧），在对应位置画的分隔线颜色。
    public static Color Marker(LineChangeKind kind, bool dark) => SyntaxTheme.Rgb(kind switch
    {
        LineChangeKind.Added => dark ? 0x549159u : 0x9CCF94u,
        LineChangeKind.Modified => dark ? 0x375FADu : 0x99B6F2u,
        _ => dark ? 0x6F737Au : 0xB4B7BDu,
    });

    /// 不提交的行：块颜色以 `alpha` 叠加在背景上。
    public static Color Blend(Color color, Color background, double alpha) => Color.FromArgb(255,
        (byte)Math.Round(color.R * alpha + background.R * (1 - alpha)),
        (byte)Math.Round(color.G * alpha + background.G * (1 - alpha)),
        (byte)Math.Round(color.B * alpha + background.B * (1 - alpha)));

    /// 强调色（复选框）。
    public static Color Accent => SyntaxTheme.Rgb(0x3574F0);
}
