using GitDeck.Core;

namespace GitDeck.Project;

/// 文件状态的展示（与 mac 端 FileChange 扩展一致）。
public static class FileStatus
{
    /// 在 Commit / Project 视图中使用的状态颜色（主题画刷的键名，对应 IDEA 的 File Status Colors）。
    public static string BrushKey(this FileChange change)
    {
        if (change.Conflict is not null) return "StatusConflictBrush";
        if (change.Unstaged == ChangeKind.Untracked) return "StatusUntrackedBrush";
        if (change.Unstaged == ChangeKind.Ignored) return "StatusIgnoredBrush";
        if (change.Staged == ChangeKind.Added || change.Unstaged == ChangeKind.Added) return "StatusAddedBrush";
        if (change.Staged == ChangeKind.Deleted || change.Unstaged == ChangeKind.Deleted) return "StatusDeletedBrush";
        if (change.Staged is ChangeKind.Renamed or ChangeKind.Copied) return "StatusRenamedBrush";
        return "StatusModifiedBrush";
    }

    public static bool IsUntracked(this FileChange change) => change.Unstaged == ChangeKind.Untracked;

    public static bool IsIgnored(this FileChange change) => change.Unstaged == ChangeKind.Ignored;

    public static string Title(this ConflictKind kind) => kind switch
    {
        ConflictKind.BothDeleted => Common.L10n.Tr("conflict.bothDeleted"),
        ConflictKind.AddedByUs => Common.L10n.Tr("conflict.addedByUs"),
        ConflictKind.DeletedByThem => Common.L10n.Tr("conflict.deletedByThem"),
        ConflictKind.AddedByThem => Common.L10n.Tr("conflict.addedByThem"),
        ConflictKind.DeletedByUs => Common.L10n.Tr("conflict.deletedByUs"),
        ConflictKind.BothAdded => Common.L10n.Tr("conflict.bothAdded"),
        _ => Common.L10n.Tr("conflict.bothModified"),
    };

    public static bool IsDeleted(this FileChange change) => change.Staged == ChangeKind.Deleted || change.Unstaged == ChangeKind.Deleted;
}
