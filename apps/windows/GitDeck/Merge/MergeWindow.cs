using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Diff;
using GitDeck.Editor;
using GitDeck.Project;
using GitDeck.Vcs;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;

namespace GitDeck.Merge;

/// 三栏合并工具（IDEA 的 Merge Revisions，与 mac 端 MergeWindowController 一致）：
/// 左为 “我们” 的版本，中为结果（可编辑），右为 “他们” 的版本。
///
/// 结果栏初始为共同祖先的内容；用连接带上的 `»` / `«` 把一侧的修改应用到结果，`×` 忽略该侧修改。
/// 冲突块两侧都可以应用（后应用的一侧追加在前者之后）。点击 “应用” 写入结果并标记为已解决。
public sealed class MergeWindow : Window
{
    private const double TitleBarHeight = 32;
    private const double ConnectorWidth = 48;

    public enum Side
    {
        Left,
        Right,
    }

    /// 一个三方变更块及其在结果文本中的当前位置与处理状态。
    public sealed class ChunkState(MergeChunk chunk)
    {
        public MergeChunk Chunk { get; } = chunk;
        public int ResultStart { get; set; } = (int)chunk.BaseStart;
        public int ResultCount { get; set; } = (int)chunk.BaseCount;
        public bool LeftApplied { get; set; }
        public bool RightApplied { get; set; }
        public bool LeftIgnored { get; set; }
        public bool RightIgnored { get; set; }

        private bool LeftHandled => LeftApplied || LeftIgnored;
        private bool RightHandled => RightApplied || RightIgnored;

        public bool IsResolved => Chunk.Kind switch
        {
            MergeChunkKind.Ours => LeftHandled,
            MergeChunkKind.Theirs => RightHandled,
            MergeChunkKind.Both => LeftHandled || RightHandled,
            _ => LeftHandled && RightHandled,
        };

        public bool CanAct(Side side) => !IsResolved && (side == Side.Left
            ? Chunk.Kind != MergeChunkKind.Theirs && !LeftHandled
            : Chunk.Kind != MergeChunkKind.Ours && !RightHandled);
    }

    private readonly ProjectModel _model;
    private readonly string _path;
    private readonly ConflictLabels _labels;
    private readonly List<string> _baseLines;
    private readonly List<string> _oursLines;
    private readonly List<string> _theirsLines;
    private readonly List<ChunkState> _chunks;
    private readonly CodeEditor _leftEditor;
    private readonly CodeEditor _centerEditor;
    private readonly CodeEditor _rightEditor;
    private readonly Canvas _leftConnector = new();
    private readonly Canvas _rightConnector = new();
    private readonly TextBlock _count = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid _root = new();
    private readonly List<(Side Side, int Index, bool Apply, Rect Box)> _buttons = [];
    private bool _applying;
    private bool _syncing;
    private bool _modified;
    private bool _saving;
    private bool _closeConfirmed;

    public MergeWindow(ProjectModel model, string path, ConflictVersions versions, ConflictLabels labels, MergeChunk[] chunks)
    {
        _model = model;
        _path = path;
        _labels = labels;
        var baseText = versions.Base ?? "";
        var ours = versions.Ours ?? "";
        var theirs = versions.Theirs ?? "";
        _baseLines = SplitLines(baseText);
        _oursLines = SplitLines(ours);
        _theirsLines = SplitLines(theirs);
        _chunks = [.. chunks.Select(c => new ChunkState(c))];

        var language = CoreApi.LanguageForPath(System.IO.Path.GetFileName(path));
        _leftEditor = new CodeEditor(ours, language, isEditable: false) { ShowVerticalScrollBar = false };
        _centerEditor = new CodeEditor(baseText, language, isEditable: true) { ShowVerticalScrollBar = false };
        _rightEditor = new CodeEditor(theirs, language, isEditable: false);

        Title = L10n.Tr("merge.window.title", path);
        ExtendsContentIntoTitleBar = true;
        WindowHelper.SetIcon(this);
        BuildLayout();
        Content = _root;
        Appearance.Register(this);
        WindowHelper.ResizeAndCenter(this, 1400, 820);
        WindowHelper.SetMinimumSize(this, 900, 480);

        foreach (var editor in new[] { _leftEditor, _centerEditor, _rightEditor })
        {
            editor.Scrolled += () => SyncScroll(editor);
            editor.Initialized += Refresh;
        }
        _centerEditor.LinesEdited += CenterEdited;
        _centerEditor.TextChanged += () => _modified = true;
        _root.ActualThemeChanged += (_, _) => Refresh();
        _leftConnector.SizeChanged += (_, _) => DrawConnectors();
        AppWindow.Closing += async (_, args) =>
        {
            if (!_modified || _closeConfirmed) return;
            args.Cancel = true;
            if (await ConfirmDialog.Show(_root.XamlRoot, L10n.Tr("merge.discard.title"), L10n.Tr("merge.discard.message"), L10n.Tr("merge.discard.confirm")))
            {
                _closeConfirmed = true;
                Close();
            }
        };
    }

    /// 编辑器加载后执行（调试：自动应用不冲突的更改）。
    public event Action? Ready;

    /// 按 `\n` 切分并保留行尾（与核心的行号规则一致，`\r\n` 中的 `\r` 留在行内）。
    public static List<string> SplitLines(string text)
    {
        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\n') continue;
            lines.Add(text[start..(i + 1)]);
            start = i + 1;
        }
        if (start < text.Length) lines.Add(text[start..]);
        return lines;
    }

    // MARK: - 布局

    private void BuildLayout()
    {
        Themed.Background(_root, "EditorBackgroundBrush");
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBarHeight) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var titleBar = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        titleBar.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = Title,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(12, 0, 140, 0),
            TextTrimming = TextTrimming.CharacterEllipsis,
        }, "PrimaryTextBrush"));
        _root.Children.Add(titleBar);
        SetTitleBar(titleBar);

        var apply = new IconButton(Icon.Wand, L10n.Tr("merge.applyNonConflicting"), 26, 14);
        apply.Click += (_, _) => ApplyNonConflicting();
        var previous = new IconButton(Icon.ArrowUp, L10n.Tr("merge.previousConflict"), 26, 13);
        previous.Click += (_, _) => Navigate(forward: false);
        var next = new IconButton(Icon.ArrowDown, L10n.Tr("merge.nextConflict"), 26, 13);
        next.Click += (_, _) => Navigate(forward: true);
        _count.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        var toolbar = new Grid { Margin = new Thickness(8, 4, 12, 4) };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { apply, previous, next } });
        Grid.SetColumn(_count, 1);
        toolbar.Children.Add(_count);
        Grid.SetRow(toolbar, 1);
        _root.Children.Add(toolbar);

        var topDivider = Themed.Background(new Border(), "SeparatorBrush");
        Grid.SetRow(topDivider, 2);
        _root.Children.Add(topDivider);

        var titles = PaneGrid();
        AddTitle(titles, 0, L10n.Tr("merge.title.side", _labels.Ours), bold: false);
        AddTitle(titles, 2, L10n.Tr("merge.title.result"), bold: true);
        AddTitle(titles, 4, L10n.Tr("merge.title.side", _labels.Theirs), bold: false);
        Grid.SetRow(titles, 3);
        _root.Children.Add(titles);

        var panes = PaneGrid();
        foreach (var (element, column) in new (FrameworkElement, int)[] { (_leftEditor, 0), (_leftConnector, 1), (_centerEditor, 2), (_rightConnector, 3), (_rightEditor, 4) })
        {
            Grid.SetColumn(element, column);
            panes.Children.Add(element);
        }
        foreach (var connector in new[] { _leftConnector, _rightConnector })
        {
            Themed.Background(connector, "EditorBackgroundBrush");
            connector.Tapped += OnConnectorTapped;
        }
        Grid.SetRow(panes, 4);
        _root.Children.Add(panes);

        var bottomDivider = Themed.Background(new Border(), "SeparatorBrush");
        Grid.SetRow(bottomDivider, 5);
        _root.Children.Add(bottomDivider);

        var acceptLeft = new Button { Content = L10n.Tr("merge.acceptSide", _labels.Ours) };
        acceptLeft.Click += (_, _) => Accept(ConflictSide.Ours);
        var acceptRight = new Button { Content = L10n.Tr("merge.acceptSide", _labels.Theirs) };
        acceptRight.Click += (_, _) => Accept(ConflictSide.Theirs);
        var applyButton = new Button { Content = L10n.Tr("merge.apply"), Style = (Style)Application.Current.Resources["AccentButtonStyle"], MinWidth = 90 };
        applyButton.Click += (_, _) => ApplyResult();
        applyButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control });
        var cancel = new Button { Content = L10n.Tr("common.cancel"), MinWidth = 90 };
        cancel.Click += (_, _) => Close();
        // Windows 的按钮顺序：确定在前、取消在后。
        var buttons = new Grid { Margin = new Thickness(12, 10, 12, 12) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { acceptLeft, acceptRight } });
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { applyButton, cancel } };
        Grid.SetColumn(right, 1);
        buttons.Children.Add(right);
        Grid.SetRow(buttons, 6);
        _root.Children.Add(buttons);
    }

    private static Grid PaneGrid()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ConnectorWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ConnectorWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        return grid;
    }

    private static void AddTitle(Grid grid, int column, string text, bool bold)
    {
        var title = new TextBlock
        {
            Text = text,
            Margin = new Thickness(10, 6, 10, 6),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        if (bold)
        {
            title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            Themed.Foreground(title, "PrimaryTextBrush");
        }
        else
        {
            title.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        }
        Grid.SetColumn(title, column);
        grid.Children.Add(title);
    }

    // MARK: - 应用与忽略

    private void Apply(int index, Side side)
    {
        var state = _chunks[index];
        if (!state.CanAct(side)) return;
        var c = state.Chunk;
        var lines = side == Side.Left
            ? Slice(_oursLines, c.OursStart, c.OursCount)
            : Slice(_theirsLines, c.TheirsStart, c.TheirsCount);
        // 冲突块另一侧已应用时，本侧追加在其后，保留双方内容。
        var otherApplied = side == Side.Left ? state.RightApplied : state.LeftApplied;
        var append = c.Kind == MergeChunkKind.Conflict && otherApplied;
        _applying = true;
        if (append) _centerEditor.ReplaceLines(state.ResultStart + state.ResultCount, 0, string.Concat(lines));
        else _centerEditor.ReplaceLines(state.ResultStart, state.ResultCount, string.Concat(lines));
        _applying = false;

        var newCount = append ? state.ResultCount + lines.Count : lines.Count;
        var delta = newCount - state.ResultCount;
        state.ResultCount = newCount;
        foreach (var later in _chunks.Skip(index + 1)) later.ResultStart += delta;
        if (side == Side.Left) state.LeftApplied = true;
        else state.RightApplied = true;
        _modified = true;
        Refresh();
    }

    private void Ignore(int index, Side side)
    {
        var state = _chunks[index];
        if (!state.CanAct(side)) return;
        if (side == Side.Left) state.LeftIgnored = true;
        else state.RightIgnored = true;
        Refresh();
    }

    /// IDEA 的 “Apply All Non-Conflicting Changes”（魔术棒按钮）。
    public void ApplyNonConflicting()
    {
        for (var index = 0; index < _chunks.Count; index++)
        {
            var state = _chunks[index];
            if (state.IsResolved || state.Chunk.Kind == MergeChunkKind.Conflict) continue;
            Apply(index, state.Chunk.Kind == MergeChunkKind.Theirs ? Side.Right : Side.Left);
        }
    }

    /// 仅调试：在结果栏执行一次撤销。
    public void DebugUndo() => _centerEditor.Undo();

    /// 仅调试：冲突块依次应用两侧（先左后右），然后写入结果。
    public void DebugResolve()
    {
        for (var index = 0; index < _chunks.Count; index++)
        {
            if (_chunks[index].Chunk.Kind != MergeChunkKind.Conflict) continue;
            Apply(index, Side.Left);
            Apply(index, Side.Right);
        }
        var content = _centerEditor.Text;
        Run((repository, path) => repository.ResolveConflict(path, content));
    }

    private static List<string> Slice(List<string> lines, uint start, uint count)
    {
        var lower = Math.Min((int)start, lines.Count);
        return lines.GetRange(lower, Math.Min((int)count, lines.Count - lower));
    }

    // MARK: - 跟踪结果栏中的手动编辑

    /// 结果栏的文本变化（手动编辑、撤销 / 重做）：调整各块的位置与行数。
    private void CenterEdited(int startLine, int linesAdded)
    {
        if (_applying) return;
        var endLine = startLine + Math.Max(0, -linesAdded);
        foreach (var state in _chunks)
        {
            var end = state.ResultStart + state.ResultCount;
            if (state.ResultStart > endLine)
            {
                state.ResultStart += linesAdded;
            }
            else if (end > startLine || (state.ResultCount == 0 && state.ResultStart >= startLine))
            {
                // 编辑落在块内：块随之伸缩，保持未解决状态。
                state.ResultCount = Math.Max(0, state.ResultCount + linesAdded);
            }
        }
        ReconcileAppliedState();
        Refresh();
    }

    /// 撤销 / 重做会改变结果栏中块的内容：按块的当前内容重新判断哪一侧已应用，
    /// 使撤销 “应用” 后该块恢复为未处理（可再次应用），重做后重新标记为已应用。
    private void ReconcileAppliedState()
    {
        var result = SplitLines(_centerEditor.Text);
        foreach (var state in _chunks)
        {
            if (state.ResultStart + state.ResultCount > result.Count) continue;
            var c = state.Chunk;
            var current = result.GetRange(state.ResultStart, state.ResultCount);
            var baseLines = Slice(_baseLines, c.BaseStart, c.BaseCount);
            var ours = Slice(_oursLines, c.OursStart, c.OursCount);
            var theirs = Slice(_theirsLines, c.TheirsStart, c.TheirsCount);
            if (current.SequenceEqual(baseLines))
            {
                state.LeftApplied = false;
                state.RightApplied = false;
            }
            else if (c.Kind != MergeChunkKind.Theirs && current.SequenceEqual(ours))
            {
                state.LeftApplied = true;
                state.RightApplied = false;
            }
            else if (c.Kind != MergeChunkKind.Ours && current.SequenceEqual(theirs))
            {
                state.LeftApplied = false;
                state.RightApplied = true;
            }
            else if (c.Kind == MergeChunkKind.Conflict && (current.SequenceEqual(ours.Concat(theirs)) || current.SequenceEqual(theirs.Concat(ours))))
            {
                state.LeftApplied = true;
                state.RightApplied = true;
            }
            // 其他（手动编辑过的内容）：保持原状态。
        }
    }

    // MARK: - 刷新显示

    private void Refresh()
    {
        var left = new List<CodeEditor.DiffLine>();
        var center = new List<CodeEditor.DiffLine>();
        var right = new List<CodeEditor.DiffLine>();
        foreach (var state in _chunks.Where(s => !s.IsResolved))
        {
            var c = state.Chunk;
            var conflict = c.Kind == MergeChunkKind.Conflict;
            if (state.CanAct(Side.Left)) AddLines(left, (int)c.OursStart, (int)c.OursCount, Kind(c.BaseCount, c.OursCount), conflict);
            if (state.CanAct(Side.Right)) AddLines(right, (int)c.TheirsStart, (int)c.TheirsCount, Kind(c.BaseCount, c.TheirsCount), conflict);
            var sideCount = c.Kind == MergeChunkKind.Theirs ? c.TheirsCount : c.OursCount;
            AddLines(center, state.ResultStart, state.ResultCount, Kind(c.BaseCount, sideCount), conflict);
        }
        _leftEditor.SetDiffDecorations(left, []);
        _centerEditor.SetDiffDecorations(center, []);
        _rightEditor.SetDiffDecorations(right, []);

        var unresolved = _chunks.Where(s => !s.IsResolved).ToList();
        var conflicts = unresolved.Count(s => s.Chunk.Kind == MergeChunkKind.Conflict);
        _count.Text = unresolved.Count == 0
            ? L10n.Tr("merge.allResolved")
            : L10n.Tr("merge.count", unresolved.Count, conflicts);
        DrawConnectors();
    }

    /// 块的行：有内容时逐行着色；行数为 0 时在插入位置上方一行画分隔线。
    private static void AddLines(List<CodeEditor.DiffLine> lines, int start, int count, LineChangeKind kind, bool conflict)
    {
        if (count == 0)
        {
            if (start > 0) lines.Add(new CodeEditor.DiffLine(start - 1, kind, Separator: true, Conflict: conflict));
            return;
        }
        for (var line = start; line < start + count; line++) lines.Add(new CodeEditor.DiffLine(line, kind, Conflict: conflict));
    }

    /// 非冲突块按该侧相对基准的变化着色：新增、删除或修改。
    private static LineChangeKind Kind(uint baseCount, uint sideCount) =>
        baseCount == 0 ? LineChangeKind.Added : sideCount == 0 ? LineChangeKind.Deleted : LineChangeKind.Modified;

    // MARK: - 连接带

    private void DrawConnectors()
    {
        _buttons.Clear();
        DrawConnector(_leftConnector, Side.Left, _leftEditor);
        DrawConnector(_rightConnector, Side.Right, _rightEditor);
    }

    /// 外侧编辑器与结果栏之间的连接带：曲线色带连接对应的块，外侧一端带应用（» / «）与忽略（×）按钮。
    private void DrawConnector(Canvas canvas, Side side, CodeEditor outer)
    {
        canvas.Children.Clear();
        var height = canvas.ActualHeight;
        if (height <= 0) return;
        var dark = _root.ActualTheme == ElementTheme.Dark;
        const double w = ConnectorWidth;
        for (var index = 0; index < _chunks.Count; index++)
        {
            var state = _chunks[index];
            if (!state.CanAct(side)) continue;
            var c = state.Chunk;
            var (start, count) = side == Side.Left ? (c.OursStart, c.OursCount) : (c.TheirsStart, c.TheirsCount);
            var (oTop, oBottom) = Span(outer, (int)start, (int)count);
            var (cTop, cBottom) = Span(_centerEditor, state.ResultStart, state.ResultCount);
            if (Math.Max(oBottom, cBottom) < 0 || Math.Min(oTop, cTop) > height) continue;

            // 外侧在左时色带从左（外侧）连到右（结果），反之亦然。
            var (x0, x1) = side == Side.Left ? (0.0, w) : (w, 0.0);
            var figure = new PathFigure { StartPoint = new Point(x0, oTop), IsClosed = true };
            figure.Segments.Add(new BezierSegment { Point1 = new Point(w / 2, oTop), Point2 = new Point(w / 2, cTop), Point3 = new Point(x1, cTop) });
            figure.Segments.Add(new LineSegment { Point = new Point(x1, cBottom) });
            figure.Segments.Add(new BezierSegment { Point1 = new Point(w / 2, cBottom), Point2 = new Point(w / 2, oBottom), Point3 = new Point(x0, oBottom) });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            var conflict = c.Kind == MergeChunkKind.Conflict;
            var kind = Kind(c.BaseCount, count);
            canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = geometry,
                Fill = new SolidColorBrush(conflict ? DiffColors.ConflictBlock(dark) : DiffColors.Block(kind, dark)),
                Stroke = new SolidColorBrush(conflict ? DiffColors.ConflictMarker(dark) : DiffColors.Marker(kind, dark)),
                StrokeThickness = 1,
            });

            const double size = 16;
            var y = Math.Max(2, Math.Min(oTop + 2, height - size - 2));
            var applyX = side == Side.Left ? 2 : w - size - 2;
            var ignoreX = side == Side.Left ? applyX + size + 2 : applyX - size - 2;
            var applyBox = new Rect(applyX, y, size, size);
            var ignoreBox = new Rect(ignoreX, y, size, size);
            AddButton(canvas, applyBox, side == Side.Left ? Icon.ChevronsRight : Icon.ChevronsLeft, new SolidColorBrush(DiffColors.Accent), dark);
            AddButton(canvas, ignoreBox, Icon.Close, Icons.ThemeBrush(_root, "SecondaryTextBrush"), dark);
            _buttons.Add((side, index, true, applyBox));
            _buttons.Add((side, index, false, ignoreBox));
        }
    }

    private static void AddButton(Canvas canvas, Rect box, Icon icon, Brush brush, bool dark)
    {
        var background = SyntaxTheme.Background(dark);
        var border = new Border
        {
            Width = box.Width,
            Height = box.Height,
            CornerRadius = new CornerRadius(3),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(217, background.R, background.G, background.B)),
            Child = Icons.Create(icon, 12, brush),
        };
        Canvas.SetLeft(border, box.X);
        Canvas.SetTop(border, box.Y);
        canvas.Children.Add(border);
    }

    private void OnConnectorTapped(object sender, TappedRoutedEventArgs e)
    {
        var side = ReferenceEquals(sender, _leftConnector) ? Side.Left : Side.Right;
        var point = e.GetPosition((UIElement)sender);
        foreach (var (buttonSide, index, apply, box) in _buttons)
        {
            if (buttonSide != side) continue;
            if (point.X >= box.X - 2 && point.X <= box.Right + 2 && point.Y >= box.Y - 2 && point.Y <= box.Bottom + 2)
            {
                if (apply) Apply(index, side);
                else Ignore(index, side);
                return;
            }
        }
    }

    /// 块在编辑器可见区域中的上下边界（相对连接带顶部）。
    private static (double Top, double Bottom) Span(CodeEditor editor, int start, int count)
    {
        var offset = editor.TextAreaTop;
        var top = editor.LineTop(start) + offset;
        if (count == 0) return (top, top);
        return (top, editor.LineTop(start + count) + offset);
    }

    // MARK: - 跳转与同步滚动

    private void Navigate(bool forward)
    {
        var unresolved = _chunks.Where(s => !s.IsResolved).ToList();
        if (unresolved.Count == 0) return;
        var caret = _centerEditor.CaretLine;
        var target = forward
            ? unresolved.FirstOrDefault(s => s.ResultStart > caret) ?? unresolved[0]
            : unresolved.LastOrDefault(s => s.ResultStart < caret) ?? unresolved[^1];
        _centerEditor.Reveal(target.ResultStart);
        _centerEditor.Focus();
        SyncScroll(_centerEditor);
    }

    /// 结果栏到某一侧的行对应关系（包括已解决的块，保证对齐）。
    private List<(double FromStart, double FromCount, double ToStart, double ToCount)> Segments(Side side, bool reversed) =>
        [.. _chunks.Select(state =>
        {
            var c = state.Chunk;
            var (start, count) = side == Side.Left ? (c.OursStart, c.OursCount) : (c.TheirsStart, c.TheirsCount);
            return reversed
                ? ((double)start, (double)count, (double)state.ResultStart, (double)state.ResultCount)
                : ((double)state.ResultStart, (double)state.ResultCount, (double)start, (double)count);
        })];

    /// 按块的对应关系换算行号：块内按比例映射，块外按前面各块的行数差平移。
    private static double MapLine(double line, List<(double FromStart, double FromCount, double ToStart, double ToCount)> segments)
    {
        var delta = 0.0;
        foreach (var (fromStart, fromCount, toStart, toCount) in segments)
        {
            if (line < fromStart) break;
            if (line < fromStart + fromCount) return toStart + (line - fromStart) / fromCount * toCount;
            delta = toStart + toCount - (fromStart + fromCount);
        }
        return line + delta;
    }

    private void SyncScroll(CodeEditor source)
    {
        if (_syncing) return;
        _syncing = true;
        try
        {
            double centerLine;
            if (source == _centerEditor)
            {
                centerLine = _centerEditor.FirstVisibleLine;
            }
            else
            {
                centerLine = MapLine(source.FirstVisibleLine, Segments(source == _leftEditor ? Side.Left : Side.Right, reversed: true));
                _centerEditor.FirstVisibleLine = (int)Math.Round(centerLine);
            }
            if (source != _leftEditor) _leftEditor.FirstVisibleLine = (int)Math.Round(MapLine(centerLine, Segments(Side.Left, reversed: false)));
            if (source != _rightEditor) _rightEditor.FirstVisibleLine = (int)Math.Round(MapLine(centerLine, Segments(Side.Right, reversed: false)));
        }
        finally
        {
            _syncing = false;
        }
        DrawConnectors();
    }

    // MARK: - 完成

    private async void ApplyResult()
    {
        var unresolved = _chunks.Count(s => !s.IsResolved);
        if (unresolved > 0 && !await ConfirmDialog.Show(_root.XamlRoot, L10n.Tr("merge.unresolved.title"),
                L10n.Tr("merge.unresolved.message", unresolved), L10n.Tr("merge.apply")))
        {
            return;
        }
        var content = _centerEditor.Text;
        Run((repository, path) => repository.ResolveConflict(path, content));
    }

    private void Accept(ConflictSide side) => Run((repository, path) => repository.AcceptConflictSide(path, side));

    private void Run(Action<Repository, string> work)
    {
        if (_saving) return;
        _saving = true;
        var repository = _model.Repository;
        var path = _path;
        Task.Run(() => work(repository, path)).ContinueWith(task => DispatcherQueue.TryEnqueue(async () =>
        {
            _saving = false;
            if (task.Exception?.InnerException is { } error)
            {
                await Dialogs.ShowMessage(_root.XamlRoot, L10n.Tr("conflicts.failed"), L10n.Message(error));
                return;
            }
            _closeConfirmed = true;
            _model.Post(L10n.Tr("merge.resolved", path));
            _model.Refresh();
            Close();
        }), TaskScheduler.Default);
    }

    /// 编辑器加载完成后通知一次（调试参数在此之后执行）。
    public void NotifyWhenReady()
    {
        var pending = 3;
        foreach (var editor in new[] { _leftEditor, _centerEditor, _rightEditor })
        {
            editor.Initialized += () =>
            {
                if (--pending == 0) Ready?.Invoke();
            };
        }
    }
}
