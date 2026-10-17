import AppKit
import CodeEditTextView
import GitDeckCore

/// 一侧的内容。`text` 为 `nil` 表示该版本中文件不存在。
struct DiffSide {
    var title: String
    var text: String?
}

/// 并排 Diff 视图（IDEA 的 side-by-side viewer）：左侧为基准版本，右侧为新版本。
final class DiffView: NSView {
    private let left: DiffSide
    private let right: DiffSide
    private let language: String?
    private let leftEditor: CodeEditorView
    private let rightEditor: CodeEditorView
    private let leftBackground: DiffBackgroundView
    private let rightBackground: DiffBackgroundView
    private let connector = DiffConnectorView()
    private let countLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let whitespacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let binaryLabel = NSTextField.label(tr("diff.binary"), color: Theme.secondaryText)

    private var blocks: [DiffBlock] = []
    private var currentBlock: Int?
    private var isSyncingScroll = false
    private var observers: [NSObjectProtocol] = []
    private var diffTask: Task<Void, Never>?

    private static let whitespaceModes: [(WhitespaceMode, String)] = [
        (.compare, "diff.whitespace.compare"),
        (.trim, "diff.whitespace.trim"),
        (.ignore, "diff.whitespace.ignore"),
    ]

    init(left: DiffSide, right: DiffSide, path: String) {
        self.left = left
        self.right = right
        language = languageForPath(path: path)
        leftEditor = CodeEditorView(text: left.text ?? "", language: language, isEditable: false)
        rightEditor = CodeEditorView(text: right.text ?? "", language: language, isEditable: false)
        leftBackground = DiffBackgroundView(textView: leftEditor.textView, side: .base)
        rightBackground = DiffBackgroundView(textView: rightEditor.textView, side: .new)
        super.init(frame: .zero)
        buildLayout()
        observeScrolling()
        if isBinary {
            leftEditor.isHidden = true
            rightEditor.isHidden = true
            connector.isHidden = true
        } else {
            recompute()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        diffTask?.cancel()
    }

    private var isBinary: Bool {
        (left.text?.contains("\0") ?? false) || (right.text?.contains("\0") ?? false)
    }

    // MARK: - 布局

    private func buildLayout() {
        let background = ColoredView(Theme.editorBackground)
        addSubview(background)
        background.pinEdges(to: self)

        func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 26, pointSize: 12)
            b.target = self
            b.action = action
            return b
        }
        for (_, key) in Self.whitespaceModes { whitespacePopup.addItem(withTitle: tr(key)) }
        whitespacePopup.bezelStyle = .inline
        whitespacePopup.controlSize = .small
        whitespacePopup.font = Theme.smallFont
        whitespacePopup.target = self
        whitespacePopup.action = #selector(whitespaceChanged)

        let toolbar = NSStackView(views: [
            button("arrow.up", tr("diff.previous"), #selector(previousDifference)),
            button("arrow.down", tr("diff.next"), #selector(nextDifference)),
            whitespacePopup, NSView(), countLabel,
        ])
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let leftTitle = titleLabel(left)
        let rightTitle = titleLabel(right)
        let topDivider = SeparatorLine(.horizontal)
        let titleDivider = SeparatorLine(.horizontal)
        for view in [leftEditor, rightEditor, connector] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        binaryLabel.isHidden = !isBinary

        for view in [toolbar, topDivider, leftTitle, rightTitle, titleDivider, leftEditor, connector, rightEditor, binaryLabel] as [NSView] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            topDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftTitle.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 6),
            leftTitle.leadingAnchor.constraint(equalTo: leftEditor.leadingAnchor, constant: 10),
            leftTitle.trailingAnchor.constraint(lessThanOrEqualTo: leftEditor.trailingAnchor, constant: -10),
            rightTitle.topAnchor.constraint(equalTo: leftTitle.topAnchor),
            rightTitle.leadingAnchor.constraint(equalTo: rightEditor.leadingAnchor, constant: 10),
            rightTitle.trailingAnchor.constraint(lessThanOrEqualTo: rightEditor.trailingAnchor, constant: -10),
            titleDivider.topAnchor.constraint(equalTo: leftTitle.bottomAnchor, constant: 6),
            titleDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftEditor.topAnchor.constraint(equalTo: titleDivider.bottomAnchor),
            leftEditor.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftEditor.bottomAnchor.constraint(equalTo: bottomAnchor),
            connector.topAnchor.constraint(equalTo: leftEditor.topAnchor),
            connector.bottomAnchor.constraint(equalTo: bottomAnchor),
            connector.leadingAnchor.constraint(equalTo: leftEditor.trailingAnchor),
            connector.widthAnchor.constraint(equalToConstant: 36),
            rightEditor.topAnchor.constraint(equalTo: leftEditor.topAnchor),
            rightEditor.leadingAnchor.constraint(equalTo: connector.trailingAnchor),
            rightEditor.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightEditor.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightEditor.widthAnchor.constraint(equalTo: leftEditor.widthAnchor),

            binaryLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            binaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        connector.leftEditor = leftEditor
        connector.rightEditor = rightEditor
    }

    private func titleLabel(_ side: DiffSide) -> NSTextField {
        let text = side.text == nil ? tr("diff.title.missing", side.title) : side.title
        return NSTextField.label(text, font: Theme.smallFont, color: Theme.secondaryText)
    }

    // MARK: - 计算差异

    @objc private func whitespaceChanged() {
        recompute()
    }

    private func recompute() {
        let base = left.text ?? ""
        let text = right.text ?? ""
        let mode = Self.whitespaceModes[max(0, whitespacePopup.indexOfSelectedItem)].0
        diffTask?.cancel()
        diffTask = Task {
            let blocks = await Task.detached(priority: .userInitiated) {
                diffTexts(base: base, text: text, whitespace: mode)
            }.value
            guard !Task.isCancelled else { return }
            self.blocks = blocks
            self.currentBlock = nil
            self.leftBackground.blocks = blocks
            self.rightBackground.blocks = blocks
            self.connector.blocks = blocks
            self.countLabel.stringValue = blocks.isEmpty
                ? tr("diff.identical")
                : (blocks.count == 1 ? tr("diff.count.one") : tr("diff.count", "\(blocks.count)"))
        }
    }

    // MARK: - 跳转

    @objc func nextDifference() {
        guard !blocks.isEmpty else { return }
        let next = currentBlock.map { min($0 + 1, blocks.count - 1) } ?? firstBlockBelowViewport()
        go(to: next)
    }

    @objc func previousDifference() {
        guard !blocks.isEmpty else { return }
        go(to: currentBlock.map { max($0 - 1, 0) } ?? 0)
    }

    /// 首次跳转时从当前可见区域之后的第一个差异开始。
    private func firstBlockBelowViewport() -> Int {
        let top = topVisibleLine(of: rightEditor)
        return blocks.firstIndex { Double($0.change.start) >= top } ?? 0
    }

    private func go(to index: Int) {
        currentBlock = index
        let change = blocks[index].change
        guard let line = rightEditor.textView.layoutManager.lineStorage.getLine(atIndex: Int(change.start))
            ?? rightEditor.textView.layoutManager.lineStorage.last else { return }
        // 把差异放在视口上方约三分之一处，与 IDEA 一致。
        let target = max(0, line.yPos - rightEditor.scrollView.contentView.bounds.height / 3)
        scroll(rightEditor, toY: target)
        rightEditor.textView.selectionManager.setSelectedRange(NSRange(location: line.range.location, length: 0))
        syncScroll(from: rightEditor)
    }

    // MARK: - 同步滚动

    private func observeScrolling() {
        for editor in [leftEditor, rightEditor] {
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: editor.scrollView.contentView,
                queue: .main
            ) { [weak self, weak editor] _ in
                MainActor.assumeIsolated {
                    guard let self, let editor else { return }
                    self.syncScroll(from: editor)
                    self.connector.needsDisplay = true
                }
            }
            observers.append(token)
        }
    }

    /// 按变更块的对应关系换算行号，让另一侧显示相同的内容位置。
    private func syncScroll(from source: CodeEditorView) {
        guard !isSyncingScroll else { return }
        let target = source === leftEditor ? rightEditor : leftEditor
        let fromBase = source === leftEditor
        let line = topVisibleLine(of: source)
        let mapped = mapLine(line, fromBase: fromBase)
        let storage = target.textView.layoutManager.lineStorage
        let whole = Int(mapped.rounded(.down))
        let y: CGFloat
        if let position = storage.getLine(atIndex: whole) {
            y = position.yPos + CGFloat(mapped - Double(whole)) * position.height
        } else if let last = storage.last {
            y = last.yPos + last.height
        } else {
            y = 0
        }
        isSyncingScroll = true
        scroll(target, toY: y)
        isSyncingScroll = false
        connector.needsDisplay = true
    }

    /// 视口顶部所在的行（带小数部分）。
    private func topVisibleLine(of editor: CodeEditorView) -> Double {
        let y = editor.scrollView.contentView.bounds.minY
        guard let line = editor.textView.layoutManager.lineStorage.getLine(atPosition: max(0, y)) else { return 0 }
        let fraction = line.height > 0 ? Double((y - line.yPos) / line.height) : 0
        return Double(line.index) + min(max(fraction, 0), 1)
    }

    private func mapLine(_ line: Double, fromBase: Bool) -> Double {
        var delta = 0.0
        for block in blocks {
            let c = block.change
            let (fromStart, fromCount, toStart, toCount) = fromBase
                ? (Double(c.baseStart), Double(c.baseCount), Double(c.start), Double(c.count))
                : (Double(c.start), Double(c.count), Double(c.baseStart), Double(c.baseCount))
            if line < fromStart { break }
            if line < fromStart + fromCount {
                // 块内按比例映射。
                return toStart + (line - fromStart) / fromCount * toCount
            }
            delta = (toStart + toCount) - (fromStart + fromCount)
        }
        return line + delta
    }

    private func scroll(_ editor: CodeEditorView, toY y: CGFloat) {
        let clip = editor.scrollView.contentView
        let maxY = max(0, (editor.scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
        editor.scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - 配色

/// Diff 着色，对应 IDEA 的 Diff Inserted / Modified / Deleted 配色；单词级变化使用更深的同色系。
enum DiffColors {
    static func block(_ kind: LineChangeKind) -> NSColor {
        switch kind {
        case .added: Theme.dynamic(light: 0xE3F5E1, dark: 0x294436)
        case .modified: Theme.dynamic(light: 0xE3ECFC, dark: 0x2B3B57)
        case .deleted: Theme.dynamic(light: 0xEBEBEB, dark: 0x3A3D41)
        }
    }

    static func inline(_ kind: LineChangeKind) -> NSColor {
        switch kind {
        case .added: Theme.dynamic(light: 0xC3E8BF, dark: 0x375E46)
        case .modified: Theme.dynamic(light: 0xC3D5F5, dark: 0x36507A)
        case .deleted: Theme.dynamic(light: 0xD6D6D6, dark: 0x4E5157)
        }
    }

    /// 一侧没有对应行时（新增块的左侧、删除块的右侧），在对应位置画的分隔线颜色。
    static func marker(_ kind: LineChangeKind) -> NSColor {
        switch kind {
        case .added: Theme.dynamic(light: 0x9CCF94, dark: 0x549159)
        case .modified: Theme.dynamic(light: 0x99B6F2, dark: 0x375FAD)
        case .deleted: Theme.dynamic(light: 0xB4B7BD, dark: 0x6F737A)
        }
    }
}

// MARK: - 背景

/// 画在文本下方的变更背景：整行宽的块背景 + 单词级高亮。
///
/// 作为 TextView 的子视图加入，图层 zPosition 为 -1，因而位于文字之下。
final class DiffBackgroundView: NSView {
    enum Side { case base, new }

    var blocks: [DiffBlock] = [] {
        didSet { needsDisplay = true }
    }

    private weak var textView: TextView?
    private let side: Side

    init(textView: TextView, side: Side) {
        self.textView = textView
        self.side = side
        super.init(frame: textView.bounds)
        wantsLayer = true
        layer?.zPosition = -1
        autoresizingMask = [.width, .height]
        textView.addSubview(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = textView?.layoutManager else { return }
        let storage = layout.lineStorage
        for block in blocks {
            let c = block.change
            let (start, count) = side == .base ? (c.baseStart, c.baseCount) : (c.start, c.count)
            if count == 0 {
                // 对侧有内容而本侧没有：在插入位置画一条细线。
                let y = storage.getLine(atIndex: Int(start))?.yPos
                    ?? storage.last.map { $0.yPos + $0.height } ?? 0
                DiffColors.marker(c.kind).setFill()
                NSRect(x: 0, y: y - 1, width: bounds.width, height: 2).fill()
                continue
            }
            guard let first = storage.getLine(atIndex: Int(start)),
                  let last = storage.getLine(atIndex: Int(start + count) - 1) else { continue }
            let rect = NSRect(x: 0, y: first.yPos, width: bounds.width, height: last.yPos + last.height - first.yPos)
            guard rect.intersects(dirtyRect) else { continue }
            DiffColors.block(c.kind).setFill()
            rect.fill()

            DiffColors.inline(c.kind).setFill()
            for range in side == .base ? block.baseInline : block.inline {
                let nsRange = NSRange(location: Int(range.start), length: Int(range.end - range.start))
                for wordRect in layout.rectsFor(range: nsRange) {
                    NSBezierPath(roundedRect: wordRect.insetBy(dx: -1, dy: 1), xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }
}

// MARK: - 连接带

/// 两侧编辑器之间的连接带：把左右对应的变更块用曲线色带连起来（IDEA 的 diff divider）。
final class DiffConnectorView: NSView {
    weak var leftEditor: CodeEditorView?
    weak var rightEditor: CodeEditorView?

    var blocks: [DiffBlock] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        guard let leftEditor, let rightEditor else { return }
        for block in blocks {
            let c = block.change
            let (lTop, lBottom) = span(in: leftEditor, start: c.baseStart, count: c.baseCount)
            let (rTop, rBottom) = span(in: rightEditor, start: c.start, count: c.count)
            if max(lBottom, rBottom) < 0 || min(lTop, rTop) > bounds.height { continue }

            let w = bounds.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: lTop))
            path.curve(to: NSPoint(x: w, y: rTop), controlPoint1: NSPoint(x: w / 2, y: lTop), controlPoint2: NSPoint(x: w / 2, y: rTop))
            path.line(to: NSPoint(x: w, y: rBottom))
            path.curve(to: NSPoint(x: 0, y: lBottom), controlPoint1: NSPoint(x: w / 2, y: rBottom), controlPoint2: NSPoint(x: w / 2, y: lBottom))
            path.close()
            DiffColors.block(c.kind).setFill()
            path.fill()
            DiffColors.marker(c.kind).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// 变更块在编辑器可见区域中的上下边界（相对本视图顶部）。
    private func span(in editor: CodeEditorView, start: UInt32, count: UInt32) -> (CGFloat, CGFloat) {
        let storage = editor.textView.layoutManager.lineStorage
        let offset = editor.scrollView.contentView.bounds.minY
        if count == 0 {
            let y = (storage.getLine(atIndex: Int(start))?.yPos ?? storage.last.map { $0.yPos + $0.height } ?? 0) - offset
            return (y, y)
        }
        let top = storage.getLine(atIndex: Int(start))?.yPos ?? 0
        let lastLine = storage.getLine(atIndex: Int(start + count) - 1)
        let bottom = lastLine.map { $0.yPos + $0.height } ?? top
        return (top - offset, bottom - offset)
    }
}
