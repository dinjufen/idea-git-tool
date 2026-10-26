using System.Text;
using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Diff;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using WinUIEditor;

namespace GitDeck.Editor;

/// 代码编辑器：WinUIEdit（Scintilla）文本视图 + 行号与变更标记 gutter + 语法高亮 + 查找栏。
///
/// 与 mac 端 CodeEditorView 一致：只使用组件的文本视图，配色、行号、变更标记、高亮（Rust tree-sitter）、查找都自建。
/// Scintilla 内部以 UTF-8 字节编址，核心的高亮区间与 .NET 字符串以 UTF-16 编址，这里负责两者换算。
public sealed partial class CodeEditor : Grid
{
    // 页边：0 Annotate 注释（默认隐藏），1 AI 评审标记（有标记时显示），2 行号，3 变更标记，4 与正文之间的空隙。
    private const int AnnotationMargin = 0;
    private const int ReviewMargin = 1;
    private const int NumberMargin = 2;
    private const int ChangeMargin = 3;
    private const int GapMargin = 4;
    private const double ReviewMarginWidth = 16;
    // AI 评审标记：错误、警告、建议。
    private const int ReviewMarkerBase = 14;
    private const double AnnotationWidth = 170;

    // 标记编号。
    private const int AddedMarker = 0;
    private const int ModifiedMarker = 1;
    private const int DeletedMarker = 2;

    private const int FindIndicator = 8;

    // Diff 装饰：整行背景（新增 / 修改 / 删除，以及不提交时的浅色）、无对应行时的分隔线、单词级高亮。
    private const int DiffLineMarkerBase = 3;
    private const int DiffExcludedMarkerBase = 6;
    private const int DiffSeparatorMarkerBase = 9;
    private const int InlineIndicatorBase = 9;
    // 三栏合并中的冲突块（红色背景）与无对应行时的分隔线。
    private const int ConflictMarker = 12;
    private const int ConflictSeparatorMarker = 13;
    private const int StyleDefault = 32;
    private const int StyleLineNumber = 33;
    // Annotate 注释的样式：按提交新旧分为若干档背景色（越新越深），最后一档为未提交的行。
    private const int StyleAnnotationBase = 40;
    private const int AnnotationAgeLevels = 8;
    private const int StyleAnnotationPlain = StyleAnnotationBase + AnnotationAgeLevels;

    private readonly EditorBaseControl _control = new();
    private readonly FindBar _findBar = new();
    private string _text;
    private string? _language;
    private IReadOnlyList<HighlightSpan> _spans = [];
    private IReadOnlyList<LineChange> _lineChanges = [];
    private bool _ready;
    private bool _suppressChange;
    private int _revision;
    private CancellationTokenSource? _highlightCancel;
    private List<(int Start, int Length)> _findMatches = [];
    private int? _findIndex;

    public CodeEditor(string text, string? language, bool isEditable = true)
    {
        _text = text;
        _language = language;
        IsEditable = isEditable;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _findBar.Visibility = Visibility.Collapsed;
        SetRow(_control, 1);
        Children.Add(_findBar);
        Children.Add(_control);

        _findBar.QueryChanged += () => Find(keepIndex: false);
        _findBar.Next += () => MoveFind(1);
        _findBar.Previous += () => MoveFind(-1);
        _findBar.Closed += HideFindBar;
        _findBar.Replace += ReplaceCurrent;
        _findBar.ReplaceAll += ReplaceAll;

        _control.Loaded += (_, _) => Initialize();
        ActualThemeChanged += (_, _) => ApplyAppearance();
        EditorSettings.Changed += SettingsChanged;
        Unloaded += (_, _) =>
        {
            _highlightCancel?.Cancel();
            HideInlineBlamePopup();
        };
    }

    /// 文本被用户编辑（不含程序设置文本）。
    public event Action? TextChanged;

    /// 光标位置变化：行、列（从 1 开始）。
    public event Action<int, int>? CaretChanged;

    public bool IsEditable { get; }

    /// 当前文本。
    public string Text => _text;

    /// 每次文本变化递增，用于丢弃过期的后台计算结果。
    public int Revision => _revision;

    /// 行尾风格（状态栏显示）。
    public string LineEnding => _text.Contains("\r\n", StringComparison.Ordinal) ? "CRLF" : "LF";

    public string? SyntaxLanguage
    {
        get => _language;
        set
        {
            _language = value;
            ScheduleHighlight(TimeSpan.Zero);
        }
    }

    /// 相对基准版本（HEAD）的行变更，显示在行号右侧。
    public IReadOnlyList<LineChange> LineChanges
    {
        get => _lineChanges;
        set
        {
            _lineChanges = value;
            ApplyLineChanges();
        }
    }

    public Microsoft.UI.Xaml.Controls.Control FocusTarget => _control;

    /// 把全文替换为 `newText`：只替换前后不同的部分，保留撤销历史与滚动位置（外部修改文件后重新载入时使用）。
    public void ReplaceText(string newText)
    {
        if (!_ready)
        {
            _text = newText;
            return;
        }
        var prefix = 0;
        while (prefix < _text.Length && prefix < newText.Length && _text[prefix] == newText[prefix]) prefix++;
        var suffix = 0;
        while (suffix < _text.Length - prefix && suffix < newText.Length - prefix
               && _text[^(suffix + 1)] == newText[^(suffix + 1)]) suffix++;
        var start = ByteOffset(_text, prefix);
        var end = ByteOffset(_text, _text.Length - suffix);
        var editor = _control.Editor;
        _suppressChange = true;
        editor.SetTargetRange(start, end);
        editor.ReplaceTarget(-1, newText[prefix..(newText.Length - suffix)]);
        _suppressChange = false;
        TextUpdated(raiseEvent: false);
    }

    public void Focus() => _control.Focus(FocusState.Programmatic);

    /// 编辑菜单中的命令（快捷键由 Scintilla 自身处理，菜单项只是另一个入口）。
    public void Undo() => Run(e => e.Undo());

    public void Redo() => Run(e => e.Redo());

    public void Cut() => Run(e => e.Cut());

    public void Copy() => Run(e => e.Copy());

    public void Paste() => Run(e => e.Paste());

    public void SelectAll() => Run(e => e.SelectAll());

    private void Run(Action<WinUIEditor.Editor> action)
    {
        if (!_ready) return;
        action(_control.Editor);
        Focus();
    }

    /// 把第 `line` 行（从 0 开始）滚动到视口中并放置光标。
    /// 点击行号（参数为从 0 开始的行）。Diff 中用于按行选择要提交的改动。
    public event Action<int>? LineNumberClicked;

    /// 垂直滚动位置变化（两侧同步滚动、重画连接带）。
    public event Action? Scrolled;

    /// 编辑器组件加载完成（此后行位置等信息可用）。
    public event Action? Initialized;

    /// 点击 Annotate 注释：该行最后修改所在的提交。
    public event Action<string>? AnnotationClicked;

    /// 点击 AI 评审标记：该行最严重的发现在评审结果中的下标。
    public event Action<int>? ReviewMarkerClicked;

    /// 在行号或注释列上右键：显示 gutter 菜单（Annotate、显示历史）的位置（相对本控件）。
    public event Action<Windows.Foundation.Point>? GutterContextRequested;

    /// 文本被修改（含程序修改与撤销 / 重做）：起始行与增加的行数（删除时为负）。三栏合并据此跟踪结果栏中块的位置。
    public event Action<int, int>? LinesEdited;

    public int LineCount => _ready ? (int)_control.Editor.LineCount : _text.Count(c => c == '\n') + 1;

    /// 视口顶部的行（Diff 两侧同步滚动）。
    public int FirstVisibleLine
    {
        get => _ready ? (int)_control.Editor.FirstVisibleLine : 0;
        set
        {
            if (_ready) _control.Editor.FirstVisibleLine = Math.Max(0, value);
        }
    }

    /// 第 `line` 行顶部相对编辑器文本区域顶部的位置（逻辑像素）；用于画 Diff 连接带。
    public double LineTop(int line)
    {
        if (!_ready) return 0;
        var editor = _control.Editor;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var count = (int)editor.LineCount;
        if (line >= count)
        {
            var last = Math.Max(0, count - 1);
            return (editor.PointYFromPosition(editor.PositionFromLine(last)) + editor.TextHeight(last)) / scale;
        }
        return editor.PointYFromPosition(editor.PositionFromLine(Math.Max(0, line))) / scale;
    }

    /// 编辑器文本区域在本控件中的上边距（查找栏显示时向下偏移）。
    public double TextAreaTop => _findBar.Visibility == Visibility.Visible ? _findBar.ActualHeight : 0;

    /// 显示垂直滚动条（Diff 左侧隐藏，只保留右侧的滚动条）。
    public bool ShowVerticalScrollBar
    {
        get => _showVerticalScrollBar;
        set
        {
            _showVerticalScrollBar = value;
            if (_ready) _control.Editor.VScrollBar = value;
        }
    }

    private bool _showVerticalScrollBar = true;
    private IReadOnlyList<DiffLine> _diffLines = [];
    private IReadOnlyList<DiffInline> _diffInline = [];
    private Func<int, string?>? _lineNumberText;
    private int _lineNumberWidth;

    /// Diff 中一行的装饰：所在变更块的种类，是否不提交，或者是对侧有内容时画在该行下方的分隔线。
    public readonly record struct DiffLine(int Line, LineChangeKind Kind, bool Excluded = false, bool Separator = false, bool Conflict = false);

    /// 单词级变化（UTF-16 偏移）。
    public readonly record struct DiffInline(uint Start, uint End, LineChangeKind Kind);

    /// 设置 Diff 装饰（整行背景、分隔线与单词级高亮）。
    public void SetDiffDecorations(IReadOnlyList<DiffLine> lines, IReadOnlyList<DiffInline> inline)
    {
        _diffLines = lines;
        _diffInline = inline;
        ApplyDiffDecorations();
    }

    /// 自定义行号（统一 Diff 视图显示新旧两列行号）；`width` 为预留的字符数。
    public void SetLineNumbers(int width, Func<int, string?>? text)
    {
        _lineNumberWidth = width;
        _lineNumberText = text;
        ApplyLineNumbers();
    }

    private BlameResult? _blame;
    private bool _showAnnotations;
    private IReadOnlyList<int?>? _annotationLineMap;
    private long _oldest;
    private long _newest;
    private ToolTip? _annotationTip;

    /// git blame 结果：Annotate 注释列与光标行的行内提交信息共用。
    public BlameResult? Blame
    {
        get => _blame;
        set
        {
            _blame = value;
            var times = value?.Commits.Where(c => !c.IsUncommitted).Select(c => c.AuthorTime).ToList() ?? [];
            _oldest = times.Count > 0 ? times.Min() : 0;
            _newest = times.Count > 0 ? times.Max() : 0;
            ApplyAnnotations();
            UpdateInlineBlame(force: true);
        }
    }

    /// 显示 Annotate 注释列（需要 <see cref="Blame"/>）。
    public bool ShowAnnotations
    {
        get => _showAnnotations;
        set
        {
            _showAnnotations = value;
            ApplyAnnotations();
        }
    }

    /// 编辑后的行号映射：当前行 → blame 时的行；null 元素表示新增或修改的行（不显示注释）。
    /// 为 null 时按行号一一对应（文件未修改）。
    public IReadOnlyList<int?>? AnnotationLineMap
    {
        get => _annotationLineMap;
        set
        {
            _annotationLineMap = value;
            ApplyAnnotations();
            UpdateInlineBlame(force: true);
        }
    }

    private BlameCommit? AnnotationCommit(int line)
    {
        if (_blame is not { } blame) return null;
        int? mapped = _annotationLineMap is { } map ? (line < map.Count ? map[line] : null) : line;
        if (mapped is not { } index || index < 0 || index >= blame.Lines.Length) return null;
        var commit = (int)blame.Lines[index];
        return commit < blame.Commits.Length ? blame.Commits[commit] : null;
    }

    /// 写入注释列：每行按提交新旧设置背景，同一提交的连续行只在第一行显示日期与作者（与 IDEA 一致）。
    private void ApplyAnnotations()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        editor.MarginTextClearAll();
        if (_blame is null || !_showAnnotations)
        {
            editor.SetMarginWidthN(AnnotationMargin, 0);
            ApplyLineNumbers();
            return;
        }
        var scale = XamlRoot?.RasterizationScale ?? 1;
        editor.SetMarginWidthN(AnnotationMargin, (int)Math.Round(AnnotationWidth * scale));
        var count = (int)editor.LineCount;
        string? previous = null;
        for (var line = 0; line < count; line++)
        {
            var commit = AnnotationCommit(line);
            if (commit is null || commit.IsUncommitted)
            {
                previous = commit?.Hash;
                editor.MarginSetText(line, " ");
                editor.MarginSetStyle(line, StyleAnnotationPlain);
                continue;
            }
            var text = commit.Hash == previous
                ? " "
                : $" {DateTimeOffset.FromUnixTimeSeconds(commit.AuthorTime).LocalDateTime:d}  {commit.AuthorName}";
            previous = commit.Hash;
            editor.MarginSetText(line, text);
            editor.MarginSetStyle(line, StyleAnnotationBase + AgeLevel(commit.AuthorTime));
        }
        // 页边文本按行共享：注释列只用于普通编辑器，不与自定义行号（统一 Diff）同时出现。
    }

    private int AgeLevel(long time)
    {
        var span = Math.Max(_newest - _oldest, 1);
        var recency = (double)(time - _oldest) / span;
        return Math.Clamp((int)(recency * (AnnotationAgeLevels - 1) + 0.5), 0, AnnotationAgeLevels - 1);
    }

    /// 悬停在注释上时显示提交详情。
    private void ShowAnnotationTip(int x, int y)
    {
        if (!_showAnnotations && _reviewMarkers.Count == 0) return;
        var editor = _control.Editor;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var annotationWidth = editor.GetMarginWidthN(AnnotationMargin);
        var reviewWidth = editor.GetMarginWidthN(ReviewMargin);
        if (x > annotationWidth + reviewWidth) return;
        var line = (int)editor.LineFromPosition(editor.PositionFromPoint(annotationWidth + reviewWidth + editor.GetMarginWidthN(NumberMargin) + 40, y));
        _annotationTip ??= new ToolTip { Placement = Microsoft.UI.Xaml.Controls.Primitives.PlacementMode.Right };
        if (x >= annotationWidth)
        {
            // AI 评审标记的说明。
            var markers = _reviewMarkers.Where(m => m.Line == line).ToList();
            if (markers.Count == 0) return;
            _annotationTip.Content = string.Join("\n", markers.Select(m => m.Tooltip));
            _annotationTip.PlacementRect = new Windows.Foundation.Rect(x / scale, y / scale, 1, editor.TextHeight(line) / scale);
            ToolTipService.SetToolTip(_control, _annotationTip);
            _annotationTip.IsOpen = true;
            return;
        }
        if (AnnotationCommit(line) is not { IsUncommitted: false } commit) return;
        _annotationTip.Content = $"{commit.Hash[..Math.Min(8, commit.Hash.Length)]}  {commit.AuthorName} <{commit.AuthorEmail}>\n"
            + $"{Git.LogDates.Detailed(commit.AuthorTime)}\n\n{commit.Summary}";
        _annotationTip.PlacementRect = new Windows.Foundation.Rect(x / scale, y / scale, 1, editor.TextHeight(line) / scale);
        ToolTipService.SetToolTip(_control, _annotationTip);
        _annotationTip.IsOpen = true;
    }

    private void HideAnnotationTip()
    {
        if (_annotationTip is null) return;
        _annotationTip.IsOpen = false;
        ToolTipService.SetToolTip(_control, null);
    }

    /// AI 评审在编辑器中的标记（行从 0 开始）。
    public readonly record struct ReviewMarker(int Index, int Line, ReviewSeverity Severity, string Tooltip);

    private IReadOnlyList<ReviewMarker> _reviewMarkers = [];

    public IReadOnlyList<ReviewMarker> ReviewMarkers
    {
        get => _reviewMarkers;
        set
        {
            _reviewMarkers = value;
            ApplyReviewMarkers();
        }
    }

    private void ApplyReviewMarkers()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        for (var i = 0; i < 3; i++) editor.MarkerDeleteAll(ReviewMarkerBase + i);
        var scale = XamlRoot?.RasterizationScale ?? 1;
        editor.SetMarginWidthN(ReviewMargin, _reviewMarkers.Count == 0 ? 0 : (int)Math.Round(ReviewMarginWidth * scale));
        var lastLine = Math.Max(0, (int)editor.LineCount - 1);
        // 同一行有多条发现时只显示最严重的。
        foreach (var marker in _reviewMarkers.GroupBy(m => m.Line).Select(g => g.MinBy(m => (int)m.Severity)))
        {
            editor.MarkerAdd(Math.Min(marker.Line, lastLine), ReviewMarkerBase + (int)marker.Severity);
        }
    }

    private ReviewMarker? ReviewMarkerAt(int line) =>
        _reviewMarkers.Where(m => m.Line == line).OrderBy(m => (int)m.Severity).Cast<ReviewMarker?>().FirstOrDefault();

    private void ApplyDiffDecorations()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        for (var i = 0; i < 3; i++)
        {
            editor.MarkerDeleteAll(DiffLineMarkerBase + i);
            editor.MarkerDeleteAll(DiffExcludedMarkerBase + i);
            editor.MarkerDeleteAll(DiffSeparatorMarkerBase + i);
            editor.IndicatorCurrent = InlineIndicatorBase + i;
            editor.IndicatorClearRange(0, editor.Length);
        }
        editor.MarkerDeleteAll(ConflictMarker);
        editor.MarkerDeleteAll(ConflictSeparatorMarker);
        foreach (var line in _diffLines)
        {
            if (line.Conflict)
            {
                editor.MarkerAdd(line.Line, line.Separator ? ConflictSeparatorMarker : ConflictMarker);
                continue;
            }
            var kind = (int)line.Kind;
            var marker = line.Separator ? DiffSeparatorMarkerBase + kind : (line.Excluded ? DiffExcludedMarkerBase : DiffLineMarkerBase) + kind;
            editor.MarkerAdd(line.Line, marker);
        }
        if (_diffInline.Count > 0)
        {
            var offsets = Utf8Offsets(_text);
            foreach (var range in _diffInline)
            {
                if (range.End > _text.Length || range.End <= range.Start) continue;
                editor.IndicatorCurrent = InlineIndicatorBase + (int)range.Kind;
                editor.IndicatorFillRange(offsets[range.Start], offsets[range.End] - offsets[range.Start]);
            }
        }
    }

    private void ApplyLineNumbers()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        if (_lineNumberText is null)
        {
            editor.SetMarginTypeN(NumberMargin, MarginType.Number);
            UpdateNumberMarginWidth();
            return;
        }
        editor.SetMarginTypeN(NumberMargin, MarginType.RText);
        editor.MarginTextClearAll();
        var count = (int)editor.LineCount;
        for (var line = 0; line < count; line++)
        {
            if (_lineNumberText(line) is { } text)
            {
                editor.MarginSetText(line, text);
                editor.MarginSetStyle(line, StyleLineNumber);
            }
        }
        editor.SetMarginWidthN(NumberMargin, editor.TextWidth(StyleLineNumber, new string('9', Math.Max(3, _lineNumberWidth))) + 12);
    }

    /// 把第 `start` 行起的 `count` 行（含行尾）替换为 `text`，作为一次可撤销的编辑（三栏合并应用变更块）。
    public void ReplaceLines(int start, int count, string text)
    {
        if (!_ready) return;
        var editor = _control.Editor;
        var lineCount = (int)editor.LineCount;
        var from = start >= lineCount ? editor.Length : editor.PositionFromLine(start);
        var to = start + count >= lineCount ? editor.Length : editor.PositionFromLine(start + count);
        editor.SetTargetRange(from, to);
        editor.ReplaceTarget(-1, text);
    }

    /// 光标所在行（从 0 开始）。
    public int CaretLine => _ready ? (int)_control.Editor.LineFromPosition(_control.Editor.CurrentPos) : 0;

    public void Reveal(int line)
    {
        if (!_ready) return;
        var editor = _control.Editor;
        editor.GotoLine(line);
        editor.EnsureVisibleEnforcePolicy(line);
    }

    // MARK: - 初始化与外观

    private void Initialize()
    {
        if (_ready) return;
        _ready = true;
        var editor = _control.Editor;
        editor.SetText(_text);
        editor.EmptyUndoBuffer();
        editor.SetSavePoint();
        editor.ReadOnly = !IsEditable;
        editor.EOLMode = LineEnding == "CRLF" ? EndOfLine.CrLf : EndOfLine.Lf;
        editor.TabWidth = 4;
        editor.UseTabs = false;
        editor.ScrollWidthTracking = true;
        editor.ScrollWidth = 1;
        editor.EndAtLastLine = false;
        editor.MarginLeft = 0;
        editor.MarginRight = 6;
        editor.CaretLineVisibleAlways = true;
        editor.SelectionLayer = Layer.UnderText;

        editor.SetMarginTypeN(AnnotationMargin, MarginType.Text);
        editor.SetMarginMaskN(AnnotationMargin, 0);
        editor.SetMarginWidthN(AnnotationMargin, 0);
        editor.SetMarginSensitiveN(AnnotationMargin, true);
        editor.SetMarginTypeN(ReviewMargin, MarginType.Symbol);
        editor.SetMarginMaskN(ReviewMargin, (1 << ReviewMarkerBase) | (1 << (ReviewMarkerBase + 1)) | (1 << (ReviewMarkerBase + 2)));
        editor.SetMarginWidthN(ReviewMargin, 0);
        editor.SetMarginSensitiveN(ReviewMargin, true);
        for (var i = 0; i < 3; i++) editor.MarkerDefine(ReviewMarkerBase + i, MarkerSymbol.Circle);
        editor.SetMarginTypeN(NumberMargin, MarginType.Number);
        editor.SetMarginMaskN(NumberMargin, 0);
        editor.SetMarginTypeN(ChangeMargin, MarginType.Symbol);
        editor.SetMarginMaskN(ChangeMargin, (1 << AddedMarker) | (1 << ModifiedMarker) | (1 << DeletedMarker));
        editor.SetMarginWidthN(ChangeMargin, 4);
        editor.SetMarginTypeN(GapMargin, MarginType.Symbol);
        editor.SetMarginMaskN(GapMargin, 0);
        editor.SetMarginWidthN(GapMargin, 8);
        editor.MarkerDefine(AddedMarker, MarkerSymbol.FullRect);
        editor.MarkerDefine(ModifiedMarker, MarkerSymbol.FullRect);
        editor.MarkerDefine(DeletedMarker, MarkerSymbol.Arrow);
        editor.IndicSetStyle(FindIndicator, IndicatorStyle.FullBox);
        editor.IndicSetUnder(FindIndicator, true);

        editor.Modified += (_, args) =>
        {
            const int textChange = (int)(ModificationFlags.InsertText | ModificationFlags.DeleteText);
            if ((args.ModificationType & textChange) == 0) return;
            if (!_suppressChange) TextUpdated(raiseEvent: true);
            LinesEdited?.Invoke((int)editor.LineFromPosition(args.Position), args.LinesAdded);
        };
        editor.UpdateUI += (_, args) =>
        {
            ReportCaret();
            UpdateInlineBlame(force: false);
            if ((args.Updated & (int)(Update.VScroll | Update.HScroll)) != 0) HideInlineBlamePopup();
            if ((args.Updated & (int)Update.VScroll) != 0) Scrolled?.Invoke();
        };
        editor.SetMarginSensitiveN(NumberMargin, true);
        editor.MarginClick += (_, args) =>
        {
            var line = (int)editor.LineFromPosition(args.Position);
            if (args.Margin == NumberMargin) LineNumberClicked?.Invoke(line);
            else if (args.Margin == AnnotationMargin && AnnotationCommit(line) is { IsUncommitted: false } commit) AnnotationClicked?.Invoke(commit.Hash);
            else if (args.Margin == ReviewMargin && ReviewMarkerAt(line) is { } marker) ReviewMarkerClicked?.Invoke(marker.Index);
        };
        editor.MarginRightClick += (_, args) =>
        {
            if (args.Margin != NumberMargin && args.Margin != AnnotationMargin) return;
            var scale = XamlRoot?.RasterizationScale ?? 1;
            var y = editor.PointYFromPosition(args.Position) / scale + TextAreaTop;
            GutterContextRequested?.Invoke(new Windows.Foundation.Point(4, y + 8));
        };
        editor.MouseDwellTime = 500;
        editor.DwellStart += (_, args) => ShowAnnotationTip(args.X, args.Y);
        editor.DwellEnd += (_, _) => HideAnnotationTip();
        editor.VScrollBar = _showVerticalScrollBar;
        for (var i = 0; i < 3; i++)
        {
            editor.MarkerDefine(DiffLineMarkerBase + i, MarkerSymbol.Background);
            editor.MarkerDefine(DiffExcludedMarkerBase + i, MarkerSymbol.Background);
            editor.MarkerDefine(DiffSeparatorMarkerBase + i, MarkerSymbol.Underline);
            editor.IndicSetStyle(InlineIndicatorBase + i, IndicatorStyle.FullBox);
            editor.IndicSetUnder(InlineIndicatorBase + i, true);
        }
        editor.MarkerDefine(ConflictMarker, MarkerSymbol.Background);
        editor.MarkerDefine(ConflictSeparatorMarker, MarkerSymbol.Underline);

        ApplyAppearance();
        ApplyLineChanges();
        ApplyReviewMarkers();
        InitializeInlineBlame();
        ScheduleHighlight(TimeSpan.Zero);
        // 等首次排版完成后再通知，行位置才是准确的。
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Initialized?.Invoke());
    }

    private bool IsDark => ActualTheme == ElementTheme.Dark;

    private void ApplyAppearance()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        var dark = IsDark;
        var family = EditorSettings.EffectiveFamily;
        var points = (int)Math.Round(EditorSettings.FontSize * 0.75 * 100);

        editor.StyleSetFont(StyleDefault, family);
        editor.StyleSetSizeFractional(StyleDefault, points);
        editor.StyleSetFore(StyleDefault, Bgr(SyntaxTheme.Text(dark)));
        editor.StyleSetBack(StyleDefault, Bgr(SyntaxTheme.Background(dark)));
        editor.StyleClearAll();
        editor.StyleSetFore(StyleLineNumber, Bgr(SyntaxTheme.LineNumber(dark)));
        editor.StyleSetBack(StyleLineNumber, Bgr(SyntaxTheme.Background(dark)));
        editor.StyleSetSizeFractional(StyleLineNumber, Math.Max(700, points - 75));
        var gutterBackground = SyntaxTheme.Background(dark);
        for (var level = 0; level <= AnnotationAgeLevels; level++)
        {
            var style = StyleAnnotationBase + level;
            editor.StyleSetFont(style, "Segoe UI");
            editor.StyleSetSizeFractional(style, Math.Max(700, points - 150));
            editor.StyleSetFore(style, Bgr(SyntaxTheme.LineNumber(dark)));
            // 越新的提交背景越深（IDEA 按提交时间的热力着色）。
            var alpha = level == AnnotationAgeLevels ? 0 : 0.04 + 0.22 * level / (AnnotationAgeLevels - 1);
            editor.StyleSetBack(style, Bgr(DiffColors.Blend(DiffColors.Accent, gutterBackground, alpha)));
        }
        foreach (var kind in Enum.GetValues<TokenKind>())
        {
            editor.StyleSetFore(TokenStyle(kind), Bgr(SyntaxTheme.Token(kind, dark)));
        }

        // 行距：在字体高度之上均分额外空间。
        var extra = (int)Math.Round(EditorSettings.FontSize * (EditorSettings.LineSpacing - 1) / 2);
        editor.ExtraAscent = extra;
        editor.ExtraDescent = extra;

        editor.SetElementColour(Element.Caret, Opaque(SyntaxTheme.Text(dark)));
        editor.SetElementColour(Element.CaretLineBack, Opaque(SyntaxTheme.CurrentLine(dark)));
        editor.SetElementColour(Element.SelectionBack, Opaque(SyntaxTheme.Selection(dark)));
        editor.SetElementColour(Element.SelectionInactiveBack, Opaque(SyntaxTheme.Selection(dark)));
        editor.SetMarginBackN(GapMargin, Bgr(SyntaxTheme.Background(dark)));
        editor.MarkerSetBack(AddedMarker, Bgr(SyntaxTheme.LineAdded(dark)));
        editor.MarkerSetFore(AddedMarker, Bgr(SyntaxTheme.LineAdded(dark)));
        editor.MarkerSetBack(ModifiedMarker, Bgr(SyntaxTheme.LineModified(dark)));
        editor.MarkerSetFore(ModifiedMarker, Bgr(SyntaxTheme.LineModified(dark)));
        editor.MarkerSetBack(DeletedMarker, Bgr(SyntaxTheme.LineDeleted(dark)));
        editor.MarkerSetFore(DeletedMarker, Bgr(SyntaxTheme.LineDeleted(dark)));
        editor.IndicSetFore(FindIndicator, Bgr(SyntaxTheme.FindMatch(dark)));
        editor.IndicSetAlpha(FindIndicator, (Alpha)255);
        foreach (var kind in Enum.GetValues<LineChangeKind>())
        {
            var i = (int)kind;
            var block = DiffColors.Block(kind, dark);
            editor.MarkerSetBack(DiffLineMarkerBase + i, Bgr(block));
            editor.MarkerSetBack(DiffExcludedMarkerBase + i, Bgr(DiffColors.Blend(block, SyntaxTheme.Background(dark), 0.3)));
            editor.MarkerSetBack(DiffSeparatorMarkerBase + i, Bgr(DiffColors.Marker(kind, dark)));
            editor.IndicSetFore(InlineIndicatorBase + i, Bgr(DiffColors.Inline(kind, dark)));
            editor.IndicSetAlpha(InlineIndicatorBase + i, (Alpha)255);
        }
        foreach (var severity in Enum.GetValues<ReviewSeverity>())
        {
            var color = Bgr(AI.AIReviewToolWindow.SeverityColor(severity, dark));
            editor.MarkerSetBack(ReviewMarkerBase + (int)severity, color);
            editor.MarkerSetFore(ReviewMarkerBase + (int)severity, color);
        }
        editor.MarkerSetBack(ConflictMarker, Bgr(DiffColors.ConflictBlock(dark)));
        editor.MarkerSetBack(ConflictSeparatorMarker, Bgr(DiffColors.ConflictMarker(dark)));
        UpdateNumberMarginWidth();
        ApplyAnnotations();
        ApplyInlineBlameStyle();
        ApplyStyles(_spans);
        ApplyDiffDecorations();
    }

    private void SettingsChanged()
    {
        if (DispatcherQueue.HasThreadAccess) ApplyAppearance();
        else DispatcherQueue.TryEnqueue(ApplyAppearance);
    }

    private void UpdateNumberMarginWidth()
    {
        if (_lineNumberText is not null) return;
        var editor = _control.Editor;
        var digits = Math.Max(3, editor.LineCount.ToString(System.Globalization.CultureInfo.InvariantCulture).Length);
        var width = editor.TextWidth(StyleLineNumber, new string('9', digits)) + 12;
        editor.SetMarginWidthN(NumberMargin, width);
    }

    /// 运算符与标点使用默认文本色（与 IDEA 默认配色一致），不单独设样式。
    private static int TokenStyle(TokenKind kind) => kind is TokenKind.Operator or TokenKind.Punctuation ? 0 : (int)kind + 1;

    private static int Bgr(Color color) => color.R | (color.G << 8) | (color.B << 16);

    private static int Opaque(Color color) => unchecked((int)0xFF000000) | Bgr(color);

    // MARK: - 文本变化

    private void TextUpdated(bool raiseEvent)
    {
        var editor = _control.Editor;
        _text = editor.GetText(editor.Length);
        _revision++;
        UpdateNumberMarginWidth();
        // 输入时稍作停顿再重新高亮，避免每个按键都触发完整解析。
        ScheduleHighlight(TimeSpan.FromMilliseconds(120));
        if (_findBar.Visibility == Visibility.Visible) Find(keepIndex: true);
        if (raiseEvent) TextChanged?.Invoke();
    }

    private void ReportCaret()
    {
        var editor = _control.Editor;
        var position = editor.CurrentPos;
        var line = editor.LineFromPosition(position);
        var lineStart = editor.PositionFromLine(line);
        var column = editor.CountCharacters(lineStart, position);
        CaretChanged?.Invoke((int)line + 1, (int)column + 1);
    }

    // MARK: - 语法高亮

    private void ScheduleHighlight(TimeSpan delay)
    {
        _highlightCancel?.Cancel();
        if (!_ready) return;
        if (_language is not { } language)
        {
            _spans = [];
            ApplyStyles(_spans);
            return;
        }
        var cancel = _highlightCancel = new CancellationTokenSource();
        var text = _text;
        var expected = _revision;
        _ = Task.Run(async () =>
        {
            if (delay > TimeSpan.Zero) await Task.Delay(delay, cancel.Token);
            var spans = CoreApi.Highlight(language, text);
            DispatcherQueue.TryEnqueue(() =>
            {
                if (cancel.IsCancellationRequested || _revision != expected) return;
                _spans = spans;
                ApplyStyles(spans);
            });
        }, cancel.Token);
    }

    /// 把 UTF-16 区间换算为字节位置后写入 Scintilla 的样式（未覆盖的部分为默认样式）。
    private void ApplyStyles(IReadOnlyList<HighlightSpan> spans)
    {
        if (!_ready) return;
        var editor = _control.Editor;
        var offsets = Utf8Offsets(_text);
        var total = offsets[^1];
        editor.StartStyling(0, 0);
        var position = 0;
        foreach (var span in spans.OrderBy(s => s.Start))
        {
            if (span.End > _text.Length || span.Start < 0) continue;
            // 样式边界不能落在 CRLF 中间（tree-sitter 的行注释会包含 CR），否则 Scintilla 排版会陷入死循环。
            var startIndex = SplitsCrLf(span.Start) ? (int)span.Start - 1 : (int)span.Start;
            var endIndex = SplitsCrLf(span.End) ? (int)span.End - 1 : (int)span.End;
            var start = offsets[startIndex];
            var end = offsets[endIndex];
            if (end <= start) continue;
            if (start < position) continue;
            if (start > position) editor.SetStyling(start - position, 0);
            editor.SetStyling(end - start, TokenStyle(span.Kind));
            position = end;
        }
        if (total > position) editor.SetStyling(total - position, 0);
    }

    private bool SplitsCrLf(uint index) => index > 0 && index < _text.Length && _text[(int)index - 1] == '\r' && _text[(int)index] == '\n';

    /// 每个 UTF-16 下标对应的 UTF-8 字节偏移（长度为字符数 + 1）。
    private static int[] Utf8Offsets(string text)
    {
        var offsets = new int[text.Length + 1];
        var bytes = 0;
        for (var i = 0; i < text.Length; i++)
        {
            offsets[i] = bytes;
            var c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                bytes += 4;
                offsets[++i] = bytes;
                continue;
            }
            bytes += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
        }
        offsets[text.Length] = bytes;
        return offsets;
    }

    private static int ByteOffset(string text, int index) => Encoding.UTF8.GetByteCount(text.AsSpan(0, index));

    // MARK: - 变更标记

    private void ApplyLineChanges()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        editor.MarkerDeleteAll(AddedMarker);
        editor.MarkerDeleteAll(ModifiedMarker);
        editor.MarkerDeleteAll(DeletedMarker);
        var lastLine = Math.Max(0, editor.LineCount - 1);
        foreach (var change in _lineChanges)
        {
            switch (change.Kind)
            {
                case LineChangeKind.Deleted:
                    editor.MarkerAdd(Math.Min(change.Start, lastLine), DeletedMarker);
                    break;
                default:
                    var marker = change.Kind == LineChangeKind.Added ? AddedMarker : ModifiedMarker;
                    for (var line = change.Start; line < change.Start + change.Count; line++) editor.MarkerAdd(line, marker);
                    break;
            }
        }
    }

    // MARK: - 查找与替换（IDEA / VSCode 的 Ctrl+F、Ctrl+R）

    public void ShowFindBar(bool replace = false)
    {
        string? selected = null;
        if (_ready && !_control.Editor.SelectionEmpty)
        {
            var editor = _control.Editor;
            selected = editor.GetSelText();
            if (selected.Contains('\n')) selected = null;
        }
        _findBar.IsReplaceMode = replace && IsEditable;
        _findBar.Visibility = Visibility.Visible;
        _findBar.FocusQuery(selected);
    }

    /// 设置查找内容（调试截图用）。
    public void SetFindQuery(string query) => _findBar.FocusQuery(query);

    public void HideFindBar()
    {
        _findBar.Visibility = Visibility.Collapsed;
        ClearFindIndicators();
        _findMatches = [];
        Focus();
    }

    public void FindNext()
    {
        if (_findBar.Visibility != Visibility.Visible) ShowFindBar();
        else MoveFind(1);
    }

    public void FindPrevious()
    {
        if (_findBar.Visibility != Visibility.Visible) ShowFindBar();
        else MoveFind(-1);
    }

    private void Find(bool keepIndex)
    {
        var query = _findBar.Query;
        var comparison = _findBar.MatchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var matches = new List<(int, int)>();
        if (query.Length > 0)
        {
            var index = 0;
            while (matches.Count < 10_000 && (index = _text.IndexOf(query, index, comparison)) >= 0)
            {
                matches.Add((index, query.Length));
                index += query.Length;
            }
        }
        _findMatches = matches;
        if (matches.Count == 0)
        {
            _findIndex = null;
        }
        else if (!keepIndex || _findIndex is null)
        {
            // 从光标位置开始找第一个匹配。
            var caret = _ready ? CharIndex(_control.Editor.SelectionStart) : 0;
            var first = matches.FindIndex(m => m.Item1 >= caret);
            _findIndex = first >= 0 ? first : 0;
        }
        else
        {
            _findIndex = Math.Min(_findIndex.Value, matches.Count - 1);
        }
        ShowFindResults(select: !keepIndex);
    }

    private void MoveFind(int step)
    {
        if (_findMatches.Count == 0) return;
        _findIndex = ((_findIndex ?? -step) + step + _findMatches.Count) % _findMatches.Count;
        ShowFindResults(select: true);
    }

    private void ShowFindResults(bool select)
    {
        if (!_ready) return;
        var editor = _control.Editor;
        ClearFindIndicators();
        var offsets = Utf8Offsets(_text);
        editor.IndicatorCurrent = FindIndicator;
        foreach (var (start, length) in _findMatches)
        {
            editor.IndicatorFillRange(offsets[start], offsets[start + length] - offsets[start]);
        }
        if (select && _findIndex is { } index)
        {
            var (start, length) = _findMatches[index];
            editor.SetSel(offsets[start], offsets[start + length]);
            editor.ScrollRange(offsets[start], offsets[start + length]);
        }
        _findBar.SetResult(_findIndex, _findMatches.Count);
    }

    private void ClearFindIndicators()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        editor.IndicatorCurrent = FindIndicator;
        editor.IndicatorClearRange(0, editor.Length);
    }

    /// 替换当前匹配并定位到下一个。
    private void ReplaceCurrent(string replacement)
    {
        if (!IsEditable || !_ready || _findIndex is not { } index || index >= _findMatches.Count) return;
        var (start, length) = _findMatches[index];
        var editor = _control.Editor;
        editor.SetTargetRange(ByteOffset(_text, start), ByteOffset(_text, start + length));
        editor.ReplaceTarget(-1, replacement);
        Find(keepIndex: true);
        ShowFindResults(select: true);
    }

    private void ReplaceAll(string replacement)
    {
        if (!IsEditable || !_ready || _findMatches.Count == 0) return;
        var count = _findMatches.Count;
        var editor = _control.Editor;
        // 从后往前替换，前面匹配的位置不受影响；整体作为一次撤销。
        editor.BeginUndoAction();
        var offsets = Utf8Offsets(_text);
        foreach (var (start, length) in Enumerable.Reverse(_findMatches))
        {
            editor.SetTargetRange(offsets[start], offsets[start + length]);
            editor.ReplaceTarget(-1, replacement);
        }
        editor.EndUndoAction();
        Find(keepIndex: false);
        _findBar.SetResultText(L10n.Tr("find.replaced", count));
    }

    private int CharIndex(long bytePosition)
    {
        var offsets = Utf8Offsets(_text);
        var index = Array.BinarySearch(offsets, (int)bytePosition);
        return index >= 0 ? index : ~index;
    }
}
