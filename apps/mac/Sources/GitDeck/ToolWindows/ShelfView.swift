import AppKit
import GitDeckCore

/// 提交工具窗口的 “搁置” 标签（IDEA 的 Shelf）：搁置的改动列表，展开为文件；可取回全部或选中的文件。
final class ShelfView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class EntryItem {
        let entry: ShelfEntry
        private(set) var files: [FileItem] = []
        init(_ entry: ShelfEntry) {
            self.entry = entry
            files = entry.files.map { FileItem($0, entry: self) }
        }
    }

    final class FileItem {
        let file: PatchFile
        unowned let parent: EntryItem
        init(_ file: PatchFile, entry: EntryItem) {
            self.file = file
            parent = entry
        }
    }

    private let model: ProjectModel
    private let operations: GitOperations
    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField.label(tr("shelf.empty"), color: Theme.secondaryText)
    private var items: [EntryItem] = []
    private var observer: UUID?
    private var actionButtons: [IconButton] = []
    private var loadTask: Task<Void, Never>?

    init(model: ProjectModel, operations: GitOperations) {
        self.model = model
        self.operations = operations
        super.init(frame: .zero)
        buildLayout()
        observer = model.observe { [weak self] in
            guard let self, !self.model.isRefreshing, !self.isHidden else { return }
            self.reload()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { if !isHidden { reload() } }
    }

    private func buildLayout() {
        func button(_ symbol: String, _ tooltip: String, _ action: Selector, needsSelection: Bool = true) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 26, pointSize: 12)
            b.target = self
            b.action = action
            if needsSelection { actionButtons.append(b) }
            return b
        }
        let toolbar = NSStackView(views: [
            button("arrow.clockwise", tr("git.action.refresh"), #selector(reload), needsSelection: false),
            button("tray.and.arrow.up", tr("shelf.action.unshelve"), #selector(unshelveSelected)),
            button("trash", tr("shelf.action.delete"), #selector(deleteSelected)),
        ])
        toolbar.spacing = 0
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .sourceList
        outline.backgroundColor = Theme.toolWindowBackground
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.menu = contextMenu()
        outline.setAccessibilityLabel(tr("commit.tab.shelf"))
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [toolbar, scroll, emptyLabel] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateButtons()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            (tr("shelf.action.unshelve"), #selector(unshelveSelected)),
            (tr("shelf.action.unshelveKeep"), #selector(unshelveKeepSelected)),
            (tr("shelf.action.rename"), #selector(renameSelected)),
            (tr("shelf.action.delete"), #selector(deleteSelected)),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    @objc func reload() {
        let repository = model.repository
        loadTask?.cancel()
        loadTask = Task {
            let entries = await Task.detached { (try? repository.shelves()) ?? [] }.value
            guard !Task.isCancelled else { return }
            let expanded = Set(items.filter { outline.isItemExpanded($0) }.map(\.entry.id))
            items = entries.map(EntryItem.init)
            outline.reloadData()
            for item in items where expanded.contains(item.entry.id) { outline.expandItem(item) }
            emptyLabel.isHidden = !items.isEmpty
            updateButtons()
        }
    }

    #if DEBUG
    func expandFirst() {
        if let first = items.first { outline.expandItem(first) }
    }
    #endif

    /// 右键时作用于点击的行（不在选中范围内时只作用于该行），否则作用于选中行。
    private var targetRows: IndexSet {
        outline.clickedRow >= 0 && !outline.selectedRowIndexes.contains(outline.clickedRow)
            ? IndexSet(integer: outline.clickedRow)
            : outline.selectedRowIndexes
    }

    /// 目标条目及其中选中的文件（选中整个条目时文件为空，表示全部）。
    private var target: (ShelfEntry, [String])? {
        var entry: EntryItem?
        var files: [String] = []
        for row in targetRows {
            switch outline.item(atRow: row) {
            case let item as EntryItem:
                guard entry == nil || entry === item else { return nil }
                entry = item
                return (item.entry, [])
            case let file as FileItem:
                guard entry == nil || entry === file.parent else { continue }
                entry = file.parent
                files.append(file.file.path)
            default: break
            }
        }
        return entry.map { ($0.entry, files) }
    }

    private func updateButtons() {
        let enabled = target != nil
        actionButtons.forEach { $0.isEnabled = enabled }
    }

    @objc private func unshelveSelected() {
        guard let (entry, files) = target else { return }
        operations.unshelve(entry, paths: files, keep: false)
    }

    @objc private func unshelveKeepSelected() {
        guard let (entry, files) = target else { return }
        operations.unshelve(entry, paths: files, keep: true)
    }

    @objc private func renameSelected() {
        guard let (entry, _) = target else { return }
        operations.renameShelf(entry)
    }

    @objc private func deleteSelected() {
        guard let (entry, _) = target else { return }
        operations.deleteShelf(entry)
    }

    // MARK: - NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let entry = item as? EntryItem { return entry.files.count }
        return item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let entry = item as? EntryItem { return entry.files[index] }
        return items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is EntryItem }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let title: NSTextField
        let detail: NSTextField
        let icon = NSImageView()
        switch item {
        case let entry as EntryItem:
            title = NSTextField.label(entry.entry.name, font: .systemFont(ofSize: 13, weight: .medium))
            let count = entry.files.count == 1 ? tr("commit.group.oneFile") : tr("commit.group.files", "\(entry.files.count)")
            detail = NSTextField.label("\(LogDateFormatter.short(entry.entry.time))  \(count)", font: Theme.smallFont, color: Theme.secondaryText)
            icon.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
        case let file as FileItem:
            let name = (file.file.path as NSString).lastPathComponent
            title = NSTextField.label(name)
            let directory = (file.file.path as NSString).deletingLastPathComponent
            detail = NSTextField.label("\(directory)  +\(file.file.added) −\(file.file.deleted)", font: Theme.smallFont, color: Theme.secondaryText)
            icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            cell.toolTip = file.file.path
        default:
            return nil
        }
        icon.contentTintColor = Theme.secondaryText
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, title, detail])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
