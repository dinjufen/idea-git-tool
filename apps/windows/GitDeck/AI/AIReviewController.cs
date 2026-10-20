using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.AI;

/// 一个项目的 AI 评审（与 mac 端 AIReviewController 一致）：启动与取消评审、接收核心的进度事件、首次使用确认、
/// 提交前检查与生成提交信息。AI Review 工具窗口与编辑器标记都观察它。
public sealed class AIReviewController
{
    public enum Phase
    {
        Idle,
        Running,
        Finished,
        Failed,
        Cancelled,
    }

    private enum Readiness
    {
        Ready,
        Skip,
        Cancelled,
    }

    private readonly ProjectModel _model;
    private readonly Func<XamlRoot?> _root;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private ReviewScope? _scope;
    private AiTask? _task;
    private int _generation;
    private Action<ReviewResult?>? _completion;
    private AiTask? _messageTask;

    public AIReviewController(ProjectModel model, Func<XamlRoot?> root)
    {
        _model = model;
        _root = root;
    }

    /// 正在或最近一次评审的仓库（多仓库项目中可能是嵌套仓库）；发现中的路径相对该仓库。
    private ProjectModel? _reviewedModel;

    /// 正在评审的仓库（未开始过评审时为主仓库）。
    public ProjectModel Target => _reviewedModel ?? _model;

    /// 多仓库项目：评审标题中带上仓库名。
    public Workspace? Workspace { get; set; }

    /// 多仓库项目中评审时，标题前加上仓库名。
    private string Titled(string title, ProjectModel repository) =>
        Workspace is { IsMultiRoot: true } workspace ? $"{workspace.DisplayName(repository)}: {title}" : title;

    /// 状态变化（工具窗口与编辑器标记刷新）。
    public event Action? Changed;

    /// 显示 AI Review 工具窗口。
    public event Action? Reveal;

    public Phase State { get; private set; } = Phase.Idle;
    public string Title { get; private set; } = "";
    public string[] Files { get; private set; } = [];
    public List<string> Activities { get; } = [];

    /// 当前一轮模型输出的正文（Agent 的说明文字）。
    public string Narration { get; private set; } = "";
    public ReviewResult? Result { get; private set; }
    public string? ErrorText { get; private set; }
    public (ulong Input, ulong Output) Usage { get; private set; }
    public uint Turn { get; private set; }
    public string ModelName { get; private set; } = "";

    /// 已应用建议的发现（按 Result.Findings 下标）。
    public HashSet<int> Applied { get; } = [];

    public bool IsRunning => State == Phase.Running;
    public bool CanRerun => _scope is not null && !IsRunning;
    public bool IsGeneratingMessage => _messageTask is not null;

    /// 评审的是工作区（本地改动，或与当前 HEAD 相同且没有本地改动的修订）：发现可以在编辑器中标记、直接应用建议。
    public bool IsWorkingTreeResult(string path)
    {
        if (Result is not { } result) return false;
        if (result.Revision is not { } revision) return true;
        var head = Target.Status.Branch.Oid ?? "";
        var matchesHead = revision == "HEAD" || (head.Length > 0 && head.StartsWith(revision, StringComparison.Ordinal))
                          || (revision.Length > 0 && head.Length > 0 && revision.StartsWith(head, StringComparison.Ordinal));
        return matchesHead && !Target.Status.Changes.Any(c => c.Path == path);
    }

    /// 工作区文件上未应用的发现（下标与发现），用于编辑器标记；`repository` 为文件所属的仓库。
    public List<(int Index, ReviewFinding Finding)> WorkingTreeFindings(string path, ProjectModel? repository = null)
    {
        if ((repository ?? _model) != Target || Result is not { } result || !IsWorkingTreeResult(path)) return [];
        return [.. result.Findings.Select((f, i) => (i, f)).Where(x => x.f.File == path && !Applied.Contains(x.i))];
    }

    private void Notify() => Changed?.Invoke();

    // MARK: - 准备：配置与授权

    /// 检查是否已配置模型服务，并在本项目首次发送代码前请用户确认。
    private async Task<(Readiness, AiProviderConfig?, string)> Prepare(bool allowSkip = false)
    {
        if (_root() is not { } root) return (Readiness.Cancelled, null, "");
        if (AISettings.Current() is not { } current)
        {
            var dialog = Dialogs.Create(root, L10n.Tr("ai.notConfigured.title"));
            dialog.Content = new TextBlock { Text = L10n.Tr("ai.notConfigured.message"), TextWrapping = TextWrapping.Wrap, MaxWidth = 420 };
            dialog.PrimaryButtonText = L10n.Tr("ai.notConfigured.open");
            if (allowSkip) dialog.SecondaryButtonText = L10n.Tr("ai.precommit.commitAnyway");
            dialog.CloseButtonText = L10n.Tr("common.cancel");
            switch (await dialog.ShowAsync())
            {
                case ContentDialogResult.Primary:
                    SettingsWindow.Show(SettingsWindow.Page.AI);
                    return (Readiness.Cancelled, null, "");
                case ContentDialogResult.Secondary:
                    return (Readiness.Skip, null, "");
                default:
                    return (Readiness.Cancelled, null, "");
            }
        }
        var (config, apiKey) = current;
        var project = _model.RootPath;
        if (!AISettings.HasConsent(project, config))
        {
            var host = AISettings.Host(config.BaseUrl);
            if (!await ConfirmDialog.Show(root, L10n.Tr("ai.consent.title", host), L10n.Tr("ai.consent.message", _model.ProjectName, host), L10n.Tr("ai.consent.allow")))
            {
                return (Readiness.Cancelled, null, "");
            }
            AISettings.GrantConsent(project, config);
        }
        return (Readiness.Ready, config, apiKey);
    }

    // MARK: - 评审

    public Task ReviewLocalChanges(IReadOnlyList<string> paths, ProjectModel? repository = null)
    {
        var owner = repository ?? _model;
        var count = paths.Count == 0 ? owner.Status.Changes.Length : paths.Count;
        return Start(new ReviewScope.LocalChanges([.. paths]), Titled(L10n.Tr("ai.scope.local", count), owner), owner);
    }

    public Task ReviewCommits(IReadOnlyList<string> hashes, string? subject, ProjectModel? repository = null)
    {
        var owner = repository ?? _model;
        var title = hashes.Count == 1
            ? L10n.Tr("ai.scope.commit", hashes[0][..Math.Min(8, hashes[0].Length)], subject ?? "")
            : L10n.Tr("ai.scope.commits", hashes.Count);
        return Start(new ReviewScope.Commits([.. hashes]), Titled(title, owner), owner);
    }

    public Task ReviewBranch(string against, ProjectModel? repository = null)
    {
        var owner = repository ?? _model;
        var head = owner.Status.Branch.Head ?? "HEAD";
        return Start(new ReviewScope.BranchCompare(against, "HEAD"), Titled(L10n.Tr("ai.scope.branch", head, against), owner), owner);
    }

    public Task Rerun() => _scope is { } scope && !IsRunning ? Start(scope, Title, Target) : Task.CompletedTask;

    /// 开始评审；`repository` 为被评审的仓库（默认主仓库）；`completion` 在结束时调用（失败或取消时参数为 null）。
    public async Task Start(ReviewScope scope, string title, ProjectModel? repository = null, bool allowSkip = false, Action<ReviewResult?>? completion = null)
    {
        if (IsRunning)
        {
            Reveal?.Invoke();
            return;
        }
        var (readiness, config, apiKey) = await Prepare(allowSkip);
        if (readiness == Readiness.Skip)
        {
            completion?.Invoke(new ReviewResult("", [], null, 0, 0, 0, true));
            return;
        }
        if (readiness == Readiness.Cancelled || config is null)
        {
            completion?.Invoke(null);
            return;
        }
        var current = ++_generation;
        _reviewedModel = repository ?? _model;
        _scope = scope;
        Title = title;
        _completion = completion;
        State = Phase.Running;
        Files = [];
        Activities.Clear();
        Narration = "";
        Result = null;
        ErrorText = null;
        Usage = (0, 0);
        Turn = 0;
        Applied.Clear();
        ModelName = config.Model;
        Reveal?.Invoke();
        Notify();

        var options = new ReviewOptions(AISettings.ReviewLanguage.PromptName(), [.. AISettings.SensitivePatterns], 0, 0);
        // 回调来自核心的后台线程：按顺序转到界面线程处理，丢弃旧评审的事件。
        var listener = new ListenerBridge(e => _dispatcher.TryEnqueue(() => Handle(e, current)));
        var target = Target.Repository;
        _task = await Task.Run(() => target.StartAiReview(config, apiKey, scope, options, listener));
    }

    public void Cancel()
    {
        if (!IsRunning) return;
        _task?.Cancel();
        // 不等待后台线程结束：立即显示已取消，之后到达的事件被丢弃。
        _generation++;
        State = Phase.Cancelled;
        _task = null;
        Finish(null);
    }

    public void Clear()
    {
        if (IsRunning) return;
        State = Phase.Idle;
        _scope = null;
        Result = null;
        Activities.Clear();
        Narration = "";
        ErrorText = null;
        Notify();
    }

    public void MarkApplied(int index)
    {
        Applied.Add(index);
        Notify();
    }

    private void Handle(ReviewEvent e, int generation)
    {
        if (generation != _generation) return;
        switch (e)
        {
            case ReviewEvent.Started started:
                Files = started.Files;
                Activities.Add(L10n.Tr("ai.activity.files", started.Files.Length));
                if (started.Excluded.Length > 0) Activities.Add(L10n.Tr("ai.activity.excluded", string.Join(", ", started.Excluded)));
                if (started.Truncated) Activities.Add(L10n.Tr("ai.activity.truncated"));
                break;
            case ReviewEvent.Thinking thinking:
                Turn = thinking.Turn;
                FlushNarration();
                break;
            case ReviewEvent.Text text:
                Narration += text.TextValue;
                break;
            case ReviewEvent.ToolCall call:
                // 模型在调用工具前写的说明排在工具调用之前。
                FlushNarration();
                Activities.Add($"{ToolTitle(call.Name)}  {call.Detail}");
                break;
            case ReviewEvent.Usage usage:
                Usage = (usage.InputTokens, usage.OutputTokens);
                break;
            case ReviewEvent.Finished finished:
                Result = finished.Result;
                State = Phase.Finished;
                _task = null;
                Finish(finished.Result);
                break;
            case ReviewEvent.Failed failed:
                _task = null;
                if (failed.Error is CoreException.AiCancelled)
                {
                    State = Phase.Cancelled;
                }
                else
                {
                    State = Phase.Failed;
                    ErrorText = L10n.Message(failed.Error);
                }
                Finish(null);
                break;
        }
        Notify();
    }

    private void FlushNarration()
    {
        var text = Narration.Trim();
        if (text.Length > 0) Activities.Add(text);
        Narration = "";
    }

    private void Finish(ReviewResult? result)
    {
        var completion = _completion;
        _completion = null;
        if (result is not null)
        {
            var problems = result.Findings.Length;
            _model.Post(problems == 0 ? L10n.Tr("ai.done.none") : L10n.Tr("ai.done.some", problems));
        }
        else if (State == Phase.Failed)
        {
            _model.Post(L10n.Tr("ai.failed"), isError: true);
        }
        Notify();
        completion?.Invoke(result);
    }

    private static string ToolTitle(string name) => name switch
    {
        "read_file" => L10n.Tr("ai.tool.readFile"),
        "list_directory" => L10n.Tr("ai.tool.listDirectory"),
        "search_code" => L10n.Tr("ai.tool.search"),
        "git_log" => L10n.Tr("ai.tool.log"),
        "git_blame" => L10n.Tr("ai.tool.blame"),
        _ => name,
    };

    // MARK: - 提交前检查

    /// 提交前评审选中的改动；返回是否继续提交。发现错误或警告时询问用户。
    public async Task<bool> ReviewBeforeCommit(IReadOnlyList<string> paths)
    {
        var source = new TaskCompletionSource<ReviewResult?>();
        await Start(new ReviewScope.LocalChanges([.. paths]), L10n.Tr("ai.scope.local", paths.Count), allowSkip: true, completion: result => source.TrySetResult(result));
        var result = await source.Task;
        if (_root() is not { } root) return false;
        if (result is null)
        {
            // 失败或取消：失败时询问是否仍然提交。
            if (State != Phase.Failed) return false;
            return await ConfirmDialog.Show(root, L10n.Tr("ai.precommit.failed"), ErrorText ?? "", L10n.Tr("ai.precommit.commitAnyway"));
        }
        var problems = result.Findings.Count(f => f.Severity != ReviewSeverity.Suggestion);
        if (problems == 0) return true;
        var dialog = Dialogs.Create(root, L10n.Tr("ai.precommit.problems", problems));
        dialog.Content = new TextBlock { Text = L10n.Tr("ai.precommit.problems.message"), TextWrapping = TextWrapping.Wrap, MaxWidth = 420 };
        dialog.PrimaryButtonText = L10n.Tr("ai.precommit.review");
        dialog.SecondaryButtonText = L10n.Tr("ai.precommit.commitAnyway");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        switch (await dialog.ShowAsync())
        {
            case ContentDialogResult.Primary:
                Reveal?.Invoke();
                return false;
            case ContentDialogResult.Secondary:
                return true;
            default:
                return false;
        }
    }

    // MARK: - 生成提交信息

    /// 根据选中文件生成提交信息；生成中再次调用为取消。取消或失败时返回 null（失败会提示）。
    public async Task<string?> GenerateCommitMessage(IReadOnlyList<string> paths)
    {
        if (_messageTask is { } running)
        {
            running.Cancel();
            _messageTask = null;
            Notify();
            return null;
        }
        var (readiness, config, apiKey) = await Prepare();
        if (readiness != Readiness.Ready || config is null) return null;
        var task = new AiTask();
        _messageTask = task;
        Notify();
        var repository = _model.Repository;
        var language = AISettings.ReviewLanguage.PromptName();
        var patterns = AISettings.SensitivePatterns.ToArray();
        string? message = null;
        Exception? failure = null;
        try
        {
            message = await Task.Run(() => repository.GenerateCommitMessage(config, apiKey, [.. paths], language, patterns, task));
        }
        catch (CoreException error)
        {
            failure = error;
        }
        if (_messageTask != task) return null;
        _messageTask = null;
        Notify();
        if (failure is null or CoreException.AiCancelled) return message;
        if (_root() is { } root) await Dialogs.ShowMessage(root, L10n.Tr("ai.message.failed"), L10n.Message(failure));
        return null;
    }

    /// 把核心的回调接口转成委托。
    private sealed class ListenerBridge(Action<ReviewEvent> handler) : ReviewListener
    {
        public void OnEvent(ReviewEvent @event) => handler(@event);
    }
}
