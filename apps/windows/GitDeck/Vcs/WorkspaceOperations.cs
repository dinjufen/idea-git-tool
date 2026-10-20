using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// 跨仓库的 Fetch / Update Project / Push（IDEA 多 VCS 根项目中的同名操作，与 mac 端 WorkspaceOperations 一致）：
/// 依次对每个仓库执行，汇总结果后在状态栏通知；只有一个仓库时直接交给该仓库的操作。
public sealed class WorkspaceOperations(Workspace workspace, Func<ProjectModel, GitOperations> operationsFor, Func<XamlRoot?> root)
{
    /// 进度通知（状态栏），参数为 null 表示结束。
    public event Action<string?>? Progress;

    public bool IsRunning { get; private set; }

    private GitOperations Primary => operationsFor(workspace.Primary);

    /// 依次对每个仓库执行 `work`，返回每个仓库的结果。
    private async Task<List<(ProjectModel Model, T? Value, Exception? Error)>> RunEach<T>(string title, IEnumerable<ProjectModel> models, Func<Repository, T> work)
    {
        IsRunning = true;
        var results = new List<(ProjectModel, T?, Exception?)>();
        try
        {
            foreach (var model in models.ToList())
            {
                Progress?.Invoke($"{title} — {workspace.DisplayName(model)}");
                var repository = model.Repository;
                try
                {
                    results.Add((model, await Task.Run(() => work(repository)), null));
                }
                catch (Exception error) when (error is CoreException or IOException)
                {
                    results.Add((model, default, error));
                }
            }
        }
        finally
        {
            IsRunning = false;
            Progress?.Invoke(null);
            workspace.RefreshAll();
        }
        return results;
    }

    /// 失败的仓库：报告第一个错误（附带仓库名）。
    private async Task<bool> ReportFailures<T>(List<(ProjectModel Model, T? Value, Exception? Error)> results, string title)
    {
        if (results.FirstOrDefault(r => r.Error is not null) is not { Error: { } error } failure) return false;
        var message = L10n.Tr("workspace.failedIn", title, workspace.DisplayName(failure.Model));
        workspace.Primary.Post(message, isError: true);
        if (root() is { } xamlRoot) await Dialogs.ShowMessage(xamlRoot, message, L10n.Message(error));
        return true;
    }

    public async Task FetchAll()
    {
        if (!workspace.IsMultiRoot)
        {
            await Primary.Fetch();
            return;
        }
        if (IsRunning) return;
        var results = await RunEach(L10n.Tr("ops.progress.fetch"), workspace.Models, repo => repo.Fetch(false));
        if (await ReportFailures(results, L10n.Tr("git.action.fetch"))) return;
        var total = results.Sum(r => (long)r.Value);
        workspace.Primary.Post(total == 0 ? L10n.Tr("ops.fetch.nothing") : L10n.Tr("workspace.fetch.done", total, results.Count));
    }

    /// 更新所有设置了上游的仓库；某个仓库出现冲突时停止并提示。
    public async Task UpdateAll()
    {
        if (!workspace.IsMultiRoot)
        {
            await Primary.UpdateProject();
            return;
        }
        if (IsRunning || await Primary.ChooseUpdateMethod() is not { } method) return;
        var targets = workspace.Models.Where(m => m.Status.Branch.Upstream is not null).ToList();
        if (targets.Count == 0)
        {
            workspace.Primary.Post(L10n.Tr("workspace.update.noUpstream"), isError: true);
            return;
        }
        var results = new List<(ProjectModel Model, UpdateResult? Value, Exception? Error)>();
        foreach (var model in targets)
        {
            var result = await RunEach(L10n.Tr("ops.progress.update"), [model], repo => repo.UpdateProject(method));
            results.AddRange(result);
            if (result[0].Value is { Outcome: MergeOutcome.Conflicts } update)
            {
                await operationsFor(model).ShowConflicts(L10n.Tr("ops.update.name"), update.StashKept);
                workspace.Primary.Post(L10n.Tr("workspace.update.conflicts", workspace.DisplayName(model)), isError: true);
                return;
            }
        }
        if (await ReportFailures(results, L10n.Tr("git.action.update"))) return;
        var received = results.Sum(r => (long)(r.Value?.Received ?? 0));
        workspace.Primary.Post(received == 0 ? L10n.Tr("ops.update.upToDate") : L10n.Tr("workspace.update.done", received, results.Count));
    }

    /// 有待推送提交的仓库：只有一个时打开其 Push 对话框，多个时列出供勾选后一起推送。
    public async Task PushAll()
    {
        if (!workspace.IsMultiRoot)
        {
            await Primary.Push();
            return;
        }
        if (IsRunning) return;
        var targets = await RunEach(L10n.Tr("workspace.push.checking"), workspace.Models, repo => repo.PushTarget());
        var pending = targets.Where(t => t.Value is { Commits.Length: > 0, Remote: not null }).Select(t => (t.Model, Target: t.Value!)).ToList();
        switch (pending.Count)
        {
            case 0:
                workspace.Primary.Post(L10n.Tr("workspace.push.nothing"));
                break;
            case 1:
                await operationsFor(pending[0].Model).Push();
                break;
            default:
                await AskPush(pending);
                break;
        }
    }

    private async Task AskPush(List<(ProjectModel Model, PushTarget Target)> pending)
    {
        if (root() is not { } xamlRoot) return;
        var dialog = Dialogs.Create(xamlRoot, L10n.Tr("workspace.push.title"));
        var boxes = pending.Select(p => new CheckBox
        {
            IsChecked = true,
            Content = L10n.Tr("workspace.push.item", workspace.DisplayName(p.Model), p.Target.LocalBranch,
                $"{p.Target.Remote}/{p.Target.RemoteBranch}", p.Target.Commits.Length),
        }).ToList();
        var stack = new StackPanel { Spacing = 6, MaxWidth = 460, Children = { new TextBlock { Text = L10n.Tr("workspace.push.message"), TextWrapping = TextWrapping.Wrap } } };
        foreach (var box in boxes) stack.Children.Add(box);
        dialog.Content = stack;
        dialog.PrimaryButtonText = L10n.Tr("workspace.push.confirm");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        if (!DebugOptions.Has("debug.confirm") && await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        for (var i = 0; i < pending.Count; i++)
        {
            if (boxes[i].IsChecked != true) continue;
            var (model, target) = pending[i];
            await operationsFor(model).PerformPush(new PushOptions(target.LocalBranch, target.Remote ?? "origin", target.RemoteBranch, false, false, !target.HasUpstream));
        }
    }
}
