using System.Text;
using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// 工作树、远程、子模块与补丁操作：与 mac 端 GitOperations+Workspace 一致。
public sealed partial class GitOperations
{
    private XamlRoot? _rootOverride;

    /// 在另一个窗口（例如 Remotes 管理窗口）中执行操作：期间的对话框与错误提示显示在该窗口中
    /// （对应 mac 端临时把 `operations.window` 换成面板）。
    public async Task InRoot(XamlRoot root, Func<Task> action)
    {
        var previous = _rootOverride;
        _rootOverride = root;
        try
        {
            await action();
        }
        finally
        {
            _rootOverride = previous;
        }
    }

    // MARK: - 工作树

    /// IDEA 的 “New Worktree” 对话框：分支（已有分支直接检出，新名称则从 HEAD 新建）与位置。
    public async Task NewWorktree()
    {
        if (Root is not { } root) return;
        var localBranches = LocalBranchNames.Order(StringComparer.OrdinalIgnoreCase).ToList();
        var dialog = Dialogs.Create(root, L10n.Tr("worktree.new.title"));
        var branch = new ComboBox { IsEditable = true, PlaceholderText = L10n.Tr("worktree.new.branch"), Width = 380, ItemsSource = localBranches };
        var location = new TextBox { PlaceholderText = L10n.Tr("worktree.new.location"), Width = 380 };
        dialog.Content = new StackPanel
        {
            Spacing = 8,
            Children = { new TextBlock { Text = L10n.Tr("worktree.new.message"), TextWrapping = TextWrapping.Wrap, MaxWidth = 380 }, branch, location },
        };
        dialog.PrimaryButtonText = L10n.Tr("worktree.new.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        dialog.Opened += (_, _) => branch.Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var name = (branch.Text ?? "").Trim();
        if (name.Length == 0) return;
        // 默认放在仓库旁边：<父目录>/<仓库名>-<分支名>。
        var parent = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(_model.RootPath)) ?? _model.RootPath;
        var path = location.Text.Trim().Length == 0
            ? Path.Combine(parent, $"{_model.ProjectName}-{name.Replace('/', '-')}")
            : Environment.ExpandEnvironmentVariables(location.Text.Trim());
        var existing = localBranches.Contains(name);
        await Run(L10n.Tr("ops.progress.worktree"), repo => repo.AddWorktree(path, existing ? name : null, existing ? null : name, null),
            () => Done(L10n.Tr("worktree.new.done", path)), error => ShowError(L10n.Tr("worktree.new.failed"), error));
    }

    /// 删除工作树；有未提交的改动时再次确认后强制删除。返回是否已删除。
    public async Task<bool> RemoveWorktree(Worktree worktree, bool force = false)
    {
        if (Root is not { } root) return false;
        if (!force && !await ConfirmDialog.Show(root, L10n.Tr("worktree.remove.title"), worktree.Path, L10n.Tr("worktree.remove"))) return false;
        var removed = false;
        var dirty = false;
        await Run(L10n.Tr("ops.progress.worktree"), repo => repo.RemoveWorktree(worktree.Path, force), () =>
        {
            removed = true;
            return Done(L10n.Tr("worktree.remove.done", worktree.Path));
        }, error =>
        {
            if (!force && error is CoreException.CommandFailed failed && failed.stderr.Contains("modified or untracked", StringComparison.Ordinal))
            {
                dirty = true;
                return Task.CompletedTask;
            }
            return ShowError(L10n.Tr("worktree.remove.failed"), error);
        });
        // 工作树中有未提交的改动：再次确认后强制删除。
        if (dirty && await ConfirmDialog.Show(root, L10n.Tr("worktree.remove.dirty.title"), L10n.Tr("worktree.remove.dirty.message"), L10n.Tr("worktree.remove.force")))
        {
            return await RemoveWorktree(worktree, force: true);
        }
        return removed;
    }

    // MARK: - 远程

    /// 新建或编辑远程：`existing` 为空时新建。
    public async Task EditRemote(Remote? existing)
    {
        if (Root is not { } root) return;
        var dialog = Dialogs.Create(root, existing is null ? L10n.Tr("remotes.add.title") : L10n.Tr("remotes.edit.title", existing.Name));
        var name = new TextBox
        {
            PlaceholderText = L10n.Tr("remotes.name"),
            Width = 400,
            Text = existing?.Name ?? (_model.Branches.Any(b => b.Remote == "origin") ? "" : "origin"),
        };
        var url = new TextBox { PlaceholderText = L10n.Tr("remotes.url"), Width = 400, Text = existing?.Url ?? "" };
        dialog.Content = new StackPanel { Spacing = 8, Children = { name, url } };
        dialog.PrimaryButtonText = L10n.Tr("remotes.save");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        dialog.Opened += (_, _) => (existing is null ? name : url).Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var newName = name.Text.Trim();
        var newUrl = url.Text.Trim();
        if (newName.Length == 0 || newUrl.Length == 0) return;
        await Run(L10n.Tr("ops.progress.remotes"), repo =>
        {
            if (existing is not null)
            {
                if (existing.Name != newName) repo.RenameRemote(existing.Name, newName);
                if (existing.Url != newUrl) repo.SetRemoteUrl(newName, newUrl);
            }
            else
            {
                repo.AddRemote(newName, newUrl);
            }
        }, () => Task.CompletedTask, error => ShowError(L10n.Tr("remotes.failed"), error));
    }

    public async Task RemoveRemote(Remote remote)
    {
        if (Root is not { } root) return;
        if (!await ConfirmDialog.Show(root, L10n.Tr("remotes.remove.title", remote.Name), remote.Url, L10n.Tr("remotes.remove"))) return;
        await Run(L10n.Tr("ops.progress.remotes"), repo => repo.RemoveRemote(remote.Name),
            () => Task.CompletedTask, error => ShowError(L10n.Tr("remotes.failed"), error));
    }

    // MARK: - 子模块

    /// 初始化并更新子模块（`paths` 为空时为全部）。
    public Task UpdateSubmodules(IReadOnlyList<string> paths) =>
        Run(L10n.Tr("ops.progress.submodules"), repo => repo.UpdateSubmodules([.. paths], true),
            () => Done(L10n.Tr("submodules.updated")), error => ShowError(L10n.Tr("submodules.failed"), error));

    // MARK: - 补丁

    /// 把本地改动（`paths` 为空时为全部）保存为补丁文件。
    public Task CreatePatch(IReadOnlyList<string> paths) =>
        SavePatch($"{_model.ProjectName}.patch", repo => repo.CreatePatch([.. paths]));

    /// 把提交（从旧到新）保存为补丁文件。
    public Task CreatePatchFromCommits(IReadOnlyList<string> hashes)
    {
        var name = hashes.Count == 1 ? $"{hashes[0][..Math.Min(8, hashes[0].Length)]}.patch" : $"{_model.ProjectName}-{hashes.Count}-commits.patch";
        return SavePatch(name, repo => repo.CreatePatchFromCommits([.. hashes]));
    }

    private async Task SavePatch(string defaultName, Func<Repository, string> make)
    {
        if (Root is not { } root) return;
        var picker = new Microsoft.Windows.Storage.Pickers.FileSavePicker(root.ContentIslandEnvironment.AppWindowId)
        {
            SuggestedFileName = Path.GetFileNameWithoutExtension(defaultName),
            DefaultFileExtension = ".patch",
        };
        picker.FileTypeChoices.Add(L10n.Tr("patch.fileType"), [".patch", ".diff"]);
        var result = await picker.PickSaveFileAsync();
        if (result is null) return;
        var path = result.Path;
        await Run(L10n.Tr("ops.progress.patch"), repo =>
        {
            var patch = make(repo);
            File.WriteAllText(path, patch, new UTF8Encoding(false));
            return patch.Length == 0;
        }, empty => Done(empty ? L10n.Tr("patch.empty") : L10n.Tr("patch.created", Path.GetFileName(path)), empty),
            error => ShowError(L10n.Tr("patch.failed"), error));
    }

    /// IDEA 的 “Apply Patch”：选择补丁文件，确认涉及的文件后应用；不能直接应用时用三方合并。
    public async Task ApplyPatch()
    {
        if (Root is not { } root) return;
        var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(root.ContentIslandEnvironment.AppWindowId);
        picker.FileTypeFilter.Add(".patch");
        picker.FileTypeFilter.Add(".diff");
        picker.FileTypeFilter.Add("*");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await ApplyPatchFile(file.Path);
    }

    public async Task ApplyPatchFile(string path)
    {
        if (Root is not { } root) return;
        var repository = _model.Repository;
        var name = Path.GetFileName(path);
        string patch;
        PatchFile[] files;
        bool clean;
        try
        {
            patch = Encoding.UTF8.GetString(await File.ReadAllBytesAsync(path));
            (files, clean) = await Task.Run(() => (repository.PatchFiles(patch), repository.CanApplyPatch(patch)));
        }
        catch (Exception error) when (error is CoreException or IOException or UnauthorizedAccessException)
        {
            await ShowError(L10n.Tr("patch.apply.failed"), error);
            return;
        }
        var list = string.Join("\n", files.Take(20).Select(f => $"{f.Path}  (+{f.Added} −{f.Deleted})"));
        var message = L10n.Tr("patch.apply.files", files.Length) + "\n\n" + list + (files.Length > 20 ? "\n…" : "");
        if (!clean) message += "\n\n" + L10n.Tr("patch.apply.threeWay");
        if (!DebugOptions.Has("debug.confirm") && !await ConfirmDialog.Show(root, L10n.Tr("patch.apply.title", name), message, L10n.Tr("patch.apply.confirm"))) return;
        await Run(L10n.Tr("ops.progress.patch"), repo => repo.ApplyPatch(patch, true), async outcome =>
        {
            if (outcome.Conflicts) await ShowConflicts(L10n.Tr("patch.apply.name"));
            else Post(L10n.Tr("patch.applied", name));
        }, error => ShowError(L10n.Tr("patch.apply.failed"), error));
    }
}
