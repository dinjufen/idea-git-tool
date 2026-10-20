using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Dispatching;
using Windows.UI;

namespace GitDeck.Project;

/// 一个项目窗口中的所有仓库（IDEA 的多个 VCS 根，与 mac 端 Workspace 一致）：项目根目录的仓库 + 用户加入的嵌套仓库 / 子模块。
///
/// 每个仓库仍由独立的 ProjectModel 表示；本类负责持久化仓库列表、检测未加入的嵌套仓库、
/// 按文件路径找到所属仓库，以及汇总各仓库的状态变化。
public sealed class Workspace
{
    /// 每个仓库在 Log、提交窗口与分支弹窗中的标识色（主仓库为第一种）：浅色、深色。
    private static readonly (uint Light, uint Dark)[] Palette =
    [
        (0x534AB7, 0x8F87F1),
        (0x1D9E75, 0x4CC79C),
        (0xD85A30, 0xF0886A),
        (0x378ADD, 0x6AA8EC),
        (0xBA7517, 0xE4A548),
        (0xD4537E, 0xEC85A8),
    ];

    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly List<ProjectModel> _models;

    public Workspace(ProjectModel primary)
    {
        Primary = primary;
        _models = [primary];
        primary.Changed += Notify;
    }

    /// 仓库列表或任一仓库的状态变化。
    public event Action? Changed;

    /// 加入了新的仓库（参数为该仓库）。
    public event Action<ProjectModel>? Added;

    public ProjectModel Primary { get; }

    public IReadOnlyList<ProjectModel> Models => _models;

    /// 检测到但尚未加入、也未被忽略的嵌套仓库（显示在提示条中）。
    public IReadOnlyList<NestedRepository> Candidates { get; private set; } = [];

    public bool IsMultiRoot => _models.Count > 1;

    private string RootsKey => "workspace.roots:" + Primary.RootPath.ToLowerInvariant();

    private string IgnoredKey => "workspace.ignored:" + Primary.RootPath.ToLowerInvariant();

    private void Notify() => Changed?.Invoke();

    // MARK: - 仓库列表

    /// 打开上次加入的仓库，然后检测新的嵌套仓库。
    public void Load()
    {
        var saved = Settings.GetStringList(RootsKey);
        OpenAll(saved, save: false, Detect);
    }

    private void OpenAll(IReadOnlyList<string> paths, bool save, Action? then = null)
    {
        Task.Run(() => paths.Select(path =>
        {
            try
            {
                return Repository.Open(path);
            }
            catch (CoreException)
            {
                return null;
            }
        }).OfType<Repository>().ToList()).ContinueWith(task => _dispatcher.TryEnqueue(() =>
        {
            foreach (var repository in task.Result)
            {
                if (Contains(repository.Root())) continue;
                var model = new ProjectModel(repository);
                _models.Add(model);
                model.Changed += Notify;
                model.Refresh();
                Added?.Invoke(model);
            }
            if (save) Save();
            Notify();
            then?.Invoke();
        }), TaskScheduler.Default);
    }

    private bool Contains(string path) => _models.Any(m => RecentProjects.SamePath(m.RootPath, path));

    private void Save() => Settings.Set(RootsKey, _models.Skip(1).Select(m => m.RootPath));

    /// 加入仓库（检测到的嵌套仓库或用户选择的目录）。
    public void Add(IReadOnlyList<string> paths)
    {
        var ignored = Settings.GetStringList(IgnoredKey);
        ignored.RemoveAll(p => paths.Any(path => RecentProjects.SamePath(p, path)));
        Settings.Set(IgnoredKey, ignored);
        OpenAll(paths, save: true, () =>
        {
            Candidates = [.. Candidates.Where(c => !Contains(c.Path))];
            Notify();
        });
    }

    public void Remove(ProjectModel model)
    {
        if (model == Primary || !_models.Remove(model)) return;
        model.Changed -= Notify;
        Save();
        Notify();
    }

    /// 不再提示这些嵌套仓库。加入时从忽略列表中移除。
    public void Ignore(IReadOnlyList<string> paths)
    {
        var ignored = Settings.GetStringList(IgnoredKey);
        ignored.AddRange(paths.Where(p => !ignored.Contains(p, StringComparer.OrdinalIgnoreCase)));
        Settings.Set(IgnoredKey, ignored);
        Candidates = [.. Candidates.Where(c => !paths.Contains(c.Path, StringComparer.OrdinalIgnoreCase))];
        Notify();
    }

    /// 检测项目目录中尚未加入的仓库（子模块与嵌套仓库）。
    public void Detect()
    {
        var repository = Primary.Repository;
        var ignored = Settings.GetStringList(IgnoredKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Task.Run(() =>
        {
            try
            {
                return repository.NestedRepositories(4);
            }
            catch (CoreException)
            {
                return [];
            }
        }).ContinueWith(task => _dispatcher.TryEnqueue(() =>
        {
            Candidates = [.. task.Result.Where(c => !ignored.Contains(c.Path) && !Contains(c.Path))];
            Notify();
        }), TaskScheduler.Default);
    }

    // MARK: - 查询

    /// 包含该文件的仓库（嵌套仓库优先，即根目录最长的那个）；不在任何仓库内时为主仓库。
    public ProjectModel ModelContaining(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd('\\', '/');
        return _models
            .Where(m =>
            {
                var root = Path.GetFullPath(m.RootPath).TrimEnd('\\', '/');
                return full.Equals(root, StringComparison.OrdinalIgnoreCase)
                       || full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
            })
            .MaxBy(m => m.RootPath.Length) ?? Primary;
    }

    /// 文件相对其所属仓库根目录的路径（`/` 分隔）。
    public (ProjectModel Model, string RelativePath) Locate(string path)
    {
        var model = ModelContaining(path);
        var relative = Path.GetRelativePath(model.RootPath, Path.GetFullPath(path)).Replace('\\', '/');
        return (model, relative == "." ? "" : relative);
    }

    public Color Color(ProjectModel model, bool dark)
    {
        var index = Math.Max(0, _models.IndexOf(model));
        var (light, darkColor) = Palette[index % Palette.Length];
        return Editor.SyntaxTheme.Rgb(dark ? darkColor : light);
    }

    /// 仓库的显示名：相对主仓库的路径（主仓库为项目名）。
    public string DisplayName(ProjectModel model)
    {
        if (model == Primary) return Primary.ProjectName;
        var relative = Path.GetRelativePath(Primary.RootPath, model.RootPath).Replace('\\', '/');
        return relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative) ? model.ProjectName : relative;
    }

    /// 分支组件标题：各仓库在同一分支时显示分支名，否则显示主仓库分支并注明仓库数（IDEA 的多仓库分支组件）。
    public string BranchWidgetTitle
    {
        get
        {
            if (!IsMultiRoot) return Primary.BranchWidgetTitle;
            var heads = _models.Select(m => m.CurrentBranchTitle).Distinct().Count();
            return heads == 1
                ? L10n.Tr("workspace.branch.same", Primary.BranchWidgetTitle, _models.Count)
                : L10n.Tr("workspace.branch.mixed", Primary.CurrentBranchTitle, _models.Count);
        }
    }

    public bool IsRefreshing => _models.Any(m => m.IsRefreshing);

    public void RefreshAll()
    {
        foreach (var model in _models) model.Refresh();
    }
}

/// 多仓库的同步分支控制（IDEA 的 “Synchronous branch control”）：在一个仓库中签出或新建分支时，
/// 对其他仓库执行相同的操作。
public static class SyncBranchControl
{
    private const string Key = "workspace.syncBranches";

    public static bool IsEnabled
    {
        get => Settings.GetBool(Key, true);
        set => Settings.Set(Key, value);
    }
}
