using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// 提交级操作（Log 右键菜单）与标签操作：与 mac 端 GitOperations+History 一致。
public sealed partial class GitOperations
{
    // MARK: - Cherry-pick / Revert

    /// 拣选提交；`hashes` 按从旧到新的顺序应用。
    public Task CherryPick(IReadOnlyList<string> hashes) =>
        Run(L10n.Tr("ops.progress.cherryPick"), repo => repo.CherryPick([.. hashes]),
            outcome => Report(outcome, L10n.Tr("ops.cherryPick.name")), error => ShowError(L10n.Tr("ops.cherryPick.failed"), error));

    /// 还原提交；`hashes` 按从新到旧的顺序还原。
    public Task Revert(IReadOnlyList<string> hashes) =>
        Run(L10n.Tr("ops.progress.revert"), repo => repo.RevertCommits([.. hashes]),
            outcome => Report(outcome, L10n.Tr("ops.revert.name")), error => ShowError(L10n.Tr("ops.revert.failed"), error));

    // MARK: - Reset / Undo / Edit / Drop

    /// IDEA 的 “Git Reset” 对话框：选择 Soft / Mixed / Hard / Keep。
    public async Task ResetDialog(string hash, string subject)
    {
        if (Root is not { } root) return;
        var modes = new (ResetMode Mode, string Title, string Help)[]
        {
            (ResetMode.Soft, L10n.Tr("reset.soft"), L10n.Tr("reset.soft.help")),
            (ResetMode.Mixed, L10n.Tr("reset.mixed"), L10n.Tr("reset.mixed.help")),
            (ResetMode.Hard, L10n.Tr("reset.hard"), L10n.Tr("reset.hard.help")),
            (ResetMode.Keep, L10n.Tr("reset.keep"), L10n.Tr("reset.keep.help")),
        };
        var dialog = Dialogs.Create(root, L10n.Tr("reset.title", _model.CurrentBranchTitle, Short(hash)));
        var options = new RadioOptions(modes.Select(m => (m.Title, (string?)m.Help)), selected: 1);
        dialog.Content = new StackPanel
        {
            Spacing = 10,
            MaxWidth = 420,
            Children = { new TextBlock { Text = subject, TextWrapping = TextWrapping.Wrap }, options },
        };
        dialog.PrimaryButtonText = L10n.Tr("reset.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || options.SelectedIndex < 0) return;
        var mode = modes[options.SelectedIndex].Mode;
        await Run(L10n.Tr("ops.progress.reset"), repo => repo.ResetTo(hash, mode),
            () => Done(L10n.Tr("reset.done", Short(hash))), error => ShowError(L10n.Tr("reset.failed"), error));
    }

    /// 撤销最近一次提交（改动回到暂存区）；已推送时先确认。
    public async Task UndoCommit(string hash)
    {
        if (!await ConfirmIfPushed([hash])) return;
        await Run(L10n.Tr("ops.progress.undo"), repo => repo.UndoLastCommit(),
            () => Done(L10n.Tr("undo.done")), error => ShowError(L10n.Tr("undo.failed"), error));
    }

    /// IDEA 的 “Edit Commit Message”：多行编辑框，已推送时先确认。
    public async Task EditMessage(string hash, string current)
    {
        if (Root is not { } root) return;
        var dialog = Dialogs.Create(root, L10n.Tr("editMessage.title", Short(hash)));
        var field = MessageBox(current);
        dialog.Content = field;
        dialog.PrimaryButtonText = L10n.Tr("editMessage.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        dialog.Opened += (_, _) => field.Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var message = field.Text.Replace("\r\n", "\n").Replace('\r', '\n');
        if (message.Trim() == current.Trim() || message.Trim().Length == 0) return;
        if (!await ConfirmIfPushed([hash])) return;
        await Run(L10n.Tr("ops.progress.editMessage"), repo => repo.EditCommitMessage(hash, message),
            outcome => Report(outcome, L10n.Tr("editMessage.name")), error => ShowError(L10n.Tr("editMessage.failed"), error));
    }

    public async Task DropCommits(IReadOnlyList<string> hashes)
    {
        if (Root is not { } root) return;
        if (!await ConfirmDialog.Show(root, L10n.Tr("drop.title", hashes.Count), L10n.Tr("drop.message"), L10n.Tr("drop.confirm"))) return;
        if (!await ConfirmIfPushed(hashes)) return;
        await Run(L10n.Tr("ops.progress.drop"), repo => repo.DropCommits([.. hashes]),
            outcome => Report(outcome, L10n.Tr("drop.name")), error => ShowError(L10n.Tr("drop.failed"), error));
    }

    // MARK: - 交互式变基

    /// IDEA 的 “Interactively Rebase from Here”：读取候选提交后打开编辑对话框。
    public async Task InteractiveRebase(string hash)
    {
        if (Root is not { } root) return;
        var repository = _model.Repository;
        RebaseCommit[] commits;
        try
        {
            commits = await Task.Run(() => repository.RebaseCommits(hash));
        }
        catch (CoreException error)
        {
            await ShowError(L10n.Tr("ops.rebase.failed"), error);
            return;
        }
        var steps = await InteractiveRebaseDialog.Show(root, commits, _model.CurrentBranchTitle);
        if (steps is null) return;
        if (!await ConfirmIfPushed([.. commits.Select(c => c.Hash)])) return;
        await Run(L10n.Tr("ops.progress.rebase", _model.CurrentBranchTitle, Short(hash)), repo => repo.InteractiveRebase(hash, steps),
            outcome => Report(outcome, L10n.Tr("ops.rebase.name")), error => ShowError(L10n.Tr("ops.rebase.failed"), error));
    }

    /// 改写已推送到远程的提交前提醒（IDEA 同样会警告改写已推送的历史）。返回是否继续。
    private async Task<bool> ConfirmIfPushed(IReadOnlyList<string> hashes)
    {
        var repository = _model.Repository;
        var pushed = await Task.Run(() => hashes.Any(h =>
        {
            try
            {
                return repository.IsPushed(h);
            }
            catch (CoreException)
            {
                return false;
            }
        }));
        if (!pushed) return true;
        return Root is { } root && await ConfirmDialog.Show(root, L10n.Tr("pushedWarning.title"), L10n.Tr("pushedWarning.message"), L10n.Tr("pushedWarning.confirm"));
    }

    // MARK: - 标签

    /// IDEA 的 “Create New Tag” 对话框：名称 + 可选说明（填写说明则创建附注标签）。
    public async Task NewTag(string? target)
    {
        if (Root is not { } root) return;
        var existing = _model.Tags.Select(t => t.Name).ToHashSet();
        var repository = _model.Repository;
        var dialog = Dialogs.Create(root, L10n.Tr("tag.new.title"));
        var name = new TextBox { PlaceholderText = L10n.Tr("tag.new.name"), Width = 340 };
        var message = new TextBox { PlaceholderText = L10n.Tr("tag.new.message"), Width = 340 };
        var error = Themed.Foreground(new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed }, "ErrorTextBrush");
        dialog.Content = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = target is null ? L10n.Tr("tag.new.onHead") : L10n.Tr("tag.new.on", Short(target)) },
                name,
                error,
                message,
            },
        };
        dialog.PrimaryButtonText = L10n.Tr("tag.new.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        void Validate()
        {
            var text = name.Text.Trim();
            var problem = text.Length == 0 ? null
                : existing.Contains(text) ? L10n.Tr("ops.validate.exists", text)
                : repository.IsValidTagName(text) ? null : L10n.Tr("ops.validate.invalid");
            error.Text = problem ?? "";
            error.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = text.Length > 0 && problem is null;
        }
        name.TextChanged += (_, _) => Validate();
        Validate();
        dialog.Opened += (_, _) => name.Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var tagName = name.Text.Trim();
        var text = message.Text.Trim();
        await Run(L10n.Tr("ops.progress.tag", tagName), repo => repo.CreateTag(tagName, target, text.Length == 0 ? null : text),
            () => Done(L10n.Tr("tag.new.done", tagName)), e => ShowError(L10n.Tr("tag.new.failed"), e));
    }

    private static string Short(string hash) => hash[..Math.Min(8, hash.Length)];

    /// 多行提交信息输入框。
    internal static TextBox MessageBox(string text) => new()
    {
        Text = text,
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        Width = 440,
        Height = 160,
    };
}
