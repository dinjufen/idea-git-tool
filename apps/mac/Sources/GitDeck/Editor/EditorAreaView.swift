import AppKit
import GitDeckCore

/// 编辑器区域：标签栏 + 代码编辑器（语法高亮、查找、相对 HEAD 的变更标记）。
final class EditorAreaView: NSView {
    @MainActor
    final class Document {
        let url: URL
        /// 相对仓库根目录的路径；仓库外的文件为 `nil`（不显示变更标记）。
        let relativePath: String?
        let editor: CodeEditorView
        var isModified = false
        /// HEAD 中的内容；文件不在 HEAD 中时为 `nil`。
        var base: String?
        var lineStatusTask: Task<Void, Never>?

        init(url: URL, relativePath: String?, text: String) {
            self.url = url
            self.relativePath = relativePath
            editor = CodeEditorView(text: text, language: languageForPath(path: url.lastPathComponent))
        }
    }

    var onCaretChange: ((String) -> Void)?

    private let model: ProjectModel
    private let tabBar = NSStackView()
    private let content = ColoredView(Theme.editorBackground)
    private let emptyState = NSStackView()
    private var documents: [Document] = []
    private var active: Document?
    private var observer: UUID?
    private var lastHead: String?

    init(model: ProjectModel) {
        self.model = model
        super.init(frame: .zero)
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
        observer = model.observe { [weak self] in self?.modelChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hasModifiedDocuments: Bool { documents.contains(where: \.isModified) }

    var activeEditor: CodeEditorView? { active?.editor }

    // MARK: - 打开的标签页持久化（与 IDEA 重新打开项目时恢复编辑器标签一致）

    private var sessionKey: String { "openFiles:" + model.rootURL.path }

    /// 恢复上次打开的文件，最后一个为当前标签。
    func restoreSession() {
        let paths = UserDefaults.standard.stringArray(forKey: sessionKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }
    }

    private func saveSession() {
        var paths = documents.map(\.url.path)
        // 当前标签放在最后，恢复时最后打开即成为当前标签。
        if let active, let index = paths.firstIndex(of: active.url.path) {
            paths.append(paths.remove(at: index))
        }
        UserDefaults.standard.set(paths, forKey: sessionKey)
    }

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
        let document = Document(url: url, relativePath: relativePath(of: url), text: text)
        document.editor.onTextChange = { [weak self, weak document] in
            guard let self, let document else { return }
            if !document.isModified {
                document.isModified = true
                self.rebuildTabs()
            }
            self.updateLineStatus(document, delay: .milliseconds(250))
        }
        document.editor.onCaretChange = { [weak self] line, column in
            self?.onCaretChange?("\(line):\(column)    LF    UTF-8")
        }
        documents.append(document)
        activate(document)
        loadBase(document)
    }

    func saveActive() throws {
        guard let doc = active else { return }
        try doc.editor.text.write(to: doc.url, atomically: true, encoding: .utf8)
        doc.isModified = false
        rebuildTabs()
    }

    func closeActive() {
        guard let doc = active else { return }
        close(doc)
    }

    // MARK: - 变更标记（line status）

    private func relativePath(of url: URL) -> String? {
        let root = model.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// 读取 HEAD 版本作为对比基准，然后计算变更标记。
    private func loadBase(_ doc: Document) {
        guard let path = doc.relativePath else { return }
        let repository = model.repository
        Task {
            let base = await Task.detached { try? repository.fileAtRevision(revision: "HEAD", path: path) }.value
            doc.base = base ?? nil
            self.updateLineStatus(doc, delay: .zero)
        }
    }

    private func updateLineStatus(_ doc: Document, delay: Duration) {
        doc.lineStatusTask?.cancel()
        guard let base = doc.base else {
            doc.editor.lineChanges = []
            return
        }
        let text = doc.editor.text
        let revision = doc.editor.revision
        doc.lineStatusTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let changes = await Task.detached { GitDeckCore.lineChanges(base: base, text: text) }.value
            guard !Task.isCancelled, doc.editor.revision == revision else { return }
            doc.editor.lineChanges = changes
        }
    }

    /// 提交、检出等操作改变 HEAD 后，重新读取所有打开文件的基准版本。
    private func modelChanged() {
        guard !model.isRefreshing, model.status.branch.oid != lastHead else { return }
        lastHead = model.status.branch.oid
        documents.forEach(loadBase)
    }

    // MARK: - 标签页

    private func close(_ doc: Document) {
        if doc.isModified {
            let alert = NSAlert()
            alert.messageText = tr("editor.unsaved.title", doc.url.lastPathComponent)
            alert.addButton(withTitle: tr("editor.unsaved.save"))
            alert.addButton(withTitle: tr("editor.unsaved.discard"))
            alert.addButton(withTitle: tr("common.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try? doc.editor.text.write(to: doc.url, atomically: true, encoding: .utf8)
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        doc.lineStatusTask?.cancel()
        let index = documents.firstIndex { $0 === doc } ?? 0
        documents.removeAll { $0 === doc }
        defer { saveSession() }
        if active === doc {
            active = nil
            doc.editor.removeFromSuperview()
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
        active?.editor.removeFromSuperview()
        emptyState.removeFromSuperview()
        active = doc
        content.addSubview(doc.editor)
        doc.editor.pinEdges(to: content)
        window?.makeFirstResponder(doc.editor.textView)
        rebuildTabs()
        saveSession()
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
}

/// 编辑器标签：选中时底部显示强调色下划线（New UI 样式）。
final class EditorTab: ColoredView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, modified: Bool, selected: Bool) {
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
