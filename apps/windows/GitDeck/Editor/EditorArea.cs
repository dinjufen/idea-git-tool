using System.Text;
using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Editor;

/// 编辑器区域：标签栏 + 代码编辑器（语法高亮、查找、相对 HEAD 的变更标记）。与 mac 端 EditorAreaView 一致。
/// Diff 页等其他标签内容在后续批次加入。
public sealed class EditorArea : Grid
{
    /// 打开的文件。
    public sealed class Document
    {
        public Document(string path, string? relativePath, string text, bool hasBom)
        {
            Path = path;
            RelativePath = relativePath;
            HasBom = hasBom;
            Editor = new CodeEditor(text, CoreApi.LanguageForPath(System.IO.Path.GetFileName(path)));
        }

        public string Path { get; }

        /// 相对仓库根目录的路径（`/` 分隔）；仓库外的文件为 null（不显示变更标记）。
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

        public string Title => System.IO.Path.GetFileName(Path);
    }

    private readonly ProjectModel _model;
    private readonly StackPanel _tabBar = new() { Orientation = Orientation.Horizontal };
    private readonly Grid _content = new();
    private readonly FrameworkElement _emptyState;
    private readonly List<Document> _documents = [];
    private Document? _active;
    private string? _lastHead;

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

    public CodeEditor? ActiveEditor => _active?.Editor;

    public bool HasModifiedDocuments => _documents.Any(d => d.IsModified);

    // MARK: - 打开与保存

    public void Open(string path)
    {
        path = System.IO.Path.GetFullPath(path);
        if (_documents.FirstOrDefault(d => RecentProjects.SamePath(d.Path, path)) is { } existing)
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
        var document = new Document(path, RelativePath(path), text, hasBom);
        document.Editor.TextChanged += () =>
        {
            if (!document.IsModified && !document.IsReloading)
            {
                document.IsModified = true;
                RebuildTabs();
            }
            UpdateLineStatus(document, TimeSpan.FromMilliseconds(250));
        };
        document.Editor.CaretChanged += (line, column) =>
        {
            if (document == _active) CaretInfoChanged?.Invoke($"{line}:{column}    {document.Editor.LineEnding}    UTF-8");
        };
        _documents.Add(document);
        Activate(document);
        LoadBase(document);
    }

    /// 打开文件并把第 `line` 行（从 0 开始）滚动到视口中。
    public void Open(string path, int line)
    {
        Open(path);
        if (_active is { } document && RecentProjects.SamePath(document.Path, path))
        {
            // 新打开的编辑器尚未加载，等加载完成后再滚动。
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => document.Editor.Reveal(Math.Max(0, line)));
        }
    }

    public void SaveActive()
    {
        if (_active is not { } document) return;
        try
        {
            Write(document);
            document.IsModified = false;
            RebuildTabs();
            _model.Refresh();
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
        foreach (var document in _documents.Where(d => d.IsModified).ToList())
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
        foreach (var document in _documents.Where(d => !d.IsModified && changed.Contains(d.Path)))
        {
            if (!TryRead(document.Path, out var text, out _) || text == document.Editor.Text) continue;
            document.IsReloading = true;
            document.Editor.ReplaceText(text);
            document.IsReloading = false;
            UpdateLineStatus(document, TimeSpan.Zero);
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

    private string? RelativePath(string path)
    {
        var relative = System.IO.Path.GetRelativePath(_model.RootPath, path);
        return relative.StartsWith("..", StringComparison.Ordinal) || System.IO.Path.IsPathRooted(relative)
            ? null
            : relative.Replace('\\', '/');
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
        var paths = _documents.Select(d => d.Path).ToList();
        // 当前标签放在最后，恢复时最后打开即成为当前标签。
        if (_active is { } active)
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
        var repository = _model.Repository;
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
        if (_model.IsRefreshing || _model.Status.Branch.Oid == _lastHead) return;
        _lastHead = _model.Status.Branch.Oid;
        foreach (var document in _documents) LoadBase(document);
    }

    // MARK: - 标签页

    private async Task Close(Document document)
    {
        if (!await ConfirmClose(document)) return;
        document.LineStatusCancel?.Cancel();
        var index = _documents.IndexOf(document);
        _documents.Remove(document);
        if (_active == document)
        {
            _active = null;
            _content.Children.Clear();
            if (_documents.Count == 0)
            {
                ShowEmptyState();
                RebuildTabs();
            }
            else
            {
                Activate(_documents[Math.Min(index, _documents.Count - 1)]);
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

    private void Activate(Document document)
    {
        _content.Children.Clear();
        _active = document;
        _content.Children.Add(document.Editor);
        document.Editor.Focus();
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
        foreach (var document in _documents)
        {
            var tab = new EditorTab(document.Title, document.IsModified, document == _active);
            ToolTipService.SetToolTip(tab, document.Path);
            tab.Selected += () => Activate(document);
            tab.CloseRequested += () => _ = Close(document);
            _tabBar.Children.Add(tab);
        }
    }
}

/// 编辑器标签：选中时底部显示强调色下划线（New UI 样式）；中键点击关闭。
public sealed class EditorTab : Grid
{
    public event Action? Selected;

    public event Action? CloseRequested;

    public EditorTab(string title, bool modified, bool selected)
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
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { label, close } });
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
