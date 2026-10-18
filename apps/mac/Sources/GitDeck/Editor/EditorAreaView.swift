import AppKit
import GitDeckCore

/// 编辑器标签页的内容：文件文档或 Diff 页。
@MainActor
protocol EditorTabContent: AnyObject {
    var tabTitle: String { get }
    var tabTooltip: String { get }
    /// 标签上的图标（SF Symbol）；文件文档不显示图标。
    var tabSymbol: String? { get }
    var contentView: NSView { get }
    var focusView: NSView? { get }
    var isModified: Bool { get }
}

/// 编辑器区域：标签栏 + 代码编辑器（语法高亮、查找、相对 HEAD 的变更标记）或 Diff 页。
final class EditorAreaView: NSView {
    @MainActor
    final class Document: EditorTabContent {
        let url: URL
        /// 相对仓库根目录的路径；仓库外的文件为 `nil`（不显示变更标记）。
        let relativePath: String?
        let editor: CodeEditorView
        var isModified = false
        /// 正在从磁盘重新载入（编辑器内容变化不标记为已修改）。
        var isReloading = false
        /// HEAD 中的内容；文件不在 HEAD 中时为 `nil`。
        var base: String?
        var lineStatusTask: Task<Void, Never>?

        init(url: URL, relativePath: String?, text: String) {
            self.url = url
            self.relativePath = relativePath
            editor = CodeEditorView(text: text, language: languageForPath(path: url.lastPathComponent))
        }

        var tabTitle: String { url.lastPathComponent }
        var tabTooltip: String { url.path }
        var tabSymbol: String? { nil }
        var contentView: NSView { editor }
        var focusView: NSView? { editor.textView }
    }

    /// Diff 页：同一来源（例如同一提交中的同一文件）只打开一个标签。
    @MainActor
    final class DiffTab: EditorTabContent {
        let key: String
        let tabTitle: String
        let tabTooltip: String
        let view: DiffView

        init(key: String, title: String, tooltip: String, view: DiffView) {
            self.key = key
            tabTitle = title
            tabTooltip = tooltip
            self.view = view
        }

        var tabSymbol: String? { "arrow.left.arrow.right" }
        var contentView: NSView { view }
        var focusView: NSView? { nil }
        var isModified: Bool { false }
    }

    var onCaretChange: ((String) -> Void)?
    /// 在 Git 日志中定位某个提交（点击 Annotate 注释时）。
    var onShowCommit: ((String) -> Void)?
    /// 显示某个文件（相对路径）的历史。
    var onShowHistory: ((String) -> Void)?
    /// 点击编辑器中的 AI 评审标记（参数为发现的下标）。
    var onReviewMarkerClick: ((Int) -> Void)?

    /// AI 评审：在打开的文件上显示发现的标记。
    var aiReview: AIReviewController? {
        didSet {
            if let reviewObserver { oldValue?.removeObserver(reviewObserver) }
            reviewObserver = aiReview?.observe { [weak self] in self?.updateReviewMarkers() }
            updateReviewMarkers()
        }
    }

    private var reviewObserver: UUID?

    private let model: ProjectModel
    private let tabBar = NSStackView()
    private let content = ColoredView(Theme.editorBackground)
    private let emptyState = NSStackView()
    private var tabs: [any EditorTabContent] = []
    private var active: (any EditorTabContent)?
    private var documents: [Document] { tabs.compactMap { $0 as? Document } }
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

    var activeEditor: CodeEditorView? { (active as? Document)?.editor }

    var activeDiff: DiffView? { (active as? DiffTab)?.view }

    /// 当前文件文档相对仓库根目录的路径。
    var activeRelativePath: String? { (active as? Document)?.relativePath }

    var isActiveAnnotated: Bool { activeEditor?.annotations != nil }

    // MARK: - Annotate

    /// 打开或关闭当前文件的 Annotate 列。
    func toggleAnnotations() {
        guard let doc = active as? Document else { return }
        if doc.editor.annotations != nil {
            doc.editor.annotations = nil
        } else {
            loadBlame(doc)
        }
    }

    private func loadBlame(_ doc: Document) {
        guard let path = doc.relativePath else { return }
        let repository = model.repository
        Task {
            let result = await Task.detached { Result { try repository.blame(path: path, revision: nil) } }.value
            switch result {
            case let .success(blame): doc.editor.annotations = blame
            case .failure: model.post(tr("annotate.failed", doc.url.lastPathComponent), isError: true)
            }
        }
    }

    private func gutterMenu(for doc: Document) -> NSMenu {
        let menu = NSMenu()
        let annotate = NSMenuItem(
            title: doc.editor.annotations == nil ? tr("git.action.annotate") : tr("git.action.closeAnnotations"),
            action: #selector(MenuAction.invoke), keyEquivalent: ""
        )
        let annotateAction = MenuAction { [weak self, weak doc] in
            guard let self, let doc else { return }
            if doc.editor.annotations != nil { doc.editor.annotations = nil } else { self.loadBlame(doc) }
        }
        annotate.target = annotateAction
        annotate.representedObject = annotateAction
        annotate.isEnabled = doc.relativePath != nil
        menu.addItem(annotate)

        let history = NSMenuItem(title: tr("git.action.showHistory"), action: #selector(MenuAction.invoke), keyEquivalent: "")
        let historyAction = MenuAction { [weak self, weak doc] in
            guard let path = doc?.relativePath else { return }
            self?.onShowHistory?(path)
        }
        history.target = historyAction
        history.representedObject = historyAction
        history.isEnabled = doc.relativePath != nil
        menu.addItem(history)
        return menu
    }

    /// 打开 Diff 页；`key` 相同的 Diff 已打开时直接切换过去。
    func openDiff(key: String, title: String, tooltip: String, make: () -> DiffView) {
        if let existing = tabs.first(where: { ($0 as? DiffTab)?.key == key }) {
            activate(existing)
            return
        }
        let tab = DiffTab(key: key, title: title, tooltip: tooltip, view: make())
        tabs.append(tab)
        activate(tab)
    }

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
        if let active = active as? Document, let index = paths.firstIndex(of: active.url.path) {
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
            if !document.isModified, !document.isReloading {
                document.isModified = true
                self.rebuildTabs()
            }
            self.updateLineStatus(document, delay: .milliseconds(250))
        }
        document.editor.gutterMenu = { [weak self, weak document] in
            guard let self, let document else { return nil }
            return self.gutterMenu(for: document)
        }
        document.editor.onAnnotationClick = { [weak self] hash in self?.onShowCommit?(hash) }
        document.editor.onCaretChange = { [weak self] line, column in
            self?.onCaretChange?("\(line):\(column)    LF    UTF-8")
        }
        document.editor.onReviewMarkerClick = { [weak self] index in self?.onReviewMarkerClick?(index) }
        tabs.append(document)
        activate(document)
        loadBase(document)
        updateReviewMarkers(document)
    }

    /// 打开文件并把第 `line` 行（从 0 开始）滚动到视口中。
    func open(_ url: URL, line: Int) {
        open(url)
        guard let document = documents.first(where: { $0.url == url }) else { return }
        // 新打开的编辑器尚未布局，等布局完成后再滚动。
        DispatchQueue.main.async { document.editor.reveal(line: max(0, line)) }
    }

    /// 外部修改了文件：没有未保存修改的文档重新载入磁盘内容（可撤销），有修改的保持不变。
    func reloadFromDisk(paths: [String]) {
        let changed = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        for document in documents where !document.isModified {
            let path = document.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard changed.contains(path),
                  let data = try? Data(contentsOf: document.url),
                  let text = String(data: data, encoding: .utf8),
                  text != document.editor.text else { continue }
            document.isReloading = true
            document.editor.replaceText(with: text)
            document.isReloading = false
            updateLineStatus(document, delay: .zero)
        }
    }

    /// 已打开文件的当前内容（含未保存的修改）。
    func text(of url: URL) -> String? {
        documents.first(where: { $0.url == url })?.editor.text
    }

    /// 修改文件内容：已打开时在编辑器中替换（可撤销）并保存，否则直接写入文件。
    func applyEdit(to url: URL, newText: String) throws {
        if let document = documents.first(where: { $0.url == url }) {
            document.editor.replaceText(with: newText)
            try document.editor.text.write(to: url, atomically: true, encoding: .utf8)
            document.isModified = false
            rebuildTabs()
        } else {
            try newText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func updateReviewMarkers() {
        documents.forEach(updateReviewMarkers)
    }

    private func updateReviewMarkers(_ document: Document) {
        guard let path = document.relativePath, let aiReview else {
            document.editor.reviewMarkers = []
            return
        }
        document.editor.reviewMarkers = aiReview.workingTreeFindings(for: path)
            .filter { !aiReview.applied.contains($0.index) }
            .map { ReviewMarker(index: $0.index, line: Int($0.finding.line) - 1, severity: $0.finding.severity, title: $0.finding.title) }
    }

    func saveActive() throws {
        guard let doc = active as? Document else { return }
        try doc.editor.text.write(to: doc.url, atomically: true, encoding: .utf8)
        doc.isModified = false
        rebuildTabs()
        // 保存后重新 blame，使注释与文件内容对应。
        if doc.editor.annotations != nil { loadBlame(doc) }
    }

    func closeActive() {
        guard let active else { return }
        close(active)
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
        // 提交、签出后注释可能已过期。
        documents.filter { $0.editor.annotations != nil }.forEach(loadBlame)
    }

    // MARK: - 标签页

    private func close(_ tab: any EditorTabContent) {
        if let doc = tab as? Document, doc.isModified {
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
        (tab as? Document)?.lineStatusTask?.cancel()
        let index = tabs.firstIndex { $0 === tab } ?? 0
        tabs.removeAll { $0 === tab }
        defer { saveSession() }
        if active === tab {
            active = nil
            tab.contentView.removeFromSuperview()
            if tabs.isEmpty {
                showEmptyState()
                rebuildTabs()
            } else {
                activate(tabs[min(index, tabs.count - 1)])
            }
        } else {
            rebuildTabs()
        }
    }

    private func activate(_ tab: any EditorTabContent) {
        active?.contentView.removeFromSuperview()
        emptyState.removeFromSuperview()
        active = tab
        content.addSubview(tab.contentView)
        tab.contentView.pinEdges(to: content)
        if let focus = tab.focusView { window?.makeFirstResponder(focus) }
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
        for item in tabs {
            let tab = EditorTab(title: item.tabTitle, symbol: item.tabSymbol, modified: item.isModified, selected: item === active)
            tab.toolTip = item.tabTooltip
            tab.onSelect = { [weak self] in self?.activate(item) }
            tab.onClose = { [weak self] in self?.close(item) }
            tabBar.addArrangedSubview(tab)
        }
    }
}

/// 编辑器标签：选中时底部显示强调色下划线（New UI 样式）。
final class EditorTab: ColoredView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, symbol: String? = nil, modified: Bool, selected: Bool) {
        super.init(selected ? Theme.editorBackground : nil)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label(modified ? "• " + title : title, color: selected ? Theme.text : Theme.secondaryText)
        let close = IconButton(symbol: "xmark", tooltip: tr("menu.file.closeTab"), size: 16, pointSize: 8)
        close.target = self
        close.action = #selector(closeClicked)
        var views: [NSView] = [label, close]
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image.withSymbolConfiguration(.init(pointSize: 10, weight: .regular)) ?? image)
            icon.contentTintColor = Theme.accent
            views.insert(icon, at: 0)
        }
        let stack = NSStackView(views: views)
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
