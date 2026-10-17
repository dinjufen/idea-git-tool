import AppKit
import GitDeckCore

/// Commit 工具窗口（IDEA 非模态提交界面）：变更树 + 提交信息 + 提交按钮。
final class CommitToolWindow: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?
    var onShowDiff: ((FileChange) -> Void)?

    /// 变更树的分组节点，顺序与 IDEA 一致。
    final class Group {
        enum Kind { case conflicts, changes, unversioned }
        let kind: Kind
        var files: [FileChange] = []
        init(_ kind: Kind) { self.kind = kind }

        var title: String {
            switch kind {
            case .conflicts: tr("commit.group.conflicts")
            case .changes: tr("commit.group.changes")
            case .unversioned: tr("commit.group.unversioned")
            }
        }
    }

    /// 文件节点。用类包装以便 NSOutlineView 按引用识别条目。
    final class FileItem {
        let change: FileChange
        init(_ change: FileChange) { self.change = change }
    }

    private let model: ProjectModel
    private let outline = NSOutlineView()
    private let messageView = PlaceholderTextView()
    private let amendCheckbox = NSButton(checkboxWithTitle: tr("commit.amend"), target: nil, action: nil)
    private let commitButton = NSButton(title: tr("commit.button.commit"), target: nil, action: nil)
    private let commitPushButton = NSButton(title: tr("commit.button.commitAndPush"), target: nil, action: nil)
    private let optionsButton = IconButton(symbol: "gearshape", tooltip: tr("commit.options"), size: 24, pointSize: 12)
    private let spinner = NSProgressIndicator()

    private var groups: [Group] = []
    private var items: [String: FileItem] = [:]
    /// 勾选要提交的文件路径。
    private var included: Set<String> = []
    /// 已见过的路径；新出现的已跟踪变更默认勾选，未跟踪文件默认不勾选（与 IDEA 一致）。
    private var known: Set<String> = []
    private var observer: UUID?

    // 提交选项（IDEA 提交区齿轮菜单中的 Sign-off 与 Run Git hooks），在会话内保留。
    private var signOff = false
    private var runHooks = true
    private var isCommitting = false
    /// 勾选 Amend 时自动填入的上一次提交信息；取消勾选时若未被修改则清空。
    private var amendPrefill: String?

    init(model: ProjectModel) {
        self.model = model
        super.init(frame: .zero)
        buildLayout()
        observer = model.observe { [weak self] in self?.statusChanged() }
        statusChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focusMessage() {
        window?.makeFirstResponder(messageView)
    }

    // MARK: - 布局

    private func buildLayout() {
        let background = ColoredView(Theme.toolWindowBackground)
        addSubview(background)
        background.pinEdges(to: self)

        let header = ToolWindowHeader(title: tr("toolwindow.commit"))
        let toolbar = makeToolbar()

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .sourceList
        outline.backgroundColor = Theme.toolWindowBackground
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        // 与 IDEA 一致：双击打开 Diff，右键菜单可跳到源码。
        outline.doubleAction = #selector(showDiffForClicked)
        outline.menu = changeMenu()
        outline.setAccessibilityLabel(tr("commit.changes.accessibility"))

        let treeScroll = NSScrollView()
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.drawsBackground = false

        messageView.placeholder = tr("commit.message.placeholder")
        messageView.font = Theme.uiFont
        messageView.textColor = Theme.text
        messageView.backgroundColor = Theme.editorBackground
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.textContainerInset = NSSize(width: 6, height: 6)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.setAccessibilityLabel(tr("commit.message.placeholder"))
        messageView.onTextChange = { [weak self] in self?.updateCommitButtons() }
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .noBorder
        messageView.autoresizingMask = [.width]
        messageView.isVerticallyResizable = true
        messageView.textContainer?.widthTracksTextView = true

        treeScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        let messageDivider = SeparatorLine(.horizontal)

        commitButton.bezelStyle = .push
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.toolTip = tr("commit.button.commit.tooltip")
        // 推送在后续步骤实现，届时“提交并推送”会在提交成功后打开 Push 对话框。
        commitPushButton.bezelStyle = .push
        commitPushButton.isEnabled = false
        commitPushButton.toolTip = tr("common.notImplemented")
        amendCheckbox.target = self
        amendCheckbox.action = #selector(amendToggled)
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        // 面板较窄时优先截断“提交并推送”，保证主按钮完整显示。
        commitButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        amendCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        commitPushButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [commitButton, commitPushButton, spinner, NSView(), amendCheckbox, optionsButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, toolbar, treeScroll, messageDivider, messageScroll, buttons] as [NSView] { addSubview(view) }
        // 变更树占满剩余空间，提交信息区固定高度（拖拽调整高度在后续 UI 打磨阶段加入）。
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            treeScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            treeScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            messageDivider.topAnchor.constraint(equalTo: treeScroll.bottomAnchor),
            messageDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: messageDivider.bottomAnchor),
            messageScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageScroll.heightAnchor.constraint(equalToConstant: 140),
            buttons.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func makeToolbar() -> NSStackView {
        func button(_ symbol: String, _ tooltip: String, _ action: Selector?) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 26, pointSize: 12)
            b.target = self
            b.action = action
            b.isEnabled = action != nil
            return b
        }
        let stack = NSStackView(views: [
            button("arrow.clockwise", tr("git.action.refresh"), #selector(refresh)),
            button("arrow.uturn.backward", tr("commit.action.rollback"), nil),
            button("plus.forwardslash.minus", tr("commit.action.showDiff"), #selector(showDiffForSelection)),
            button("tray.and.arrow.down", tr("commit.action.shelve"), nil),
            button("arrow.up.left.and.arrow.down.right", tr("tree.expandAll"), #selector(expandAll)),
            button("arrow.down.right.and.arrow.up.left", tr("tree.collapseAll"), #selector(collapseAll)),
        ])
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - 数据

    private func statusChanged() {
        guard !model.isRefreshing else { return }
        let conflicts = Group(.conflicts)
        let changes = Group(.changes)
        let unversioned = Group(.unversioned)
        for change in model.status.changes where !change.isIgnored {
            if change.conflict != nil {
                conflicts.files.append(change)
            } else if change.isUntracked {
                unversioned.files.append(change)
            } else {
                changes.files.append(change)
            }
        }
        let sort: (FileChange, FileChange) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for group in [conflicts, changes, unversioned] { group.files.sort(by: sort) }

        let current = Set(model.status.changes.map(\.path))
        for path in Set(changes.files.map(\.path)).subtracting(known) { included.insert(path) }
        included.formIntersection(current)
        known = current
        items = Dictionary(model.status.changes.map { ($0.path, FileItem($0)) }, uniquingKeysWith: { a, _ in a })

        // 冲突与未跟踪分组为空时隐藏；Changes 分组始终显示。
        groups = [conflicts, changes, unversioned].filter { $0.kind == .changes || !$0.files.isEmpty }
        outline.reloadData()
        for group in groups where group.kind != .unversioned { outline.expandItem(group) }
        updateCommitButtons()
    }

    @objc private func refresh() { model.refresh() }
    @objc private func expandAll() { outline.expandItem(nil, expandChildren: true) }
    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }

    // MARK: - 提交

    private func updateCommitButtons() {
        let hasMessage = !messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFiles = !included.isEmpty || amendCheckbox.state == .on
        commitButton.isEnabled = hasMessage && hasFiles && !isCommitting
    }

    @objc private func amendToggled() {
        updateCommitButtons()
        if amendCheckbox.state == .on {
            guard messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let repository = model.repository
            Task {
                let message = await Task.detached { try? repository.lastCommitMessage() }.value
                guard let message, self.amendCheckbox.state == .on, self.messageView.string.isEmpty else { return }
                self.messageView.string = message
                self.amendPrefill = message
                self.messageView.didChangeText()
            }
        } else if let prefill = amendPrefill, messageView.string == prefill {
            messageView.string = ""
            amendPrefill = nil
            messageView.didChangeText()
        }
    }

    @objc private func showOptions() {
        let menu = NSMenu()
        let signOffItem = NSMenuItem(title: tr("commit.option.signOff"), action: #selector(toggleSignOff), keyEquivalent: "")
        signOffItem.state = signOff ? .on : .off
        signOffItem.target = self
        let hooksItem = NSMenuItem(title: tr("commit.option.runHooks"), action: #selector(toggleHooks), keyEquivalent: "")
        hooksItem.state = runHooks ? .on : .off
        hooksItem.target = self
        menu.items = [signOffItem, hooksItem]
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.height + 4), in: optionsButton)
    }

    @objc private func toggleSignOff() { signOff.toggle() }
    @objc private func toggleHooks() { runHooks.toggle() }

    @objc private func commit() {
        guard commitButton.isEnabled else { return }
        // 只提交仍存在于当前变更中的勾选文件。
        let paths = model.status.changes.map(\.path).filter { included.contains($0) }
        let options = CommitOptions(
            message: messageView.string,
            paths: paths,
            amend: amendCheckbox.state == .on,
            signOff: signOff,
            skipHooks: !runHooks,
            author: nil
        )
        isCommitting = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        updateCommitButtons()
        let repository = model.repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.commit(options: options) }
            }.value
            self.isCommitting = false
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            switch result {
            case let .success(commit):
                self.messageView.string = ""
                self.messageView.didChangeText()
                self.amendCheckbox.state = .off
                self.amendPrefill = nil
                let text = commit.fileCount == 1
                    ? tr("commit.done.one", commit.subject)
                    : tr("commit.done.many", "\(commit.fileCount)", commit.subject)
                self.model.post(text)
            case let .failure(error):
                // 钩子输出等错误信息较长，用对话框完整展示。
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = tr("commit.failed")
                alert.informativeText = errorMessage(error)
                if let window = self.window {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
                self.model.post(tr("commit.failed"), isError: true)
            }
            self.model.refresh()
            self.updateCommitButtons()
        }
    }

    private func changeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("commit.action.showDiff"), action: #selector(showDiffForSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("commit.action.jumpToSource"), action: #selector(jumpToSource), keyEquivalent: "").target = self
        return menu
    }

    /// 右键时作用于点击的行，否则作用于选中行。
    private var targetItem: FileItem? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? FileItem
    }

    @objc private func showDiffForClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? FileItem else { return }
        onShowDiff?(item.change)
    }

    @objc func showDiffForSelection() {
        guard let item = targetItem else { return }
        onShowDiff?(item.change)
    }

    @objc private func jumpToSource() {
        guard let item = targetItem, !item.change.isDeleted else { return }
        onOpenFile?(model.rootURL.appendingPathComponent(item.change.path))
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0 else { return }
        let on = sender.state == .on
        switch outline.item(atRow: row) {
        case let group as Group:
            for file in group.files {
                if on { included.insert(file.path) } else { included.remove(file.path) }
            }
        case let item as FileItem:
            if on { included.insert(item.change.path) } else { included.remove(item.change.path) }
        default:
            break
        }
        outline.reloadData()
        updateCommitButtons()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: groups.count
        case let group as Group: group.files.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? Group {
            let path = group.files[index].path
            return items[path] ?? FileItem(group.files[index])
        }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChangeCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeCellView ?? ChangeCellView(identifier: id)
        cell.checkbox.target = self
        cell.checkbox.action = #selector(checkboxToggled(_:))

        switch item {
        case let group as Group:
            let count = group.files.count
            let selected = group.files.filter { included.contains($0.path) }.count
            cell.checkbox.allowsMixedState = true
            cell.checkbox.state = selected == 0 ? .off : (selected == count ? .on : .mixed)
            cell.checkbox.isEnabled = count > 0 && group.kind != .conflicts
            cell.file.configure(
                icon: nil,
                name: group.title,
                detail: count == 1 ? tr("commit.group.oneFile") : tr("commit.group.files", "\(count)"),
                color: Theme.text,
                bold: true
            )
        case let item as FileItem:
            let change = item.change
            cell.checkbox.allowsMixedState = false
            cell.checkbox.state = included.contains(change.path) ? .on : .off
            cell.checkbox.isEnabled = change.conflict == nil
            var detail = change.directory
            if let conflict = change.conflict {
                detail = [detail, conflict.title].filter { !$0.isEmpty }.joined(separator: "  ")
            } else if let orig = change.origPath {
                detail = tr("commit.renamedFrom", orig)
            }
            cell.file.configure(
                icon: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)),
                name: change.fileName,
                detail: detail,
                color: change.statusColor,
                strikethrough: change.isDeleted
            )
        default:
            return nil
        }
        return cell
    }
}

/// 变更树单元格：复选框 + 文件单元格。
final class ChangeCellView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let file: FileCellView

    init(identifier: NSUserInterfaceItemIdentifier) {
        file = FileCellView(identifier: identifier)
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        file.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        addSubview(file)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            file.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 2),
            file.trailingAnchor.constraint(equalTo: trailingAnchor),
            file.topAnchor.constraint(equalTo: topAnchor),
            file.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 带占位文字的文本视图（提交信息输入框）。
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.uiFont,
            .foregroundColor: Theme.secondaryText,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attrs)
    }

    var onTextChange: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onTextChange?()
    }
}
