import AppKit
import CodeEditTextView
import GitDeckCore

/// 三栏合并工具（IDEA 的 Merge Revisions）：左为 “我们” 的版本，中为结果（可编辑），右为 “他们” 的版本。
///
/// 结果栏初始为共同祖先的内容；用连接带上的 `»` / `«` 把一侧的修改应用到结果，`×` 忽略该侧修改。
/// 冲突块两侧都可以应用（后应用的一侧追加在前者之后）。点击 “应用” 写入结果并标记为已解决。
@MainActor
final class MergeWindowController: NSWindowController, NSWindowDelegate {
    enum Side { case left, right }

    /// 一个三方变更块及其在结果文本中的当前位置与处理状态。
    final class ChunkState {
        let chunk: MergeChunk
        var resultStart: Int
        var resultCount: Int
        var leftApplied = false
        var rightApplied = false
        var leftIgnored = false
        var rightIgnored = false

        init(_ chunk: MergeChunk) {
            self.chunk = chunk
            resultStart = Int(chunk.baseStart)
            resultCount = Int(chunk.baseCount)
        }

        var leftHandled: Bool { leftApplied || leftIgnored }
        var rightHandled: Bool { rightApplied || rightIgnored }

        var isResolved: Bool {
            switch chunk.kind {
            case .ours: leftHandled
            case .theirs: rightHandled
            case .both: leftHandled || rightHandled
            case .conflict: leftHandled && rightHandled
            }
        }

        func canAct(_ side: Side) -> Bool {
            guard !isResolved else { return false }
            switch side {
            case .left: return chunk.kind != .theirs && !leftHandled
            case .right: return chunk.kind != .ours && !rightHandled
            }
        }
    }

    var onClose: (() -> Void)?

    private let model: ProjectModel
    private let path: String
    private let labels: ConflictLabels
    private let baseLines: [String]
    private let oursLines: [String]
    private let theirsLines: [String]
    private let leftEditor: CodeEditorView
    private let centerEditor: CodeEditorView
    private let rightEditor: CodeEditorView
    private let leftBackground: MergeBackgroundView
    private let centerBackground: MergeBackgroundView
    private let rightBackground: MergeBackgroundView
    private let leftConnector: MergeConnectorView
    private let rightConnector: MergeConnectorView
    private let countLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let applyButton = NSButton(title: tr("merge.apply"), target: nil, action: nil)

    private var chunks: [ChunkState]
    private var isApplyingChunk = false
    private var isSyncingScroll = false
    private var isModified = false
    private var isSaving = false
    private var pendingEdit: (startLine: Int, endLine: Int, oldNewlines: Int)?
    private var observers: [NSObjectProtocol] = []

    init(model: ProjectModel, path: String, versions: ConflictVersions, labels: ConflictLabels, chunks: [MergeChunk]) {
        self.model = model
        self.path = path
        self.labels = labels
        let base = versions.base ?? ""
        let ours = versions.ours ?? ""
        let theirs = versions.theirs ?? ""
        baseLines = Self.splitLines(base)
        oursLines = Self.splitLines(ours)
        theirsLines = Self.splitLines(theirs)
        self.chunks = chunks.map(ChunkState.init)

        let language = languageForPath(path: path)
        leftEditor = CodeEditorView(text: ours, language: language, isEditable: false)
        centerEditor = CodeEditorView(text: base, language: language, isEditable: true)
        rightEditor = CodeEditorView(text: theirs, language: language, isEditable: false)
        leftBackground = MergeBackgroundView(textView: leftEditor.textView)
        centerBackground = MergeBackgroundView(textView: centerEditor.textView)
        rightBackground = MergeBackgroundView(textView: rightEditor.textView)
        leftConnector = MergeConnectorView(side: .left)
        rightConnector = MergeConnectorView(side: .right)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("merge.window.title", path)
        window.minSize = NSSize(width: 900, height: 480)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.center()
        buildLayout()
        wireEditors()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    #if DEBUG
    /// 仅 Debug：在结果栏执行一次撤销。
    func debugUndo() {
        centerEditor.textView._undoManager?.undo()
    }
    #endif

    /// 按 `\n` 切分并保留行尾（与核心的行号规则一致，`\r\n` 中的 `\r` 留在行内）。
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            current.append(scalar)
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    // MARK: - 布局

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        let background = ColoredView(Theme.editorBackground)
        content.addSubview(background)
        background.pinEdges(to: content)

        func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 26, pointSize: 12)
            b.target = self
            b.action = action
            return b
        }
        let toolbar = NSStackView(views: [
            button("wand.and.stars", tr("merge.applyNonConflicting"), #selector(applyNonConflicting)),
            button("arrow.up", tr("merge.previousConflict"), #selector(previousChange)),
            button("arrow.down", tr("merge.nextConflict"), #selector(nextChange)),
            NSView(), countLabel,
        ])
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let leftTitle = NSTextField.label(tr("merge.title.side", labels.ours), font: Theme.smallFont, color: Theme.secondaryText)
        let centerTitle = NSTextField.label(tr("merge.title.result"), font: .systemFont(ofSize: 12, weight: .semibold))
        let rightTitle = NSTextField.label(tr("merge.title.side", labels.theirs), font: Theme.smallFont, color: Theme.secondaryText)

        let acceptLeft = NSButton(title: tr("merge.acceptSide", labels.ours), target: self, action: #selector(acceptLeftFile))
        let acceptRight = NSButton(title: tr("merge.acceptSide", labels.theirs), target: self, action: #selector(acceptRightFile))
        let cancel = NSButton(title: tr("common.cancel"), target: self, action: #selector(cancel))
        applyButton.target = self
        applyButton.action = #selector(applyResult)
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [acceptLeft, acceptRight, NSView(), cancel, applyButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let topDivider = SeparatorLine(.horizontal)
        let bottomDivider = SeparatorLine(.horizontal)
        let panes = [leftEditor, leftConnector, centerEditor, rightConnector, rightEditor] as [NSView]
        for view in panes { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [toolbar, topDivider, leftTitle, centerTitle, rightTitle, bottomDivider, buttons] + panes {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            topDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            topDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            leftTitle.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 6),
            leftTitle.leadingAnchor.constraint(equalTo: leftEditor.leadingAnchor, constant: 10),
            leftTitle.trailingAnchor.constraint(lessThanOrEqualTo: leftEditor.trailingAnchor, constant: -10),
            centerTitle.centerYAnchor.constraint(equalTo: leftTitle.centerYAnchor),
            centerTitle.leadingAnchor.constraint(equalTo: centerEditor.leadingAnchor, constant: 10),
            rightTitle.centerYAnchor.constraint(equalTo: leftTitle.centerYAnchor),
            rightTitle.leadingAnchor.constraint(equalTo: rightEditor.leadingAnchor, constant: 10),
            rightTitle.trailingAnchor.constraint(lessThanOrEqualTo: rightEditor.trailingAnchor, constant: -10),

            leftEditor.topAnchor.constraint(equalTo: leftTitle.bottomAnchor, constant: 6),
            leftEditor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftEditor.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            leftConnector.topAnchor.constraint(equalTo: leftEditor.topAnchor),
            leftConnector.bottomAnchor.constraint(equalTo: leftEditor.bottomAnchor),
            leftConnector.leadingAnchor.constraint(equalTo: leftEditor.trailingAnchor),
            leftConnector.widthAnchor.constraint(equalToConstant: 48),
            centerEditor.topAnchor.constraint(equalTo: leftEditor.topAnchor),
            centerEditor.bottomAnchor.constraint(equalTo: leftEditor.bottomAnchor),
            centerEditor.leadingAnchor.constraint(equalTo: leftConnector.trailingAnchor),
            centerEditor.widthAnchor.constraint(equalTo: leftEditor.widthAnchor),
            rightConnector.topAnchor.constraint(equalTo: leftEditor.topAnchor),
            rightConnector.bottomAnchor.constraint(equalTo: leftEditor.bottomAnchor),
            rightConnector.leadingAnchor.constraint(equalTo: centerEditor.trailingAnchor),
            rightConnector.widthAnchor.constraint(equalToConstant: 48),
            rightEditor.topAnchor.constraint(equalTo: leftEditor.topAnchor),
            rightEditor.bottomAnchor.constraint(equalTo: leftEditor.bottomAnchor),
            rightEditor.leadingAnchor.constraint(equalTo: rightConnector.trailingAnchor),
            rightEditor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightEditor.widthAnchor.constraint(equalTo: leftEditor.widthAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        leftConnector.outer = leftEditor
        leftConnector.center = centerEditor
        rightConnector.outer = rightEditor
        rightConnector.center = centerEditor
        for connector in [leftConnector, rightConnector] {
            connector.onApply = { [weak self, weak connector] index in
                guard let self, let connector else { return }
                self.apply(index, side: connector.side)
            }
            connector.onIgnore = { [weak self, weak connector] index in
                guard let self, let connector else { return }
                self.ignore(index, side: connector.side)
            }
        }
    }

    private func wireEditors() {
        centerEditor.onWillReplace = { [weak self] range, string in self?.willEdit(range, string) }
        centerEditor.onDidReplace = { [weak self] _, string in self?.didEdit(string) }
        for editor in [leftEditor, centerEditor, rightEditor] {
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: editor.scrollView.contentView,
                queue: .main
            ) { [weak self, weak editor] _ in
                MainActor.assumeIsolated {
                    guard let self, let editor else { return }
                    self.syncScroll(from: editor)
                }
            }
            observers.append(token)
        }
    }

    // MARK: - 应用与忽略

    private func apply(_ index: Int, side: Side) {
        let state = chunks[index]
        guard state.canAct(side) else { return }
        let c = state.chunk
        let lines = side == .left
            ? oursLines[Int(c.oursStart)..<Int(c.oursStart + c.oursCount)]
            : theirsLines[Int(c.theirsStart)..<Int(c.theirsStart + c.theirsCount)]
        // 冲突块另一侧已应用时，本侧追加在其后，保留双方内容。
        let otherApplied = side == .left ? state.rightApplied : state.leftApplied
        let append = c.kind == .conflict && otherApplied
        let range = append
            ? resultRange(start: state.resultStart + state.resultCount, count: 0)
            : resultRange(start: state.resultStart, count: state.resultCount)
        let newCount = append ? state.resultCount + lines.count : lines.count

        isApplyingChunk = true
        centerEditor.textView.replaceCharacters(in: range, with: lines.joined())
        isApplyingChunk = false

        let delta = newCount - state.resultCount
        state.resultCount = newCount
        for later in chunks[(index + 1)...] { later.resultStart += delta }
        if side == .left { state.leftApplied = true } else { state.rightApplied = true }
        isModified = true
        refresh()
    }

    private func ignore(_ index: Int, side: Side) {
        let state = chunks[index]
        guard state.canAct(side) else { return }
        if side == .left { state.leftIgnored = true } else { state.rightIgnored = true }
        refresh()
    }

    /// IDEA 的 “Apply All Non-Conflicting Changes”（魔术棒按钮）。
    @objc private func applyNonConflicting() {
        for (index, state) in chunks.enumerated() where !state.isResolved && state.chunk.kind != .conflict {
            apply(index, side: state.chunk.kind == .theirs ? .right : .left)
        }
    }

    /// 结果文本中 `[start, start + count)` 行对应的字符范围（含行尾）。
    private func resultRange(start: Int, count: Int) -> NSRange {
        let storage = centerEditor.textView.layoutManager.lineStorage
        let length = centerEditor.textView.textStorage.length
        let location = storage.getLine(atIndex: start)?.range.location ?? length
        guard count > 0, let last = storage.getLine(atIndex: start + count - 1) else {
            return NSRange(location: location, length: 0)
        }
        return NSRange(location: location, length: NSMaxRange(last.range) - location)
    }

    // MARK: - 跟踪结果栏中的手动编辑

    private func willEdit(_ range: NSRange, _ string: String) {
        guard !isApplyingChunk, let layout = centerEditor.textView.layoutManager else { return }
        let text = centerEditor.textView.string as NSString
        let old = text.substring(with: range)
        let startLine = layout.textLineForOffset(range.location)?.index ?? max(0, layout.lineCount - 1)
        let endLine = layout.textLineForOffset(NSMaxRange(range))?.index ?? max(0, layout.lineCount - 1)
        pendingEdit = (startLine, endLine, old.filter { $0 == "\n" || $0 == "\r\n" }.count)
    }

    private func didEdit(_ string: String) {
        guard !isApplyingChunk, let edit = pendingEdit else { return }
        pendingEdit = nil
        let delta = string.filter { $0 == "\n" || $0 == "\r\n" }.count - edit.oldNewlines
        for state in chunks {
            let end = state.resultStart + state.resultCount
            if state.resultStart > edit.endLine {
                state.resultStart += delta
            } else if end > edit.startLine || (state.resultCount == 0 && state.resultStart >= edit.startLine) {
                // 编辑落在块内：块随之伸缩，保持未解决状态。
                state.resultCount = max(0, state.resultCount + delta)
            }
        }
        reconcileAppliedState()
        isModified = true
        refresh()
    }

    /// 撤销 / 重做会改变结果栏中块的内容：按块的当前内容重新判断哪一侧已应用，
    /// 使撤销 “应用” 后该块恢复为未处理（可再次应用），重做后重新标记为已应用。
    private func reconcileAppliedState() {
        let text = centerEditor.textView.string as NSString
        for state in chunks {
            let c = state.chunk
            let range = resultRange(start: state.resultStart, count: state.resultCount)
            guard NSMaxRange(range) <= text.length else { continue }
            let current = Self.splitLines(text.substring(with: range))
            let base = Array(baseLines[Self.slice(c.baseStart, c.baseCount, in: baseLines)])
            let ours = Array(oursLines[Self.slice(c.oursStart, c.oursCount, in: oursLines)])
            let theirs = Array(theirsLines[Self.slice(c.theirsStart, c.theirsCount, in: theirsLines)])
            switch current {
            case base:
                state.leftApplied = false
                state.rightApplied = false
            case ours where c.kind != .theirs:
                state.leftApplied = true
                state.rightApplied = false
            case theirs where c.kind != .ours:
                state.leftApplied = false
                state.rightApplied = true
            case ours + theirs where c.kind == .conflict, theirs + ours where c.kind == .conflict:
                state.leftApplied = true
                state.rightApplied = true
            default:
                // 手动编辑过的内容：保持原状态。
                break
            }
        }
    }

    private static func slice(_ start: UInt32, _ count: UInt32, in lines: [String]) -> Range<Int> {
        let lower = min(Int(start), lines.count)
        return lower ..< min(lower + Int(count), lines.count)
    }

    // MARK: - 刷新显示

    private func refresh() {
        var left: [MergeBackgroundView.Highlight] = []
        var center: [MergeBackgroundView.Highlight] = []
        var right: [MergeBackgroundView.Highlight] = []
        for state in chunks where !state.isResolved {
            let c = state.chunk
            let conflict = c.kind == .conflict
            if state.canAct(.left) {
                left.append(.init(start: Int(c.oursStart), count: Int(c.oursCount),
                                  kind: conflict ? nil : Self.kind(base: c.baseCount, side: c.oursCount)))
            }
            if state.canAct(.right) {
                right.append(.init(start: Int(c.theirsStart), count: Int(c.theirsCount),
                                   kind: conflict ? nil : Self.kind(base: c.baseCount, side: c.theirsCount)))
            }
            let sideCount = c.kind == .theirs ? c.theirsCount : c.oursCount
            center.append(.init(start: state.resultStart, count: state.resultCount,
                                kind: conflict ? nil : Self.kind(base: c.baseCount, side: sideCount)))
        }
        leftBackground.highlights = left
        centerBackground.highlights = center
        rightBackground.highlights = right
        leftConnector.chunks = chunks
        rightConnector.chunks = chunks

        let unresolved = chunks.filter { !$0.isResolved }
        let conflicts = unresolved.filter { $0.chunk.kind == .conflict }.count
        countLabel.stringValue = unresolved.isEmpty
            ? tr("merge.allResolved")
            : tr("merge.count", "\(unresolved.count)", "\(conflicts)")
    }

    /// 非冲突块按该侧相对基准的变化着色：新增、删除或修改。
    private static func kind(base: UInt32, side: UInt32) -> LineChangeKind {
        if base == 0 { return .added }
        if side == 0 { return .deleted }
        return .modified
    }

    // MARK: - 跳转与同步滚动

    @objc private func nextChange() { navigate(forward: true) }
    @objc private func previousChange() { navigate(forward: false) }

    private func navigate(forward: Bool) {
        let unresolved = chunks.filter { !$0.isResolved }
        guard !unresolved.isEmpty else { return }
        let caret = centerEditor.textView.selectionManager.textSelections.first?.range.location ?? 0
        let caretLine = centerEditor.textView.layoutManager.textLineForOffset(caret)?.index ?? 0
        let target = forward
            ? unresolved.first { $0.resultStart > caretLine } ?? unresolved[0]
            : unresolved.last { $0.resultStart < caretLine } ?? unresolved[unresolved.count - 1]
        centerEditor.reveal(line: target.resultStart)
        syncScroll(from: centerEditor)
    }

    /// 结果栏到某一侧的行对应关系（包括已解决的块，保证对齐）。
    private func segments(to side: Side) -> [LineSegment] {
        chunks.map { state in
            let c = state.chunk
            let (start, count) = side == .left ? (c.oursStart, c.oursCount) : (c.theirsStart, c.theirsCount)
            return LineSegment(
                fromStart: Double(state.resultStart), fromCount: Double(state.resultCount),
                toStart: Double(start), toCount: Double(count)
            )
        }
    }

    private func syncScroll(from source: CodeEditorView) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        defer {
            isSyncingScroll = false
            leftConnector.needsDisplay = true
            rightConnector.needsDisplay = true
        }
        let toLeft = segments(to: .left)
        let toRight = segments(to: .right)
        let centerLine: Double
        if source === centerEditor {
            centerLine = centerEditor.topVisibleLine
        } else {
            let fromSide = (source === leftEditor ? toLeft : toRight).map(\.reversed)
            centerLine = LineMapping.map(source.topVisibleLine, fromSide)
            centerEditor.scroll(toLine: centerLine)
        }
        if source !== leftEditor { leftEditor.scroll(toLine: LineMapping.map(centerLine, toLeft)) }
        if source !== rightEditor { rightEditor.scroll(toLine: LineMapping.map(centerLine, toRight)) }
    }

    // MARK: - 完成

    @objc private func applyResult() {
        let unresolved = chunks.filter { !$0.isResolved }.count
        guard unresolved > 0 else { return save(content: centerEditor.text) }
        let alert = NSAlert()
        alert.messageText = tr("merge.unresolved.title")
        alert.informativeText = tr("merge.unresolved.message", "\(unresolved)")
        alert.addButton(withTitle: tr("merge.apply"))
        alert.addButton(withTitle: tr("common.cancel"))
        alert.beginSheetModal(for: window!) { [self] response in
            if response == .alertFirstButtonReturn { save(content: centerEditor.text) }
        }
    }

    @objc private func acceptLeftFile() { accept(.ours) }
    @objc private func acceptRightFile() { accept(.theirs) }

    private func save(content: String) {
        run { repository, path in try repository.resolveConflict(path: path, content: content) }
    }

    private func accept(_ side: ConflictSide) {
        run { repository, path in try repository.acceptConflictSide(path: path, side: side) }
    }

    private func run(_ work: @escaping @Sendable (Repository, String) throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        let repository = model.repository
        let path = path
        Task {
            let result = await Task.detached { Result { try work(repository, path) } }.value
            isSaving = false
            switch result {
            case .success:
                isModified = false
                model.post(tr("merge.resolved", path))
                model.refresh()
                close()
            case let .failure(error):
                let alert = NSAlert()
                alert.messageText = tr("conflicts.failed")
                alert.informativeText = errorMessage(error)
                alert.beginSheetModal(for: window!, completionHandler: nil)
            }
        }
    }

    @objc private func cancel() {
        window?.performClose(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = tr("merge.discard.title")
        alert.informativeText = tr("merge.discard.message")
        alert.addButton(withTitle: tr("merge.discard.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        alert.beginSheetModal(for: sender) { [self] response in
            if response == .alertFirstButtonReturn {
                isModified = false
                close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - 着色

/// 合并工具中的块背景：冲突为红色，非冲突按新增 / 修改 / 删除着色；行数为 0 的块画一条分隔线。
final class MergeBackgroundView: NSView {
    struct Highlight {
        let start: Int
        let count: Int
        /// `nil` 表示冲突。
        let kind: LineChangeKind?
    }

    var highlights: [Highlight] = [] {
        didSet { needsDisplay = true }
    }

    private weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
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
        for highlight in highlights {
            if highlight.count == 0 {
                let y = storage.getLine(atIndex: highlight.start)?.yPos ?? storage.last.map { $0.yPos + $0.height } ?? 0
                MergeColors.marker(highlight.kind).setFill()
                NSRect(x: 0, y: y - 1, width: bounds.width, height: 2).fill()
                continue
            }
            guard let first = storage.getLine(atIndex: highlight.start),
                  let last = storage.getLine(atIndex: highlight.start + highlight.count - 1) else { continue }
            MergeColors.block(highlight.kind).setFill()
            NSRect(x: 0, y: first.yPos, width: bounds.width, height: last.yPos + last.height - first.yPos).fill()
        }
    }
}

enum MergeColors {
    static func block(_ kind: LineChangeKind?) -> NSColor {
        kind.map(DiffColors.block) ?? Theme.dynamic(light: 0xFFDEDE, dark: 0x5C3535)
    }

    static func marker(_ kind: LineChangeKind?) -> NSColor {
        kind.map(DiffColors.marker) ?? Theme.dynamic(light: 0xE57373, dark: 0xB34A4A)
    }
}

/// 外侧编辑器与结果栏之间的连接带，带有应用（» / «）与忽略（×）按钮。
final class MergeConnectorView: NSView {
    let side: MergeWindowController.Side
    weak var outer: CodeEditorView?
    weak var center: CodeEditorView?
    var onApply: ((Int) -> Void)?
    var onIgnore: ((Int) -> Void)?

    var chunks: [MergeWindowController.ChunkState] = [] {
        didSet { needsDisplay = true }
    }

    private var buttons: [(rect: NSRect, index: Int, apply: Bool)] = []
    private static let buttonSize: CGFloat = 16

    init(side: MergeWindowController.Side) {
        self.side = side
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        buttons = []
        guard let outer, let center else { return }
        let w = bounds.width
        for (index, state) in chunks.enumerated() where state.canAct(side) {
            let c = state.chunk
            let (start, count) = side == .left ? (c.oursStart, c.oursCount) : (c.theirsStart, c.theirsCount)
            let (oTop, oBottom) = span(in: outer, start: Int(start), count: Int(count))
            let (cTop, cBottom) = span(in: center, start: state.resultStart, count: state.resultCount)
            if max(oBottom, cBottom) < 0 || min(oTop, cTop) > bounds.height { continue }

            // 外侧在左时色带从左（外侧）连到右（结果），反之亦然。
            let (x0, x1) = side == .left ? (CGFloat(0), w) : (w, CGFloat(0))
            let (top0, bottom0, top1, bottom1) = (oTop, oBottom, cTop, cBottom)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x0, y: top0))
            path.curve(to: NSPoint(x: x1, y: top1), controlPoint1: NSPoint(x: w / 2, y: top0), controlPoint2: NSPoint(x: w / 2, y: top1))
            path.line(to: NSPoint(x: x1, y: bottom1))
            path.curve(to: NSPoint(x: x0, y: bottom0), controlPoint1: NSPoint(x: w / 2, y: bottom1), controlPoint2: NSPoint(x: w / 2, y: bottom0))
            path.close()
            let kind: LineChangeKind? = c.kind == .conflict ? nil : (c.baseCount == 0 ? .added : (count == 0 ? .deleted : .modified))
            MergeColors.block(kind).setFill()
            path.fill()
            MergeColors.marker(kind).setStroke()
            path.lineWidth = 1
            path.stroke()

            // 按钮放在外侧一端：应用（» / «）与忽略（×）。
            let size = Self.buttonSize
            let y = max(2, min(oTop + 2, bounds.height - size - 2))
            let applyX = side == .left ? 2 : w - size - 2
            let ignoreX = side == .left ? applyX + size + 2 : applyX - size - 2
            let applyRect = NSRect(x: applyX, y: y, width: size, height: size)
            let ignoreRect = NSRect(x: ignoreX, y: y, width: size, height: size)
            drawSymbol(side == .left ? "chevron.right.2" : "chevron.left.2", in: applyRect, color: Theme.accent)
            drawSymbol("xmark", in: ignoreRect, color: Theme.secondaryText)
            buttons.append((applyRect, index, true))
            buttons.append((ignoreRect, index, false))
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        Theme.editorBackground.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) else { return }
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let origin = NSPoint(x: rect.midX - tinted.size.width / 2, y: rect.midY - tinted.size.height / 2)
        tinted.draw(in: NSRect(origin: origin, size: tinted.size), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = buttons.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) else { return }
        if hit.apply { onApply?(hit.index) } else { onIgnore?(hit.index) }
    }

    override func resetCursorRects() {
        for button in buttons { addCursorRect(button.rect, cursor: .pointingHand) }
    }

    /// 块在编辑器可见区域中的上下边界（相对本视图顶部）。
    private func span(in editor: CodeEditorView, start: Int, count: Int) -> (CGFloat, CGFloat) {
        let storage = editor.textView.layoutManager.lineStorage
        let offset = editor.scrollView.contentView.bounds.minY
        let top = storage.getLine(atIndex: start)?.yPos ?? storage.last.map { $0.yPos + $0.height } ?? 0
        guard count > 0, let last = storage.getLine(atIndex: start + count - 1) else {
            return (top - offset, top - offset)
        }
        return (top - offset, last.yPos + last.height - offset)
    }
}
