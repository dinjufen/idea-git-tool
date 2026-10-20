using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Dispatching;

namespace GitDeck.Project;

/// 一个项目窗口对应的仓库状态（与 mac 端 ProjectModel 一致）。
/// 所有 git 调用在后台线程执行，结果回到界面线程后触发 <see cref="Changed"/>。
public sealed class ProjectModel
{
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private bool _pendingRefresh;

    public ProjectModel(Repository repository)
    {
        Repository = repository;
        RootPath = Path.GetFullPath(repository.Root());
    }

    public event Action? Changed;

    public Repository Repository { get; }

    public string RootPath { get; }

    public string ProjectName => Path.GetFileName(Path.TrimEndingDirectorySeparator(RootPath));

    public RepoStatus Status { get; private set; } =
        new(new BranchStatus(null, null, null, 0, 0), [], RepositoryState.Normal);

    public BranchRef[] Branches { get; private set; } = [];

    public TagInfo[] Tags { get; private set; } = [];

    public StashEntry[] Stashes { get; private set; } = [];

    /// 引用或 HEAD 发生变化时改变，用于判断 Log 是否需要重新加载。
    public string RefsSignature =>
        string.Join("\n", new[] { Status.Branch.Oid ?? "", Status.Branch.Head ?? "" }
            .Concat(Branches.Select(b => b.FullRef + "=" + b.Target))
            .Concat(Tags.Select(t => "tag:" + t.Name + "=" + t.Target)));

    /// 相对路径 → 变更，供 Project 树着色。
    public IReadOnlyDictionary<string, FileChange> ChangesByPath { get; private set; } = new Dictionary<string, FileChange>();

    public bool IsRefreshing { get; private set; }

    public string? LastError { get; private set; }

    /// 最近一条通知（例如操作结果），显示在状态栏，对应 IDEA 的事件通知。
    public (string Text, bool IsError)? Notification { get; private set; }

    /// 当前分支显示名：分离 HEAD 时显示短提交号，与 IDEA 一致。
    public string CurrentBranchTitle =>
        Status.Branch.Head ?? (Status.Branch.Oid is { } oid ? oid[..Math.Min(8, oid.Length)] : L10n.Tr("vcs.noBranch"));

    /// VCS 分支组件标题：分支名 + 进行中的操作 + 与上游的差异（例如 `main ↑1 ↓2`）。
    public string BranchWidgetTitle
    {
        get
        {
            var parts = new List<string> { CurrentBranchTitle };
            switch (Status.State)
            {
                case RepositoryState.Merging: parts.Add(L10n.Tr("vcs.state.merging")); break;
                case RepositoryState.Rebasing: parts.Add(L10n.Tr("vcs.state.rebasing")); break;
                case RepositoryState.CherryPicking: parts.Add(L10n.Tr("vcs.state.cherryPicking")); break;
                case RepositoryState.Reverting: parts.Add(L10n.Tr("vcs.state.reverting")); break;
            }
            if (Status.Branch.Ahead > 0) parts.Add($"↑{Status.Branch.Ahead}");
            if (Status.Branch.Behind > 0) parts.Add($"↓{Status.Branch.Behind}");
            return string.Join(" ", parts);
        }
    }

    public void Post(string text, bool isError = false)
    {
        Notification = (text, isError);
        Changed?.Invoke();
    }

    /// 刷新状态与分支。刷新进行中再次调用时，会在结束后补刷一次。
    public void Refresh()
    {
        if (IsRefreshing)
        {
            _pendingRefresh = true;
            return;
        }
        IsRefreshing = true;
        Changed?.Invoke();
        var repository = Repository;
        Task.Run(() => (repository.Status(), repository.Branches(), repository.Tags(), repository.Stashes())).ContinueWith(task =>
        {
            _dispatcher.TryEnqueue(() =>
            {
                if (task.Exception?.InnerException is { } error)
                {
                    LastError = L10n.Message(error);
                }
                else
                {
                    (Status, Branches, Tags, Stashes) = task.Result;
                    ChangesByPath = Status.Changes.GroupBy(c => c.Path).ToDictionary(g => g.Key, g => g.First());
                    LastError = null;
                }
                IsRefreshing = false;
                Changed?.Invoke();
                if (_pendingRefresh)
                {
                    _pendingRefresh = false;
                    Refresh();
                }
            });
        }, TaskScheduler.Default);
    }
}
