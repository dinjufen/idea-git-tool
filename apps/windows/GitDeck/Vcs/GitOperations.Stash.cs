using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// Stash（储藏）与 Shelve（搁置）：与 mac 端 GitOperations 的储藏部分及 GitOperations+Shelf 一致。
public sealed partial class GitOperations
{
    // MARK: - Stash

    /// IDEA 的 “Stash Changes” 对话框：消息、保留索引、包含未跟踪文件。`paths` 为空时储藏全部改动。
    public async Task StashChanges(IReadOnlyList<string>? paths = null)
    {
        if (Root is not { } root) return;
        paths ??= [];
        var dialog = Dialogs.Create(root, paths.Count == 0 ? L10n.Tr("stash.dialog.title") : L10n.Tr("stash.dialog.titleSelected", paths.Count));
        var field = new TextBox { PlaceholderText = L10n.Tr("stash.dialog.placeholder"), Width = 360 };
        var keepIndex = new CheckBox { Content = L10n.Tr("stash.dialog.keepIndex") };
        var untracked = new CheckBox { Content = L10n.Tr("stash.dialog.untracked") };
        dialog.Content = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = L10n.Tr("stash.dialog.message", _model.CurrentBranchTitle), TextWrapping = TextWrapping.Wrap, MaxWidth = 360 },
                field,
                keepIndex,
                untracked,
            },
        };
        dialog.PrimaryButtonText = L10n.Tr("stash.dialog.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        dialog.Opened += (_, _) => field.Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var message = field.Text.Trim();
        var options = new StashOptions(message.Length == 0 ? null : message, [.. paths], untracked.IsChecked == true, keepIndex.IsChecked == true);
        await Run(L10n.Tr("ops.progress.stash"), repo => repo.StashChanges(options),
            stashed => Done(stashed ? L10n.Tr("stash.done") : L10n.Tr("stash.nothing")),
            error => ShowError(L10n.Tr("stash.failed"), error));
    }

    public async Task ApplyStash(StashEntry stash, bool pop, bool reinstateIndex = false)
    {
        await Run(L10n.Tr("ops.progress.unstash"), repo => repo.ApplyStash(stash.Index, pop, reinstateIndex), async outcome =>
        {
            if (outcome.Conflicts) await ShowConflicts(L10n.Tr("stash.unstash.name"));
            else Post(pop ? L10n.Tr("stash.popped", stash.Message) : L10n.Tr("stash.applied", stash.Message));
        }, error => ShowError(L10n.Tr("stash.unstash.failed"), error));
    }

    public async Task DropStash(StashEntry stash)
    {
        if (Root is not { } root) return;
        if (!await ConfirmDialog.Show(root, L10n.Tr("stash.drop.title"), L10n.Tr("stash.drop.message", stash.Message), L10n.Tr("stash.drop.confirm"))) return;
        await Run(L10n.Tr("ops.progress.dropStash"), repo => repo.DropStash(stash.Index),
            () => Done(L10n.Tr("stash.dropped")), error => ShowError(L10n.Tr("stash.drop.failed"), error));
    }

    public async Task ClearStashes()
    {
        if (Root is not { } root || _model.Stashes.Length == 0) return;
        if (!await ConfirmDialog.Show(root, L10n.Tr("stash.clear.title"), L10n.Tr("stash.clear.message", _model.Stashes.Length), L10n.Tr("stash.clear.confirm"))) return;
        await Run(L10n.Tr("ops.progress.dropStash"), repo => repo.ClearStashes(),
            () => Done(L10n.Tr("stash.cleared")), error => ShowError(L10n.Tr("stash.drop.failed"), error));
    }

    /// IDEA 的 “Unstash as new branch”：从储藏时的提交新建分支并应用储藏。
    public async Task UnstashAsBranch(StashEntry stash)
    {
        if (Root is not { } root) return;
        var repository = _model.Repository;
        var existing = LocalBranchNames;
        var result = await NameDialog.Show(root, L10n.Tr("stash.branch.title"), stash.Message, "", L10n.Tr("ops.newBranch.confirm"),
            name => existing.Contains(name) ? L10n.Tr("ops.validate.exists", name)
                : repository.IsValidBranchName(name) ? null : L10n.Tr("ops.validate.invalid"));
        if (result is null) return;
        await Run(L10n.Tr("ops.progress.newBranch", result.Name), repo => repo.StashToBranch(stash.Index, result.Name),
            () => Done(L10n.Tr("stash.branch.done", result.Name)), error => ShowError(L10n.Tr("stash.unstash.failed"), error));
    }

    // MARK: - Shelf

    /// 询问名称后搁置 `paths`（为空时搁置全部改动）。
    public async Task Shelve(IReadOnlyList<string> paths, string defaultName)
    {
        if (Root is not { } root) return;
        var result = await NameDialog.Show(root,
            paths.Count == 0 ? L10n.Tr("shelf.dialog.title") : L10n.Tr("shelf.dialog.titleSelected", paths.Count),
            L10n.Tr("shelf.dialog.message"), defaultName, L10n.Tr("shelf.dialog.confirm"), _ => null);
        if (result is null) return;
        await Run(L10n.Tr("ops.progress.shelve"), repo => repo.ShelveChanges([.. paths], result.Name),
            entry => Done(L10n.Tr("shelf.done", entry.Name, entry.Files.Length)),
            error => ShowError(L10n.Tr("shelf.failed"), error));
    }

    /// 取回搁置的改动；`paths` 为空时取回全部文件。`keep` 为 false 时从搁置中移除已取回的文件。
    public async Task Unshelve(ShelfEntry entry, IReadOnlyList<string> paths, bool keep)
    {
        await Run(L10n.Tr("ops.progress.unshelve", entry.Name), repo => repo.Unshelve(entry.Id, [.. paths], keep), async outcome =>
        {
            if (outcome.Conflicts) await ShowConflicts(L10n.Tr("shelf.unshelve.name"));
            else Post(L10n.Tr("shelf.unshelved", entry.Name));
            ShelfChanged?.Invoke();
        }, error => ShowError(L10n.Tr("shelf.unshelve.failed"), error));
    }

    public async Task DeleteShelf(ShelfEntry entry)
    {
        if (Root is not { } root) return;
        if (!await ConfirmDialog.Show(root, L10n.Tr("shelf.delete.title"), L10n.Tr("shelf.delete.message", entry.Name), L10n.Tr("shelf.delete.confirm"))) return;
        await Run(L10n.Tr("ops.progress.deleteShelf"), repo => repo.DeleteShelf(entry.Id), () =>
        {
            ShelfChanged?.Invoke();
            return Done(L10n.Tr("shelf.deleted"));
        }, error => ShowError(L10n.Tr("shelf.delete.failed"), error));
    }

    public async Task RenameShelf(ShelfEntry entry)
    {
        if (Root is not { } root) return;
        var result = await NameDialog.Show(root, L10n.Tr("shelf.rename.title"), null, entry.Name, L10n.Tr("shelf.rename.confirm"), _ => null);
        if (result is null) return;
        await Run(L10n.Tr("ops.progress.renameShelf"), repo => repo.RenameShelf(entry.Id, result.Name), () =>
        {
            ShelfChanged?.Invoke();
            return Task.CompletedTask;
        }, error => ShowError(L10n.Tr("shelf.rename.failed"), error));
    }

    /// 搁置列表变化（搁置记录不在仓库状态中，需要单独通知 Shelf 标签刷新）。
    public event Action? ShelfChanged;
}
