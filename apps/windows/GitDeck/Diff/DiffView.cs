using GitDeck.Common;
using GitDeck.Controls;
using GitDeck.Core;
using GitDeck.Editor;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace GitDeck.Diff;

/// 一侧的内容。`Text` 为 null 表示该版本中文件不存在。
public sealed record DiffSide(string Title, string? Text);

/// 跳转到源码的目标：工作区中的文件（完整路径），以及右侧是否就是工作区版本（否则跳转时把行号映射到当前文件）。
public sealed record DiffSource(string FullPath, bool RightIsWorkingTree);

/// 本地改动的 Diff 可以选择要提交的改动块 / 行（部分提交）。
public sealed record DiffInclusion(LineSelectionStore Store, string Path);

/// Diff 视图（IDEA 的 Diff viewer，与 mac 端 DiffView 一致）：并排模式左侧为基准版本、右侧为新版本；
/// 统一模式在一栏中依次显示删除与新增的行。
///
/// 打开本地改动时（`inclusion` 非空）可以勾选要提交的改动：并排模式中间连接带上的复选框按块切换，
/// 点击行号按行切换；不提交的行以浅色显示。
public sealed class DiffView : Grid
{
    private const double ConnectorWidth = 36;
    private const string UnifiedKey = "diff.unified";

    private static readonly (WhitespaceMode Mode, string Key)[] WhitespaceModes =
    [
        (WhitespaceMode.Compare, "diff.whitespace.compare"),
        (WhitespaceMode.Trim, "diff.whitespace.trim"),
        (WhitespaceMode.Ignore, "diff.whitespace.ignore"),
    ];

    private readonly DiffSide _left;
    private readonly DiffSide _right;
    private readonly string? _language;
    private readonly DiffInclusion? _inclusion;
    private readonly CodeEditor _leftEditor;
    private readonly CodeEditor _rightEditor;
    private readonly Canvas _connector = new();
    private readonly Grid _sideBySide = new();
    private readonly Grid _unifiedContainer = new();
    private readonly TextBlock _leftTitle = new();
    private readonly TextBlock _rightTitle = new();
    private readonly TextBlock _count = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ComboBox _viewer = new() { MinWidth = 0 };
    private readonly ComboBox _whitespace = new() { MinWidth = 0 };
    private CodeEditor? _unifiedEditor;
    private CodeEditor? _focusedEditor;
    private readonly IconButton _jumpToSource = new(Icon.Edit, L10n.Tr("diff.jumpToSource"), 26, 13);
    private UnifiedModel _unified = UnifiedModel.Empty;
    private IReadOnlyList<DiffBlock> _blocks = [];
    private int? _currentBlock;
    private bool _syncing;
    private int _computation;

    public DiffView(DiffSide left, DiffSide right, string path, DiffInclusion? inclusion = null)
    {
        _left = left;
        _right = right;
        _inclusion = inclusion;
        _language = CoreApi.LanguageForPath(System.IO.Path.GetFileName(path));
        _leftEditor = new CodeEditor(left.Text ?? "", _language, isEditable: false) { ShowVerticalScrollBar = false };
        _rightEditor = new CodeEditor(right.Text ?? "", _language, isEditable: false);
        Themed.Background(this, "EditorBackgroundBrush");
        BuildLayout();

        _leftEditor.GotFocus += (_, _) => _focusedEditor = _leftEditor;
        _rightEditor.GotFocus += (_, _) => _focusedEditor = _rightEditor;
        // F4：跳转到源码（IDEA 的 Jump to Source）。
        AddHandler(KeyDownEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler((_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.F4 || Source is null) return;
            JumpToSource();
            e.Handled = true;
        }), true);
        _leftEditor.Scrolled += () => SyncScroll(_leftEditor);
        _rightEditor.Scrolled += () => SyncScroll(_rightEditor);
        _leftEditor.SizeChanged += (_, _) => DrawConnector();
        _leftEditor.Initialized += DrawConnector;
        _rightEditor.Initialized += DrawConnector;
        _connector.SizeChanged += (_, _) => DrawConnector();
        ActualThemeChanged += (_, _) =>
        {
            DrawConnector();
            UpdateDecorations();
        };
        if (inclusion is not null)
        {
            inclusion.Store.Changed += SelectionChanged;
            Unloaded += (_, _) => inclusion.Store.Changed -= SelectionChanged;
            _rightEditor.LineNumberClicked += line => ToggleLine(newLine: (uint)line);
            _leftEditor.LineNumberClicked += line => ToggleLine(baseLine: (uint)line);
        }

        if (IsBinary)
        {
            _sideBySide.Visibility = Visibility.Collapsed;
            _viewer.IsEnabled = false;
            _count.Text = L10n.Tr("diff.binary");
        }
        else
        {
            ApplyViewer();
            Recompute();
        }
    }

    private bool IsBinary => (_left.Text?.Contains('\0') ?? false) || (_right.Text?.Contains('\0') ?? false);

    private bool IsUnified => _viewer.SelectedIndex == 1;

    private WhitespaceMode Whitespace => WhitespaceModes[Math.Max(0, _whitespace.SelectedIndex)].Mode;

    /// 跳转到源码的目标；为 null 时不显示铅笔按钮（例如 AI 建议的预览）。
    public DiffSource? Source
    {
        get => _source;
        set
        {
            _source = value;
            UpdateJumpToSource();
        }
    }

    private DiffSource? _source;

    /// 请求在编辑器中打开文件：完整路径与行（从 0 开始）。
    public event Action<string, int>? JumpToSourceRequested;

    /// 读取文件当前的内容（编辑器中未保存的内容优先）；右侧不是工作区版本时用于映射行号。
    public Func<string, string?>? CurrentText { get; set; }

    private void UpdateJumpToSource()
    {
        _jumpToSource.Visibility = _source is null ? Visibility.Collapsed : Visibility.Visible;
        // 文件在工作区中已不存在（例如已删除）时不能跳转。
        _jumpToSource.IsEnabled = _source is { } source && File.Exists(source.FullPath);
    }

    /// 跳转到源码：取最近获得焦点的一侧的光标行，换算为新版本中的行；右侧不是工作区版本时再映射到当前文件。
    public void JumpToSource()
    {
        if (_source is not { } source || !File.Exists(source.FullPath)) return;
        var line = NewSideLine();
        if (!source.RightIsWorkingTree && _right.Text is { } rightText && (CurrentText?.Invoke(source.FullPath) ?? ReadFile(source.FullPath)) is { } current)
        {
            line = MapLine(CoreApi.LineChanges(rightText, current), line, fromBase: true);
        }
        JumpToSourceRequested?.Invoke(source.FullPath, Math.Max(0, line));
    }

    private int NewSideLine()
    {
        if (IsUnified && _unifiedEditor is not null)
        {
            var row = _unifiedEditor.CaretLine;
            var rows = _unified.Rows;
            // 删除的行在新版本中没有对应：取其后第一个有新版本行号的行。
            for (var i = Math.Min(row, rows.Count - 1); i >= 0 && i < rows.Count; i++)
            {
                if (rows[i].New is { } n) return n;
            }
            return _unified.MaxNew > 0 ? _unified.MaxNew - 1 : 0;
        }
        if (_focusedEditor == _leftEditor) return MapLine(_blocks.Select(b => b.Change), _leftEditor.CaretLine, fromBase: true);
        return _rightEditor.CaretLine;
    }

    /// 按行变更把一侧的行换算到另一侧：变更段之前按偏移平移，落在变更段内时取对应段的起始行（与 IDEA 一致）。
    public static int MapLine(IEnumerable<LineChange> changes, int line, bool fromBase)
    {
        var delta = 0;
        foreach (var c in changes)
        {
            var (fromStart, fromCount, toStart, toCount) = fromBase
                ? ((int)c.BaseStart, (int)c.BaseCount, (int)c.Start, (int)c.Count)
                : ((int)c.Start, (int)c.Count, (int)c.BaseStart, (int)c.BaseCount);
            if (line < fromStart) break;
            if (line < fromStart + fromCount) return toStart + Math.Min(line - fromStart, Math.Max(0, toCount - 1));
            delta = toStart + toCount - (fromStart + fromCount);
        }
        return line + delta;
    }

    private static string? ReadFile(string path)
    {
        try
        {
            return System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// 可以勾选要提交的改动（只在逐字比较空白时，块与提交内容一致）。
    private bool IsSelectable => _inclusion is not null && Whitespace == WhitespaceMode.Compare;

    /// 把新版本一侧的第 `line` 行（从 0 开始）滚动到视口中。
    public void Reveal(int line)
    {
        if (IsUnified && _unifiedEditor is not null) _unifiedEditor.Reveal(_unified.RowForNewLine(line));
        else _rightEditor.Reveal(line);
    }

    // MARK: - 布局

    private void BuildLayout()
    {
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var previous = new IconButton(Icon.ArrowUp, L10n.Tr("diff.previous"), 26, 13);
        previous.Click += (_, _) => PreviousDifference();
        var next = new IconButton(Icon.ArrowDown, L10n.Tr("diff.next"), 26, 13);
        next.Click += (_, _) => NextDifference();
        _jumpToSource.Click += (_, _) => JumpToSource();
        UpdateJumpToSource();
        _viewer.Items.Add(L10n.Tr("diff.viewer.sideBySide"));
        _viewer.Items.Add(L10n.Tr("diff.viewer.unified"));
        _viewer.SelectedIndex = Settings.GetBool(UnifiedKey) ? 1 : 0;
        _viewer.SelectionChanged += (_, _) =>
        {
            Settings.Set(UnifiedKey, IsUnified);
            ApplyViewer();
            RebuildUnified();
        };
        foreach (var (_, key) in WhitespaceModes) _whitespace.Items.Add(L10n.Tr(key));
        _whitespace.SelectedIndex = 0;
        _whitespace.SelectionChanged += (_, _) => Recompute();
        _count.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];

        var toolbar = new Grid { Margin = new Thickness(8, 4, 12, 4), ColumnSpacing = 4 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { previous, next, _jumpToSource, _viewer, _whitespace } });
        SetColumn(_count, 2);
        toolbar.Children.Add(_count);
        Children.Add(toolbar);

        var topDivider = Themed.Background(new Border(), "SeparatorBrush");
        SetRow(topDivider, 1);
        Children.Add(topDivider);

        foreach (var title in new[] { _leftTitle, _rightTitle })
        {
            title.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
            title.Margin = new Thickness(10, 6, 10, 6);
            title.TextTrimming = TextTrimming.CharacterEllipsis;
        }
        _leftTitle.Text = Title(_left);
        _rightTitle.Text = Title(_right);
        var titles = new Grid();
        titles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ConnectorWidth) });
        titles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        SetColumn(_rightTitle, 2);
        titles.Children.Add(_leftTitle);
        titles.Children.Add(_rightTitle);
        SetRow(titles, 2);
        Children.Add(titles);

        var titleDivider = Themed.Background(new Border(), "SeparatorBrush");
        SetRow(titleDivider, 3);
        Children.Add(titleDivider);

        _sideBySide.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _sideBySide.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ConnectorWidth) });
        _sideBySide.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Themed.Background(_connector, "EditorBackgroundBrush");
        _connector.Tapped += OnConnectorTapped;
        SetColumn(_connector, 1);
        SetColumn(_rightEditor, 2);
        _sideBySide.Children.Add(_leftEditor);
        _sideBySide.Children.Add(_connector);
        _sideBySide.Children.Add(_rightEditor);
        SetRow(_sideBySide, 4);
        SetRow(_unifiedContainer, 4);
        Children.Add(_sideBySide);
        Children.Add(_unifiedContainer);
    }

    private static string Title(DiffSide side) => side.Text is null ? L10n.Tr("diff.title.missing", side.Title) : side.Title;

    private void ApplyViewer()
    {
        var unified = IsUnified;
        _sideBySide.Visibility = unified || IsBinary ? Visibility.Collapsed : Visibility.Visible;
        _unifiedContainer.Visibility = unified && !IsBinary ? Visibility.Visible : Visibility.Collapsed;
        _rightTitle.Visibility = unified ? Visibility.Collapsed : Visibility.Visible;
        _leftTitle.Text = unified ? $"{Title(_left)}  →  {Title(_right)}" : Title(_left);
        SetColumnSpan(_leftTitle, unified ? 3 : 1);
    }

    // MARK: - 计算差异

    private void Recompute()
    {
        var baseText = _left.Text ?? "";
        var text = _right.Text ?? "";
        var mode = Whitespace;
        var token = ++_computation;
        Task.Run(() => CoreApi.DiffTexts(baseText, text, mode)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _computation || task.IsFaulted) return;
            _blocks = task.Result;
            _currentBlock = null;
            RebuildUnified();
            SelectionChanged();
            if (DebugOptions.Get("debug.excludeBlock") is { } raw && int.TryParse(raw, out var index)
                && index < _blocks.Count && BlockState(index) == true)
            {
                ToggleBlock(index);
            }
        }), TaskScheduler.Default);
    }

    private void UpdateCountLabel()
    {
        if (IsBinary) return;
        if (_blocks.Count == 0)
        {
            _count.Text = L10n.Tr("diff.identical");
            return;
        }
        var text = _blocks.Count == 1 ? L10n.Tr("diff.count.one") : L10n.Tr("diff.count", _blocks.Count);
        if (IsSelectable && CurrentSelection is { IsEmpty: false })
        {
            var included = Enumerable.Range(0, _blocks.Count).Count(i => BlockState(i) != false);
            text = L10n.Tr("diff.included", included, _blocks.Count);
        }
        _count.Text = text;
    }

    // MARK: - 装饰

    private void UpdateDecorations()
    {
        var selection = IsSelectable ? EditableSelection : null;
        var leftLines = new List<CodeEditor.DiffLine>();
        var rightLines = new List<CodeEditor.DiffLine>();
        var leftInline = new List<CodeEditor.DiffInline>();
        var rightInline = new List<CodeEditor.DiffInline>();
        foreach (var block in _blocks)
        {
            var c = block.Change;
            AddSide(leftLines, c.BaseStart, c.BaseCount, c.Kind, line => selection?.ExcludedBaseLines.Contains(line) ?? false);
            AddSide(rightLines, c.Start, c.Count, c.Kind, line => selection?.ExcludedLines.Contains(line) ?? false);
            leftInline.AddRange(block.BaseInline.Select(r => new CodeEditor.DiffInline(r.Start, r.End, c.Kind)));
            rightInline.AddRange(block.Inline.Select(r => new CodeEditor.DiffInline(r.Start, r.End, c.Kind)));
        }
        _leftEditor.SetDiffDecorations(leftLines, leftInline);
        _rightEditor.SetDiffDecorations(rightLines, rightInline);
        if (_unifiedEditor is not null)
        {
            var rows = new List<CodeEditor.DiffLine>();
            for (var i = 0; i < _unified.Rows.Count; i++)
            {
                var row = _unified.Rows[i];
                if (row.Kind == UnifiedModel.RowKind.Context) continue;
                var excluded = row.Kind == UnifiedModel.RowKind.Added
                    ? row.New is { } n && (selection?.ExcludedLines.Contains((uint)n) ?? false)
                    : row.Old is { } o && (selection?.ExcludedBaseLines.Contains((uint)o) ?? false);
                rows.Add(new CodeEditor.DiffLine(i, row.Kind == UnifiedModel.RowKind.Added ? LineChangeKind.Added : LineChangeKind.Deleted, excluded));
            }
            _unifiedEditor.SetDiffDecorations(rows, []);
        }
        DrawConnector();
    }

    /// 一侧的块：有内容时逐行着色；本侧没有内容时在插入位置上方一行画分隔线。
    private static void AddSide(List<CodeEditor.DiffLine> lines, uint start, uint count, LineChangeKind kind, Func<uint, bool> excluded)
    {
        if (count == 0)
        {
            if (start > 0) lines.Add(new CodeEditor.DiffLine((int)start - 1, kind, Separator: true));
            return;
        }
        for (var line = start; line < start + count; line++) lines.Add(new CodeEditor.DiffLine((int)line, kind, excluded(line)));
    }

    // MARK: - 连接带

    private readonly List<(int Index, Rect Box)> _checkboxes = [];

    /// 两侧编辑器之间的连接带：把左右对应的变更块用曲线色带连起来（IDEA 的 diff divider）。
    /// 可部分提交时在每个块上画复选框，点击切换整块是否提交。
    private void DrawConnector()
    {
        _connector.Children.Clear();
        _checkboxes.Clear();
        if (IsUnified || _blocks.Count == 0 || _connector.ActualHeight <= 0) return;
        var dark = ActualTheme == ElementTheme.Dark;
        var width = ConnectorWidth;
        var height = _connector.ActualHeight;
        var leftOffset = _leftEditor.TextAreaTop;
        var rightOffset = _rightEditor.TextAreaTop;
        for (var index = 0; index < _blocks.Count; index++)
        {
            var c = _blocks[index].Change;
            var (lTop, lBottom) = Span(_leftEditor, c.BaseStart, c.BaseCount, leftOffset);
            var (rTop, rBottom) = Span(_rightEditor, c.Start, c.Count, rightOffset);
            if (Math.Max(lBottom, rBottom) < 0 || Math.Min(lTop, rTop) > height) continue;
            var state = IsSelectable ? BlockState(index) : true;
            var fill = DiffColors.Block(c.Kind, dark);
            if (state == false) fill = DiffColors.Blend(fill, SyntaxTheme.Background(dark), 0.3);
            var figure = new PathFigure { StartPoint = new Point(0, lTop), IsClosed = true };
            figure.Segments.Add(new BezierSegment { Point1 = new Point(width / 2, lTop), Point2 = new Point(width / 2, rTop), Point3 = new Point(width, rTop) });
            figure.Segments.Add(new LineSegment { Point = new Point(width, rBottom) });
            figure.Segments.Add(new BezierSegment { Point1 = new Point(width / 2, rBottom), Point2 = new Point(width / 2, lBottom), Point3 = new Point(0, lBottom) });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            _connector.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = geometry,
                Fill = new SolidColorBrush(fill),
                Stroke = new SolidColorBrush(DiffColors.Marker(c.Kind, dark)),
                StrokeThickness = 1,
            });
            if (IsSelectable)
            {
                const double size = 14;
                var box = new Rect((width - size) / 2, (lTop + rTop) / 2 + 2, size, size);
                DrawCheckbox(box, state, c.Kind, dark);
                _checkboxes.Add((index, box));
            }
        }
    }

    private void DrawCheckbox(Rect rect, bool? state, LineChangeKind kind, bool dark)
    {
        var border = new Border
        {
            Width = rect.Width,
            Height = rect.Height,
            CornerRadius = new CornerRadius(3),
            BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(state == false ? SyntaxTheme.Background(dark) : DiffColors.Accent),
            BorderBrush = new SolidColorBrush(state == false ? DiffColors.Marker(kind, dark) : DiffColors.Accent),
        };
        if (state != false)
        {
            var mark = state == true ? "M3,7 L5.6,9.6 L11,4" : "M3.5,7 L10.5,7";
            border.Child = new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = (Geometry)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(typeof(Geometry), mark),
                Stroke = new SolidColorBrush(Microsoft.UI.Colors.White),
                StrokeThickness = 1.8,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
                Margin = new Thickness(-1),
            };
        }
        Canvas.SetLeft(border, rect.X);
        Canvas.SetTop(border, rect.Y);
        _connector.Children.Add(border);
    }

    private void OnConnectorTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        var point = e.GetPosition(_connector);
        foreach (var (index, box) in _checkboxes)
        {
            if (point.X >= box.X - 3 && point.X <= box.Right + 3 && point.Y >= box.Y - 3 && point.Y <= box.Bottom + 3)
            {
                ToggleBlock(index);
                return;
            }
        }
    }

    /// 变更块在编辑器可见区域中的上下边界（相对连接带顶部）。
    private static (double Top, double Bottom) Span(CodeEditor editor, uint start, uint count, double offset)
    {
        var top = editor.LineTop((int)start) + offset;
        if (count == 0) return (top, top);
        return (top, editor.LineTop((int)(start + count)) + offset);
    }

    // MARK: - 统一视图

    private void RebuildUnified()
    {
        if (!IsUnified || IsBinary)
        {
            UpdateDecorations();
            return;
        }
        _unified = UnifiedModel.Build(_left.Text ?? "", _right.Text ?? "", _blocks);
        _unifiedContainer.Children.Clear();
        var editor = new CodeEditor(_unified.Text, _language, isEditable: false);
        var model = _unified;
        var width = Math.Max(model.MaxOld, model.MaxNew).ToString(System.Globalization.CultureInfo.InvariantCulture).Length;
        editor.SetLineNumbers(width * 2 + 1, row =>
        {
            if (row >= model.Rows.Count) return null;
            var r = model.Rows[row];
            var old = r.Old is { } o ? (o + 1).ToString(System.Globalization.CultureInfo.InvariantCulture) : "";
            var @new = r.New is { } n ? (n + 1).ToString(System.Globalization.CultureInfo.InvariantCulture) : "";
            return old.PadLeft(width) + " " + @new.PadLeft(width);
        });
        if (_inclusion is not null)
        {
            editor.LineNumberClicked += row =>
            {
                if (row >= _unified.Rows.Count) return;
                var r = _unified.Rows[row];
                if (r.Kind == UnifiedModel.RowKind.Added && r.New is { } n) ToggleLine(newLine: (uint)n);
                else if (r.Kind == UnifiedModel.RowKind.Deleted && r.Old is { } o) ToggleLine(baseLine: (uint)o);
            };
        }
        _unifiedEditor = editor;
        editor.GotFocus += (_, _) => _focusedEditor = editor;
        _unifiedContainer.Children.Add(editor);
        UpdateDecorations();
    }

    // MARK: - 部分提交

    private LineSelectionStore.Selection? CurrentSelection => _inclusion?.Store.Get(_inclusion.Path);

    /// 选择的基准与本视图的内容不同（文件已改变）时，按全部提交处理。
    private LineSelectionStore.Selection EditableSelection =>
        CurrentSelection is { } selection && selection.Base == (_left.Text ?? "") && selection.Text == (_right.Text ?? "")
            ? selection.Copy()
            : new LineSelectionStore.Selection(_left.Text ?? "", _right.Text ?? "");

    /// 块的勾选状态：true 全部提交，false 全部不提交，null 部分提交。
    private bool? BlockState(int index)
    {
        var c = _blocks[index].Change;
        var selection = CurrentSelection is { } current && current.Base == (_left.Text ?? "") && current.Text == (_right.Text ?? "") ? current : null;
        if (selection is null) return true;
        var excluded = 0;
        for (var line = c.Start; line < c.Start + c.Count; line++) if (selection.ExcludedLines.Contains(line)) excluded++;
        for (var line = c.BaseStart; line < c.BaseStart + c.BaseCount; line++) if (selection.ExcludedBaseLines.Contains(line)) excluded++;
        var total = (int)(c.Count + c.BaseCount);
        return excluded == 0 ? true : excluded == total ? false : null;
    }

    private void ToggleBlock(int index)
    {
        if (_inclusion is null || !IsSelectable || index >= _blocks.Count) return;
        var c = _blocks[index].Change;
        var selection = EditableSelection;
        var include = BlockState(index) != true;
        for (var line = c.Start; line < c.Start + c.Count; line++)
        {
            if (include) selection.ExcludedLines.Remove(line);
            else selection.ExcludedLines.Add(line);
        }
        for (var line = c.BaseStart; line < c.BaseStart + c.BaseCount; line++)
        {
            if (include) selection.ExcludedBaseLines.Remove(line);
            else selection.ExcludedBaseLines.Add(line);
        }
        _inclusion.Store.Update(_inclusion.Path, selection);
    }

    private void ToggleLine(uint? newLine = null, uint? baseLine = null)
    {
        if (_inclusion is null || !IsSelectable) return;
        var selection = EditableSelection;
        if (newLine is { } n && _blocks.Any(b => b.Change.Start <= n && n < b.Change.Start + b.Change.Count))
        {
            if (!selection.ExcludedLines.Remove(n)) selection.ExcludedLines.Add(n);
        }
        else if (baseLine is { } b && _blocks.Any(x => x.Change.BaseStart <= b && b < x.Change.BaseStart + x.Change.BaseCount))
        {
            if (!selection.ExcludedBaseLines.Remove(b)) selection.ExcludedBaseLines.Add(b);
        }
        else
        {
            return;
        }
        _inclusion.Store.Update(_inclusion.Path, selection);
    }

    private void SelectionChanged()
    {
        UpdateDecorations();
        UpdateCountLabel();
        ToolTipService.SetToolTip(_connector, IsSelectable ? L10n.Tr("diff.include.tooltip") : null);
    }

    // MARK: - 跳转（F7 / Shift+F7）

    public void NextDifference()
    {
        if (_blocks.Count == 0) return;
        Go(_currentBlock is { } current ? Math.Min(current + 1, _blocks.Count - 1) : FirstBlockBelowViewport());
    }

    public void PreviousDifference()
    {
        if (_blocks.Count == 0) return;
        Go(_currentBlock is { } current ? Math.Max(current - 1, 0) : 0);
    }

    /// 首次跳转时从当前可见区域之后的第一个差异开始。
    private int FirstBlockBelowViewport()
    {
        if (IsUnified && _unifiedEditor is not null)
        {
            var top = _unifiedEditor.FirstVisibleLine;
            var found = _unified.BlockRows.FindIndex(r => r >= top);
            return found >= 0 ? found : 0;
        }
        var first = _rightEditor.FirstVisibleLine;
        var index = _blocks.ToList().FindIndex(b => b.Change.Start >= first);
        return index >= 0 ? index : 0;
    }

    private void Go(int index)
    {
        _currentBlock = index;
        if (IsUnified && _unifiedEditor is not null && index < _unified.BlockRows.Count)
        {
            _unifiedEditor.Reveal(_unified.BlockRows[index]);
            return;
        }
        _rightEditor.Reveal((int)_blocks[index].Change.Start);
        SyncScroll(_rightEditor);
    }

    // MARK: - 同步滚动

    /// 按变更块的对应关系换算行号，让另一侧显示相同的内容位置。
    private void SyncScroll(CodeEditor source)
    {
        if (_syncing) return;
        var target = source == _leftEditor ? _rightEditor : _leftEditor;
        var fromLeft = source == _leftEditor;
        var line = (double)source.FirstVisibleLine;
        var delta = 0.0;
        var mapped = double.NaN;
        foreach (var block in _blocks)
        {
            var c = block.Change;
            var (fromStart, fromCount, toStart, toCount) = fromLeft
                ? ((double)c.BaseStart, (double)c.BaseCount, (double)c.Start, (double)c.Count)
                : ((double)c.Start, (double)c.Count, (double)c.BaseStart, (double)c.BaseCount);
            if (line < fromStart) break;
            if (line < fromStart + fromCount)
            {
                // 变更段内按比例映射。
                mapped = toStart + (line - fromStart) / fromCount * toCount;
                break;
            }
            delta = toStart + toCount - (fromStart + fromCount);
        }
        if (double.IsNaN(mapped)) mapped = line + delta;
        _syncing = true;
        target.FirstVisibleLine = (int)Math.Round(mapped);
        _syncing = false;
        DrawConnector();
    }
}

/// 统一视图的行：上下文行、删除的行（来自基准）、新增的行（来自新版本）。
public sealed class UnifiedModel
{
    public enum RowKind
    {
        Context,
        Deleted,
        Added,
    }

    public readonly record struct Row(RowKind Kind, int? Old, int? New);

    public static readonly UnifiedModel Empty = new([], "", [], 0, 0);

    private UnifiedModel(List<Row> rows, string text, List<int> blockRows, int maxOld, int maxNew)
    {
        Rows = rows;
        Text = text;
        BlockRows = blockRows;
        MaxOld = maxOld;
        MaxNew = maxNew;
    }

    public IReadOnlyList<Row> Rows { get; }

    public string Text { get; }

    /// 每个变更块在统一视图中的第一行。
    public List<int> BlockRows { get; }

    public int MaxOld { get; }

    public int MaxNew { get; }

    public static UnifiedModel Build(string baseText, string newText, IReadOnlyList<DiffBlock> blocks)
    {
        var old = Lines(baseText);
        var @new = Lines(newText);
        var rows = new List<Row>();
        var lines = new List<string>();
        var blockRows = new List<int>();
        var oldPos = 0;
        var newPos = 0;
        void Context(int oldEnd)
        {
            while (oldPos < oldEnd && oldPos < old.Count)
            {
                rows.Add(new Row(RowKind.Context, oldPos, newPos));
                lines.Add(old[oldPos]);
                oldPos++;
                newPos++;
            }
        }
        foreach (var block in blocks)
        {
            var c = block.Change;
            Context((int)c.BaseStart);
            blockRows.Add(rows.Count);
            for (var i = (int)c.BaseStart; i < c.BaseStart + c.BaseCount && i < old.Count; i++)
            {
                rows.Add(new Row(RowKind.Deleted, i, null));
                lines.Add(old[i]);
            }
            for (var j = (int)c.Start; j < c.Start + c.Count && j < @new.Count; j++)
            {
                rows.Add(new Row(RowKind.Added, null, j));
                lines.Add(@new[j]);
            }
            oldPos = (int)(c.BaseStart + c.BaseCount);
            newPos = (int)(c.Start + c.Count);
        }
        Context(old.Count);
        return new UnifiedModel(rows, string.Join("\n", lines), blockRows, old.Count, @new.Count);
    }

    /// 新版本第 `line` 行在统一视图中的行。
    public int RowForNewLine(int line)
    {
        for (var i = 0; i < Rows.Count; i++) if (Rows[i].New == line) return i;
        return 0;
    }

    private static List<string> Lines(string text)
    {
        if (text.Length == 0) return [];
        var lines = text.Split('\n').Select(l => l.EndsWith('\r') ? l[..^1] : l).ToList();
        if (text.EndsWith('\n')) lines.RemoveAt(lines.Count - 1);
        return lines;
    }
}
