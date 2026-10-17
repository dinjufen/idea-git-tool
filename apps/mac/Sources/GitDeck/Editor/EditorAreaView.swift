import AppKit

/// 编辑器区域：标签栏 + 文本编辑器。
///
/// 当前为占位实现（NSTextView）；下一阶段替换为 CodeEditSourceEditor，
/// 并接入 Rust 核心的 tree-sitter 高亮、gutter 变更标记与 Annotate。
final class EditorAreaView: NSView {
    @MainActor
    final class Document {
        let url: URL
        var text: String
        var isModified = false
        let textView: NSTextView
        let scrollView: NSScrollView

        init(url: URL, text: String) {
            self.url = url
            self.text = text
            scrollView = NSTextView.scrollableTextView()
            textView = scrollView.documentView as! NSTextView
            textView.string = text
            textView.font = Theme.editorFont
            textView.textColor = Theme.text
            textView.backgroundColor = Theme.editorBackground
            textView.isRichText = false
            textView.allowsUndo = true
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            scrollView.drawsBackground = true
            scrollView.backgroundColor = Theme.editorBackground
        }
    }

    var onCaretChange: ((String) -> Void)?

    private let tabBar = NSStackView()
    private let content = ColoredView(Theme.editorBackground)
    private let emptyState = NSStackView()
    private var documents: [Document] = []
    private var active: Document?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let background = ColoredView(Theme.editorBackground)
        addSubview(background)
        background.pinEdges(to: self)

        let tabBackground = ColoredView(Theme.editorBackground)
        tabBackground.translatesAutoresizingMaskIntoConstraints = false
        tabBar.spacing = 0
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBackground.addSubview(tabBar)
        let tabSeparator = SeparatorLine(.horizontal)

        content.translatesAutoresizingMaskIntoConstraints = false
        buildEmptyState()

        for view in [tabBackground, tabSeparator, content] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            tabBackground.topAnchor.constraint(equalTo: topAnchor),
            tabBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBackground.heightAnchor.constraint(equalToConstant: 36),
            tabBar.leadingAnchor.constraint(equalTo: tabBackground.leadingAnchor),
            tabBar.topAnchor.constraint(equalTo: tabBackground.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: tabBackground.bottomAnchor),
            tabSeparator.topAnchor.constraint(equalTo: tabBackground.bottomAnchor),
            tabSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: tabSeparator.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hasModifiedDocuments: Bool { documents.contains(where: \.isModified) }

    func open(_ url: URL) {
        if let existing = documents.first(where: { $0.url == url }) {
            activate(existing)
            return
        }
        // 二进制或非 UTF-8 文件暂不支持编辑，后续按编码检测处理。
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            NSSound.beep()
            return
        }
        let document = Document(url: url, text: text)
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: NSText.didChangeNotification, object: document.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)), name: NSTextView.didChangeSelectionNotification, object: document.textView)
        documents.append(document)
        activate(document)
    }

    func saveActive() throws {
        guard let doc = active else { return }
        try doc.textView.string.write(to: doc.url, atomically: true, encoding: .utf8)
        doc.isModified = false
        rebuildTabs()
    }

    func closeActive() {
        guard let doc = active else { return }
        close(doc)
    }

    private func close(_ doc: Document) {
        if doc.isModified {
            let alert = NSAlert()
            alert.messageText = tr("editor.unsaved.title", doc.url.lastPathComponent)
            alert.addButton(withTitle: tr("editor.unsaved.save"))
            alert.addButton(withTitle: tr("editor.unsaved.discard"))
            alert.addButton(withTitle: tr("common.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try? doc.textView.string.write(to: doc.url, atomically: true, encoding: .utf8)
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        NotificationCenter.default.removeObserver(self, name: nil, object: doc.textView)
        let index = documents.firstIndex { $0 === doc } ?? 0
        documents.removeAll { $0 === doc }
        if active === doc {
            active = nil
            doc.scrollView.removeFromSuperview()
            if documents.isEmpty {
                showEmptyState()
                rebuildTabs()
            } else {
                activate(documents[min(index, documents.count - 1)])
            }
        } else {
            rebuildTabs()
        }
    }

    private func activate(_ doc: Document) {
        active?.scrollView.removeFromSuperview()
        emptyState.removeFromSuperview()
        active = doc
        content.addSubview(doc.scrollView)
        doc.scrollView.pinEdges(to: content)
        window?.makeFirstResponder(doc.textView)
        rebuildTabs()
        updateCaret()
    }

    private func showEmptyState() {
        content.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        onCaretChange?("")
    }

    private func buildEmptyState() {
        emptyState.orientation = .vertical
        emptyState.spacing = 10
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        let hints = [
            (tr("editor.empty.commit"), "⌘K"),
            (tr("editor.empty.update"), "⌘T"),
            (tr("editor.empty.push"), "⇧⌘K"),
            (tr("editor.empty.project"), "⌘1"),
        ]
        for (title, shortcut) in hints {
            let row = NSStackView(views: [
                NSTextField.label(title, color: Theme.secondaryText),
                NSTextField.label(shortcut, color: Theme.accent),
            ])
            row.spacing = 8
            emptyState.addArrangedSubview(row)
        }
    }

    private func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for doc in documents {
            let tab = EditorTab(title: doc.url.lastPathComponent, modified: doc.isModified, selected: doc === active)
            tab.toolTip = doc.url.path
            tab.onSelect = { [weak self] in self?.activate(doc) }
            tab.onClose = { [weak self] in self?.close(doc) }
            tabBar.addArrangedSubview(tab)
        }
    }

    @objc private func textDidChange(_ note: Notification) {
        guard let doc = documents.first(where: { $0.textView === note.object as? NSTextView }) else { return }
        if !doc.isModified {
            doc.isModified = true
            rebuildTabs()
        }
    }

    @objc private func selectionDidChange(_ note: Notification) {
        updateCaret()
    }

    /// 计算光标所在行列，显示在状态栏（IDEA 格式：`行:列`）。
    private func updateCaret() {
        guard let textView = active?.textView else { return }
        let text = textView.string as NSString
        let location = min(textView.selectedRange().location, text.length)
        let prefix = text.substring(to: location) as NSString
        let line = prefix.components(separatedBy: "\n").count
        let lastNewline = prefix.range(of: "\n", options: .backwards)
        let lineStart = lastNewline.location == NSNotFound ? 0 : NSMaxRange(lastNewline)
        let column = location - lineStart + 1
        onCaretChange?("\(line):\(column)    LF    UTF-8")
    }
}

/// 编辑器标签：选中时底部显示强调色下划线（New UI 样式）。
final class EditorTab: ColoredView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let selected: Bool

    init(title: String, modified: Bool, selected: Bool) {
        self.selected = selected
        super.init(selected ? Theme.editorBackground : nil)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label(modified ? "• " + title : title, color: selected ? Theme.text : Theme.secondaryText)
        let close = IconButton(symbol: "xmark", tooltip: tr("menu.file.closeTab"), size: 16, pointSize: 8)
        close.target = self
        close.action = #selector(closeClicked)
        let stack = NSStackView(views: [label, close])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if selected {
            let underline = ColoredView(Theme.accent)
            underline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underline)
            NSLayoutConstraint.activate([
                underline.leadingAnchor.constraint(equalTo: leadingAnchor),
                underline.trailingAnchor.constraint(equalTo: trailingAnchor),
                underline.bottomAnchor.constraint(equalTo: bottomAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2),
            ])
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
