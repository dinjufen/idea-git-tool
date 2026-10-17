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

    /// 每次文本变化递增，用于丢弃过期的后台高亮结果。
    private(set) var revision = 0
    private var highlightTask: Task<Void, Never>?
    private var lastSpans: [HighlightSpan] = []
    private var findMatches: [NSRange] = []
    private var findIndex: Int?
    private var observers: [NSObjectProtocol] = []

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
        super.init(frame: .zero)
        textView.delegate = self
        buildLayout()
        applyColors()
        observe()
        scheduleHighlight(delay: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        for view in [findBar, gutter, scrollView] as [NSView] { addSubview(view) }
        // 查找栏隐藏时高度为 0；显示时由查找栏自身的高度约束（优先级略低）决定。
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBarHeight.isActive = true
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            gutter.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
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
            MainActor.assumeIsolated { self?.gutter.needsDisplay = true }
        }
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: redrawGutter),
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
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        _ = textView.updateFrameIfNeeded()
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
        // 输入时稍作停顿再重新高亮，避免每个按键都触发完整解析。
        scheduleHighlight(delay: .milliseconds(120))
        gutter.lineCountChanged()
        if findBar.isHidden == false { find(findBar.query, caseSensitive: findBar.isCaseSensitive, keepIndex: true) }
        onTextChange?()
    }

    private func selectionChanged() {
        gutter.needsDisplay = true
        guard let location = textView.selectionManager.textSelections.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(location) else { return }
        onCaretChange?(line.index + 1, location - line.range.location + 1)
    }

    // MARK: - 查找

    func showFindBar() {
        let selected = textView.selectionManager.textSelections.first.map { (textView.string as NSString).substring(with: $0.range) }
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
