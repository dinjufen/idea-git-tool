using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;

namespace GitDeck.Vcs;

/// 分支与远程操作的交互流程：在后台执行 git，处理确认对话框、错误与结果通知（与 mac 端 GitOperations 一致）。
///
/// 同一项目同一时间只运行一个操作，与 IDEA 的后台任务行为一致。
public sealed class GitOperations
{
    private readonly ProjectModel _model;
    private readonly Func<XamlRoot?> _root;

    public GitOperations(ProjectModel model, Func<XamlRoot?> root)
    {
        _model = model;
        _root = root;
    }

    /// 操作开始 / 结束时通知（状态栏显示进度）；参数为进行中的操作标题，结束时为 null。
    public event Action<string?>? Progress;

    /// 出现冲突时打开冲突解决流程（W5 实现三栏合并）。
    public event Action? Conflicts;

    /// 在 Log 中定位提交。
    public event Action<string>? RevealCommit;

    /// 打开某个修订中的文件与工作区文件的 Diff。
    public event Action<string, ChangedFile>? ShowRevisionFileDiff;

    public ProjectModel Model => _model;

    public string? RunningTitle { get; private set; }

    public bool IsRunning => RunningTitle is not null;

    private XamlRoot? Root => _root();

    // MARK: - 执行框架

    /// 在后台执行 `work`，完成后刷新状态并回调。
    public async Task Run<T>(string title, Func<Repository, T> work, Func<T, Task> success, Func<Exception, Task> failure)
    {
        if (IsRunning) return;
        RunningTitle = title;
        Progress?.Invoke(title);
        var repository = _model.Repository;
        T result;
        try
        {
            result = await Task.Run(() => work(repository));
        }
        catch (Exception error) when (error is CoreException or IOException)
        {
            RunningTitle = null;
            Progress?.Invoke(null);
            _model.Refresh();
            await failure(error);
            return;
        }
        RunningTitle = null;
        Progress?.Invoke(null);
        _model.Refresh();
        await success(result);
    }

    public Task Run(string title, Action<Repository> work, Func<Task> success, Func<Exception, Task> failure) =>
        Run(title, repo =>
        {
            work(repo);
            return true;
        }, _ => success(), failure);

    public async Task ShowError(string title, Exception error)
    {
        _model.Post(title, isError: true);
        if (Root is { } root) await Dialogs.ShowMessage(root, title, L10n.Message(error));
    }

    private void Post(string text, bool isError = false) => _model.Post(text, isError);

    private Task Done(string text, bool isError = false)
    {
        Post(text, isError);
        return Task.CompletedTask;
    }

    // MARK: - 签出

    public enum TargetKind
    {
        Local,
        Remote,
        Revision,
    }

    public Task Checkout(TargetKind kind, string name, CheckoutMode mode = CheckoutMode.Normal) =>
        Run(L10n.Tr("ops.progress.checkout", name), repo => kind switch
        {
            TargetKind.Local => repo.CheckoutBranch(name, mode),
            TargetKind.Remote => repo.CheckoutRemoteBranch(name, mode),
            _ => repo.CheckoutRevision(name, mode),
        }, outcome => Done(outcome.StashConflicts ? L10n.Tr("ops.checkout.stashConflicts", name) : L10n.Tr("ops.checkout.done", name), outcome.StashConflicts),
        async error =>
        {
            if (error is CoreException.LocalChangesWouldBeOverwritten overwritten) await AskCheckoutProblem(kind, name, overwritten.files);
            else await ShowError(L10n.Tr("ops.checkout.failed"), error);
        });

    /// IDEA 的 “Git Checkout Problem” 对话框：Smart Checkout 或 Force Checkout。
    private async Task AskCheckoutProblem(TargetKind kind, string name, string[] files)
    {
        if (Root is not { } root) return;
        var dialog = Dialogs.Create(root, L10n.Tr("ops.checkoutProblem.title"));
        dialog.Content = new Microsoft.UI.Xaml.Controls.ScrollViewer
        {
            MaxHeight = 320,
            Content = new Microsoft.UI.Xaml.Controls.TextBlock
            {
                Text = L10n.Tr("ops.checkoutProblem.message", string.Join("\n", files.Take(20))),
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 460,
            },
        };
        dialog.PrimaryButtonText = L10n.Tr("ops.checkoutProblem.smart");
        dialog.SecondaryButtonText = L10n.Tr("ops.checkoutProblem.force");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        switch (await dialog.ShowAsync())
        {
            case Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary: await Checkout(kind, name, CheckoutMode.Smart); break;
            case Microsoft.UI.Xaml.Controls.ContentDialogResult.Secondary: await Checkout(kind, name, CheckoutMode.Force); break;
        }
    }

    public async Task CheckoutRevisionDialog()
    {
        if (Root is not { } root) return;
        var result = await NameDialog.Show(root, L10n.Tr("ops.checkoutRevision.title"), L10n.Tr("ops.checkoutRevision.message"), "",
            L10n.Tr("ops.checkoutRevision.confirm"), _ => null);
        if (result is not null) await Checkout(TargetKind.Revision, result.Name);
    }

    // MARK: - 新建 / 重命名 / 删除

    private HashSet<string> LocalBranchNames => _model.Branches.Where(b => b.Kind == BranchKind.Local).Select(b => b.Name).ToHashSet();

    /// IDEA 的 “Create New Branch” 对话框：名称 + “Checkout branch” 复选框。
    public async Task NewBranch(string? startPoint = null)
    {
        if (Root is not { } root) return;
        var repository = _model.Repository;
        var existing = LocalBranchNames;
        var result = await NameDialog.Show(root, L10n.Tr("ops.newBranch.title"),
            startPoint is null ? null : L10n.Tr("ops.newBranch.from", startPoint), "", L10n.Tr("ops.newBranch.confirm"),
            name => existing.Contains(name) ? L10n.Tr("ops.validate.exists", name)
                : repository.IsValidBranchName(name) ? null : L10n.Tr("ops.validate.invalid"),
            L10n.Tr("ops.newBranch.checkout"));
        if (result is null) return;
        await Run(L10n.Tr("ops.progress.newBranch", result.Name), repo => repo.CreateBranch(result.Name, startPoint, result.Checked),
            () => Done(L10n.Tr("ops.newBranch.done", result.Name)), error => ShowError(L10n.Tr("ops.newBranch.failed"), error));
    }

    public async Task Rename(string branch)
    {
        if (Root is not { } root) return;
        var repository = _model.Repository;
        var existing = LocalBranchNames;
        var result = await NameDialog.Show(root, L10n.Tr("ops.rename.title", branch), null, branch, L10n.Tr("ops.rename.confirm"),
            name => name != branch && existing.Contains(name) ? L10n.Tr("ops.validate.exists", name)
                : repository.IsValidBranchName(name) ? null : L10n.Tr("ops.validate.invalid"));
        if (result is null || result.Name == branch) return;
        await Run(L10n.Tr("ops.progress.rename", branch), repo => repo.RenameBranch(branch, result.Name),
            () => Done(L10n.Tr("ops.rename.done", branch, result.Name)), error => ShowError(L10n.Tr("ops.rename.failed"), error));
    }

    public Task Delete(string branch, bool force = false) =>
        Run(L10n.Tr("ops.progress.delete", branch), repo => repo.DeleteBranch(branch, force),
            () => Done(L10n.Tr("ops.delete.done", branch)),
            async error =>
            {
                if (error is CoreException.BranchNotFullyMerged && Root is { } root)
                {
                    if (await ConfirmDialog.Show(root, L10n.Tr("ops.delete.notMerged.title", branch), L10n.Tr("ops.delete.notMerged.message"), L10n.Tr("ops.delete.force")))
                    {
                        await Delete(branch, force: true);
                    }
                    return;
                }
                await ShowError(L10n.Tr("ops.delete.failed"), error);
            });

    public async Task DeleteRemoteBranch(string branch)
    {
        if (Root is not { } root) return;
        if (!await ConfirmDialog.Show(root, L10n.Tr("ops.deleteRemote.title", branch), L10n.Tr("ops.deleteRemote.message"), L10n.Tr("ops.deleteRemote.confirm"))) return;
        await Run(L10n.Tr("ops.progress.deleteRemote", branch), repo => repo.DeleteRemoteBranch(branch),
            () => Done(L10n.Tr("ops.deleteRemote.done", branch)), error => ShowError(L10n.Tr("ops.deleteRemote.failed"), error));
    }

    // MARK: - 合并 / 变基

    public Task Merge(string branch) =>
        Run(L10n.Tr("ops.progress.merge", branch, _model.CurrentBranchTitle), repo => repo.MergeBranch(branch),
            outcome => Report(outcome, L10n.Tr("ops.merge.name")), error => ShowError(L10n.Tr("ops.merge.failed"), error));

    public Task Rebase(string onto) =>
        Run(L10n.Tr("ops.progress.rebase", _model.CurrentBranchTitle, onto), repo => repo.RebaseOnto(onto),
            outcome => Report(outcome, L10n.Tr("ops.rebase.name")), error => ShowError(L10n.Tr("ops.rebase.failed"), error));

    /// 签出 `branch` 并变基到当前分支上。
    public Task CheckoutAndRebase(string branch)
    {
        var current = _model.CurrentBranchTitle;
        return Run(L10n.Tr("ops.progress.checkoutAndRebase", branch, current), repo => repo.CheckoutAndRebase(branch, current),
            outcome => Report(outcome, L10n.Tr("ops.rebase.name")), error => ShowError(L10n.Tr("ops.rebase.failed"), error));
    }

    public Task ContinueRebase() =>
        Run(L10n.Tr("ops.progress.continueRebase"), repo => repo.ContinueRebase(),
            outcome => Report(outcome, L10n.Tr("ops.rebase.name")), error => ShowError(L10n.Tr("ops.rebase.failed"), error));

    public Task AbortRebase() =>
        Run(L10n.Tr("ops.progress.abort"), repo => repo.AbortRebase(),
            () => Done(L10n.Tr("ops.abort.rebaseDone")), error => ShowError(L10n.Tr("ops.abort.failed"), error));

    public Task AbortMerge() =>
        Run(L10n.Tr("ops.progress.abort"), repo => repo.AbortMerge(),
            () => Done(L10n.Tr("ops.abort.mergeDone")), error => ShowError(L10n.Tr("ops.abort.failed"), error));

    public Task ContinueCherryPick() =>
        Run(L10n.Tr("ops.progress.cherryPick"), repo => repo.ContinueCherryPick(),
            outcome => Report(outcome, L10n.Tr("ops.cherryPick.name")), error => ShowError(L10n.Tr("ops.cherryPick.failed"), error));

    public Task AbortCherryPick() =>
        Run(L10n.Tr("ops.progress.abort"), repo => repo.AbortCherryPick(),
            () => Done(L10n.Tr("ops.abort.cherryPickDone")), error => ShowError(L10n.Tr("ops.abort.failed"), error));

    public Task ContinueRevert() =>
        Run(L10n.Tr("ops.progress.revert"), repo => repo.ContinueRevert(),
            outcome => Report(outcome, L10n.Tr("ops.revert.name")), error => ShowError(L10n.Tr("ops.revert.failed"), error));

    public Task AbortRevert() =>
        Run(L10n.Tr("ops.progress.abort"), repo => repo.AbortRevert(),
            () => Done(L10n.Tr("ops.abort.revertDone")), error => ShowError(L10n.Tr("ops.abort.failed"), error));

    public async Task Report(MergeOutcome outcome, string operation)
    {
        switch (outcome)
        {
            case MergeOutcome.UpToDate: Post(L10n.Tr("ops.upToDate")); break;
            case MergeOutcome.FastForward or MergeOutcome.Merged: Post(L10n.Tr("ops.done", operation)); break;
            case MergeOutcome.Paused: Post(L10n.Tr("ops.paused", operation)); break;
            case MergeOutcome.Conflicts: await ShowConflicts(operation); break;
        }
    }

    /// 出现冲突：提示用户在提交工具窗口中解决（三栏合并在 W5 中加入）。
    public async Task ShowConflicts(string operation, bool stashKept = false)
    {
        var title = L10n.Tr("ops.conflicts.title", operation);
        Post(stashKept ? title + " " + L10n.Tr("ops.conflicts.stashKept") : title, isError: true);
        if (Conflicts is not null)
        {
            Conflicts();
            return;
        }
        var text = L10n.Tr("ops.conflicts.message");
        if (stashKept) text += "\n\n" + L10n.Tr("ops.conflicts.stashKept");
        if (Root is { } root) await Dialogs.ShowMessage(root, title, text);
    }

    // MARK: - Fetch / Update / Push

    public Task Fetch() =>
        Run(L10n.Tr("ops.progress.fetch"), repo => repo.Fetch(false),
            count => Done(count == 0 ? L10n.Tr("ops.fetch.nothing") : L10n.Tr("ops.fetch.done", count)),
            error => ShowError(L10n.Tr("ops.fetch.failed"), error));

    /// IDEA 的 “Update Project” 对话框：选择 Merge 或 Rebase，记住上次的选择。
    /// 勾选 “不再显示” 后直接按设置中的方式更新。
    public async Task UpdateProject()
    {
        if (await ChooseUpdateMethod() is not { } method) return;
        await Run(L10n.Tr("ops.progress.update"), repo => repo.UpdateProject(method), async update =>
        {
            switch (update.Outcome)
            {
                case MergeOutcome.UpToDate: Post(L10n.Tr("ops.update.upToDate")); break;
                case MergeOutcome.Conflicts: await ShowConflicts(L10n.Tr("ops.update.name"), update.StashKept); break;
                default:
                    Post(update.StashConflicts ? L10n.Tr("ops.update.stashConflicts", update.Received) : L10n.Tr("ops.update.done", update.Received),
                        update.StashConflicts);
                    break;
            }
        }, error => ShowError(L10n.Tr("ops.update.failed"), error));
    }

    private async Task<UpdateMethod?> ChooseUpdateMethod()
    {
        if (!GitSettings.ShowUpdateDialog) return GitSettings.UpdateMethod;
        if (Root is not { } root) return null;
        var dialog = Dialogs.Create(root, L10n.Tr("ops.update.title"));
        var options = new RadioOptions(
        [
            (L10n.Tr("ops.update.merge.title"), L10n.Tr("ops.update.merge")),
            (L10n.Tr("ops.update.rebase.title"), L10n.Tr("ops.update.rebase")),
        ], GitSettings.UpdateMethod == UpdateMethod.Rebase ? 1 : 0);
        var dontShow = new Microsoft.UI.Xaml.Controls.CheckBox { Content = L10n.Tr("ops.update.dontShow") };
        dialog.Content = new Microsoft.UI.Xaml.Controls.StackPanel
        {
            Spacing = 10,
            Width = 360,
            Children = { new Microsoft.UI.Xaml.Controls.TextBlock { Text = L10n.Tr("ops.update.message") }, options, dontShow },
        };
        dialog.PrimaryButtonText = L10n.Tr("ops.update.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        if (await dialog.ShowAsync() != Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary) return null;
        var method = options.SelectedIndex == 1 ? UpdateMethod.Rebase : UpdateMethod.Merge;
        GitSettings.UpdateMethod = method;
        if (dontShow.IsChecked == true) GitSettings.ShowUpdateDialog = false;
        return method;
    }

    /// 快进非当前的本地分支到其上游；当前分支走 Update Project。
    public Task UpdateBranch(string branch)
    {
        if (branch == _model.Status.Branch.Head) return UpdateProject();
        return Run(L10n.Tr("ops.progress.updateBranch", branch), repo => repo.UpdateBranch(branch),
            () => Done(L10n.Tr("ops.updateBranch.done", branch)), error => ShowError(L10n.Tr("ops.updateBranch.failed", branch), error));
    }

    /// 打开 Push 对话框：先在后台读取推送目标与待推送提交。
    public async Task Push()
    {
        if (IsRunning || Root is not { } root) return;
        var repository = _model.Repository;
        PushTarget target;
        Remote[] remotes;
        try
        {
            (target, remotes) = await Task.Run(() => (repository.PushTarget(), repository.Remotes()));
        }
        catch (CoreException error)
        {
            await ShowError(L10n.Tr("ops.push.failed"), error);
            return;
        }
        if (await PushDialog.Show(root, target, [.. remotes.Select(r => r.Name)], _model.ProjectName) is { } options) await PerformPush(options);
    }

    private Task PerformPush(PushOptions options)
    {
        var destination = $"{options.Remote}/{options.RemoteBranch}";
        return Run(L10n.Tr("ops.progress.push", destination), repo => repo.Push(options),
            push => Done(push.UpToDate ? L10n.Tr("ops.push.upToDate") : L10n.Tr("ops.push.done", push.PushedCommits, destination)),
            async error =>
            {
                if (error is CoreException.PushRejected rejected && Root is { } root)
                {
                    // IDEA 的 “Push Rejected” 对话框：远程有本地没有的提交时，建议先更新。
                    Post(L10n.Tr("ops.pushRejected.title"), isError: true);
                    if (await ConfirmDialog.Show(root, L10n.Tr("ops.pushRejected.title"), L10n.Tr("ops.error.pushRejected", rejected.reason), L10n.Tr("ops.pushRejected.update")))
                    {
                        await UpdateProject();
                    }
                    return;
                }
                await ShowError(L10n.Tr("ops.push.failed"), error);
            });
    }

    // MARK: - 标签

    public async Task PushTag(string name)
    {
        var remote = (await Task.Run(() => _model.Repository.Remotes())).FirstOrDefault()?.Name;
        if (remote is null) return;
        await Run(L10n.Tr("ops.progress.tag", name), repo => repo.PushTag(remote, name),
            () => Done(L10n.Tr("ops.done", name)), error => ShowError(L10n.Tr("ops.push.failed"), error));
    }

    public Task DeleteTag(string name) =>
        Run(L10n.Tr("ops.progress.tag", name), repo => repo.DeleteTag(name),
            () => Done(L10n.Tr("ops.done", name)), error => ShowError(L10n.Tr("ops.delete.failed"), error));

    // MARK: - 比较

    /// IDEA 的 Compare with Current：分别列出只在对方分支 / 只在当前分支上的提交，双击在 Log 中定位。
    public async Task CompareWithCurrent(string branch)
    {
        if (Root is not { } root) return;
        var current = _model.CurrentBranchTitle;
        var head = _model.Status.Branch.Head ?? "HEAD";
        var repository = _model.Repository;
        LogCommit[] Page(string include, string exclude) =>
            repository.Log(new LogFilter([include, "^" + exclude], [], null, null, [], null, LogOrder.Topological, 500)).Commits;
        (LogCommit[] Incoming, LogCommit[] Outgoing) result;
        try
        {
            result = await Task.Run(() => (Page(branch, head), Page(head, branch)));
        }
        catch (CoreException error)
        {
            await ShowError(L10n.Tr("compare.failed"), error);
            return;
        }
        ListDialog.Item Row(LogCommit commit) => new ListDialog.Row(commit.Subject,
            $"{commit.Hash[..Math.Min(8, commit.Hash.Length)]}  {commit.AuthorName}  {Git.LogDates.Short(commit.AuthorTime)}",
            () => RevealCommit?.Invoke(commit.Hash));
        var items = new List<ListDialog.Item> { new ListDialog.Header(L10n.Tr("compare.incoming", branch, current, result.Incoming.Length)) };
        items.AddRange(result.Incoming.Select(Row));
        items.Add(new ListDialog.Header(L10n.Tr("compare.outgoing", current, branch, result.Outgoing.Length)));
        items.AddRange(result.Outgoing.Select(Row));
        await ListDialog.Show(root, L10n.Tr("compare.title", branch, current), L10n.Tr("compare.message"), items,
            result.Incoming.Length + result.Outgoing.Length == 0 ? L10n.Tr("compare.identical") : L10n.Tr("compare.message"));
    }

    /// IDEA 的 Show Diff with Working Tree：列出工作区与该分支不同的文件，双击打开 Diff。
    public async Task ShowDiffWithWorkingTree(string branch)
    {
        if (Root is not { } root) return;
        var repository = _model.Repository;
        ChangedFile[] files;
        try
        {
            files = await Task.Run(() => repository.DiffWithWorkingTree(branch));
        }
        catch (CoreException error)
        {
            await ShowError(L10n.Tr("compare.failed"), error);
            return;
        }
        var items = files.Select(file => (ListDialog.Item)new ListDialog.Row(file.Path,
            file.OrigPath is { } orig ? L10n.Tr("compare.renamedFrom", orig) : "",
            () => ShowRevisionFileDiff?.Invoke(branch, file))).ToList();
        await ListDialog.Show(root, L10n.Tr("compare.workingTree.title", branch), L10n.Tr("compare.workingTree.message", files.Length), items,
            L10n.Tr("compare.workingTree.none"));
    }
}
