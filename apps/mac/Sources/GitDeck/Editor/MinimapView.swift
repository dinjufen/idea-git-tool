import AppKit
import GitDeckCore

/// Diff / 合并界面中按行着色的缩略图装饰。
///
/// `kind == nil` 表示冲突；`count == 0` 时在 `start` 行位置画一条删除标记。
struct MinimapDiffHighlight: Sendable {
    var start: Int
    var count: Int
    var kind: LineChangeKind?
}

/// 缩略图向编辑器读取文档与滚动状态。
@MainActor
protocol MinimapDataSource: AnyObject {
    var minimapText: String { get }
    var minimapSpans: [HighlightSpan] { get }
    var minimapLineChanges: [LineChange] { get }
    var minimapDiffHighlights: [MinimapDiffHighlight] { get }
    var minimapTopVisibleLine: Double { get }
    var minimapVisibleLineCount: Double { get }
    var minimapLineCount: Int { get }
    /// 与原生滚动条同一坐标系的文档滚动空间高度（点）。
    var minimapScrollHeight: CGFloat { get }
    /// 第 `line` 行顶部在滚动空间中的垂直偏移（点）。
    func minimapVerticalOffset(forLine line: Int) -> CGFloat
    /// 滚动空间中的垂直偏移对应的文档行（可带小数）。
    func minimapLine(atVerticalOffset offset: CGFloat) -> Double
    /// 概览条应对齐的滚动条轨道（相对缩略图视图）；`nil` 表示铺满自身高度。
    var minimapOverviewTrack: (y: CGFloat, height: CGFloat)? { get }
    func minimapScroll(toLine line: Double)
}

extension MinimapDataSource {
    var minimapScrollHeight: CGFloat { CGFloat(max(minimapLineCount, 1)) }
    func minimapVerticalOffset(forLine line: Int) -> CGFloat { CGFloat(max(line, 0)) }
    func minimapLine(atVerticalOffset offset: CGFloat) -> Double {
        let height = max(minimapScrollHeight, 1)
        return Double(offset / height * CGFloat(max(minimapLineCount, 1)))
    }
    var minimapOverviewTrack: (y: CGFloat, height: CGFloat)? { nil }
}

/// 右侧概览样式：普通编辑器为完整文本缩略图，Diff / 合并为窄的变更着色条（VS Code 的 overview ruler）。
enum MinimapStyle {
    /// VS Code 的 minimap：按字符绘制全文，带视口滑块。
    case document
    /// VS Code 的 overview ruler：只在变更处着色，色块按滚动空间映射到滚动条轨道。
    case overview

    var width: CGFloat {
        switch self {
        case .document: 90
        case .overview: 12
        }
    }
}

/// 编辑器右侧的文档缩略图或差异概览条。
///
/// 普通编辑器按字符绘制全文概览（并可叠上 git 行变更装饰）；Diff / 合并界面改为窄的 overview ruler，只在变动处着色。
final class MinimapView: NSView {
    private static let minLineHeight: CGFloat = 2
    private static let maxLineHeight: CGFloat = 4
    private static let charWidth: CGFloat = 1
    private static let padding: CGFloat = 2
    private static let tabColumns = 4

    weak var dataSource: MinimapDataSource?

    /// 完整文本缩略图或窄的差异概览条。
    var style: MinimapStyle = .document {
        didSet {
            guard style != oldValue else { return }
            widthConstraint.constant = style.width
            invalidateIntrinsicContentSize()
            applyAccessibility()
            contentOffset = 0
            cache = nil
            invalidateContent()
        }
    }

    private var content: Content?
    private var cache: CGImage?
    private var cacheScale: CGFloat = 1
    private var cacheOffset: CGFloat = -1
    private var cacheSize: CGSize = .zero
    private var lineHeight: CGFloat = 2
    private var contentOffset: CGFloat = 0
    private var trackTop: CGFloat = 0
    private var trackHeight: CGFloat = 1
    private var scrollHeight: CGFloat = 1
    private var generation = 0
    private var rebuildTask: Task<Void, Never>?
    private var isDragging = false
    /// 拖动时指针在视口矩形内的偏移（文档行）。
    private var dragLineOffset: Double = 0
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: MinimapStyle.document.width)
        widthConstraint.isActive = true
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        applyAccessibility()
    }

    private func applyAccessibility() {
        switch style {
        case .document:
            setAccessibilityLabel(tr("editor.minimap"))
            toolTip = tr("editor.minimap.tooltip")
        case .overview:
            setAccessibilityLabel(tr("editor.minimap.overview"))
            toolTip = tr("editor.minimap.overview.tooltip")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: style.width, height: NSView.noIntrinsicMetric) }

    /// 文本、高亮或装饰变化后重建内容（滚动只需调用 `invalidateViewport`）。
    func invalidateContent() {
        generation += 1
        scheduleRebuild()
    }

    /// 编辑器滚动或尺寸变化后更新视口矩形。
    func invalidateViewport() {
        updateMetrics()
        let offsetChanged = relayoutOffset()
        if offsetChanged {
            cache = nil
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateContent()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { invalidateViewport(); if cacheSize != newSize { cache = nil; needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        updateMetrics()
        let bg = resolved(Theme.editorBackground)
        bg.setFill()
        bounds.fill()

        if cache == nil || cacheSize != bounds.size || cacheOffset != contentOffset || cacheScale != backingScale
            || cachedTrackTop != trackTop || cachedTrackHeight != trackHeight || cachedScrollHeight != scrollHeight {
            rebuildCache()
        }
        if let cache {
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cache, in: bounds)
            ctx.restoreGState()
        }

        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        // 概览条只显示变更色块，视口由编辑器自身的滚动条表示（对齐 VS Code 的 overview ruler）。
        guard style == .document, let source = dataSource, let content, content.lineCount > 0, lineHeight > 0 else { return }
        let top = source.minimapTopVisibleLine
        let visible = max(source.minimapVisibleLineCount, 1)
        let y = CGFloat(top) * lineHeight - contentOffset
        let height = max(CGFloat(visible) * lineHeight, 4)
        var slider = NSRect(x: 0, y: y, width: bounds.width, height: height)
        slider = slider.intersection(NSRect(x: 0, y: -2, width: bounds.width, height: bounds.height + 4))
        guard !slider.isNull, slider.height > 0 else { return }
        MinimapColors.slider.setFill()
        slider.fill()
        MinimapColors.sliderBorder.setStroke()
        let path = NSBezierPath(rect: slider.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        guard dataSource != nil else { return }
        if style == .overview {
            guard scrollHeight > 0, trackHeight > 0 else { return }
        } else {
            guard lineHeight > 0 else { return }
        }
        let point = convert(event.locationInWindow, from: nil)
        let line = documentLine(atY: point.y)
        if style == .overview {
            let visible = dataSource?.minimapVisibleLineCount ?? 1
            dragLineOffset = visible / 2
            dataSource?.minimapScroll(toLine: max(0, line - dragLineOffset))
            isDragging = true
            return
        }
        if sliderRect().contains(point) {
            dragLineOffset = line - (dataSource?.minimapTopVisibleLine ?? 0)
        } else {
            let visible = dataSource?.minimapVisibleLineCount ?? 1
            dragLineOffset = visible / 2
            dataSource?.minimapScroll(toLine: max(0, line - dragLineOffset))
        }
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let line = documentLine(atY: point.y)
        dataSource?.minimapScroll(toLine: max(0, line - dragLineOffset))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - 内容构建

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        let expected = generation
        let source = dataSource
        let text = source?.minimapText ?? ""
        let spans = source?.minimapSpans ?? []
        let changes = source?.minimapLineChanges ?? []
        let highlights = source?.minimapDiffHighlights ?? []
        let includeText = style == .document
        let colors = resolvedColors()
        rebuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let built = Content.build(text: text, spans: spans, changes: changes, highlights: highlights, colors: colors, includeText: includeText)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == expected else { return }
                self.content = built
                self.cache = nil
                self.updateMetrics()
                _ = self.relayoutOffset()
                self.needsDisplay = true
            }
        }
    }

    private func updateMetrics() {
        let lines = max(content?.lineCount ?? dataSource?.minimapLineCount ?? 1, 1)
        let fitted = bounds.height > 0 ? bounds.height / CGFloat(lines) : Self.minLineHeight
        if style == .overview, let source = dataSource {
            // 与原生滚动条同一坐标系：y = verticalOffset / scrollHeight * trackHeight。
            let track = source.minimapOverviewTrack
            trackTop = track?.y ?? 0
            trackHeight = max(track?.height ?? bounds.height, 1)
            scrollHeight = max(source.minimapScrollHeight, 1)
            lineHeight = trackHeight / scrollHeight
        } else {
            lineHeight = min(max(fitted, Self.minLineHeight), Self.maxLineHeight)
            trackTop = 0
            trackHeight = max(bounds.height, 1)
            scrollHeight = CGFloat(lines) * lineHeight
        }
    }

    /// 文档高于缩略图时，按编辑器滚动比例平移缩略图，使视口矩形保持可见。返回偏移是否变化。
    @discardableResult
    private func relayoutOffset() -> Bool {
        let old = contentOffset
        if style == .overview {
            contentOffset = 0
            return old != 0
        }
        let contentHeight = CGFloat(content?.lineCount ?? 0) * lineHeight
        let viewHeight = bounds.height
        guard contentHeight > viewHeight, viewHeight > 0, let source = dataSource else {
            contentOffset = 0
            return old != 0
        }
        let top = source.minimapTopVisibleLine
        let visible = max(source.minimapVisibleLineCount, 1)
        let maxEditor = max(CGFloat(content?.lineCount ?? 0) - CGFloat(visible), 1)
        let maxOffset = contentHeight - viewHeight
        contentOffset = min(max(CGFloat(top) / maxEditor * maxOffset, 0), maxOffset)
        return old != contentOffset
    }

    private func documentLine(atY y: CGFloat) -> Double {
        if style == .overview, let source = dataSource {
            guard trackHeight > 0, scrollHeight > 0 else { return 0 }
            let offset = (y - trackTop) / trackHeight * scrollHeight
            return source.minimapLine(atVerticalOffset: offset)
        }
        guard lineHeight > 0 else { return 0 }
        return Double((contentOffset + y) / lineHeight)
    }

    private func sliderRect() -> NSRect {
        guard let source = dataSource, lineHeight > 0 else { return .zero }
        let y = CGFloat(source.minimapTopVisibleLine) * lineHeight - contentOffset
        let height = max(CGFloat(source.minimapVisibleLineCount) * lineHeight, 4)
        return NSRect(x: 0, y: y, width: bounds.width, height: height)
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var cachedTrackTop: CGFloat = 0
    private var cachedTrackHeight: CGFloat = 0
    private var cachedScrollHeight: CGFloat = 0

    private func rebuildCache() {
        cacheSize = bounds.size
        cacheOffset = contentOffset
        cacheScale = backingScale
        cachedTrackTop = trackTop
        cachedTrackHeight = trackHeight
        cachedScrollHeight = scrollHeight
        cache = nil
        guard bounds.width > 0, bounds.height > 0, let content else { return }

        let scale = cacheScale
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let background = content.colors.background
        fill(pixels: &pixels, width: width, height: height, x: 0, y: 0, w: width, h: height, color: background)

        let linePx = max(lineHeight * scale, 1)
        let offsetPx = contentOffset * scale
        let first = max(Int((contentOffset / lineHeight).rounded(.down)), 0)
        let last = min(content.lineCount, Int(ceil((contentOffset + bounds.height) / lineHeight)) + 1)
        guard first < last else {
            cache = image(from: pixels, width: width, height: height)
            return
        }

        if style == .overview, let source = dataSource {
            paintOverviewDecorations(pixels: &pixels, width: width, height: height, scale: scale, source: source, content: content)
            cache = image(from: pixels, width: width, height: height)
            return
        }

        // 先画装饰背景，再画字符像素。
        for decoration in content.decorations {
            let start = decoration.start
            let minH = max(Int((2 * scale).rounded()), 2)
            if decoration.count == 0 {
                let y = Int((CGFloat(start) * lineHeight * scale - offsetPx).rounded())
                fill(pixels: &pixels, width: width, height: height, x: 0, y: y, w: width, h: minH, color: decoration.color)
                continue
            }
            let y = Int((CGFloat(start) * lineHeight * scale - offsetPx).rounded())
            let h = max(Int((CGFloat(decoration.count) * lineHeight * scale).rounded()), minH)
            fill(pixels: &pixels, width: width, height: height, x: 0, y: y, w: width, h: h, color: decoration.color)
        }

        guard style == .document else {
            cache = image(from: pixels, width: width, height: height)
            return
        }

        let pad = Int((Self.padding * scale).rounded())
        let charW = max(Int((Self.charWidth * scale).rounded()), 1)
        let gap = max(Int((linePx * 0.25).rounded()), 1)
        let charH = max(Int(linePx.rounded()) - gap, 1)
        let maxColumns = max((width - pad * 2) / charW, 1)

        for index in first ..< last {
            let y = Int((CGFloat(index) * lineHeight * scale - offsetPx).rounded())
            if y + charH < 0 || y >= height { continue }
            for run in content.lines[index].runs {
                if Int(run.column) >= maxColumns { break }
                let widthCols = min(Int(run.width), maxColumns - Int(run.column))
                guard widthCols > 0 else { continue }
                let x = pad + Int(run.column) * charW
                fill(pixels: &pixels, width: width, height: height, x: x, y: y, w: widthCols * charW, h: charH, color: run.color)
            }
        }

        cache = image(from: pixels, width: width, height: height)
    }

    /// 按 VS Code overview ruler 公式绘制：y = verticalOffset / scrollHeight * trackHeight。
    /// 最短色块为 6 设备像素，过小时居中并夹紧到轨道内。
    private func paintOverviewDecorations(pixels: inout [UInt8], width: Int, height: Int, scale: CGFloat, source: MinimapDataSource, content: Content) {
        guard scrollHeight > 0, trackHeight > 0 else { return }
        let trackTopPx = trackTop * scale
        let trackHeightPx = max(trackHeight * scale, 1)
        let heightRatio = trackHeightPx / scrollHeight
        let minDecorationHeight = 6
        for decoration in content.decorations {
            let startOffset = source.minimapVerticalOffset(forLine: decoration.start)
            let endOffset: CGFloat
            if decoration.count <= 0 {
                endOffset = startOffset
            } else {
                endOffset = source.minimapVerticalOffset(forLine: decoration.start + decoration.count)
            }
            var y1 = trackTopPx + startOffset * heightRatio
            var y2 = trackTopPx + endOffset * heightRatio
            if decoration.count <= 0 || y2 - y1 < CGFloat(minDecorationHeight) {
                let mid = decoration.count <= 0 ? y1 : (y1 + y2) / 2
                y1 = mid - CGFloat(minDecorationHeight) / 2
                y2 = y1 + CGFloat(minDecorationHeight)
            }
            var top = Int(y1.rounded())
            var bottom = Int(y2.rounded())
            if bottom <= top { bottom = top + minDecorationHeight }
            let trackStart = Int(trackTopPx.rounded())
            var trackEnd = Int((trackTopPx + trackHeightPx).rounded())
            if trackEnd <= trackStart { trackEnd = trackStart + 1 }
            top = min(max(top, trackStart), trackEnd)
            bottom = min(max(bottom, trackStart), trackEnd)
            if bottom <= top { continue }
            top = min(max(top, 0), height)
            bottom = min(max(bottom, 0), height)
            if bottom <= top { continue }
            fill(pixels: &pixels, width: width, height: height, x: 0, y: top, w: width, h: bottom - top, color: decoration.color)
        }
    }


    private func fill(pixels: inout [UInt8], width: Int, height: Int, x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        let x0 = max(x, 0)
        let y0 = max(y, 0)
        let x1 = min(x + w, width)
        let y1 = min(y + h, height)
        guard x0 < x1, y0 < y1 else { return }
        let r = UInt8((color >> 24) & 0xFF)
        let g = UInt8((color >> 16) & 0xFF)
        let b = UInt8((color >> 8) & 0xFF)
        let a = UInt8(color & 0xFF)
        // 半透明装饰叠在已有像素上；不透明则直接覆盖。
        if a == 255 {
            for row in y0 ..< y1 {
                var i = (row * width + x0) * 4
                for _ in x0 ..< x1 {
                    pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
                    i += 4
                }
            }
        } else {
            let fa = Float(a) / 255
            let ia = 1 - fa
            let fr = Float(r) * fa, fg = Float(g) * fa, fb = Float(b) * fa
            for row in y0 ..< y1 {
                var i = (row * width + x0) * 4
                for _ in x0 ..< x1 {
                    pixels[i] = UInt8(fr + Float(pixels[i]) * ia)
                    pixels[i + 1] = UInt8(fg + Float(pixels[i + 1]) * ia)
                    pixels[i + 2] = UInt8(fb + Float(pixels[i + 2]) * ia)
                    pixels[i + 3] = 255
                    i += 4
                }
            }
        }
    }

    private func image(from pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - 颜色

    private func resolved(_ color: NSColor) -> NSColor {
        var result = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: color.cgColor) ?? color
        }
        return result
    }

    private func pack(_ color: NSColor, alpha: CGFloat = 1) -> UInt32 {
        let c = resolved(color).usingColorSpace(.sRGB) ?? resolved(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let aa = min(max(a * alpha, 0), 1)
        return (UInt32((r * 255).rounded()) << 24)
            | (UInt32((g * 255).rounded()) << 16)
            | (UInt32((b * 255).rounded()) << 8)
            | UInt32((aa * 255).rounded())
    }

    private func resolvedColors() -> ColorTable {
        var tokens: [TokenKind: UInt32] = [:]
        for kind in TokenKind.minimapCases {
            tokens[kind] = pack(SyntaxTheme.color(for: kind))
        }
        // 概览条没有文字叠在上面，色块用更高不透明度，接近 VS Code 的 diff overview。
        return ColorTable(
            background: pack(Theme.editorBackground),
            text: pack(SyntaxTheme.text),
            tokens: tokens,
            added: pack(MinimapColors.added, alpha: style == .overview ? 0.9 : 0.55),
            deleted: pack(MinimapColors.deleted, alpha: style == .overview ? 0.95 : 0.7),
            modified: pack(MinimapColors.modified, alpha: style == .overview ? 0.85 : 0.45),
            conflict: pack(MinimapColors.conflict, alpha: style == .overview ? 0.9 : 0.55)
        )
    }
}

// MARK: - 模型

private struct ColorTable: Sendable {
    var background: UInt32
    var text: UInt32
    var tokens: [TokenKind: UInt32]
    var added: UInt32
    var deleted: UInt32
    var modified: UInt32
    var conflict: UInt32

    func token(_ kind: TokenKind) -> UInt32 { tokens[kind] ?? text }

    func decoration(_ kind: LineChangeKind?) -> UInt32 {
        switch kind {
        case .added: added
        case .deleted: deleted
        case .modified: modified
        case nil: conflict
        }
    }
}

private struct Content: Sendable {
    struct Run: Sendable {
        var column: UInt16
        var width: UInt16
        var color: UInt32
    }

    struct Line: Sendable {
        var runs: [Run]
    }

    struct Decoration: Sendable {
        var start: Int
        var count: Int
        var color: UInt32
    }

    var lineCount: Int
    var lines: [Line]
    var decorations: [Decoration]
    var colors: ColorTable

    static func build(
        text: String,
        spans: [HighlightSpan],
        changes: [LineChange],
        highlights: [MinimapDiffHighlight],
        colors: ColorTable,
        includeText: Bool
    ) -> Content {
        let utf16 = Array(text.utf16)
        var lines: [Line] = []
        var runs: [Run] = []
        var column = 0
        var index = 0
        var spanIndex = 0
        let sorted = spans.sorted { $0.start < $1.start }

        func flushLine() {
            lines.append(Line(runs: runs))
            runs = []
            column = 0
        }

        func currentColor() -> UInt32 {
            while spanIndex < sorted.count, sorted[spanIndex].end <= UInt32(index) { spanIndex += 1 }
            guard spanIndex < sorted.count, sorted[spanIndex].start <= UInt32(index) else { return colors.text }
            return colors.token(sorted[spanIndex].kind)
        }

        while index < utf16.count {
            let unit = utf16[index]
            if unit == 13 { // \r
                if index + 1 < utf16.count, utf16[index + 1] == 10 { index += 1 }
                flushLine()
                index += 1
                continue
            }
            if unit == 10 { // \n
                flushLine()
                index += 1
                continue
            }
            if unit == 9 { // tab
                column = (column / 4 + 1) * 4
                index += 1
                continue
            }
            // 空白只占列，不画像素（与 VS Code 一致，突出缩进与行长）。
            let isSpace = unit == 32 || unit == 0x00A0
            let isSurrogate = unit >= 0xD800 && unit <= 0xDBFF && index + 1 < utf16.count
            let advance = isSurrogate ? 2 : 1
            if includeText, !isSpace {
                let color = currentColor()
                if let last = runs.last, last.color == color, Int(last.column) + Int(last.width) == column {
                    runs[runs.count - 1].width += 1
                } else {
                    runs.append(Run(column: UInt16(clamping: column), width: 1, color: color))
                }
            }
            column += 1
            index += advance
        }
        // 与编辑器一致：即使末尾没有换行，也保留最后一行；空文档仍有一行。
        if !runs.isEmpty || lines.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\r\n") {
            flushLine()
        }
        if lines.isEmpty { lines = [Line(runs: [])] }

        var decorations: [Decoration] = []
        if highlights.isEmpty {
            for change in changes {
                let color = colors.decoration(change.kind)
                if change.count == 0 {
                    decorations.append(Decoration(start: Int(change.start), count: 0, color: color))
                } else {
                    decorations.append(Decoration(start: Int(change.start), count: Int(change.count), color: color))
                }
            }
        } else {
            for highlight in highlights {
                decorations.append(Decoration(
                    start: highlight.start,
                    count: highlight.count,
                    color: colors.decoration(highlight.kind)
                ))
            }
        }

        return Content(lineCount: lines.count, lines: lines, decorations: decorations, colors: colors)
    }
}

/// 缩略图中的 git 装饰配色：新增为绿色、删除为品红（对齐 VS Code 参考截图），修改为蓝色、冲突为红色。
enum MinimapColors {
    static let added = Theme.dynamic(light: 0x7CB87A, dark: 0x3F7A45)
    static let deleted = Theme.dynamic(light: 0xE08AAA, dark: 0xC45C80)
    static let modified = Theme.dynamic(light: 0x8AA6E0, dark: 0x3A5A8C)
    static let conflict = Theme.dynamic(light: 0xE57373, dark: 0xB34A4A)
    static let slider = Theme.dynamic(light: 0x8A909A, dark: 0x8A909A).withAlphaComponent(0.28)
    static let sliderBorder = Theme.dynamic(light: 0x6A7080, dark: 0xA0A6B0).withAlphaComponent(0.45)
}

private extension TokenKind {
    /// 用于预解析配色；与 `SyntaxTheme.color(for:)` 的分支保持一致。
    static let minimapCases: [TokenKind] = [
        .keyword, .string, .stringSpecial, .escape, .comment, .number, .constant, .function, .type,
        .parameter, .property, .operator, .punctuation, .tag, .attribute, .namespace, .label, .heading,
    ]
}
