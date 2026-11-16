using System.Runtime.InteropServices.WindowsRuntime;
using GitDeck.Common;
using Microsoft.UI.Xaml.Automation;
using GitDeck.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace GitDeck.Editor;

/// 右侧概览样式：普通编辑器为完整文本缩略图，Diff / 合并为窄的变更着色条（VS Code 的 overview ruler）。
public enum MinimapStyle
{
    /// VS Code 的 minimap：按字符绘制全文，带视口滑块。
    Document,
    /// VS Code 的 overview ruler：只在变更处着色，色块按滚动空间映射到滚动条轨道。
    Overview,
}

/// 编辑器右侧的文档缩略图或差异概览条。
///
/// 普通编辑器按字符绘制全文概览（并可叠上 git 行变更装饰）；Diff / 合并界面改为窄的 overview ruler，只在变动处着色。
public sealed class MinimapView : Grid
{
    public const double DocumentWidth = 90;
    public const double OverviewWidth = 12;
    public const double WidthPx = DocumentWidth;
    private const double MinLineHeight = 2;
    private const double MaxLineHeight = 4;
    private const double CharWidth = 1;
    private const double PadPx = 2;

    public static double WidthFor(MinimapStyle style) => style == MinimapStyle.Overview ? OverviewWidth : DocumentWidth;
    public double LaneWidth => WidthFor(LaneStyle);

    private readonly Image _image = new() { Stretch = Stretch.Fill, IsHitTestVisible = false };
    private readonly Rectangle _slider = new() { IsHitTestVisible = false, StrokeThickness = 1 };
    private readonly Rectangle _border = new() { Width = 1, HorizontalAlignment = HorizontalAlignment.Left, IsHitTestVisible = false };

    private CodeEditor? _editor;
    private Content? _content;
    private double _lineHeight = 2;
    private double _contentOffset;
    private double _trackTop;
    private double _trackHeight = 1;
    private double _scrollHeightLines = 1;
    private double _viewportLines = 1;
    private int _generation;
    private CancellationTokenSource? _rebuild;
    private bool _dragging;
    private double _dragLineOffset;
    private bool _pointerHooked;
    private MinimapStyle _style = MinimapStyle.Document;

    public MinimapStyle LaneStyle
    {
        get => _style;
        set
        {
            if (_style == value) return;
            _style = value;
            ApplyLaneWidth();
            ApplyAccessibility();
            _contentOffset = 0;
            InvalidateContent();
        }
    }

    public MinimapView()
    {
        ApplyLaneWidth();
        Children.Add(_image);
        Children.Add(_slider);
        Children.Add(_border);
        Themed.Background(this, "EditorBackgroundBrush");
        Themed.Brush(_border, "SeparatorBrush", (e, b) => e.Fill = b);
        SizeChanged += (_, _) => RefreshViewport();
        ActualThemeChanged += (_, _) => InvalidateContent();
        Loaded += (_, _) =>
        {
            if (_pointerHooked) return;
            _pointerHooked = true;
            PointerPressed += OnPressed;
            PointerMoved += OnMoved;
            PointerReleased += OnReleased;
            PointerCaptureLost += (_, _) => _dragging = false;
        };
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        ApplyAccessibility();
    }

    private void ApplyLaneWidth()
    {
        var width = LaneWidth;
        Width = width;
        MinWidth = width;
        MaxWidth = width;
    }

    private void ApplyAccessibility()
    {
        if (LaneStyle == MinimapStyle.Overview)
        {
            AutomationProperties.SetName(this, L10n.Tr("editor.minimap.overview"));
            ToolTipService.SetToolTip(this, L10n.Tr("editor.minimap.overview.tooltip"));
        }
        else
        {
            AutomationProperties.SetName(this, L10n.Tr("editor.minimap"));
            ToolTipService.SetToolTip(this, L10n.Tr("editor.minimap.tooltip"));
        }
    }

    public void Attach(CodeEditor editor)
    {
        _editor = editor;
        InvalidateContent();
    }

    /// 文本、高亮或装饰变化后重建内容。
    public void InvalidateContent()
    {
        _generation++;
        ScheduleRebuild();
    }

    /// 编辑器滚动或尺寸变化后更新视口矩形。
    public void RefreshViewport()
    {
        UpdateMetrics();
        RelayoutOffset();
        LayoutSlider();
        // 内容已按当前偏移绘制时不必重建位图；偏移变化则重画可见片段。
        if (_content is not null) ScheduleSlice();
    }

    private void ScheduleRebuild()
    {
        _rebuild?.Cancel();
        var editor = _editor;
        if (editor is null)
        {
            _content = null;
            _image.Source = null;
            _slider.Visibility = Visibility.Collapsed;
            return;
        }
        var expected = _generation;
        var cancel = _rebuild = new CancellationTokenSource();
        var text = editor.Text;
        var spans = editor.MinimapSpans;
        var changes = editor.LineChanges;
        var diffLines = editor.MinimapDiffLines;
        var dark = ActualTheme == ElementTheme.Dark;
        var colors = ColorTable.Resolve(dark, LaneStyle == MinimapStyle.Overview);
        _ = Task.Run(() =>
        {
            var built = Content.Build(text, spans, changes, diffLines, colors, includeText: LaneStyle == MinimapStyle.Document);
            if (cancel.IsCancellationRequested) return;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (cancel.IsCancellationRequested || _generation != expected) return;
                _content = built;
                UpdateMetrics();
                RelayoutOffset();
                RenderSlice();
                LayoutSlider();
            });
        }, cancel.Token);
    }

    private double _renderedOffset = double.NaN;
    private double _renderedWidth;
    private double _renderedHeight;
    private double _renderedTrackTop = double.NaN;
    private double _renderedTrackHeight = double.NaN;
    private double _renderedScrollHeight = double.NaN;

    private void ScheduleSlice()
    {
        if (_content is null) return;
        var metricsChanged = LaneStyle == MinimapStyle.Overview
            && (_trackTop != _renderedTrackTop || _trackHeight != _renderedTrackHeight || _scrollHeightLines != _renderedScrollHeight);
        if (_contentOffset != _renderedOffset || ActualWidth != _renderedWidth || ActualHeight != _renderedHeight || metricsChanged)
            RenderSlice();
        LayoutSlider();
    }

    private void UpdateMetrics()
    {
        var lines = Math.Max(_content?.LineCount ?? _editor?.LineCount ?? 1, 1);
        var fitted = ActualHeight > 0 ? ActualHeight / lines : MinLineHeight;
        if (LaneStyle == MinimapStyle.Overview)
        {
            // 与原生滚动条同一坐标系：y = line / scrollHeight * trackHeight。
            var metrics = _editor?.MinimapOverviewMetrics
                ?? new CodeEditor.OverviewScrollMetrics(0, Math.Max(ActualHeight, 1), lines, 1, fitted);
            _trackTop = metrics.TrackTop;
            _trackHeight = Math.Max(metrics.TrackHeight, 1);
            _scrollHeightLines = Math.Max(metrics.ScrollHeightLines, 1);
            _viewportLines = Math.Max(metrics.ViewportLines, 1);
            _lineHeight = _trackHeight / _scrollHeightLines;
            return;
        }
        _lineHeight = Math.Min(Math.Max(fitted, MinLineHeight), MaxLineHeight);
        _trackTop = 0;
        _trackHeight = Math.Max(ActualHeight, 1);
        _scrollHeightLines = lines;
        _viewportLines = 1;
    }

    private void RelayoutOffset()
    {
        if (LaneStyle == MinimapStyle.Overview)
        {
            _contentOffset = 0;
            return;
        }
        var contentHeight = (_content?.LineCount ?? 0) * _lineHeight;
        if (contentHeight <= ActualHeight || ActualHeight <= 0 || _editor is null)
        {
            _contentOffset = 0;
            return;
        }
        var top = _editor.MinimapTopVisibleLine;
        var visible = Math.Max(_editor.MinimapVisibleLineCount, 1);
        var maxEditor = Math.Max((_content?.LineCount ?? 0) - visible, 1);
        var maxOffset = contentHeight - ActualHeight;
        _contentOffset = Math.Clamp(top / maxEditor * maxOffset, 0, maxOffset);
    }

    private void LayoutSlider()
    {
        // 概览条只显示变更色块，视口由编辑器自身的滚动条表示。
        if (LaneStyle == MinimapStyle.Overview || _editor is null || _content is null || _lineHeight <= 0 || ActualHeight <= 0)
        {
            _slider.Visibility = Visibility.Collapsed;
            return;
        }
        var y = _editor.MinimapTopVisibleLine * _lineHeight - _contentOffset;
        var height = Math.Max(_editor.MinimapVisibleLineCount * _lineHeight, 4);
        _slider.Visibility = Visibility.Visible;
        _slider.HorizontalAlignment = HorizontalAlignment.Stretch;
        _slider.VerticalAlignment = VerticalAlignment.Top;
        _slider.Margin = new Thickness(0, y, 0, 0);
        _slider.Height = height;
        var dark = ActualTheme == ElementTheme.Dark;
        _slider.Fill = new SolidColorBrush(MinimapColors.Slider(dark));
        _slider.Stroke = new SolidColorBrush(MinimapColors.SliderBorder(dark));
    }

    private void RenderSlice()
    {
        if (_content is null || ActualWidth <= 0 || ActualHeight <= 0) return;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var width = Math.Max((int)Math.Round(ActualWidth * scale), 1);
        var height = Math.Max((int)Math.Round(ActualHeight * scale), 1);
        var pixels = new byte[width * height * 4];
        var background = _content.Colors.Background;
        Fill(pixels, width, height, 0, 0, width, height, background);

        if (LaneStyle == MinimapStyle.Overview)
        {
            PaintOverviewDecorations(pixels, width, height, scale);
            var overviewBitmap = new WriteableBitmap(width, height);
            using (var stream = overviewBitmap.PixelBuffer.AsStream())
            {
                stream.Write(pixels, 0, pixels.Length);
            }
            overviewBitmap.Invalidate();
            _image.Source = overviewBitmap;
            _renderedOffset = _contentOffset;
            _renderedWidth = ActualWidth;
            _renderedHeight = ActualHeight;
            _renderedTrackTop = _trackTop;
            _renderedTrackHeight = _trackHeight;
            _renderedScrollHeight = _scrollHeightLines;
            return;
        }

        var linePx = Math.Max(_lineHeight * scale, 1);
        var offsetPx = _contentOffset * scale;
        var first = Math.Max((int)Math.Floor(_contentOffset / _lineHeight), 0);
        var last = Math.Min(_content.LineCount, (int)Math.Ceiling((_contentOffset + ActualHeight) / _lineHeight) + 1);

        var minH = Math.Max((int)Math.Round(2 * scale), 2);
        foreach (var decoration in _content.Decorations)
        {
            if (decoration.Count == 0)
            {
                var y = (int)Math.Round(decoration.Start * _lineHeight * scale - offsetPx);
                Fill(pixels, width, height, 0, y, width, minH, decoration.Color);
                continue;
            }
            var top = (int)Math.Round(decoration.Start * _lineHeight * scale - offsetPx);
            var h = Math.Max((int)Math.Round(decoration.Count * _lineHeight * scale), minH);
            Fill(pixels, width, height, 0, top, width, h, decoration.Color);
        }

        var pad = (int)Math.Round(PadPx * scale);
        var charW = Math.Max((int)Math.Round(CharWidth * scale), 1);
        var gap = Math.Max((int)Math.Round(linePx * 0.25), 1);
        var charH = Math.Max((int)Math.Round(linePx) - gap, 1);
        var maxColumns = Math.Max((width - pad * 2) / charW, 1);
        for (var index = first; index < last; index++)
        {
            var y = (int)Math.Round(index * _lineHeight * scale - offsetPx);
            if (y + charH < 0 || y >= height) continue;
            foreach (var run in _content.Lines[index].Runs)
            {
                if (run.Column >= maxColumns) break;
                var cols = Math.Min(run.Width, maxColumns - run.Column);
                if (cols <= 0) continue;
                var x = pad + run.Column * charW;
                Fill(pixels, width, height, x, y, cols * charW, charH, run.Color);
            }
        }

        _renderedOffset = _contentOffset;
        _renderedWidth = ActualWidth;
        _renderedHeight = ActualHeight;
        var bitmap = new WriteableBitmap(width, height);
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            stream.Write(pixels, 0, pixels.Length);
        }
        bitmap.Invalidate();
        _image.Source = bitmap;
    }

    /// 按 VS Code overview ruler 公式绘制：y = verticalOffset / scrollHeight * trackHeight。
    /// 最短色块为 6 设备像素，过小时居中并夹紧到轨道内。
    private void PaintOverviewDecorations(byte[] pixels, int width, int height, double scale)
    {
        if (_content is null || _scrollHeightLines <= 0 || _trackHeight <= 0) return;
        var trackTopPx = _trackTop * scale;
        var trackHeightPx = Math.Max(_trackHeight * scale, 1);
        var heightRatio = trackHeightPx / _scrollHeightLines;
        const int minDecorationHeight = 6;
        var canvasBottom = height;
        foreach (var decoration in _content.Decorations)
        {
            var start = decoration.Start;
            var end = decoration.Count <= 0 ? start : start + decoration.Count;
            var y1 = trackTopPx + start * heightRatio;
            var y2 = trackTopPx + end * heightRatio;
            if (decoration.Count <= 0 || y2 - y1 < minDecorationHeight)
            {
                var mid = decoration.Count <= 0 ? y1 : (y1 + y2) / 2;
                y1 = mid - minDecorationHeight / 2.0;
                y2 = y1 + minDecorationHeight;
            }
            var top = (int)Math.Round(y1);
            var bottom = (int)Math.Round(y2);
            if (bottom <= top) bottom = top + minDecorationHeight;
            var trackStart = (int)Math.Round(trackTopPx);
            var trackEnd = (int)Math.Round(trackTopPx + trackHeightPx);
            if (trackEnd <= trackStart) trackEnd = trackStart + 1;
            top = Math.Clamp(top, trackStart, trackEnd);
            bottom = Math.Clamp(bottom, trackStart, trackEnd);
            if (bottom <= top) continue;
            top = Math.Clamp(top, 0, canvasBottom);
            bottom = Math.Clamp(bottom, 0, canvasBottom);
            if (bottom <= top) continue;
            Fill(pixels, width, height, 0, top, width, bottom - top, decoration.Color);
        }
    }

    private static void Fill(byte[] pixels, int width, int height, int x, int y, int w, int h, uint color)
    {
        var x0 = Math.Max(x, 0);
        var y0 = Math.Max(y, 0);
        var x1 = Math.Min(x + w, width);
        var y1 = Math.Min(y + h, height);
        if (x0 >= x1 || y0 >= y1) return;
        var b = (byte)(color & 0xFF);
        var g = (byte)((color >> 8) & 0xFF);
        var r = (byte)((color >> 16) & 0xFF);
        var a = (byte)((color >> 24) & 0xFF);
        if (a == 255)
        {
            for (var row = y0; row < y1; row++)
            {
                var i = (row * width + x0) * 4;
                for (var col = x0; col < x1; col++)
                {
                    pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = 255;
                    i += 4;
                }
            }
            return;
        }
        var fa = a / 255f;
        var ia = 1 - fa;
        var fb = b * fa;
        var fg = g * fa;
        var fr = r * fa;
        for (var row = y0; row < y1; row++)
        {
            var i = (row * width + x0) * 4;
            for (var col = x0; col < x1; col++)
            {
                pixels[i] = (byte)(fb + pixels[i] * ia);
                pixels[i + 1] = (byte)(fg + pixels[i + 1] * ia);
                pixels[i + 2] = (byte)(fr + pixels[i + 2] * ia);
                pixels[i + 3] = 255;
                i += 4;
            }
        }
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_editor is null) return;
        if (LaneStyle == MinimapStyle.Overview)
        {
            if (_scrollHeightLines <= 0 || _trackHeight <= 0) return;
        }
        else if (_lineHeight <= 0) return;
        var point = e.GetCurrentPoint(this).Position;
        var line = DocumentLine(point.Y);
        if (LaneStyle == MinimapStyle.Overview)
        {
            _dragLineOffset = Math.Max(_viewportLines, 1) / 2;
            _editor.MinimapScrollToLine(Math.Max(0, line - _dragLineOffset));
            _dragging = true;
            CapturePointer(e.Pointer);
            e.Handled = true;
            return;
        }
        if (InSlider(point.Y))
        {
            _dragLineOffset = line - _editor.MinimapTopVisibleLine;
        }
        else
        {
            _dragLineOffset = Math.Max(_editor.MinimapVisibleLineCount, 1) / 2;
            _editor.MinimapScrollToLine(Math.Max(0, line - _dragLineOffset));
        }
        _dragging = true;
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _editor is null) return;
        var line = DocumentLine(e.GetCurrentPoint(this).Position.Y);
        _editor.MinimapScrollToLine(Math.Max(0, line - _dragLineOffset));
        e.Handled = true;
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private double DocumentLine(double y)
    {
        if (LaneStyle == MinimapStyle.Overview)
            return _scrollHeightLines <= 0 || _trackHeight <= 0 ? 0 : (y - _trackTop) / _trackHeight * _scrollHeightLines;
        return _lineHeight <= 0 ? 0 : (_contentOffset + y) / _lineHeight;
    }

    private bool InSlider(double y)
    {
        if (_editor is null) return false;
        var top = _editor.MinimapTopVisibleLine * _lineHeight - _contentOffset;
        var height = Math.Max(_editor.MinimapVisibleLineCount * _lineHeight, 4);
        return y >= top && y <= top + height;
    }

    private readonly record struct ColorTable(
        uint Background,
        uint Text,
        uint Added,
        uint Deleted,
        uint Modified,
        uint Conflict,
        IReadOnlyDictionary<TokenKind, uint> Tokens)
    {
        public uint Token(TokenKind kind) => Tokens.TryGetValue(kind, out var color) ? color : Text;

        public uint Decoration(LineChangeKind? kind) => kind switch
        {
            LineChangeKind.Added => Added,
            LineChangeKind.Deleted => Deleted,
            LineChangeKind.Modified => Modified,
            _ => Conflict,
        };

        public static ColorTable Resolve(bool dark, bool overview)
        {
            var tokens = new Dictionary<TokenKind, uint>();
            foreach (var kind in Enum.GetValues<TokenKind>()) tokens[kind] = Pack(SyntaxTheme.Token(kind, dark));
            // 概览条没有文字叠在上面，色块用更高不透明度，接近 VS Code 的 diff overview。
            return new ColorTable(
                Pack(SyntaxTheme.Background(dark)),
                Pack(SyntaxTheme.Text(dark)),
                Pack(MinimapColors.Added(dark), overview ? 0.9 : 0.55),
                Pack(MinimapColors.Deleted(dark), overview ? 0.95 : 0.7),
                Pack(MinimapColors.Modified(dark), overview ? 0.85 : 0.45),
                Pack(MinimapColors.Conflict(dark), overview ? 0.9 : 0.55),
                tokens);
        }

        private static uint Pack(Color color, double alpha = 1)
        {
            var a = (byte)Math.Clamp(Math.Round(color.A * alpha), 0, 255);
            return (uint)(a << 24 | color.R << 16 | color.G << 8 | color.B);
        }
    }

    private sealed class Content
    {
        public required int LineCount { get; init; }
        public required Line[] Lines { get; init; }
        public required Decoration[] Decorations { get; init; }
        public required ColorTable Colors { get; init; }

        public readonly record struct Run(int Column, int Width, uint Color);
        public readonly record struct Line(Run[] Runs);
        public readonly record struct Decoration(int Start, int Count, uint Color);

        public static Content Build(
            string text,
            IReadOnlyList<HighlightSpan> spans,
            IReadOnlyList<LineChange> changes,
            IReadOnlyList<CodeEditor.DiffLine> diffLines,
            ColorTable colors,
            bool includeText)
        {
            var lines = new List<Line>();
            var runs = new List<Run>();
            var column = 0;
            var index = 0;
            var spanIndex = 0;
            var sorted = spans.OrderBy(s => s.Start).ToArray();

            uint CurrentColor()
            {
                while (spanIndex < sorted.Length && sorted[spanIndex].End <= index) spanIndex++;
                if (spanIndex < sorted.Length && sorted[spanIndex].Start <= index) return colors.Token(sorted[spanIndex].Kind);
                return colors.Text;
            }

            void Flush()
            {
                lines.Add(new Line(runs.ToArray()));
                runs.Clear();
                column = 0;
            }

            while (index < text.Length)
            {
                var c = text[index];
                if (c == '\r')
                {
                    if (index + 1 < text.Length && text[index + 1] == '\n') index++;
                    Flush();
                    index++;
                    continue;
                }
                if (c == '\n')
                {
                    Flush();
                    index++;
                    continue;
                }
                if (c == '\t')
                {
                    column = (column / 4 + 1) * 4;
                    index++;
                    continue;
                }
                var isSpace = c == ' ' || c == '\u00A0';
                var advance = char.IsHighSurrogate(c) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]) ? 2 : 1;
                if (includeText && !isSpace)
                {
                    var color = CurrentColor();
                    if (runs.Count > 0)
                    {
                        var last = runs[^1];
                        if (last.Color == color && last.Column + last.Width == column)
                        {
                            runs[^1] = last with { Width = last.Width + 1 };
                        }
                        else runs.Add(new Run(column, 1, color));
                    }
                    else runs.Add(new Run(column, 1, color));
                }
                column++;
                index += advance;
            }
            if (runs.Count > 0 || lines.Count == 0 || text.EndsWith('\n')) Flush();
            if (lines.Count == 0) lines.Add(new Line([]));

            var decorations = new List<Decoration>();
            if (diffLines.Count > 0)
            {
                foreach (var line in diffLines)
                {
                    if (line.Separator)
                    {
                        decorations.Add(new Decoration(line.Line + 1, 0, colors.Decoration(line.Conflict ? null : line.Kind)));
                    }
                    else
                    {
                        decorations.Add(new Decoration(line.Line, 1, colors.Decoration(line.Conflict ? null : line.Kind)));
                    }
                }
            }
            else
            {
                foreach (var change in changes)
                {
                    decorations.Add(new Decoration((int)change.Start, (int)change.Count, colors.Decoration(change.Kind)));
                }
            }

            return new Content
            {
                LineCount = lines.Count,
                Lines = lines.ToArray(),
                Decorations = decorations.ToArray(),
                Colors = colors,
            };
        }
    }
}

/// 缩略图中的 git 装饰配色：新增为绿色、删除为品红（对齐 VS Code 参考截图），修改为蓝色、冲突为红色。
internal static class MinimapColors
{
    public static Color Added(bool dark) => SyntaxTheme.Rgb(dark ? 0x3F7A45u : 0x7CB87Au);
    public static Color Deleted(bool dark) => SyntaxTheme.Rgb(dark ? 0xC45C80u : 0xE08AAAu);
    public static Color Modified(bool dark) => SyntaxTheme.Rgb(dark ? 0x3A5A8Cu : 0x8AA6E0u);
    public static Color Conflict(bool dark) => SyntaxTheme.Rgb(dark ? 0xB34A4Au : 0xE57373u);
    public static Color Slider(bool dark) => Color.FromArgb(0x47, 0x8A, 0x90, 0x9A);
    public static Color SliderBorder(bool dark) => Color.FromArgb(0x73, dark ? (byte)0xA0 : (byte)0x6A, dark ? (byte)0xA6 : (byte)0x70, dark ? (byte)0xB0 : (byte)0x80);
}
