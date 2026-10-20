using System.Text;
using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Diff;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Editor;

/// 编辑器区域：标签栏 + 代码编辑器（语法高亮、查找、相对 HEAD 的变更标记）或 Diff 页。与 mac 端 EditorAreaView 一致。
public sealed class EditorArea : Grid
{
    /// 标签页的内容：文件文档或 Diff 页。
    public interface ITab
    {
        string Title { get; }

        string Tooltip { get; }

        bool IsModified { get; }

        /// 标签上显示 Diff 图标。
        bool IsDiff { get; }

        UIElement View { get; }
    }

    /// Diff 页：同一来源（例如同一提交中的同一文件）只打开一个标签。
    public sealed class DiffTab(string key, string title, string tooltip, DiffView view) : ITab
    {
        public string Key { get; } = key;

        public string Title { get; } = title;

        public string Tooltip { get; } = tooltip;

        public bool IsModified => false;

        public bool IsDiff => true;

        public DiffView Diff { get; } = view;

        public UIElement View => Diff;
    }

    /// 打开的文件。
    public sealed class Document : ITab
    {
        public Document(string path, ProjectModel owner, string? relativePath, string text, bool hasBom)
        {
            Path = path;
            Owner = owner;
            RelativePath = relativePath;
            HasBom = hasBom;
            Editor = new CodeEditor(text, CoreApi.LanguageForPath(System.IO.Path.GetFileName(path)));
        }

        public string Path { get; }

        /// 文件所属的仓库（多仓库项目中为包含该文件的嵌套仓库）。
        public ProjectModel Owner { get; }

        /// 相对所属仓库根目录的路径（`/` 分隔）；仓库外的文件为 null（不显示变更标记）。
        public string? RelativePath { get; }

        public CodeEditor Editor { get; }

        /// 原文件带 UTF-8 BOM 时保存时保留。
        public bool HasBom { get; }

        public bool IsModified { get; set; }

        /// 正在从磁盘重新载入（编辑器内容变化不标记为已修改）。
        public bool IsReloading { get; set; }

        /// HEAD 中的内容；文件不在 HEAD 中时为 null。
        public string? Base { get; set; }

        public CancellationTokenSource? LineStatusCancel { get; set; }

        /// blame 对应的文件内容；编辑后据此把注释映射到当前行。
        public string? BlameText { get; set; }

        public CancellationTokenSource? AnnotationCancel { get; set; }

        public string Title => System.IO.Path.GetFileName(Path);

        public string Tooltip => Path;

        public bool IsDiff => false;

        public UIElement View => Editor;
    }

    private readonly ProjectModel _model;
    private readonly StackPanel _tabBar = new() { Orientation = Orientation.Horizontal };
    private readonly Grid _content = new();
    private readonly FrameworkElement _emptyState;
    private readonly List<ITab> _tabs = [];
    private ITab? _active;
    /// 各仓库上次的 HEAD；变化时重新读取该仓库中打开文件的基准版本。
    private readonly Dictionary<ProjectModel, string?> _lastHeads = [];
    private Workspace? _workspace;

    public EditorArea(ProjectModel model)
    {
        _model = model;
        Themed.Background(this, "EditorBackgroundBrush");
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var tabScroll = new ScrollViewer
        {
            Content = _tabBar,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
        };
        var separator = Themed.Background(new Border(), "SeparatorBrush");
        SetRow(separator, 1);
        SetRow(_content, 2);
        Children.Add(tabScroll);
        Children.Add(separator);
        Children.Add(_content);
        _emptyState = BuildEmptyState();
        ShowEmptyState();
        _model.Changed += ModelChanged;
    }

    /// 光标信息（行:列、换行符、编码），显示在状态栏右侧。
    public event Action<string>? CaretInfoChanged;

    public event Action<string, bool>? Message;

    /// 在 Git 日志中定位某个提交（点击 Annotate 注释时）。
    public event Action<string>? ShowCommit;

    /// 显示文件历史：相对所属仓库根目录的路径与所属仓库。
    public event Action<string, ProjectModel>? ShowHistory;

    /// 点击编辑器中的 AI 评审标记（参数为发现下标）。
    public event Action<int>? ShowFinding;

    private AI.AIReviewController? _aiReview;

    /// AI 评审：工作区文件上的发现在编辑器中标记。
    public AI.AIReviewController? AiReview
    {
        get => _aiReview;
        set
        {
            _aiReview = value;
            if (value is not null) value.Changed += UpdateReviewMarkers;
            UpdateReviewMarkers();
        }
    }

    private IEnumerable<Document> Documents => _tabs.OfType<Document>();

    public CodeEditor? ActiveEditor => (_active as Document)?.Editor;

    public DiffView? ActiveDiff => (_active as DiffTab)?.Diff;

    public bool HasModifiedDocuments => Documents.Any(d => d.IsModified);

    /// 当前编辑的文件相对仓库根目录的路径（不在仓库中或不是文件时为 null）。
    public string? ActiveRelativePath => (_active as Document)?.RelativePath;

    /// 多仓库项目：嵌套仓库中的文件使用该仓库的变更标记、Blame 与历史。
    public Workspace? Workspace
    {
        get => _workspace;
        set
        {
            if (_workspace is not null) _workspace.Changed -= ModelChanged;
            else _model.Changed -= ModelChanged;
            _workspace = value;
            if (value is not null) value.Changed += ModelChanged;
            else _model.Changed += ModelChanged;
        }
    }

    /// 当前编辑的文件（完整路径）。
    public string? ActivePath => (_active as Document)?.Path;

    public bool IsActiveAnnotated => (_active as Document)?.Editor.Annotations is not null;

    /// 打开 Diff 页；`key` 相同的 Diff 已打开时直接切换过去。
    public void OpenDiff(string key, string title, string tooltip, Func<DiffView> make)
    {
        if (_tabs.OfType<DiffTab>().FirstOrDefault(t => t.Key == key) is { } existing)
        {
            Activate(existing);
            return;
        }
        var tab = new DiffTab(key, title, tooltip, make());
        _tabs.Add(tab);
        Activate(tab);
    }

    // MARK: - 打开与保存

    public void Open(string path)
    {
        path = System.IO.Path.GetFullPath(path);
        if (Documents.FirstOrDefault(d => RecentProjects.SamePath(d.Path, path)) is { } existing)
        {
            Activate(existing);
            return;
        }
        if (!TryRead(path, out var text, out var hasBom))
        {
            // 二进制或非 UTF-8 文件暂不支持编辑（与 mac 端一致，后续按编码检测处理）。
            Message?.Invoke(L10n.Tr("editor.unsupported.win", System.IO.Path.GetFileName(path)), true);
            return;
        }
        var (owner, relativePath) = Locate(path);
        var document = new Document(path, owner, relativePath, text, hasBom);
        document.Editor.TextChanged += () =>
        {
            if (!document.IsModified && !document.IsReloading)
            {
                document.IsModified = true;
                RebuildTabs();
            }
            UpdateLineStatus(document, TimeSpan.FromMilliseconds(250));
            UpdateAnnotationMap(document);
        };
        document.Editor.AnnotationClicked += hash => ShowCommit?.Invoke(hash);
        document.Editor.ReviewMarkerClicked += index => ShowFinding?.Invoke(index);
        document.Editor.GutterContextRequested += point => ShowGutterMenu(document, point);
        document.Editor.CaretChanged += (line, column) =>
        {
            if (document == _active) CaretInfoChanged?.Invoke($"{line}:{column}    {document.Editor.LineEnding}    UTF-8");
        };
        _tabs.Add(document);
        Activate(document);
        LoadBase(document);
        UpdateReviewMarkers(document);
    }

    /// 打开文件并把第 `line` 行（从 0 开始）滚动到视口中。
    public void Open(string path, int line)
    {
        Open(path);
        if (_active is Document document && RecentProjects.SamePath(document.Path, path))
        {
            // 新打开的编辑器尚未加载，等加载完成后再滚动。
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => document.Editor.Reveal(Math.Max(0, line)));
        }
    }

    public void SaveActive()
    {
        if (_active is not Document document) return;
        try
        {
            Write(document);
            document.IsModified = false;
            RebuildTabs();
            document.Owner.Refresh();
            // 保存后重新 blame，使注释与文件内容对应。
            if (document.Editor.Annotations is not null) LoadBlame(document);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Message?.Invoke(e.Message, true);
        }
    }

    public async Task CloseActive()
    {
        if (_active is { } document) await Close(document);
    }

    /// 关闭窗口前：逐个询问未保存的文件；取消时返回 false。
    public async Task<bool> ConfirmCloseAll()
    {
        foreach (var document in Documents.Where(d => d.IsModified).ToList())
        {
            Activate(document);
            if (!await ConfirmClose(document)) return false;
        }
        return true;
    }

    /// 外部修改了文件：没有未保存修改的文档重新载入磁盘内容（可撤销），有修改的保持不变。
    public void ReloadFromDisk(IReadOnlyCollection<string> paths)
    {
        var changed = new HashSet<string>(paths.Select(System.IO.Path.GetFullPath), StringComparer.OrdinalIgnoreCase);
        foreach (var document in Documents.Where(d => !d.IsModified && changed.Contains(d.Path)).ToList())
        {
            if (!TryRead(document.Path, out var text, out _) || text == document.Editor.Text) continue;
            document.IsReloading = true;
            document.Editor.ReplaceText(text);
            document.IsReloading = false;
            UpdateLineStatus(document, TimeSpan.Zero);
            if (document.Editor.Annotations is not null) LoadBlame(document);
        }
    }

    private static bool TryRead(string path, out string text, out bool hasBom)
    {
        text = "";
        hasBom = false;
        try
        {
            var bytes = File.ReadAllBytes(path);
            hasBom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
            var body = hasBom ? bytes.AsSpan(3) : bytes;
            if (body.IndexOf((byte)0) >= 0) return false;
            text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(body);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or DecoderFallbackException)
        {
            return false;
        }
    }

    private static void Write(Document document) =>
        File.WriteAllText(document.Path, document.Editor.Text, new UTF8Encoding(document.HasBom));

    /// 文件所属的仓库与相对路径；不在任何仓库中时路径为 null。
    private (ProjectModel Owner, string? RelativePath) Locate(string path)
    {
        var owner = _workspace?.ModelContaining(path) ?? _model;
        var relative = System.IO.Path.GetRelativePath(owner.RootPath, path);
        return (owner, relative.StartsWith("..", StringComparison.Ordinal) || System.IO.Path.IsPathRooted(relative)
            ? null
            : relative.Replace('\\', '/'));
    }

    // MARK: - 打开的标签页持久化（与 IDEA 重新打开项目时恢复编辑器标签一致）

    private string SessionKey => "openFiles:" + _model.RootPath.ToLowerInvariant();

    /// 恢复上次打开的文件，最后一个为当前标签。
    public void RestoreSession()
    {
        foreach (var path in Settings.GetStringList(SessionKey).Where(File.Exists)) Open(path);
    }

    private void SaveSession()
    {
        var paths = Documents.Select(d => d.Path).ToList();
        // 当前标签放在最后，恢复时最后打开即成为当前标签。
        if (_active is Document active)
        {
            paths.Remove(active.Path);
            paths.Add(active.Path);
        }
        Settings.Set(SessionKey, paths);
    }

    // MARK: - 变更标记（line status）

    /// 读取 HEAD 版本作为对比基准，然后计算变更标记。
    private void LoadBase(Document document)
    {
        if (document.RelativePath is not { } path) return;
        var repository = document.Owner.Repository;
        Task.Run(() =>
        {
            try
            {
                return repository.FileAtRevision("HEAD", path);
            }
            catch (CoreException)
            {
                return null;
            }
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            document.Base = task.Result;
            UpdateLineStatus(document, TimeSpan.Zero);
        }), TaskScheduler.Default);
    }

    private void UpdateLineStatus(Document document, TimeSpan delay)
    {
        document.LineStatusCancel?.Cancel();
        if (document.Base is not { } baseText)
        {
            document.Editor.LineChanges = [];
            return;
        }
        var cancel = document.LineStatusCancel = new CancellationTokenSource();
        var text = document.Editor.Text;
        var revision = document.Editor.Revision;
        _ = Task.Run(async () =>
        {
            if (delay > TimeSpan.Zero) await Task.Delay(delay, cancel.Token);
            var changes = CoreApi.LineChanges(baseText, text);
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!cancel.IsCancellationRequested && document.Editor.Revision == revision) document.Editor.LineChanges = changes;
            });
        }, cancel.Token);
    }

    /// 提交、检出等操作改变 HEAD 后，重新读取所有打开文件的基准版本。
    private void ModelChanged()
    {
        foreach (var model in _workspace?.Models ?? [_model])
        {
            if (model.IsRefreshing) continue;
            var head = model.Status.Branch.Oid;
            if (_lastHeads.TryGetValue(model, out var last) && last == head) continue;
            _lastHeads[model] = head;
            foreach (var document in Documents.Where(d => d.Owner == model).ToList())
            {
                LoadBase(document);
                if (document.Editor.Annotations is not null) LoadBlame(document);
            }
        }
    }

    // MARK: - AI 评审

    private void UpdateReviewMarkers()
    {
        foreach (var document in Documents) UpdateReviewMarkers(document);
    }

    private void UpdateReviewMarkers(Document document)
    {
        if (document.RelativePath is not { } path || _aiReview is null || document.Owner != _model)
        {
            document.Editor.ReviewMarkers = [];
            return;
        }
        document.Editor.ReviewMarkers = [.. _aiReview.WorkingTreeFindings(path).Select(x => new CodeEditor.ReviewMarker(
            x.Index, Math.Max(0, (int)x.Finding.Line - 1), x.Finding.Severity,
            $"{AI.AIReviewToolWindow.SeverityTitle(x.Finding.Severity)}: {x.Finding.Title}"))];
    }

    /// 文件的当前内容：已打开时为编辑器中的内容（含未保存的编辑），否则为 null。
    public string? TextOf(string path) =>
        Documents.FirstOrDefault(d => RecentProjects.SamePath(d.Path, Path.GetFullPath(path)))?.Editor.Text;

    /// 写入修改后的内容（应用 AI 建议）：已打开的文件在编辑器中替换（可撤销）并保存。
    public void ApplyEdit(string path, string text)
    {
        var full = Path.GetFullPath(path);
        if (Documents.FirstOrDefault(d => RecentProjects.SamePath(d.Path, full)) is { } document)
        {
            document.IsReloading = true;
            document.Editor.ReplaceText(text);
            document.IsReloading = false;
            Write(document);
            document.IsModified = false;
            RebuildTabs();
            UpdateLineStatus(document, TimeSpan.Zero);
            return;
        }
        var hasBom = TryRead(full, out _, out var bom) && bom;
        File.WriteAllText(full, text, new UTF8Encoding(hasBom));
    }

    // MARK: - Annotate

    /// 打开或关闭当前文件的 Annotate 列。
    public void ToggleAnnotations()
    {
        if (_active is not Document document) return;
        if (document.Editor.Annotations is not null) document.Editor.Annotations = null;
        else LoadBlame(document);
    }

    private void LoadBlame(Document document)
    {
        if (document.RelativePath is not { } path) return;
        var repository = document.Owner.Repository;
        var file = document.Path;
        Task.Run(() =>
        {
            // blame 针对磁盘上的文件；同时读出该内容作为行号映射的基准。
            var blame = repository.Blame(path, null);
            return (blame, TryRead(file, out var text, out _) ? text : null);
        }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (task.IsFaulted)
            {
                Message?.Invoke(L10n.Tr("annotate.failed", document.Title), true);
                return;
            }
            var (blame, text) = task.Result;
            document.BlameText = text;
            document.Editor.Annotations = blame;
            UpdateAnnotationMap(document);
        }), TaskScheduler.Default);
    }

    /// 文件被编辑后，把注释映射到当前行：未改动的行沿用原注释，新增与修改的行不显示注释。
    private void UpdateAnnotationMap(Document document)
    {
        document.AnnotationCancel?.Cancel();
        if (document.Editor.Annotations is null || document.BlameText is not { } baseText)
        {
            document.Editor.AnnotationLineMap = null;
            return;
        }
        var text = document.Editor.Text;
        if (text == baseText)
        {
            document.Editor.AnnotationLineMap = null;
            return;
        }
        var cancel = document.AnnotationCancel = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            await Task.Delay(150, cancel.Token);
            var changes = CoreApi.LineChanges(baseText, text);
            var lineCount = text.Length == 0 ? 0 : text.Count(c => c == '\n') + 1;
            var map = new int?[lineCount];
            int old = 0, current = 0;
            foreach (var change in changes)
            {
                while (current < change.Start && current < lineCount) map[current++] = old++;
                current += (int)change.Count;
                old += (int)change.BaseCount;
            }
            while (current < lineCount) map[current++] = old++;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!cancel.IsCancellationRequested) document.Editor.AnnotationLineMap = map;
            });
        }, cancel.Token);
    }

    /// 行号与注释列的右键菜单：Annotate / 关闭注释、显示历史（与 IDEA 的 gutter 菜单一致）。
    private void ShowGutterMenu(Document document, Windows.Foundation.Point point)
    {
        var menu = new MenuFlyout();
        var annotate = new MenuFlyoutItem
        {
            Text = document.Editor.Annotations is null ? L10n.Tr("git.action.annotate") : L10n.Tr("git.action.closeAnnotations"),
            IsEnabled = document.RelativePath is not null,
        };
        annotate.Click += (_, _) =>
        {
            if (document.Editor.Annotations is not null) document.Editor.Annotations = null;
            else LoadBlame(document);
        };
        var history = new MenuFlyoutItem { Text = L10n.Tr("git.action.showHistory"), IsEnabled = document.RelativePath is not null };
        history.Click += (_, _) =>
        {
            if (document.RelativePath is { } path) ShowHistory?.Invoke(path, document.Owner);
        };
        menu.Items.Add(annotate);
        menu.Items.Add(history);
        menu.ShowAt(document.Editor, point);
    }

    // MARK: - 标签页

    private async Task Close(ITab tab)
    {
        if (tab is Document document)
        {
            if (!await ConfirmClose(document)) return;
            document.LineStatusCancel?.Cancel();
            document.AnnotationCancel?.Cancel();
        }
        var index = _tabs.IndexOf(tab);
        _tabs.Remove(tab);
        if (_active == tab)
        {
            _active = null;
            _content.Children.Clear();
            if (_tabs.Count == 0)
            {
                ShowEmptyState();
                RebuildTabs();
            }
            else
            {
                Activate(_tabs[Math.Min(index, _tabs.Count - 1)]);
            }
        }
        else
        {
            RebuildTabs();
        }
        SaveSession();
    }

    /// 文件有未保存的修改时询问：保存 / 不保存 / 取消。返回 false 表示取消。
    private async Task<bool> ConfirmClose(Document document)
    {
        if (!document.IsModified) return true;
        var dialog = Dialogs.Create(XamlRoot, L10n.Tr("editor.unsaved.title", document.Title));
        dialog.PrimaryButtonText = L10n.Tr("editor.unsaved.save");
        dialog.SecondaryButtonText = L10n.Tr("editor.unsaved.discard");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        switch (await dialog.ShowAsync())
        {
            case ContentDialogResult.Primary:
                try
                {
                    Write(document);
                    document.IsModified = false;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    Message?.Invoke(e.Message, true);
                    return false;
                }
                return true;
            case ContentDialogResult.Secondary:
                document.IsModified = false;
                return true;
            default:
                return false;
        }
    }

    private void Activate(ITab tab)
    {
        _content.Children.Clear();
        _active = tab;
        _content.Children.Add(tab.View);
        if (tab is Document document) document.Editor.Focus();
        else CaretInfoChanged?.Invoke("");
        RebuildTabs();
        SaveSession();
    }

    private void ShowEmptyState()
    {
        _content.Children.Clear();
        _content.Children.Add(_emptyState);
        CaretInfoChanged?.Invoke("");
    }

    /// IDEA 风格的空状态：常用操作与快捷键。
    private static FrameworkElement BuildEmptyState()
    {
        var hints = new (string Title, string Shortcut)[]
        {
            (L10n.Tr("editor.empty.commit"), "Ctrl+K"),
            (L10n.Tr("editor.empty.update"), "Ctrl+T"),
            (L10n.Tr("editor.empty.push"), "Ctrl+Shift+K"),
            (L10n.Tr("editor.empty.project"), "Alt+1"),
        };
        var list = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var (title, shortcut) in hints)
        {
            list.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    Themed.Foreground(new TextBlock { Text = title }, "SecondaryTextBrush"),
                    Themed.Foreground(new TextBlock { Text = shortcut }, "AccentBrush"),
                },
            });
        }
        return list;
    }

    private void RebuildTabs()
    {
        _tabBar.Children.Clear();
        foreach (var item in _tabs)
        {
            var tab = new EditorTab(item.Title, item.IsModified, item == _active, item.IsDiff);
            ToolTipService.SetToolTip(tab, item.Tooltip);
            tab.Selected += () => Activate(item);
            tab.CloseRequested += () => _ = Close(item);
            _tabBar.Children.Add(tab);
        }
    }
}

/// 编辑器标签：选中时底部显示强调色下划线（New UI 样式）；中键点击关闭。
public sealed class EditorTab : Grid
{
    public event Action? Selected;

    public event Action? CloseRequested;

    public EditorTab(string title, bool modified, bool selected, bool isDiff = false)
    {
        Padding = new Thickness(12, 0, 6, 0);
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        var label = Themed.Foreground(new TextBlock
        {
            Text = modified ? "• " + title : title,
            VerticalAlignment = VerticalAlignment.Center,
        }, selected ? "PrimaryTextBrush" : "SecondaryTextBrush");
        var close = new IconButton(Icon.Close, L10n.Tr("menu.file.closeTab"), 18, 10) { VerticalAlignment = VerticalAlignment.Center };
        close.Click += (_, _) => CloseRequested?.Invoke();
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { label, close } };
        if (isDiff) stack.Children.Insert(0, Icons.Create(Icon.Diff, 12, Icons.ThemeBrush(this, "AccentBrush")));
        Children.Add(stack);
        if (selected)
        {
            Children.Add(Themed.Background(new Border { Height = 2, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(-12, 0, -6, 0) }, "AccentBrush"));
        }
        PointerReleased += OnPointerReleased;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var properties = e.GetCurrentPoint(this).Properties;
        if (properties.PointerUpdateKind == Microsoft.UI.Input.PointerUpdateKind.MiddleButtonReleased) CloseRequested?.Invoke();
        else if (properties.PointerUpdateKind == Microsoft.UI.Input.PointerUpdateKind.LeftButtonReleased) Selected?.Invoke();
    }
}
