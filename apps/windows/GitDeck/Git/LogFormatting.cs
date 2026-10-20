using GitDeck.Common;
using GitDeck.Core;
using Windows.UI;

namespace GitDeck.Git;

/// IDEA 的“美化”日期格式：今天 / 昨天显示相对日期，其余显示日期与时间（与 mac 端 LogDateFormatter 一致）。
public static class LogDates
{
    public static string Short(long timestamp)
    {
        var date = DateTimeOffset.FromUnixTimeSeconds(timestamp).LocalDateTime;
        var today = DateTime.Today;
        if (date.Date == today) return L10n.Tr("log.date.today", date.ToString("t"));
        if (date.Date == today.AddDays(-1)) return L10n.Tr("log.date.yesterday", date.ToString("t"));
        return date.ToString("g");
    }

    public static string Detailed(long timestamp) => DateTimeOffset.FromUnixTimeSeconds(timestamp).LocalDateTime.ToString("F");
}

/// 提交图配色，按核心返回的颜色序号循环取用。
public static class GraphPalette
{
    private static readonly uint[] Colors = [0x3574F0, 0x5FB865, 0xE55765, 0xD6AE58, 0x955AE0, 0x2E9E9E, 0xE07D3C, 0xC94F9C, 0x6C8EBF, 0x8FAD50];

    public static Color Color(uint index) => Editor.SyntaxTheme.Rgb(Colors[index % Colors.Length]);
}

/// 引用标签底色：本地分支、远程分支、标签、HEAD 区分显示。
public static class RefStyle
{
    public static Color Background(RefKind kind, bool dark) => Editor.SyntaxTheme.Rgb(kind switch
    {
        RefKind.Head => dark ? 0x5C4A1Eu : 0xFFE8B3u,
        RefKind.LocalBranch => dark ? 0x294A2Eu : 0xD9F2DBu,
        RefKind.RemoteBranch => dark ? 0x3F3554u : 0xE8E0F7u,
        _ => dark ? 0x4D4224u : 0xFFF1CCu,
    });
}

/// 历史提交中文件改动的颜色，与本地变更使用相同的 File Status Colors。
public static class ChangeKindStyle
{
    public static string BrushKey(this ChangeKind kind) => kind switch
    {
        ChangeKind.Added or ChangeKind.Copied => "StatusAddedBrush",
        ChangeKind.Deleted => "StatusDeletedBrush",
        ChangeKind.Renamed => "StatusRenamedBrush",
        _ => "StatusModifiedBrush",
    };
}
