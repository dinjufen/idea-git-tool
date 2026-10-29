import AppKit
import GitDeckCore

/// Git 日志左侧的分支面板（IDEA Log 标签页的 Branches 面板）：左边一列操作按钮（`toolbar`），
/// 右边是搜索框与分支树（`tree`；HEAD、本地分支、远程分支；名称中的 `/` 分组为文件夹，当前分支与收藏的分支排在前面）。
/// 选中分支时按该分支筛选日志，选中分组时取消分支筛选；右键为与分支弹窗相同的操作菜单。
@MainActor
final class BranchesPane: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private static let collapsedKey = "log.branchesPane.collapsed"
    private static let yellow = NSColor(hex: 0xE2A93C)

    private typealias Node = BranchTreeNode

    /// 左侧的按钮列（折叠后仍然显示）。
    let toolbar = ColoredView(Theme.toolWindowBackground)
    /// 搜索框与分支树（折叠时隐藏）。
    let tree = ColoredView(Theme.toolWindowBackground)

    /// 选中项对应的日志分支筛选：分支的完整引用名、`HEAD`，或 nil（取消分支筛选）。
    var onFilter: ((String?) -> Void)?
    /// 在日志中定位到某个提交（分支头）。
    var onNavigate: ((String) -> Void)?
    /// 折叠或展开（日志据此调整布局）。
    var onCollapsedChange: (() -> Void)?

    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private var toggleButton: IconButton!
    private var updateButton: IconButton!
    private var deleteButton: IconButton!
    private var compareButton: IconButton!
    private var favoriteButton: IconButton!
    private var navigateButton: IconButton!
    private var roots: [Node] = []
    /// 折叠的分组与文件夹（默认全部展开，与 IDEA 一致）。
    private var collapsedKeys: Set<String> = []
    private var model: ProjectModel?
    private var operations: GitOperations?
    private var rebuilding = false

    override init() {
        super.init()
        buildToolbar()
        buildTree()
        applyCollapsed(UserDefaults.standard.bool(forKey: Self.collapsedKey))
        updateButtons()
    }

    /// 折叠后只保留左侧的按钮列（与 IDEA 一致）。
    var isCollapsed: Bool {
        get { tree.isHidden }
        set {
            applyCollapsed(newValue)
            UserDefaults.standard.set(newValue, forKey: Self.collapsedKey)
            onCollapsedChange?()
        }
    }

    /// 显示某个仓库的分支（仓库或其分支变化时调用）。
    func update(model: ProjectModel, operations: GitOperations?) {
        self.model = model
        self.operations = operations
        rebuild()
    }

    // MARK: - 布局

    private func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> IconButton {
        let b = IconButton(symbol: symbol, tooltip: tooltip, size: 24, pointSize: 12)
        b.target = self
        b.action = action
        return b
    }

    private func buildToolbar() {
        toggleButton = button("chevron.left.2", tr("branchesPane.hide"), #selector(toggleCollapsed))
        updateButton = button("arrow.down.left", tr("branchesPane.update"), #selector(updateSelected))
        deleteButton = button("trash", tr("branchesPane.delete"), #selector(deleteSelected))
        compareButton = button("arrow.left.arrow.right", tr("branchesPane.compare"), #selector(compareSelected))
        favoriteButton = button("star", tr("branchesPane.favorite"), #selector(toggleFavorite))
        navigateButton = button("scope", tr("branchesPane.navigate"), #selector(navigateSelected))
        let buttons: [IconButton] = [
            toggleButton,
            button("plus", tr("branches.action.new"), #selector(newBranch)),
            updateButton, deleteButton, compareButton,
            button("arrow.clockwise", tr("git.action.fetch"), #selector(fetch)),
            favoriteButton, navigateButton,
        ]
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Git 工具窗口较矮时按钮列可以滚动，最后几个按钮不会被裁掉。
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let divider = SeparatorLine(.vertical)
        toolbar.addSubview(scroll)
        toolbar.addSubview(divider)
        NSLayoutConstraint.activate([
            toolbar.widthAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: toolbar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            divider.topAnchor.constraint(equalTo: toolbar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
        ])
    }

    private func buildTree() {
        search.placeholderString = tr("branchesPane.search")
        search.delegate = self
        search.sendsWholeSearchString = false
        search.controlSize = .small
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.setAccessibilityLabel(tr("branchesPane.title"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tree.translatesAutoresizingMaskIntoConstraints = false
        tree.addSubview(search)
        tree.addSubview(scroll)
        NSLayoutConstraint.activate([
            tree.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            tree.widthAnchor.constraint(equalToConstant: 200).withPriority(.defaultLow),
            search.topAnchor.constraint(equalTo: tree.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: tree.leadingAnchor, constant: 6),
            search.trailingAnchor.constraint(equalTo: tree.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: tree.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tree.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: tree.bottomAnchor),
        ])
    }

    private func applyCollapsed(_ collapsed: Bool) {
        tree.isHidden = collapsed
        toggleButton.image = NSImage(systemSymbolName: collapsed ? "chevron.right.2" : "chevron.left.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let tip = tr(collapsed ? "branchesPane.show" : "branchesPane.hide")
        toggleButton.toolTip = tip
        toggleButton.setAccessibilityLabel(tip)
    }

    private var favorites: Set<String> { model.map(BranchFavorites.get) ?? [] }

    // MARK: - 树

    private func rebuild() {
        guard let model else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let favorites = favorites
        let matches: (BranchRef) -> Bool = { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }

        var roots: [Node] = []
        if query.isEmpty { roots.append(Node(.head, tr("branchesPane.head"), key: "head")) }
        for (kind, key, title) in [(BranchKind.local, "local", tr("branches.section.local")), (.remote, "remote", tr("branches.section.remote"))] {
            let group = Node(.group, title, key: key)
            BranchTree.addBranches(group, model.branches.filter { $0.kind == kind && matches($0) }, favorites: favorites)
            if !group.children.isEmpty { roots.append(group) }
        }

        let selected = (outline.item(atRow: outline.selectedRow) as? Node)?.key
        rebuilding = true
        self.roots = roots
        outline.reloadData()
        expand(roots, all: !query.isEmpty)
        if let selected, let row = rowOf(identity: selected) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        rebuilding = false
        updateButtons()
    }

    private func expand(_ nodes: [Node], all: Bool) {
        for node in nodes where node.isExpandable {
            if all || !collapsedKeys.contains(node.key) {
                outline.expandItem(node)
                expand(node.children, all: all)
            }
        }
    }

    private func rowOf(identity: String) -> Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? Node)?.key == identity }
    }

    private var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }

    private func updateButtons() {
        let branch = selectedNode?.branch
        updateButton.isEnabled = branch?.kind == .local && branch?.upstream != nil
        deleteButton.isEnabled = branch.map { !$0.isCurrent } ?? false
        compareButton.isEnabled = branch.map { !$0.isCurrent } ?? false
        favoriteButton.isEnabled = branch != nil
        // 选中的分支已收藏时星标按钮显示为实心。
        let isFavorite = branch.map { favorites.contains($0.fullRef) } ?? false
        favoriteButton.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        navigateButton.isEnabled = branch != nil || selectedNode?.kind == .head
    }

    // MARK: - 操作

    @objc private func toggleCollapsed() { isCollapsed.toggle() }

    @objc private func newBranch() { operations?.newBranch(from: selectedNode?.branch?.name) }

    @objc private func updateSelected() {
        guard let branch = selectedNode?.branch, branch.kind == .local else { return }
        operations?.updateBranch(branch.name)
    }

    @objc private func deleteSelected() {
        guard let branch = selectedNode?.branch, !branch.isCurrent else { return }
        if branch.kind == .local { operations?.delete(branch.name) } else { operations?.deleteRemoteBranch(branch.name) }
    }

    @objc private func compareSelected() {
        guard let branch = selectedNode?.branch, !branch.isCurrent else { return }
        operations?.compareWithCurrent(branch.name)
    }

    @objc private func fetch() { operations?.fetch() }

    @objc private func toggleFavorite() {
        guard let branch = selectedNode?.branch, let model else { return }
        BranchFavorites.toggle(model, branch.fullRef)
        rebuild()
    }

    @objc private func navigateSelected() {
        if let branch = selectedNode?.branch {
            onNavigate?(branch.target)
        } else if selectedNode?.kind == .head, let head = model?.status.branch.oid {
            onNavigate?(head)
        }
    }

    @objc private func rowDoubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        if node.isExpandable {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else if let branch = node.branch {
            onNavigate?(branch.target)
        }
    }

    // MARK: - 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? Node, let branch = node.branch,
              let model, let operations else { return }
        outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)
        for item in BranchMenus.menu(for: branch, model: model, operations: operations).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - NSSearchField

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    // MARK: - NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isExpandable ?? false
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !rebuilding, search.stringValue.isEmpty, let node = notification.userInfo?["NSObject"] as? Node else { return }
        collapsedKeys.insert(node.key)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !rebuilding, let node = notification.userInfo?["NSObject"] as? Node else { return }
        collapsedKeys.remove(node.key)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        guard !rebuilding, let node = selectedNode else { return }
        switch node.kind {
        case .head: onFilter?("HEAD")
        case .branch: onFilter?(node.branch?.fullRef)
        case .group, .folder, .tag: onFilter?(nil)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let symbol: String?
        var tint = Theme.text
        switch node.kind {
        case .head, .group: symbol = nil
        case .tag: symbol = "tag"
        case .folder: symbol = "folder"
        case .branch:
            if node.branch?.isCurrent == true {
                symbol = "tag.fill"
                tint = Self.yellow
            } else if let branch = node.branch, favorites.contains(branch.fullRef) {
                symbol = "star.fill"
                tint = Self.yellow
            } else {
                symbol = "arrow.triangle.branch"
            }
        }
        let label = NSTextField.label(node.title, font: node.kind == .group ? Theme.font(ofSize: 13, weight: .semibold) : Theme.uiFont)
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = []
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
            icon.contentTintColor = tint
            views.append(icon)
        }
        views.append(label)
        if let branch = node.branch, branch.kind == .local {
            let indicator = IncomingOutgoingIndicator()
            indicator.set(ahead: branch.ahead, behind: branch.behind)
            views.append(indicator)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = node.branch?.subject
        cell.setAccessibilityLabel(node.branch?.name ?? node.title)
        return cell
    }
}
