using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;

namespace GitDeck.Merge;

/// 打开 Conflicts 对话框与三栏合并窗口（读取各方版本与计算分块在后台进行；与 mac 端 ConflictResolver 一致）。
public sealed class ConflictResolver
{
    private readonly ProjectModel _model;
    private readonly Func<XamlRoot?> _root;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    /// 已打开的合并窗口，按文件路径索引；同一文件只打开一个。
    private readonly Dictionary<string, MergeWindow> _mergeWindows = [];
    private ConflictsDialog? _dialog;
    /// 已请求打开 Conflicts 对话框时，还要等待的刷新次数。请求时可能已有一次旧的刷新在进行，
    /// 其结果尚不含冲突，因此最多等两次刷新完成。
    private int _pendingRefreshes;

    public ConflictResolver(ProjectModel model, Func<XamlRoot?> root)
    {
        _model = model;
        _root = root;
        _model.Changed += ModelChanged;
    }

    /// 合并窗口打开后（调试参数使用）。
    public event Action<MergeWindow>? MergeOpened;

    public bool HasConflicts => _model.Status.Changes.Any(c => c.Conflict is not null);

    private void ModelChanged()
    {
        if (_pendingRefreshes == 0 || _model.IsRefreshing) return;
        if (HasConflicts)
        {
            _pendingRefreshes = 0;
            _ = ShowConflicts();
        }
        else
        {
            _pendingRefreshes--;
        }
    }

    /// 操作刚产生冲突时调用：刷新状态后再打开对话框。
    public void RequestConflicts()
    {
        _pendingRefreshes = 2;
        _model.Refresh();
    }

    public async Task ShowConflicts()
    {
        if (!HasConflicts || _dialog is not null || _root() is not { } root) return;
        var dialog = new ConflictsDialog(_model, root, OpenMerge);
        _dialog = dialog;
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            // 同一窗口已有其他对话框打开时无法显示。
            Log.Error("conflicts dialog", e);
        }
        finally
        {
            _dialog = null;
        }
    }

    /// 打开某个冲突文件的三栏合并；一方已删除或为二进制文件时改为打开 Conflicts 对话框。
    public void OpenMerge(FileChange change)
    {
        if (change.Conflict is not { } kind || !ConflictsDialog.BothSidesExist(kind))
        {
            _ = ShowConflicts();
            return;
        }
        if (_mergeWindows.TryGetValue(change.Path, out var existing))
        {
            existing.Activate();
            return;
        }
        var repository = _model.Repository;
        var path = change.Path;
        Task.Run(() =>
        {
            var versions = repository.ConflictVersions(path);
            var labels = repository.ConflictLabels();
            var chunks = CoreApi.MergeChunks(versions.Base ?? "", versions.Ours ?? "", versions.Theirs ?? "");
            return (versions, labels, chunks);
        }).ContinueWith(task => _dispatcher.TryEnqueue(async () =>
        {
            if (task.Exception?.InnerException is { } error)
            {
                if (_root() is { } root) await Dialogs.ShowMessage(root, L10n.Tr("conflicts.failed"), L10n.Message(error));
                return;
            }
            var (versions, labels, chunks) = task.Result;
            var binary = new[] { versions.Base, versions.Ours, versions.Theirs }.Any(t => t?.Contains('\0') == true);
            if (binary)
            {
                await ShowConflicts();
                return;
            }
            var window = new MergeWindow(_model, path, versions, labels, chunks);
            window.Closed += (_, _) => _mergeWindows.Remove(path);
            _mergeWindows[path] = window;
            window.NotifyWhenReady();
            MergeOpened?.Invoke(window);
            window.Activate();
        }), TaskScheduler.Default);
    }
}
