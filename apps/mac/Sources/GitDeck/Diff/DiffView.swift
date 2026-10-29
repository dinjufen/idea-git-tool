import AppKit
import CodeEditTextView
import GitDeckCore

/// 一侧的内容。`text` 为 `nil` 表示该版本中文件不存在。
struct DiffSide {
    var title: String
    var text: String?
}

/// 跳转到源码的目标：工作区中的文件，以及右侧是否就是工作区版本（否则跳转时把行号映射到当前文件）。
struct DiffSource {
    let url: URL
    let rightIsWorkingTree: Bool
}

/// 本地改动的 Diff 可以选择要提交的改动块 / 行（部分提交）。
struct DiffInclusion {
    let store: LineSelectionStore
    let path: String
}

/// Diff 视图（IDEA 的 Diff viewer）：并排模式左侧为基准版本、右侧为新版本；统一模式在一栏中依次显示删除与新增的行。
///
/// 打开本地改动时（`inclusion` 非空）可以勾选要提交的改动：并排模式中间连接带上的复选框按块切换，
/// 点击行号按行切换；不提交的行以浅色显示。
final class DiffView: NSView {
    private let left: DiffSide
    private let right: DiffSide
    private let path: String
    private let language: String?
    private let leftEditor: CodeEditorView
    private let rightEditor: CodeEditorView
    private let leftBackground: DiffBackgroundView
    private let rightBackground: DiffBackgroundView
    private let connector = DiffConnectorView()
    private let countLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let whitespacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let viewerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let binaryLabel = NSTextField.label(tr("diff.binary"), color: Theme.secondaryText)
    private let unifiedContainer = NSView()
    private var leftTitle: NSTextField!
    private var rightTitle: NSTextField!
    private var unifiedEditor: CodeEditorView?
    private var unifiedBackground: UnifiedBackgroundView?
    private var unified = UnifiedModel()

    private let inclusion: DiffInclusion?
    private var inclusionObserver: UUID?

    private var blocks: [DiffBlock] = []
    private var currentBlock: Int?
    private var isSyncingScroll = false
    private var observers: [NSObjectProtocol] = []
    private var diffTask: Task<Void, Never>?
    private var jumpButton: IconButton!

    /// 跳转到源码的目标；为 nil 时不显示铅笔按钮（例如 AI 建议的预览）。
    var source: DiffSource? {
        didSet { updateJumpToSource() }
    }

    /// 在编辑器中打开文件：文件与行（从 0 开始）。
    var onJumpToSource: ((URL, Int) -> Void)?

    /// 读取文件当前的内容（编辑器中未保存的内容优先）；右侧不是工作区版本时用于映射行号。
    var currentText: ((URL) -> String?)?

    private static let whitespaceModes: [(WhitespaceMode, String)] = [
        (.compare, "diff.whitespace.compare"),
        (.trim, "diff.whitespace.trim"),
        (.ignore, "diff.whitespace.ignore"),
    ]

    /// 上次选择的查看方式（与 IDEA 一样在各 Diff 之间保持）。
    private static var prefersUnified: Bool {
        get { UserDefaults.standard.bool(forKey: "diff.unified") }
        set { UserDefaults.standard.set(newValue, forKey: "diff.unified") }
    }

    init(left: DiffSide, right: DiffSide, path: String, inclusion: DiffInclusion? = nil) {
        self.left = left
        self.right = right
        self.path = path
        self.inclusion = inclusion
        language = languageForPath(path: path)
        leftEditor = CodeEditorView(text: left.text ?? "", language: language, isEditable: false)
        rightEditor = CodeEditorView(text: right.text ?? "", language: language, isEditable: false)
        leftBackground = DiffBackgroundView(textView: leftEditor.textView, side: .base)
        rightBackground = DiffBackgroundView(textView: rightEditor.textView, side: .new)
        super.init(frame: .zero)
        buildLayout()
        observeScrolling()
        if let inclusion {
            inclusionObserver = inclusion.store.observe { [weak self] in self?.selectionChanged() }
            rightEditor.onLineNumberClick = { [weak self] line in self?.toggleLine(newLine: UInt32(line)) }
            leftEditor.onLineNumberClick = { [weak self] line in self?.toggleLine(baseLine: UInt32(line)) }
            connector.onToggleBlock = { [weak self] index in self?.toggleBlock(index) }
        }
        if isBinary {
            leftEditor.isHidden = true
            rightEditor.isHidden = true
            connector.isHidden = true
            viewerPopup.isEnabled = false
        } else {
            applyViewer()
            recompute()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        diffTask?.cancel()
        if let inclusionObserver { inclusion?.store.removeObserver(inclusionObserver) }
    }

    /// 把新版本一侧的第 `line` 行（从 0 开始）滚动到视口中。
    func reveal(line: Int) {
        if let unifiedEditor, isUnified {
            unifiedEditor.reveal(line: unified.row(forNewLine: line))
        } else {
            rightEditor.reveal(line: line)
        }
    }

    private var isBinary: Bool {
        (left.text?.contains("\0") ?? false) || (right.text?.contains("\0") ?? false)
    }

    private var isUnified: Bool { viewerPopup.indexOfSelectedItem == 1 }

    private var whitespaceMode: WhitespaceMode {
        Self.whitespaceModes[max(0, whitespacePopup.indexOfSelectedItem)].0
    }

    /// 可以勾选要提交的改动（只在逐字比较空白时，块与提交内容一致）。
    private var isSelectable: Bool { inclusion != nil && whitespaceMode == .compare }

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
        for popup in [whitespacePopup, viewerPopup] {
            popup.bezelStyle = .inline
            popup.controlSize = .small
            popup.font = Theme.smallFont
            popup.target = self
        }
        for (_, key) in Self.whitespaceModes { whitespacePopup.addItem(withTitle: tr(key)) }
        whitespacePopup.action = #selector(whitespaceChanged)
        viewerPopup.addItems(withTitles: [tr("diff.viewer.sideBySide"), tr("diff.viewer.unified")])
        viewerPopup.selectItem(at: Self.prefersUnified ? 1 : 0)
        viewerPopup.action = #selector(viewerChanged)

        jumpButton = button("pencil", tr("diff.jumpToSource"), #selector(jumpToSource))
        updateJumpToSource()
        let toolbar = NSStackView(views: [
            button("arrow.up", tr("diff.previous"), #selector(previousDifference)),
            button("arrow.down", tr("diff.next"), #selector(nextDifference)),
            jumpButton,
            viewerPopup, whitespacePopup, NSView(), countLabel,
        ])
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        leftTitle = titleLabel(left)
        rightTitle = titleLabel(right)
        let topDivider = SeparatorLine(.horizontal)
        let titleDivider = SeparatorLine(.horizontal)
        for view in [leftEditor, rightEditor, connector, unifiedContainer] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        binaryLabel.isHidden = !isBinary

        for view in [toolbar, topDivider, leftTitle!, rightTitle!, titleDivider, leftEditor, connector, rightEditor, unifiedContainer, binaryLabel] as [NSView] {
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
            leftTitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
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

            unifiedContainer.topAnchor.constraint(equalTo: titleDivider.bottomAnchor),
            unifiedContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            unifiedContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            unifiedContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            binaryLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            binaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        connector.leftEditor = leftEditor
        connector.rightEditor = rightEditor
        // 两侧同步滚动：只保留右侧的垂直滚动条，避免两个滚动条挤在中间。
        leftEditor.scrollView.hasVerticalScroller = false
    }

    private func titleLabel(_ side: DiffSide) -> NSTextField {
        NSTextField.label(Self.title(side), font: Theme.smallFont, color: Theme.secondaryText)
    }

    private static func title(_ side: DiffSide) -> String {
        side.text == nil ? tr("diff.title.missing", side.title) : side.title
    }

    @objc private func viewerChanged() {
        Self.prefersUnified = isUnified
        applyViewer()
        rebuildUnified()
    }

    private func applyViewer() {
        let unified = isUnified
        for view in [leftEditor, rightEditor, connector] as [NSView] { view.isHidden = unified || isBinary }
        unifiedContainer.isHidden = !unified || isBinary
        rightTitle.isHidden = unified
        leftTitle.stringValue = unified ? "\(Self.title(left))  →  \(Self.title(right))" : Self.title(left)
    }

    // MARK: - 计算差异

    @objc private func whitespaceChanged() {
        recompute()
    }

    private func recompute() {
        let base = left.text ?? ""
        let text = right.text ?? ""
        let mode = whitespaceMode
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
            self.rebuildUnified()
            self.selectionChanged()
            #if DEBUG
            // 仅 Debug：`-debug.excludeBlock <下标>` 打开后把该块移出提交，用于验证部分提交。
            if let raw = UserDefaults.standard.string(forKey: "debug.excludeBlock"), let index = Int(raw), self.blockState(index) == .on {
                self.toggleBlock(index)
            }
            #endif
        }
    }

    private func updateCountLabel() {
        guard !blocks.isEmpty else {
            countLabel.stringValue = tr("diff.identical")
            return
        }
        var text = blocks.count == 1 ? tr("diff.count.one") : tr("diff.count", "\(blocks.count)")
        if isSelectable, let selection = currentSelection, !selection.isEmpty {
            let included = blocks.indices.filter { blockState($0) != .off }.count
            text = tr("diff.included", "\(included)", "\(blocks.count)")
        }
        countLabel.stringValue = text
    }

    // MARK: - 统一视图

    private func rebuildUnified() {
        guard isUnified, !isBinary else { return }
        unified = UnifiedModel(base: left.text ?? "", text: right.text ?? "", blocks: blocks)
        unifiedEditor?.removeFromSuperview()
        let editor = CodeEditorView(text: unified.text, language: language, isEditable: false)
        editor.translatesAutoresizingMaskIntoConstraints = false
        unifiedContainer.addSubview(editor)
        editor.pinEdges(to: unifiedContainer)
        let model = unified
        let width = String(max(model.maxOld, model.maxNew)).count
        editor.setLineNumbers(width: width * 2 + 1) { row in
            guard model.rows.indices.contains(row) else { return nil }
            let r = model.rows[row]
            let old = r.old.map { String($0 + 1) } ?? ""
            let new = r.new.map { String($0 + 1) } ?? ""
            return old.leftPadded(to: width) + " " + new.leftPadded(to: width)
        }
        if inclusion != nil {
            editor.onLineNumberClick = { [weak self] row in
                guard let self, self.unified.rows.indices.contains(row) else { return }
                let r = self.unified.rows[row]
                switch r.kind {
                case .added: if let new = r.new { self.toggleLine(newLine: UInt32(new)) }
                case .deleted: if let old = r.old { self.toggleLine(baseLine: UInt32(old)) }
                case .context: break
                }
            }
        }
        unifiedBackground = UnifiedBackgroundView(textView: editor.textView, model: model)
        unifiedEditor = editor
        updateExcludedDisplay()
    }

    // MARK: - 部分提交

    private var currentSelection: LineSelectionStore.Selection? {
        guard let inclusion else { return nil }
        return inclusion.store.selection(for: inclusion.path)
    }

    /// 选择的基准与本视图的内容不同（文件已改变）时，按全部提交处理。
    private var editableSelection: LineSelectionStore.Selection {
        if let selection = currentSelection, selection.base == (left.text ?? ""), selection.text == (right.text ?? "") {
            return selection
        }
        return .init(base: left.text ?? "", text: right.text ?? "")
    }

    private func blockState(_ index: Int) -> NSControl.StateValue {
        let c = blocks[index].change
        let selection = editableSelection
        let newLines = (c.start ..< c.start + c.count)
        let baseLines = (c.baseStart ..< c.baseStart + c.baseCount)
        let excluded = newLines.filter(selection.excludedLines.contains).count + baseLines.filter(selection.excludedBaseLines.contains).count
        let total = newLines.count + baseLines.count
        return excluded == 0 ? .on : (excluded == total ? .off : .mixed)
    }

    private func toggleBlock(_ index: Int) {
        guard let inclusion, isSelectable, blocks.indices.contains(index) else { return }
        let c = blocks[index].change
        var selection = editableSelection
        let include = blockState(index) != .on
        for line in c.start ..< c.start + c.count {
            if include { selection.excludedLines.remove(line) } else { selection.excludedLines.insert(line) }
        }
        for line in c.baseStart ..< c.baseStart + c.baseCount {
            if include { selection.excludedBaseLines.remove(line) } else { selection.excludedBaseLines.insert(line) }
        }
        inclusion.store.update(inclusion.path, selection)
    }

    private func toggleLine(newLine: UInt32? = nil, baseLine: UInt32? = nil) {
        guard let inclusion, isSelectable else { return }
        var selection = editableSelection
        if let newLine, blocks.contains(where: { $0.change.start <= newLine && newLine < $0.change.start + $0.change.count }) {
            if selection.excludedLines.remove(newLine) == nil { selection.excludedLines.insert(newLine) }
        } else if let baseLine, blocks.contains(where: { $0.change.baseStart <= baseLine && baseLine < $0.change.baseStart + $0.change.baseCount }) {
            if selection.excludedBaseLines.remove(baseLine) == nil { selection.excludedBaseLines.insert(baseLine) }
        } else {
            return
        }
        inclusion.store.update(inclusion.path, selection)
    }

    private func selectionChanged() {
        updateExcludedDisplay()
        updateCountLabel()
    }

    private func updateExcludedDisplay() {
        let selection = isSelectable ? editableSelection : nil
        rightBackground.excluded = selection?.excludedLines ?? []
        leftBackground.excluded = selection?.excludedBaseLines ?? []
        connector.states = isSelectable ? blocks.indices.map(blockState) : []
        unifiedBackground?.excludedNew = selection?.excludedLines ?? []
        unifiedBackground?.excludedOld = selection?.excludedBaseLines ?? []
        let tooltip = isSelectable ? tr("diff.include.tooltip") : nil
        [leftEditor, rightEditor, unifiedEditor].forEach { $0?.toolTip = nil }
        connector.toolTip = tooltip
    }

    // MARK: - 跳转到源码（IDEA 的 Jump to Source，F4）

    private func updateJumpToSource() {
        guard let jumpButton else { return }
        jumpButton.isHidden = source == nil
        // 文件在工作区中已不存在（例如已删除）时不能跳转。
        jumpButton.isEnabled = source.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
    }

    /// 取有焦点的一侧的光标行，换算为新版本中的行；右侧不是工作区版本时再映射到当前文件。
    @objc func jumpToSource() {
        guard let source, FileManager.default.fileExists(atPath: source.url.path) else { return }
        var line = newSideLine()
        if !source.rightIsWorkingTree, let rightText = right.text,
           let current = currentText?(source.url) ?? (try? String(contentsOf: source.url, encoding: .utf8)) {
            line = Self.mapLine(GitDeckCore.lineChanges(base: rightText, text: current), line, fromBase: true)
        }
        onJumpToSource?(source.url, max(0, line))
    }

    private func newSideLine() -> Int {
        if isUnified, let unifiedEditor {
            if !unifiedEditor.hasUserCaret, let first = blocks.first { return Int(first.change.start) }
            let rows = unified.rows
            // 删除的行在新版本中没有对应：取其后第一个有新版本行号的行。
            var index = min(unifiedEditor.caretLine, rows.count - 1)
            while index >= 0, index < rows.count {
                if let new = rows[index].new { return new }
                index += 1
            }
            return max(0, unified.maxNew - 1)
        }
        if window?.firstResponder === leftEditor.textView, leftEditor.hasUserCaret {
            return Self.mapLine(blocks.map { $0.change }, leftEditor.caretLine, fromBase: true)
        }
        // 还没有放置过光标时与 IDEA 一样定位到第一处差异。
        if !rightEditor.hasUserCaret, !leftEditor.hasUserCaret, let first = blocks.first {
            return Int(first.change.start)
        }
        return rightEditor.caretLine
    }

    /// 按行变更把一侧的行换算到另一侧：变更段之前按偏移平移，落在变更段内时取对应段的起始行（与 IDEA 一致）。
    static func mapLine(_ changes: [LineChange], _ line: Int, fromBase: Bool) -> Int {
        var delta = 0
        for c in changes {
            let (fromStart, fromCount, toStart, toCount) = fromBase
                ? (Int(c.baseStart), Int(c.baseCount), Int(c.start), Int(c.count))
                : (Int(c.start), Int(c.count), Int(c.baseStart), Int(c.baseCount))
            if line < fromStart { break }
            if line < fromStart + fromCount { return toStart + min(line - fromStart, max(0, toCount - 1)) }
            delta = toStart + toCount - (fromStart + fromCount)
        }
        return line + delta
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
        if isUnified, let unifiedEditor {
            let top = unifiedEditor.topVisibleLine
            return unified.blockRows.firstIndex { Double($0) >= top } ?? 0
        }
        let top = rightEditor.topVisibleLine
        return blocks.firstIndex { Double($0.change.start) >= top } ?? 0
    }

    private func go(to index: Int) {
        currentBlock = index
        if isUnified, let unifiedEditor, unified.blockRows.indices.contains(index) {
            unifiedEditor.reveal(line: unified.blockRows[index])
            return
        }
        rightEditor.reveal(line: Int(blocks[index].change.start))
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
        let segments = blocks.map { block in
            let c = block.change
            let segment = LineSegment(
                fromStart: Double(c.baseStart), fromCount: Double(c.baseCount),
                toStart: Double(c.start), toCount: Double(c.count)
            )
            return source === leftEditor ? segment : segment.reversed
        }
        isSyncingScroll = true
        target.scroll(toLine: LineMapping.map(source.topVisibleLine, segments))
        isSyncingScroll = false
        connector.needsDisplay = true
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - 统一视图模型

/// 统一视图的行：上下文行、删除的行（来自基准）、新增的行（来自新版本）。
struct UnifiedModel {
    enum Kind { case context, deleted, added }

    struct Row {
        let kind: Kind
        let old: Int?
        let new: Int?
        /// 所属变更块的种类（用于配色）。
        let blockKind: LineChangeKind?
    }

    private(set) var rows: [Row] = []
    private(set) var text = ""
    /// 每个变更块在统一视图中的第一行。
    private(set) var blockRows: [Int] = []
    private(set) var maxOld = 0
    private(set) var maxNew = 0

    init() {}

    init(base: String, text newText: String, blocks: [DiffBlock]) {
        let old = Self.lines(base)
        let new = Self.lines(newText)
        maxOld = old.count
        maxNew = new.count
        var lines: [String] = []
        var oldPos = 0
        var newPos = 0
        func context(until oldEnd: Int) {
            while oldPos < oldEnd, oldPos < old.count {
                rows.append(Row(kind: .context, old: oldPos, new: newPos, blockKind: nil))
                lines.append(old[oldPos])
                oldPos += 1
                newPos += 1
            }
        }
        for block in blocks {
            let c = block.change
            context(until: Int(c.baseStart))
            newPos = Int(c.start)
            blockRows.append(rows.count)
            for i in Int(c.baseStart) ..< Int(c.baseStart + c.baseCount) where i < old.count {
                rows.append(Row(kind: .deleted, old: i, new: nil, blockKind: c.kind))
                lines.append(old[i])
            }
            for j in Int(c.start) ..< Int(c.start + c.count) where j < new.count {
                rows.append(Row(kind: .added, old: nil, new: j, blockKind: c.kind))
                lines.append(new[j])
            }
            oldPos = Int(c.baseStart + c.baseCount)
            newPos = Int(c.start + c.count)
        }
        context(until: old.count)
        text = lines.joined(separator: "\n")
    }

    /// 新版本第 `line` 行在统一视图中的行。
    func row(forNewLine line: Int) -> Int {
        rows.firstIndex { $0.new == line } ?? 0
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}

/// 统一视图的行背景：删除的行与新增的行分别着色，不提交的行变浅。
final class UnifiedBackgroundView: NSView {
    private weak var textView: TextView?
    private let model: UnifiedModel
    var excludedNew: Set<UInt32> = [] { didSet { needsDisplay = true } }
    var excludedOld: Set<UInt32> = [] { didSet { needsDisplay = true } }

    init(textView: TextView, model: UnifiedModel) {
        self.textView = textView
        self.model = model
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
        guard let storage = textView?.layoutManager?.lineStorage else { return }
        for (index, row) in model.rows.enumerated() where row.kind != .context {
            guard let line = storage.getLine(atIndex: index) else { continue }
            let rect = NSRect(x: 0, y: line.yPos, width: bounds.width, height: line.height)
            guard rect.intersects(dirtyRect) else { continue }
            let excluded = row.kind == .added
                ? row.new.map { excludedNew.contains(UInt32($0)) } ?? false
                : row.old.map { excludedOld.contains(UInt32($0)) } ?? false
            let color = DiffColors.block(row.kind == .added ? .added : .deleted)
            (excluded ? color.withAlphaComponent(0.3) : color).setFill()
            rect.fill()
        }
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

/// 画在文本下方的变更背景：整行宽的块背景 + 单词级高亮；不提交的行变浅。
///
/// 作为 TextView 的子视图加入，图层 zPosition 为 -1，因而位于文字之下。
final class DiffBackgroundView: NSView {
    enum Side { case base, new }

    var blocks: [DiffBlock] = [] {
        didSet { needsDisplay = true }
    }

    /// 本侧不提交的行。
    var excluded: Set<UInt32> = [] {
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
            let hasExcluded = (start ..< start + count).contains(where: excluded.contains)
            if hasExcluded {
                for index in start ..< start + count {
                    guard let line = storage.getLine(atIndex: Int(index)) else { continue }
                    let color = DiffColors.block(c.kind)
                    (excluded.contains(index) ? color.withAlphaComponent(0.3) : color).setFill()
                    NSRect(x: 0, y: line.yPos, width: bounds.width, height: line.height).fill()
                }
            } else {
                DiffColors.block(c.kind).setFill()
                rect.fill()
            }

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
/// 可部分提交时在每个块上画复选框，点击切换整块是否提交。
final class DiffConnectorView: NSView {
    weak var leftEditor: CodeEditorView?
    weak var rightEditor: CodeEditorView?
    var onToggleBlock: ((Int) -> Void)?

    var blocks: [DiffBlock] = [] {
        didSet { needsDisplay = true }
    }

    /// 每个块的勾选状态；为空时不显示复选框。
    var states: [NSControl.StateValue] = [] {
        didSet { needsDisplay = true }
    }

    private var checkboxRects: [(Int, NSRect)] = []

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (index, _) = checkboxRects.first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(point) }) {
            onToggleBlock?(index)
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        checkboxRects = []
        guard let leftEditor, let rightEditor else { return }
        for (index, block) in blocks.enumerated() {
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
            let excluded = states.indices.contains(index) && states[index] == .off
            (excluded ? DiffColors.block(c.kind).withAlphaComponent(0.3) : DiffColors.block(c.kind)).setFill()
            path.fill()
            DiffColors.marker(c.kind).setStroke()
            path.lineWidth = 1
            path.stroke()

            if states.indices.contains(index) {
                let size: CGFloat = 14
                let top = (lTop + rTop) / 2
                let rect = NSRect(x: (w - size) / 2, y: top + 2, width: size, height: size)
                drawCheckbox(in: rect, state: states[index], kind: c.kind)
                checkboxRects.append((index, rect))
            }
        }
    }

    private func drawCheckbox(in rect: NSRect, state: NSControl.StateValue, kind: LineChangeKind) {
        let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (state == .off ? Theme.editorBackground : Theme.accent).setFill()
        box.fill()
        (state == .off ? DiffColors.marker(kind) : Theme.accent).setStroke()
        box.lineWidth = 1
        box.stroke()
        guard state != .off else { return }
        let mark = NSBezierPath()
        mark.lineWidth = 1.8
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        if state == .mixed {
            mark.move(to: NSPoint(x: rect.minX + 3.5, y: rect.midY))
            mark.line(to: NSPoint(x: rect.maxX - 3.5, y: rect.midY))
        } else {
            mark.move(to: NSPoint(x: rect.minX + 3.5, y: rect.midY))
            mark.line(to: NSPoint(x: rect.midX - 1, y: rect.maxY - 3.5))
            mark.line(to: NSPoint(x: rect.maxX - 3.2, y: rect.minY + 3.5))
        }
        NSColor.white.setStroke()
        mark.stroke()
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
