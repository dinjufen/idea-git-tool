import AppKit
import CodeEditTextView
import GitDeckCore

/// AI 评审发现在编辑器中的标记。
struct ReviewMarker {
    /// 在评审结果中的下标。
    let index: Int
    /// 从 0 开始的行号。
    let line: Int
    let severity: ReviewSeverity
    let title: String
}

/// 编辑器左侧 gutter：AI 评审标记 + 行号 + 相对 HEAD 的变更标记（IDEA 的 line status markers）。
final class GutterView: NSView, NSViewToolTipOwner {
    /// 相对基准版本的行变更；为空时不显示标记。
    var changes: [LineChange] = [] {
        didSet { needsDisplay = true }
    }

    var font: NSFont = EditorSettings.font {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var contextMenu: (() -> NSMenu?)?

    /// AI 评审标记；有标记时在行号左侧显示严重程度图标。
    var reviewMarkers: [ReviewMarker] = [] {
        didSet {
            if reviewMarkers.isEmpty != oldValue.isEmpty { invalidateIntrinsicContentSize() }
            needsDisplay = true
        }
    }

    var onMarkerClick: ((Int) -> Void)?
    private static let reviewColumnWidth: CGFloat = 16
    private var markerRects: [(rect: NSRect, marker: ReviewMarker)] = []

    private weak var textView: TextView?
    private weak var scrollView: NSScrollView?
    private static let markerWidth: CGFloat = 4
    private static let markerGap: CGFloat = 6

    init(textView: TextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var numberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 1), weight: .regular)
    }

    override var intrinsicContentSize: NSSize {
        let lines = max(textView?.layoutManager?.lineCount ?? 1, 1)
        let digits = max(String(lines).count, 3)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let reviewColumn = reviewMarkers.isEmpty ? 0 : Self.reviewColumnWidth
        return NSSize(width: reviewColumn + CGFloat(digits) * digitWidth + 14 + Self.markerGap + Self.markerWidth, height: NSView.noIntrinsicMetric)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = markerRects.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            onMarkerClick?(hit.marker.index)
            return
        }
        super.mouseDown(with: event)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let markers = markerRects.filter { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }.map(\.marker)
        return markers.map { "\(AIReviewToolWindow.severityTitle($0.severity)): \($0.title)" }.joined(separator: "\n")
    }

    /// 行数位数变化时调整宽度。
    func lineCountChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        guard let textView, let scrollView, let layout = textView.layoutManager else { return }

        let offsetY = scrollView.contentView.bounds.minY
        let visibleBottom = offsetY + bounds.height
        let caretLine = textView.selectionManager.textSelections.first
            .flatMap { layout.textLineForOffset($0.range.location)?.index }
        let numberRight = bounds.width - Self.markerGap - Self.markerWidth - 4

        // 行号。
        var line = layout.lineStorage.getLine(atPosition: max(0, offsetY)) ?? layout.lineStorage.first
        while let current = line, current.yPos <= visibleBottom {
            let isCaret = current.index == caretLine
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: isCaret ? SyntaxTheme.currentLineNumber : SyntaxTheme.lineNumber,
            ]
            let number = "\(current.index + 1)" as NSString
            let size = number.size(withAttributes: attrs)
            let y = current.yPos - offsetY + (current.height - size.height) / 2
            number.draw(at: NSPoint(x: numberRight - size.width, y: y), withAttributes: attrs)
            line = layout.lineStorage.getLine(atIndex: current.index + 1)
        }

        drawReviewMarkers(layout: layout, offsetY: offsetY)

        // 变更标记。
        let markerX = bounds.width - Self.markerWidth - 2
        for change in changes {
            switch change.kind {
            case .added, .modified:
                guard let first = layout.lineStorage.getLine(atIndex: Int(change.start)),
                      let last = layout.lineStorage.getLine(atIndex: Int(change.start + change.count) - 1) else { continue }
                let top = first.yPos - offsetY
                let bottom = last.yPos + last.height - offsetY
                guard bottom >= 0, top <= bounds.height else { continue }
                (change.kind == .added ? LineStatusColors.added : LineStatusColors.modified).setFill()
                NSBezierPath(roundedRect: NSRect(x: markerX, y: top, width: Self.markerWidth, height: bottom - top),
                             xRadius: 1.5, yRadius: 1.5).fill()
            case .deleted:
                // 删除标记画在被删除内容所在位置的行间：一个指向编辑区的小三角。
                let y: CGFloat
                if let next = layout.lineStorage.getLine(atIndex: Int(change.start)) {
                    y = next.yPos - offsetY
                } else if let lastLine = layout.lineStorage.last {
                    y = lastLine.yPos + lastLine.height - offsetY
                } else {
                    continue
                }
                guard y >= -6, y <= bounds.height + 6 else { continue }
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: markerX - 1, y: y - 4))
                triangle.line(to: NSPoint(x: markerX + Self.markerWidth + 2, y: y))
                triangle.line(to: NSPoint(x: markerX - 1, y: y + 4))
                triangle.close()
                LineStatusColors.deleted.setFill()
                triangle.fill()
            }
        }
    }
}

extension GutterView {
    /// 每行只画最严重的一个图标，并为图标区域注册提示。
    fileprivate func drawReviewMarkers(layout: TextLayoutManager, offsetY: CGFloat) {
        removeAllToolTips()
        markerRects = []
        guard !reviewMarkers.isEmpty else { return }
        let rank: (ReviewSeverity) -> Int = { $0 == .error ? 0 : ($0 == .warning ? 1 : 2) }
        var byLine: [Int: ReviewMarker] = [:]
        for marker in reviewMarkers {
            if let existing = byLine[marker.line], rank(existing.severity) <= rank(marker.severity) { continue }
            byLine[marker.line] = marker
        }
        for (line, marker) in byLine {
            guard let position = layout.lineStorage.getLine(atIndex: line) else { continue }
            let size: CGFloat = 12
            let y = position.yPos - offsetY + (position.height - size) / 2
            guard y + size >= 0, y <= bounds.height else { continue }
            let rect = NSRect(x: 3, y: y, width: size, height: size)
            let (symbol, color) = AIReviewToolWindow.severitySymbol(marker.severity)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [color]))) {
                image.draw(in: rect)
            }
            for other in reviewMarkers where other.line == line {
                markerRects.append((rect, other))
            }
            addToolTip(rect, owner: self, userData: nil)
        }
    }
}

/// 变更标记颜色（IDEA 的 VCS Added / Modified / Deleted lines）。
enum LineStatusColors {
    static let added = Theme.dynamic(light: 0x9CCF94, dark: 0x549159)
    static let modified = Theme.dynamic(light: 0x99B6F2, dark: 0x375FAD)
    static let deleted = Theme.dynamic(light: 0x9EA3AE, dark: 0x868A91)
}
