using System.Text;
using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using WinUIEditor;

namespace GitDeck.Editor;

/// 代码编辑器：WinUIEdit（Scintilla）文本视图 + 行号与变更标记 gutter + 语法高亮 + 查找栏。
///
/// 与 mac 端 CodeEditorView 一致：只使用组件的文本视图，配色、行号、变更标记、高亮（Rust tree-sitter）、查找都自建。
/// Scintilla 内部以 UTF-8 字节编址，核心的高亮区间与 .NET 字符串以 UTF-16 编址，这里负责两者换算。
public sealed class CodeEditor : Grid
{
    // 页边：0 行号，1 变更标记，2 与正文之间的空隙。
    private const int NumberMargin = 0;
    private const int ChangeMargin = 1;
    private const int GapMargin = 2;

    // 标记编号。
    private const int AddedMarker = 0;
    private const int ModifiedMarker = 1;
    private const int DeletedMarker = 2;

    private const int FindIndicator = 8;
    private const int StyleDefault = 32;
    private const int StyleLineNumber = 33;

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
        Unloaded += (_, _) => _highlightCancel?.Cancel();
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
            if ((args.ModificationType & textChange) != 0 && !_suppressChange) TextUpdated(raiseEvent: true);
        };
        editor.UpdateUI += (_, _) => ReportCaret();

        ApplyAppearance();
        ApplyLineChanges();
        ScheduleHighlight(TimeSpan.Zero);
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
        UpdateNumberMarginWidth();
        ApplyStyles(_spans);
    }

    private void SettingsChanged()
    {
        if (DispatcherQueue.HasThreadAccess) ApplyAppearance();
        else DispatcherQueue.TryEnqueue(ApplyAppearance);
    }

    private void UpdateNumberMarginWidth()
    {
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
