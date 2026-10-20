using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Commit;

/// 新建 / 编辑 Changelist：名称（不能与已有列表重名）与说明（IDEA 用作该列表的默认提交信息）。
public static class ChangelistDialog
{
    public static async Task<(string Name, string Comment)?> Show(XamlRoot root, string title, string confirm, string name, string comment, IReadOnlySet<string> existing)
    {
        var dialog = Dialogs.Create(root, title);
        dialog.PrimaryButtonText = confirm;
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        var nameBox = new TextBox { Text = name, PlaceholderText = L10n.Tr("changelist.dialog.name"), Width = 360 };
        var error = Themed.Foreground(new TextBlock { FontSize = 12 }, "ErrorTextBrush");
        var commentBox = new TextBox { Text = comment, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 80, Width = 360 };
        dialog.Content = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                nameBox,
                error,
                new TextBlock { Text = L10n.Tr("changelist.dialog.comment"), Style = (Style)Application.Current.Resources["SecondaryTextStyle"] },
                commentBox,
            },
        };
        void Revalidate()
        {
            var trimmed = nameBox.Text.Trim();
            var duplicate = existing.Contains(trimmed);
            error.Text = duplicate ? L10n.Tr("changelist.exists", trimmed) : "";
            error.Visibility = duplicate ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = trimmed.Length > 0 && !duplicate;
        }
        nameBox.TextChanged += (_, _) => Revalidate();
        Revalidate();
        dialog.Opened += (_, _) => nameBox.Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        return (nameBox.Text.Trim(), commentBox.Text.Trim());
    }
}

/// IDEA 的 “Rollback Changes” 对话框：勾选要回滚的文件，可选择是否删除新增文件的本地副本。
public static class RollbackDialog
{
    public static bool IsAdded(FileChange change) =>
        change.Staged is ChangeKind.Added or ChangeKind.Renamed or ChangeKind.Copied;

    /// <param name="changes">可回滚的改动（已跟踪文件）。</param>
    /// <param name="selected">初始勾选的路径；为空时全部勾选。</param>
    public static async Task<(string[] Paths, bool DeleteAdded)?> Show(XamlRoot root, IReadOnlyList<FileChange> changes, IReadOnlySet<string> selected)
    {
        var dialog = Dialogs.Create(root, L10n.Tr("rollback.title"));
        dialog.PrimaryButtonText = L10n.Tr("rollback.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        var boxes = new List<(CheckBox Box, FileChange Change)>();
        var list = new StackPanel { Spacing = 2 };
        foreach (var change in changes)
        {
            var kind = IsAdded(change) ? L10n.Tr("rollback.kind.added") : change.IsDeleted() ? L10n.Tr("rollback.kind.deleted") : "";
            var box = new CheckBox
            {
                Content = (change.Path + "  " + kind).Trim(),
                IsChecked = selected.Count == 0 || selected.Contains(change.Path),
                MinHeight = 28,
            };
            ToolTipService.SetToolTip(box, change.Path);
            box.Click += (_, _) => dialog.IsPrimaryButtonEnabled = boxes.Any(b => b.Box.IsChecked == true);
            boxes.Add((box, change));
            list.Children.Add(box);
        }
        var deleteAdded = new CheckBox
        {
            Content = L10n.Tr("rollback.deleteAdded"),
            Visibility = changes.Any(IsAdded) ? Visibility.Visible : Visibility.Collapsed,
        };
        dialog.Content = new StackPanel
        {
            Spacing = 8,
            Width = 460,
            Children =
            {
                new TextBlock { Text = L10n.Tr("rollback.message"), TextWrapping = TextWrapping.Wrap },
                new ScrollViewer { Content = list, MaxHeight = 240 },
                deleteAdded,
            },
        };
        dialog.IsPrimaryButtonEnabled = boxes.Any(b => b.Box.IsChecked == true);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        return ([.. boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Change.Path)], deleteAdded.IsChecked == true);
    }
}
