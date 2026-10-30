using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Diff;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using WinUIEditor;

namespace GitDeck.Editor;

/// 行内提交信息（与 VSCode / GitLens 的 current line blame 一致）：光标所在行的行尾以淡色显示该行最近一次提交，
/// 不改动文本；鼠标悬停在这段文字上时弹出提交详情，鼠标在弹窗内时保持显示，移出后关闭。
public sealed partial class CodeEditor
{
    private const int StyleInlineBlame = StyleAnnotationPlain + 1;
    /// 行尾与提交信息之间的空隙。
    private const string InlineBlameGap = "    ";

    private int _inlineLine = -1;
    private string? _inlineText;
    private string? _userEmail;
    private Popup? _blamePopup;
    private int _blamePopupLine = -1;
    private bool _pointerInPopup;
    private DispatcherTimer? _blameShowTimer;
    private DispatcherTimer? _blameHideTimer;
    private Windows.Foundation.Point _blamePointer;

    /// 当前用户的提交邮箱：作者为本人的提交显示为“你”。
    public string? UserEmail
    {
        get => _userEmail;
        set
        {
            _userEmail = value;
            UpdateInlineBlame(force: true);
        }
    }

    /// 读取提交的完整信息（在后台线程调用）；弹窗据此显示完整的提交说明。
    public Func<string, CommitDetails?>? CommitDetailsProvider { get; set; }

    private void InitializeInlineBlame()
    {
        _control.AddHandler(PointerMovedEvent, new PointerEventHandler(InlineBlamePointerMoved), true);
        _control.AddHandler(PointerExitedEvent, new PointerEventHandler((_, _) => InlineBlamePointerLeft()), true);
        _control.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => HideInlineBlamePopup()), true);
        _control.AddHandler(KeyDownEvent, new KeyEventHandler((_, _) => HideInlineBlamePopup()), true);
        // 编辑区宽度变化（窗口缩放、打开注释列）时重新计算截断宽度。
        _control.SizeChanged += (_, _) => UpdateInlineBlame(force: true);
        // 编辑器组件加载后 DispatcherQueueTimer 会停止触发（WinUIEdit 的问题），这里用 XAML 的 DispatcherTimer。
        _blameShowTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        _blameShowTimer.Tick += (_, _) =>
        {
            _blameShowTimer.Stop();
            if (IsOverInlineBlame(_blamePointer)) ShowInlineBlamePopup();
        };
        _blameHideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _blameHideTimer.Tick += (_, _) =>
        {
            _blameHideTimer.Stop();
            if (!_pointerInPopup) HideInlineBlamePopup();
        };
        ApplyInlineBlameStyle();
    }

    private void ApplyInlineBlameStyle()
    {
        if (!_ready) return;
        var editor = _control.Editor;
        var dark = IsDark;
        editor.StyleSetFont(StyleInlineBlame, EditorSettings.EffectiveFamily);
        editor.StyleSetSizeFractional(StyleInlineBlame, (int)Math.Round(EditorSettings.FontSize * 0.75 * 100));
        editor.StyleSetFore(StyleInlineBlame, Bgr(DiffColors.Blend(SyntaxTheme.Text(dark), SyntaxTheme.Background(dark), 0.4)));
        // 只出现在光标行上：背景与当前行高亮相同，看起来像输入框的占位文字。
        editor.StyleSetBack(StyleInlineBlame, Bgr(SyntaxTheme.CurrentLine(dark)));
        editor.EOLAnnotationVisible = EOLAnnotationVisible.Standard;
        UpdateInlineBlame(force: true);
    }

    /// 光标所在行的提交；行在 blame 之后被修改过（或是新增的行）时返回 null。
    private (BlameCommit? Commit, bool Known) InlineBlameCommit(int line)
    {
        if (_blame is null) return (null, false);
        return (AnnotationCommit(line), true);
    }

    /// 刷新行内提交信息：只显示在光标所在行（`force` 为 false 时光标仍在同一行则不重写）。
    private void UpdateInlineBlame(bool force)
    {
        if (!_ready) return;
        var editor = _control.Editor;
        var line = EditorSettings.InlineBlame && _blame is not null ? CaretLine : -1;
        if (!force && line == _inlineLine) return;
        if (line != _inlineLine) HideInlineBlamePopup();
        var text = line >= 0 ? InlineBlameText(line) : null;
        if (!force && line == _inlineLine && text == _inlineText) return;
        // 行内文字随所在行移动（在上方插入或删除行后行号会变），整体清除而不是按旧行号清除。
        if (_inlineText is not null) editor.EOLAnnotationClearAll();
        _inlineLine = text is null ? -1 : line;
        _inlineText = text;
        if (text is null) return;
        editor.EOLAnnotationSetText(line, text);
        editor.EOLAnnotationSetStyle(line, StyleInlineBlame);
    }

    /// 行内文字：“作者, 相对时间 • 提交标题”；超出可见宽度时截断标题。
    private string? InlineBlameText(int line)
    {
        var (commit, known) = InlineBlameCommit(line);
        if (!known) return null;
        if (commit is null || commit.IsUncommitted)
        {
            return $"{InlineBlameGap}{L10n.Tr("blame.inline.you")} • {L10n.Tr("blame.inline.uncommitted")}";
        }
        var prefix = $"{InlineBlameGap}{AuthorLabel(commit)}, {RelativeDate(commit.AuthorTime)} • ";
        var summary = commit.Summary;
        var editor = _control.Editor;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        // 可用宽度：行尾到文本区域右边缘（不含垂直滚动条）。
        var available = _control.ActualWidth * scale - 16 * scale - InlineBlameStartX(line);
        var full = prefix + summary;
        if (available <= 0 || editor.TextWidth(StyleInlineBlame, full) <= available) return full;
        var keep = summary.Length;
        while (keep > 0 && editor.TextWidth(StyleInlineBlame, prefix + summary[..keep] + "…") > available) keep--;
        // 按可见宽度截断标题（与 mac 端一致）；连作者和时间都放不下时只显示到此为止。
        return keep >= summary.Length ? full : prefix + summary[..keep].TrimEnd() + "…";
    }

    private string AuthorLabel(BlameCommit commit) =>
        _userEmail is { Length: > 0 } email && string.Equals(email, commit.AuthorEmail, StringComparison.OrdinalIgnoreCase)
            ? L10n.Tr("blame.inline.you")
            : commit.AuthorName;

    /// 相对时间（“3 天前”），与 VSCode 的行内 blame 相同的粒度。
    public static string RelativeDate(long timestamp)
    {
        var then = DateTimeOffset.FromUnixTimeSeconds(timestamp).LocalDateTime;
        var now = DateTime.Now;
        var span = now - then;
        if (span.TotalMinutes < 1) return L10n.Tr("blame.date.now");
        if (span.TotalMinutes < 2) return L10n.Tr("blame.date.minute");
        if (span.TotalHours < 1) return L10n.Tr("blame.date.minutes", (int)span.TotalMinutes);
        if (span.TotalHours < 2) return L10n.Tr("blame.date.hour");
        if (span.TotalDays < 1 && then.Date == now.Date) return L10n.Tr("blame.date.hours", (int)span.TotalHours);
        var days = (now.Date - then.Date).Days;
        if (days <= 1) return L10n.Tr("blame.date.yesterday");
        if (days < 30) return L10n.Tr("blame.date.days", days);
        var months = (now.Year - then.Year) * 12 + now.Month - then.Month - (now.Day < then.Day ? 1 : 0);
        if (months < 12) return months <= 1 ? L10n.Tr("blame.date.month") : L10n.Tr("blame.date.months", months);
        var years = months / 12;
        return years <= 1 ? L10n.Tr("blame.date.year") : L10n.Tr("blame.date.years", years);
    }

    // MARK: - 悬停弹窗

    /// 行内文字的起点（编辑器像素坐标）：Scintilla 在行尾之后空出一个平均字符宽度再绘制。
    private int InlineBlameStartX(int line)
    {
        var editor = _control.Editor;
        return editor.PointXFromPosition(editor.GetLineEndPosition(line)) + editor.TextWidth(StyleInlineBlame, " ");
    }

    /// `point` 为相对编辑器控件的逻辑坐标；判断是否落在行内提交信息的文字上（不含前面的空隙）。
    private bool IsOverInlineBlame(Windows.Foundation.Point point)
    {
        if (!_ready || _inlineLine < 0 || _inlineText is not { } text) return false;
        var editor = _control.Editor;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var x = point.X * scale;
        var y = point.Y * scale;
        var top = editor.PointYFromPosition(editor.PositionFromLine(_inlineLine));
        if (y < top || y >= top + editor.TextHeight(_inlineLine)) return false;
        var start = InlineBlameStartX(_inlineLine);
        var textStart = start + editor.TextWidth(StyleInlineBlame, InlineBlameGap);
        var end = start + editor.TextWidth(StyleInlineBlame, text);
        return x >= textStart && x <= end;
    }

    private void InlineBlamePointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_inlineLine < 0) return;
        _blamePointer = e.GetCurrentPoint(_control).Position;
        var over = IsOverInlineBlame(_blamePointer);
        if (_blamePopup is { IsOpen: true })
        {
            if (over) _blameHideTimer?.Stop();
            else if (!_pointerInPopup) _blameHideTimer?.Start();
            return;
        }
        if (over)
        {
            if (_blameShowTimer is { IsEnabled: false } timer) timer.Start();
        }
        else
        {
            _blameShowTimer?.Stop();
        }
    }

    private void InlineBlamePointerLeft()
    {
        _blameShowTimer?.Stop();
        if (_blamePopup is { IsOpen: true } && !_pointerInPopup) _blameHideTimer?.Start();
    }

    private void HideInlineBlamePopup()
    {
        _blameShowTimer?.Stop();
        _blameHideTimer?.Stop();
        _pointerInPopup = false;
        _blamePopupLine = -1;
        if (_blamePopup is { } popup) popup.IsOpen = false;
    }

    private void ShowInlineBlamePopup()
    {
        if (!_ready || _inlineLine < 0 || XamlRoot is null) return;
        var line = _inlineLine;
        var (commit, _) = InlineBlameCommit(line);
        var editor = _control.Editor;
        var scale = XamlRoot.RasterizationScale;

        var content = BuildBlamePopupContent(commit);
        var border = new Border
        {
            Child = UiFont.Host(content),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            MaxWidth = 520,
            RequestedTheme = ActualTheme,
        };
        Themed.Background(border, "ToolWindowBackgroundBrush");
        Themed.Brush(border, "SeparatorBrush", (b, brush) => b.BorderBrush = brush);
        border.PointerEntered += (_, _) =>
        {
            _pointerInPopup = true;
            _blameHideTimer?.Stop();
        };
        border.PointerExited += (_, _) =>
        {
            _pointerInPopup = false;
            _blameHideTimer?.Start();
        };

        _blamePopup ??= new Popup { ShouldConstrainToRootBounds = true };
        _blamePopup.XamlRoot = XamlRoot;
        _blamePopup.Child = border;
        var (messageBlock, scroller) = content.Tag is (TextBlock m, ScrollViewer v) ? (m, v) : ((TextBlock?)null, (ScrollViewer?)null);
        PlaceBlamePopup(border, scroller, line);
        _blamePopupLine = line;
        _blamePopup.IsOpen = true;

        if (commit is { IsUncommitted: false } && CommitDetailsProvider is { } provider)
        {
            var hash = commit.Hash;
            Task.Run(() =>
            {
                try
                {
                    return provider(hash);
                }
                catch (CoreException)
                {
                    return null;
                }
            }).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
            {
                if (task.Result is not { } details || messageBlock is null || _blamePopupLine != line) return;
                messageBlock.Text = details.Message.TrimEnd();
                // 完整说明可能更长：重新选择上方或下方并限制高度。
                PlaceBlamePopup(border, scroller, line);
            }), TaskScheduler.Default);
        }
    }

    /// 提交说明区域的最大高度，超出时显示滚动条。
    private const double BlameMessageMaxHeight = 360;

    /// 放置弹窗：左端与行内文字对齐，紧贴该行（鼠标可以直接移进弹窗）。下方放得下时放在下方，否则放在上方；
    /// 两侧都放不下时放在空间较大的一侧，并压缩提交说明区域的高度（可滚动），使弹窗完整显示在窗口内。
    private void PlaceBlamePopup(Border border, ScrollViewer? scroller, int line)
    {
        if (_blamePopup is not { } popup || XamlRoot is null) return;
        var editor = _control.Editor;
        var scale = XamlRoot.RasterizationScale;
        var origin = _control.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
        var textStart = (InlineBlameStartX(line) + editor.TextWidth(StyleInlineBlame, InlineBlameGap)) / scale;
        var top = origin.Y + editor.PointYFromPosition(editor.PositionFromLine(line)) / scale;
        var bottom = top + editor.TextHeight(line) / scale;
        const double margin = 4;
        var rootWidth = XamlRoot.Size.Width;
        var spaceBelow = XamlRoot.Size.Height - margin - bottom;
        var spaceAbove = top - margin;

        if (scroller is not null) scroller.MaxHeight = BlameMessageMaxHeight;
        border.Measure(new Windows.Foundation.Size(border.MaxWidth, double.PositiveInfinity));
        var height = border.DesiredSize.Height;
        bool below;
        if (height <= spaceBelow) below = true;
        else if (height <= spaceAbove) below = false;
        else
        {
            below = spaceBelow >= spaceAbove;
            var space = Math.Max(below ? spaceBelow : spaceAbove, 0);
            if (scroller is not null)
            {
                scroller.MaxHeight = Math.Max(48, scroller.DesiredSize.Height - (height - space));
                border.Measure(new Windows.Foundation.Size(border.MaxWidth, double.PositiveInfinity));
                height = border.DesiredSize.Height;
            }
        }
        var width = border.DesiredSize.Width;
        popup.HorizontalOffset = Math.Clamp(origin.X + textStart, 0, Math.Max(0, rootWidth - width - margin));
        popup.VerticalOffset = below ? bottom : Math.Max(0, top - height);
    }

    /// 弹窗内容：作者与邮箱、相对时间与完整时间、提交说明，以及修订号与操作（在日志中显示、复制修订号）。
    private StackPanel BuildBlamePopupContent(BlameCommit? commit)
    {
        var panel = new StackPanel { Padding = new Thickness(14, 12, 14, 10), Spacing = 6 };
        if (commit is null || commit.IsUncommitted)
        {
            panel.Children.Add(Themed.Foreground(new TextBlock
            {
                Text = L10n.Tr("blame.inline.you"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            }, "PrimaryTextBrush"));
            panel.Children.Add(Themed.Foreground(new TextBlock
            {
                Text = L10n.Tr("blame.inline.uncommitted.detail"),
                TextWrapping = TextWrapping.Wrap,
            }, "SecondaryTextBrush"));
            return panel;
        }

        var author = new TextBlock { TextWrapping = TextWrapping.Wrap };
        author.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = commit.AuthorName, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (commit.AuthorEmail.Length > 0) author.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"  <{commit.AuthorEmail}>" });
        panel.Children.Add(Themed.Foreground(author, "PrimaryTextBrush"));
        panel.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = $"{RelativeDate(commit.AuthorTime)}  ({Git.LogDates.Detailed(commit.AuthorTime)})",
            TextWrapping = TextWrapping.Wrap,
        }, "SecondaryTextBrush"));

        // 先显示 blame 中的标题，读取到完整提交说明后替换。
        var message = Themed.Foreground(new TextBlock
        {
            Text = commit.Summary,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Margin = new Thickness(0, 4, 12, 4),
        }, "PrimaryTextBrush");
        // 提交说明过长时在固定高度内滚动（高度由 PlaceBlamePopup 按可用空间设置）。
        var scroller = new ScrollViewer
        {
            Content = message,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            MaxHeight = BlameMessageMaxHeight,
        };
        panel.Children.Add(scroller);
        panel.Tag = (message, scroller);

        panel.Children.Add(Themed.Background(new Border { Height = 1, Margin = new Thickness(0, 2, 0, 2) }, "SeparatorBrush"));
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var hash = commit.Hash;
        footer.Children.Add(Themed.Foreground(new TextBlock
        {
            Text = hash[..Math.Min(8, hash.Length)],
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        }, "SecondaryTextBrush"));
        var showInLog = new HyperlinkButton { Content = L10n.Tr("blame.inline.showInLog"), Padding = new Thickness(6, 2, 6, 2) };
        showInLog.Click += (_, _) =>
        {
            HideInlineBlamePopup();
            AnnotationClicked?.Invoke(hash);
        };
        var copy = new HyperlinkButton { Content = L10n.Tr("blame.inline.copyHash"), Padding = new Thickness(6, 2, 6, 2) };
        copy.Click += (_, _) =>
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(hash);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            HideInlineBlamePopup();
        };
        footer.Children.Add(showInLog);
        footer.Children.Add(copy);
        panel.Children.Add(footer);
        return panel;
    }

    /// 调试截图：把光标放到第 `line` 行，`popup` 为 true 时打开行内提交信息的弹窗。
    public void DebugShowInlineBlame(int line, bool popup)
    {
        if (!_ready) return;
        Reveal(line);
        UpdateInlineBlame(force: true);
        if (!popup) return;
        // 滚动会关闭弹窗：等 Reveal 引起的滚动处理完再打开。
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            ShowInlineBlamePopup();
        };
        timer.Start();
    }
}
