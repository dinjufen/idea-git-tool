import AppKit
import CodeEditTextView
import GitDeckCore

/// 编辑器的 Annotate 列（IDEA 的 “Annotate with Git Blame”）：每行显示最后修改该行的提交日期与作者，
/// 背景色按提交新旧着色（越新越深）；悬停显示提交详情，点击在 Git 日志中定位该提交。
final class AnnotationGutterView: NSView {
    static let width: CGFloat = 170

    var blame: BlameResult? {
        didSet {
            computeAgeRange()
            needsDisplay = true
        }
    }

    var font: NSFont = EditorSettings.font {
        didSet { needsDisplay = true }
    }

    /// 编辑后的行号映射：当前行 → blame 时的行；`nil` 元素表示新增或修改的行（不显示注释）。
    /// 为 `nil` 时按行号一一对应（文件未修改）。
    var lineMap: [Int?]? {
        didSet { needsDisplay = true }
    }

    var onClickCommit: ((String) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    private weak var textView: TextView?
    private weak var scrollView: NSScrollView?
    private var oldest: Int64 = 0
    private var newest: Int64 = 0
    private var hoveredLine: Int?

    init(textView: TextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func computeAgeRange() {
        let times = blame?.commits.filter { !$0.isUncommitted }.map(\.authorTime) ?? []
        oldest = times.min() ?? 0
        newest = times.max() ?? 0
    }

    private func commit(atLine current: Int) -> BlameCommit? {
        let mapped: Int?
        if let lineMap {
            mapped = lineMap.indices.contains(current) ? lineMap[current] : nil
        } else {
            mapped = current
        }
        guard let blame, let line = mapped, blame.lines.indices.contains(line) else { return nil }
        return blame.commits[Int(blame.lines[line])]
    }

    private func line(at point: NSPoint) -> Int? {
        guard let scrollView, let storage = textView?.layoutManager?.lineStorage else { return nil }
        return storage.getLine(atPosition: point.y + scrollView.contentView.bounds.minY)?.index
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.toolWindowBackground.setFill()
        bounds.fill()
        guard blame != nil, let textView, let scrollView, let layout = textView.layoutManager else { return }

        let offsetY = scrollView.contentView.bounds.minY
        let smallFont = NSFont.systemFont(ofSize: max(9, font.pointSize - 2))
        var position = layout.lineStorage.getLine(atPosition: max(0, offsetY)) ?? layout.lineStorage.first
        var previousHash: String?
        while let line = position, line.yPos - offsetY <= bounds.height {
            defer { position = layout.lineStorage.getLine(atIndex: line.index + 1) }
            guard let commit = commit(atLine: line.index) else { continue }
            let rect = NSRect(x: 0, y: line.yPos - offsetY, width: bounds.width, height: line.height)
            if !commit.isUncommitted {
                ageColor(commit.authorTime).setFill()
                rect.fill()
            }
            if line.index == hoveredLine {
                Theme.hover.setFill()
                rect.fill()
            }
            // 同一提交的连续行只在第一行显示文字，与 IDEA 一致。
            guard commit.hash != previousHash, !commit.isUncommitted else {
                previousHash = commit.hash
                continue
            }
            previousHash = commit.hash
            let date = Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(commit.authorTime)))
            let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: Theme.secondaryText]
            let dateSize = date.size(withAttributes: attrs)
            let y = rect.minY + (rect.height - dateSize.height) / 2
            date.draw(at: NSPoint(x: 6, y: y), withAttributes: attrs)
            let authorRect = NSRect(x: 6 + dateSize.width + 8, y: y, width: bounds.width - dateSize.width - 20, height: dateSize.height)
            commit.authorName.draw(with: authorRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
                .font: smallFont, .foregroundColor: Theme.text, .paragraphStyle: Self.truncating,
            ])
        }
        Theme.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    /// 越新的提交背景越深（IDEA 按提交时间的热力着色）。
    private func ageColor(_ time: Int64) -> NSColor {
        let span = Double(max(newest - oldest, 1))
        let recency = Double(time - oldest) / span
        return Theme.accent.withAlphaComponent(0.04 + 0.22 * recency)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    // MARK: - 交互

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // 只替换自己的跟踪区域：toolTip 也依赖 AppKit 内部的跟踪区域，全部移除会让悬停提示失效。
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    private var hoverArea: NSTrackingArea?

    override func mouseMoved(with event: NSEvent) {
        let line = line(at: convert(event.locationInWindow, from: nil))
        guard line != hoveredLine else { return }
        hoveredLine = line
        if let line, let commit = commit(atLine: line), !commit.isUncommitted {
            let date = LogDateFormatter.detailed(commit.authorTime)
            toolTip = "\(String(commit.hash.prefix(8)))  \(commit.authorName) <\(commit.authorEmail)>\n\(date)\n\n\(commit.summary)"
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLine = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let line = line(at: convert(event.locationInWindow, from: nil)),
              let commit = commit(atLine: line), !commit.isUncommitted else { return }
        onClickCommit?(commit.hash)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }
}
