import AppKit
import GitDeckCore

/// 提交工具窗口的 “储藏” 标签（IDEA New UI 的 Stash 标签）：储藏列表，展开为改动的文件。
final class StashesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onShowFileDiff: ((StashEntry, ChangedFile) -> Void)?

    /// 储藏节点；文件在首次展开时加载。
    final class StashItem {
        let entry: StashEntry
        var files: [FileItem]?
        init(_ entry: StashEntry) { self.entry = entry }
    }

    final class FileItem {
        let file: ChangedFile
        weak var stash: StashItem?
        init(_ file: ChangedFile, stash: StashItem) {
            self.file = file
            self.stash = stash
        }
    }

    private let model: ProjectModel
    private let operations: GitOperations
    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField.label(tr("stash.empty"), color: Theme.secondaryText)
    private var items: [StashItem] = []
    private var observer: UUID?
    private var actionButtons: [IconButton] = []

    init(model: ProjectModel, operations: GitOperations) {
        self.model = model
        self.operations = operations
        super.init(frame: .zero)
        buildLayout()
        observer = model.observe { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        func button(_ symbol: String, _ tooltip: String, _ action: Selector, needsSelection: Bool = true) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 26, pointSize: 12)
            b.target = self
            b.action = action
            if needsSelection { actionButtons.append(b) }
            return b
        }
        let toolbar = NSStackView(views: [
            button("arrow.clockwise", tr("git.action.refresh"), #selector(refresh), needsSelection: false),
            button("tray.and.arrow.up", tr("stash.action.apply"), #selector(applySelected)),
            button("arrow.up.doc", tr("stash.action.pop"), #selector(popSelected)),
            button("arrow.triangle.branch", tr("stash.action.branch"), #selector(branchSelected)),
            button("trash", tr("stash.action.drop"), #selector(dropSelected)),
            button("xmark.bin", tr("stash.action.clear"), #selector(clearAll), needsSelection: false),
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
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.menu = contextMenu()
        outline.setAccessibilityLabel(tr("commit.tab.stash"))
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
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            (tr("stash.action.apply"), #selector(applySelected)),
            (tr("stash.action.pop"), #selector(popSelected)),
            (tr("stash.action.applyIndex"), #selector(applyWithIndex)),
            (tr("stash.action.branch"), #selector(branchSelected)),
            (tr("stash.action.drop"), #selector(dropSelected)),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    /// 储藏列表变化时重建（保留已展开节点与已加载的文件）。
    private func reload() {
        guard !model.isRefreshing else { return }
        let existing = Dictionary(items.map { ($0.entry.hash, $0) }, uniquingKeysWith: { a, _ in a })
        let expanded = Set(items.filter { outline.isItemExpanded($0) }.map(\.entry.hash))
        items = model.stashes.map { entry in
            // 下标可能因删除而变化：复用节点时用最新的条目。
            if let old = existing[entry.hash], old.entry == entry { return old }
            let item = StashItem(entry)
            item.files = existing[entry.hash]?.files
            return item
        }
        outline.reloadData()
        for item in items where expanded.contains(item.entry.hash) { outline.expandItem(item) }
        emptyLabel.isHidden = !items.isEmpty
        updateButtons()
    }

    private var selectedStash: StashEntry? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        switch outline.item(atRow: row) {
        case let item as StashItem: return item.entry
        case let file as FileItem: return file.stash?.entry
        default: return nil
        }
    }

    private func updateButtons() {
        let enabled = selectedStash != nil
        actionButtons.forEach { $0.isEnabled = enabled }
    }

    #if DEBUG
    /// 仅 Debug 构建：展开第一条储藏，便于界面验证。
    func expandFirst() {
        if let first = items.first { outline.expandItem(first) }
    }
    #endif

    @objc private func refresh() { model.refresh() }
    @objc private func applySelected() { selectedStash.map { operations.applyStash($0, pop: false) } }
    @objc private func popSelected() { selectedStash.map { operations.applyStash($0, pop: true) } }
    @objc private func applyWithIndex() { selectedStash.map { operations.applyStash($0, pop: false, reinstateIndex: true) } }
    @objc private func branchSelected() { selectedStash.map(operations.unstashAsBranch) }
    @objc private func dropSelected() { selectedStash.map(operations.dropStash) }
    @objc private func clearAll() { operations.clearStashes() }

    @objc private func doubleClicked() {
        switch outline.item(atRow: outline.clickedRow) {
        case let file as FileItem:
            if let stash = file.stash { onShowFileDiff?(stash.entry, file.file) }
        case let item as StashItem:
            outline.isItemExpanded(item) ? outline.collapseItem(item) : outline.expandItem(item)
        default:
            break
        }
    }

    private func loadFiles(_ item: StashItem) {
        let repository = model.repository
        let index = item.entry.index
        Task {
            let files = await Task.detached { (try? repository.stashFiles(index: index)) ?? [] }.value
            item.files = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { FileItem($0, stash: item) }
            outline.reloadItem(item, reloadChildren: true)
        }
    }

    // MARK: - NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: items.count
        case let stash as StashItem: stash.files?.count ?? 0
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let stash = item as? StashItem, let files = stash.files { return files[index] }
        return items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is StashItem
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? StashItem, item.files == nil else { return }
        loadFiles(item)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("StashCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? FileCellView ?? FileCellView(identifier: id)
        switch item {
        case let stash as StashItem:
            let entry = stash.entry
            var detail = [LogDateFormatter.short(entry.time)]
            if let branch = entry.branch { detail.insert(branch, at: 0) }
            cell.configure(
                icon: NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)),
                name: entry.message,
                detail: detail.joined(separator: " · "),
                color: Theme.text
            )
            cell.toolTip = "stash@{\(entry.index)}  \(String(entry.hash.prefix(8)))"
        case let file as FileItem:
            let path = file.file.path
            cell.configure(
                icon: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)),
                name: (path as NSString).lastPathComponent,
                detail: (path as NSString).deletingLastPathComponent,
                color: file.file.kind == .untracked ? Theme.FileStatus.untracked : file.file.kind.statusColor,
                strikethrough: file.file.kind == .deleted
            )
            cell.toolTip = path
        default:
            return nil
        }
        return cell
    }
}
