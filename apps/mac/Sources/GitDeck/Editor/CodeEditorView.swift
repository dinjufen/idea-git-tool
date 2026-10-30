import AppKit
import CodeEditTextView
import GitDeckCore

/// 代码编辑器：CodeEditTextView 文本视图 + 行号 gutter + 语法高亮 + 查找栏。
///
/// 语法高亮由 Rust 核心的 tree-sitter 在后台计算；编辑器、Diff 视图与三栏合并都复用这个视图。
final class CodeEditorView: NSView, @preconcurrency TextViewDelegate {
    var onTextChange: (() -> Void)?
    var onCaretChange: ((_ line: Int, _ column: Int) -> Void)?
    /// 文本即将被替换 / 已被替换（参数为替换前的范围与新文本）。合并工具据此跟踪结果栏中的手动编辑。
    var onWillReplace: ((NSRange, String) -> Void)?
    var onDidReplace: ((NSRange, String) -> Void)?

    let textView: TextView
    /// Diff 视图需要读取与设置滚动位置以实现两侧同步。
    let scrollView = NSScrollView()
    private let gutter: GutterView
    private let annotationView: AnnotationGutterView
    private var annotationWidth: NSLayoutConstraint!
    private let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint!

    /// 语言标识（见核心 `language_for_path`）；`nil` 表示纯文本。
    var language: String? {
        didSet { scheduleHighlight(delay: .zero) }
    }

    var lineChanges: [LineChange] {
        get { gutter.changes }
        set { gutter.changes = newValue }
    }

    var text: String { textView.string }

    /// AI 评审发现的标记（显示在行号栏）。
    var reviewMarkers: [ReviewMarker] {
        get { gutter.reviewMarkers }
        set { gutter.reviewMarkers = newValue }
    }

    var onLineNumberClick: ((Int) -> Void)? {
        get { gutter.onLineNumberClick }
        set { gutter.onLineNumberClick = newValue }
    }

    /// 自定义行号（统一 Diff 视图的新旧两列行号）及其宽度（字符数）。
    func setLineNumbers(width: Int, text: ((Int) -> String?)?) {
        gutter.lineNumberWidth = width
        gutter.lineNumberText = text
    }

    /// 重绘行号栏（选择状态变化后）。
    func redrawGutter() { gutter.needsDisplay = true }

    var onReviewMarkerClick: ((Int) -> Void)? {
        get { gutter.onMarkerClick }
        set { gutter.onMarkerClick = newValue }
    }

    /// 把全文替换为 `newText`：只替换前后不同的部分，保留撤销与滚动位置。
    func replaceText(with newText: String) {
        let old = Array(text.utf16)
        let new = Array(newText.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let range = NSRange(location: prefix, length: old.count - prefix - suffix)
        let replacement = String(utf16CodeUnits: Array(new[prefix ..< new.count - suffix]), count: new.count - prefix - suffix)
        textView.replaceCharacters(in: range, with: replacement)
    }

    /// git blame 结果：Annotate 注释列与光标行的行内提交信息共用。
    var blame: BlameResult? {
        didSet {
            inlineBlame.blame = blame
            applyAnnotationColumn()
        }
    }

    /// 显示 Annotate 注释列（需要 `blame`）。
    var showAnnotations = false {
        didSet { applyAnnotationColumn() }
    }

    private func applyAnnotationColumn() {
        let shown = showAnnotations && blame != nil
        annotationView.blame = shown ? blame : nil
        annotationWidth.constant = shown ? AnnotationGutterView.width : 0
        annotationView.isHidden = !shown
        // 注释列改变了编辑区宽度：重新计算行内提交信息的截断宽度。
        inlineBlame?.relayout()
    }

    /// 编辑后注释的行号映射（见 [`AnnotationGutterView.lineMap`]）。
    var annotationLineMap: [Int?]? {
        get { annotationView.lineMap }
        set {
            annotationView.lineMap = newValue
            inlineBlame.lineMap = newValue
        }
    }

    /// 光标行的行内提交信息。
    private(set) var inlineBlame: InlineBlameController!

    /// 点击注释列中的提交。
    var onAnnotationClick: ((String) -> Void)? {
        get { annotationView.onClickCommit }
        set { annotationView.onClickCommit = newValue }
    }

    /// 行号栏与注释列的右键菜单（例如 “Annotate with Git Blame”）。
    var gutterMenu: (() -> NSMenu?)? {
        didSet {
            gutter.contextMenu = gutterMenu
            annotationView.contextMenu = gutterMenu
        }
    }

    /// 每次文本变化递增，用于丢弃过期的后台高亮结果。
    private(set) var revision = 0
    private var highlightTask: Task<Void, Never>?
    private var lastSpans: [HighlightSpan] = []
    private var findMatches: [NSRange] = []
    private var findIndex: Int?
    private var observers: [NSObjectProtocol] = []

    /// 用户放置过光标（点击，或跳转到差异时由程序放置）；Diff 的“跳转到源码”据此判断是否使用光标行。
    var hasUserCaret = false

    init(text: String, language: String?, isEditable: Bool = true) {
        self.language = language
        textView = TextView(
            string: text,
            font: EditorSettings.font,
            textColor: SyntaxTheme.text,
            lineHeightMultiplier: EditorSettings.lineSpacing,
            wrapLines: false,
            isEditable: isEditable,
            isSelectable: true,
            letterSpacing: 1.0
        )
        gutter = GutterView(textView: textView, scrollView: scrollView)
        annotationView = AnnotationGutterView(textView: textView, scrollView: scrollView)
        super.init(frame: .zero)
        textView.delegate = self
        inlineBlame = InlineBlameController(textView: textView, scrollView: scrollView)
        if !isEditable {
            // CodeEditTextView 在只读模式下单击不会移动光标；Diff 等只读视图需要光标行（跳转到源码、当前行高亮），这里补上。
            let click = NSClickGestureRecognizer(target: self, action: #selector(readOnlyClick(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            textView.addGestureRecognizer(click)
        }
        buildLayout()
        applyColors()
        observe()
        scheduleHighlight(delay: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func readOnlyClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended,
              let offset = textView.layoutManager.textOffsetAtPoint(recognizer.location(in: textView)) else { return }
        hasUserCaret = true
        textView.selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func buildLayout() {
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.edgeInsets = HorizontalEdgeInsets(left: 6, right: 6)

        findBar.isHidden = true
        findBar.onQueryChange = { [weak self] query, caseSensitive in self?.find(query, caseSensitive: caseSensitive) }
        findBar.onNext = { [weak self] in self?.moveFind(by: 1) }
        findBar.onPrevious = { [weak self] in self?.moveFind(by: -1) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        findBar.onReplace = { [weak self] text in self?.replaceCurrent(with: text) }
        findBar.onReplaceAll = { [weak self] text in self?.replaceAll(with: text) }

        annotationView.isHidden = true
        for view in [findBar, annotationView, gutter, scrollView] as [NSView] { addSubview(view) }
        annotationWidth = annotationView.widthAnchor.constraint(equalToConstant: 0)
        // 查找栏隐藏时高度为 0；显示时由查找栏自身的高度约束（优先级略低）决定。
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBarHeight.isActive = true
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            annotationView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            annotationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            annotationView.bottomAnchor.constraint(equalTo: bottomAnchor),
            annotationWidth,
            gutter.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: annotationView.trailingAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        findBar.setContentHuggingPriority(.required, for: .vertical)
    }

    private func observe() {
        let center = NotificationCenter.default
        let redrawGutter: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.gutter.needsDisplay = true
                self?.annotationView.needsDisplay = true
            }
        }
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: redrawGutter),
            // 编辑区宽度变化（窗口缩放、打开注释列）时重新计算行内提交信息的截断宽度。
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inlineBlame.relayout() }
            },
            // 滚动时关闭行内提交信息的弹窗（与 Windows 端一致）。
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inlineBlame.closePopover() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main, using: redrawGutter),
            center.addObserver(forName: TextSelectionManager.selectionChangedNotification, object: textView.selectionManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged() }
            },
            center.addObserver(forName: EditorSettings.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            },
        ]
    }

    override func layout() {
        super.layout()
        _ = textView.updateFrameIfNeeded()
        gutter.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 文本颜色在排版时固化，外观切换后需要重新设置。
        applyColors()
        apply(lastSpans)
    }

    // MARK: - 外观

    private func applyColors() {
        textView.textColor = resolved(SyntaxTheme.text)
        textView.selectionManager.selectedLineBackgroundColor = resolved(SyntaxTheme.currentLine)
        textView.selectionManager.selectionBackgroundColor = resolved(SyntaxTheme.selection)
        textView.selectionManager.insertionPointColor = resolved(SyntaxTheme.text)
        scrollView.backgroundColor = Theme.editorBackground
        gutter.needsDisplay = true
    }

    /// 把动态颜色按当前外观解析为固定颜色（CoreText 排版时不会再跟随外观变化）。
    private func resolved(_ color: NSColor) -> NSColor {
        var result = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: color.cgColor) ?? color
        }
        return result
    }

    private func settingsChanged() {
        let font = EditorSettings.font
        textView.font = font
        textView.lineHeight = EditorSettings.lineSpacing
        gutter.font = font
        annotationView.font = font
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        _ = textView.updateFrameIfNeeded()
        inlineBlame.relayout()
    }

    // MARK: - 语法高亮

    private func scheduleHighlight(delay: Duration) {
        highlightTask?.cancel()
        guard let language else {
            apply([])
            return
        }
        let text = textView.string
        let expected = revision
        highlightTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let spans = await Task.detached(priority: .userInitiated) {
                highlight(language: language, text: text)
            }.value
            guard let self, !Task.isCancelled, self.revision == expected else { return }
            self.lastSpans = spans
            self.apply(spans)
        }
    }

    private func apply(_ spans: [HighlightSpan]) {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        let base = resolved(SyntaxTheme.text)
        var colors: [TokenKind: NSColor] = [:]
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: base, range: NSRange(location: 0, length: length))
        for span in spans {
            let range = NSRange(location: Int(span.start), length: Int(span.end - span.start))
            guard NSMaxRange(range) <= length else { continue }
            let color = colors[span.kind] ?? {
                let c = resolved(SyntaxTheme.color(for: span.kind))
                colors[span.kind] = c
                return c
            }()
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()
    }

    // MARK: - TextViewDelegate

    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        onWillReplace?(range, string)
    }

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        onDidReplace?(range, string)
        revision += 1
        inlineBlame.update(force: true)
        // 输入时稍作停顿再重新高亮，避免每个按键都触发完整解析。
        scheduleHighlight(delay: .milliseconds(120))
        gutter.lineCountChanged()
        if findBar.isHidden == false { find(findBar.query, caseSensitive: findBar.isCaseSensitive, keepIndex: true) }
        onTextChange?()
    }

    private func selectionChanged() {
        gutter.needsDisplay = true
        inlineBlame.update(force: false)
        guard let location = textView.selectionManager.textSelections.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(location) else { return }
        onCaretChange?(line.index + 1, location - line.range.location + 1)
    }

    // MARK: - 查找

    func showFindBar(replace: Bool = false) {
        let selected = textView.selectionManager.textSelections.first.map { (textView.string as NSString).substring(with: $0.range) }
        findBar.isReplaceMode = replace && textView.isEditable
        findBar.isHidden = false
        findBarHeight.isActive = false
        findBar.focus(with: selected)
    }

    func hideFindBar() {
        findBar.isHidden = true
        findBarHeight.isActive = true
        textView.emphasisManager?.removeEmphases(for: Self.findGroup)
        findMatches = []
        window?.makeFirstResponder(textView)
    }

    /// 替换当前匹配并定位到下一个。
    private func replaceCurrent(with replacement: String) {
        guard textView.isEditable, let index = findIndex, findMatches.indices.contains(index) else { return }
        textView.replaceCharacters(in: findMatches[index], with: replacement)
        // 替换后重新查找（保持下标），自然落到下一个匹配。
        find(findBar.query, caseSensitive: findBar.isCaseSensitive, keepIndex: true)
        showFindResults(select: true)
    }

    private func replaceAll(with replacement: String) {
        guard textView.isEditable, !findMatches.isEmpty else { return }
        let count = findMatches.count
        textView.replaceCharacters(in: findMatches, with: replacement)
        find(findBar.query, caseSensitive: findBar.isCaseSensitive)
        findBar.setResult(text: tr("find.replaced", "\(count)"))
    }

    func findNext() {
        if findBar.isHidden { showFindBar() } else { moveFind(by: 1) }
    }

    func findPrevious() {
        if findBar.isHidden { showFindBar() } else { moveFind(by: -1) }
    }

    private static let findGroup = "find"

    private func find(_ query: String, caseSensitive: Bool, keepIndex: Bool = false) {
        let text = textView.string as NSString
        var matches: [NSRange] = []
        if !query.isEmpty {
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            var searchRange = NSRange(location: 0, length: text.length)
            while matches.count < 10_000 {
                let found = text.range(of: query, options: options, range: searchRange)
                guard found.location != NSNotFound else { break }
                matches.append(found)
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: text.length - next)
            }
        }
        findMatches = matches
        if matches.isEmpty {
            findIndex = nil
        } else if !keepIndex || findIndex == nil {
            // 从光标位置开始找第一个匹配。
            let caret = textView.selectionManager.textSelections.first?.range.location ?? 0
            findIndex = matches.firstIndex { $0.location >= caret } ?? 0
        } else {
            findIndex = min(findIndex ?? 0, matches.count - 1)
        }
        showFindResults(select: !keepIndex)
    }

    private func moveFind(by step: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = ((findIndex ?? -step) + step + findMatches.count) % findMatches.count
        showFindResults(select: true)
    }

    private func showFindResults(select: Bool) {
        let emphases = findMatches.enumerated().map { index, range in
            Emphasis(range: range, style: .standard, inactive: index != findIndex, selectInDocument: select && index == findIndex)
        }
        textView.emphasisManager?.replaceEmphases(emphases, for: Self.findGroup)
        if let findIndex, select {
            textView.scrollToRange(findMatches[findIndex])
        }
        findBar.setResult(current: findIndex, total: findMatches.count)
    }
}
