using Microsoft.UI.Dispatching;

namespace GitDeck.Project;

/// 监听项目目录的文件变化，合并短时间内的多次变化后在界面线程回调（与 mac 端 FileWatcher 一致）。
///
/// 对应 IDEA 的 VFS 刷新：外部修改文件、命令行执行 git 后自动刷新状态。
/// `.git` 中与状态无关的变化（对象库、reflog、锁文件、GitDeck 自己的数据）被忽略。
public sealed class FileWatcher : IDisposable
{
    private static readonly string[] IgnoredGitPrefixes = ["objects/", "logs/", "gitdeck/", "worktrees/", "modules/"];
    private static readonly TimeSpan Window = TimeSpan.FromMilliseconds(500);

    private readonly string _root;
    private readonly Action<IReadOnlyCollection<string>> _onChange;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly HashSet<string> _pending = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock _lock = new();
    private FileSystemWatcher? _watcher;
    private bool _flushScheduled;

    public FileWatcher(string root, Action<IReadOnlyCollection<string>> onChange)
    {
        _root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        _onChange = onChange;
    }

    public void Start()
    {
        if (_watcher is not null) return;
        _watcher = new FileSystemWatcher(_root)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
            InternalBufferSize = 64 * 1024,
        };
        _watcher.Changed += (_, e) => Received(e.FullPath);
        _watcher.Created += (_, e) => Received(e.FullPath);
        _watcher.Deleted += (_, e) => Received(e.FullPath);
        _watcher.Renamed += (_, e) =>
        {
            Received(e.OldFullPath);
            Received(e.FullPath);
        };
        // 缓冲区溢出时无法知道具体文件，按整个项目变化处理。
        _watcher.Error += (_, _) => Received(_root);
        _watcher.EnableRaisingEvents = true;
    }

    public void Dispose()
    {
        _watcher?.Dispose();
        _watcher = null;
    }

    /// 在线程池线程上调用。
    private void Received(string path)
    {
        if (!IsRelevant(path)) return;
        lock (_lock)
        {
            _pending.Add(path);
            if (_flushScheduled) return;
            _flushScheduled = true;
        }
        // 构建等大量写文件时，每 0.5 秒最多回调一次。
        Task.Delay(Window).ContinueWith(_ => _dispatcher.TryEnqueue(Flush), TaskScheduler.Default);
    }

    private void Flush()
    {
        string[] changed;
        lock (_lock)
        {
            changed = [.. _pending];
            _pending.Clear();
            _flushScheduled = false;
        }
        if (_watcher is not null) _onChange(changed);
    }

    private bool IsRelevant(string path)
    {
        var relative = Path.GetRelativePath(_root, path).Replace('\\', '/');
        if (!relative.StartsWith(".git/", StringComparison.OrdinalIgnoreCase)) return relative != ".git";
        var inner = relative[5..];
        if (inner.EndsWith(".lock", StringComparison.OrdinalIgnoreCase)) return false;
        return !IgnoredGitPrefixes.Any(prefix => inner.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }
}
