import AppKit
import GitDeckCore

/// Commit 工具窗口（IDEA 非模态提交界面）：变更树 + 提交信息 + 提交按钮。
final class CommitToolWindow: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?

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

    private var groups: [Group] = []
    private var items: [String: FileItem] = [:]
    /// 勾选要提交的文件路径。
    private var included: Set<String> = []
    /// 已见过的路径；新出现的已跟踪变更默认勾选，未跟踪文件默认不勾选（与 IDEA 一致）。
    private var known: Set<String> = []
    private var observer: UUID?

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
        outline.doubleAction = #selector(openSelected)
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
        commitPushButton.bezelStyle = .push
        commitPushButton.target = self
        commitPushButton.action = #selector(commit)
        // 提交功能在下一步接入 Rust 核心后启用。
        commitButton.isEnabled = false
        commitPushButton.isEnabled = false
        commitButton.toolTip = tr("common.notImplemented")
        commitPushButton.toolTip = tr("common.notImplemented")

        let buttons = NSStackView(views: [commitButton, commitPushButton, NSView(), amendCheckbox])
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
            button("plus.forwardslash.minus", tr("commit.action.showDiff"), nil),
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
    }

    @objc private func refresh() { model.refresh() }
    @objc private func expandAll() { outline.expandItem(nil, expandChildren: true) }
    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }

    @objc private func commit() {}

    @objc private func openSelected() {
        guard let item = outline.item(atRow: outline.clickedRow) as? FileItem, !item.change.isDeleted else { return }
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

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
