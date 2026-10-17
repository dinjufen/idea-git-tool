import AppKit
import CodeEditTextView
import GitDeckCore

/// 编辑器左侧 gutter：行号 + 相对 HEAD 的变更标记（IDEA 的 line status markers）。
final class GutterView: NSView {
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
        return NSSize(width: CGFloat(digits) * digitWidth + 14 + Self.markerGap + Self.markerWidth, height: NSView.noIntrinsicMetric)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
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

/// 变更标记颜色（IDEA 的 VCS Added / Modified / Deleted lines）。
enum LineStatusColors {
    static let added = Theme.dynamic(light: 0x9CCF94, dark: 0x549159)
    static let modified = Theme.dynamic(light: 0x99B6F2, dark: 0x375FAD)
    static let deleted = Theme.dynamic(light: 0x9EA3AE, dark: 0x868A91)
}
