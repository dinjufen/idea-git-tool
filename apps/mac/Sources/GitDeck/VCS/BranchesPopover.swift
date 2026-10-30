import AppKit
import GitDeckCore

/// VCS 分支组件弹出的 Branches 弹窗：搜索框、常用操作、本地分支与远程分支。
final class BranchesPopover: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case action(title: String, symbol: String, shortcut: String?, run: @MainActor () -> Void)
        /// 分支树中的一行：分组、文件夹、分支或标签（与 IDEA 分支弹窗一样可以展开、收起）。
        case node(BranchTreeNode, depth: Int)
    }

    /// 展开的分组与文件夹：默认展开“最近”和“本地”，远程、标签与文件夹收起（与 IDEA 一致）；在本次运行中保持。
    private static var expanded: Set<String> = ["recent", "local"]
    /// 收起的“最近”分组内的文件夹（这些文件夹默认展开，因为“最近”只列出少量分支）。
    private static var collapsedRecent: Set<String> = []

    private static func isExpanded(_ key: String) -> Bool {
        key.hasPrefix("recent/") ? !collapsedRecent.contains(key) : expanded.contains(key)
    }

    /// 弹窗所在的 popover；执行操作前先关闭，使后续对话框附着在项目窗口上。
    weak var popover: NSPopover?

    private let model: ProjectModel
    private let operations: GitOperations
    private let onCommit: @MainActor () -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private var rows: [Row] = []
    private var favorites: Set<String> = []
    /// 最近签出过的本地分支（“最近”分组），打开弹窗时在后台读取。
    private var recent: [String] = []

    init(model: ProjectModel, operations: GitOperations, onCommit: @escaping @MainActor () -> Void) {
        self.model = model
        self.operations = operations
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ColoredView(Theme.toolWindowBackground)
        root.frame = NSRect(x: 0, y: 0, width: 380, height: 460)

        search.placeholderString = tr("branches.search.placeholder")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel(tr("git.action.branches"))

        // 搜索框右侧的 Fetch 按钮（与 IDEA 分支弹窗一致），用于刷新传入 / 传出提示。
        let fetch = IconButton(symbol: "arrow.down.left", tooltip: tr("git.action.fetch"), size: 26, pointSize: 12)
        fetch.target = self
        fetch.action = #selector(fetchClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(search)
        root.addSubview(fetch)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: fetch.leadingAnchor, constant: -4),
            fetch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            fetch.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        rebuild()
        loadRecent()
    }

    @objc private func fetchClicked() {
        popover?.close()
        operations.fetch()
    }

    /// 后台读取最近签出过的分支，读到后刷新列表。
    private func loadRecent() {
        let repository = model.repository
        Task { [weak self] in
            let names = await Task.detached { repository.recentBranches(maxCount: 5) }.value
            guard let self else { return }
            recent = names
            rebuild()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuild()
    }

    /// `toggled`：正在展开 / 收起的分组或文件夹；此时只增删变化的行，其余行保持不动（不会整体刷新、闪烁）。
    private func rebuild(toggled: String? = nil) {
        let previous = rows
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: (BranchRef) -> Bool = { query.isEmpty || $0.name.lowercased().contains(query) }
        rows = []
        if query.isEmpty {
            let ops = operations
            // 合并 / 变基进行中时，与 IDEA 一样在最上方提供继续与中止操作。
            switch model.status.state {
            case .rebasing:
                rows += [
                    .action(title: tr("git.action.continueRebase"), symbol: "play", shortcut: nil, run: { ops.continueRebase() }),
                    .action(title: tr("git.action.abortRebase"), symbol: "xmark.circle", shortcut: nil, run: { ops.abortRebase() }),
                ]
            case .merging:
                rows.append(.action(title: tr("git.action.abortMerge"), symbol: "xmark.circle", shortcut: nil, run: { ops.abortMerge() }))
            case .cherryPicking:
                rows += [
                    .action(title: tr("git.action.continueCherryPick"), symbol: "play", shortcut: nil, run: { ops.continueCherryPick() }),
                    .action(title: tr("git.action.abortCherryPick"), symbol: "xmark.circle", shortcut: nil, run: { ops.abortCherryPick() }),
                ]
            case .reverting:
                rows += [
                    .action(title: tr("git.action.continueRevert"), symbol: "play", shortcut: nil, run: { ops.continueRevert() }),
                    .action(title: tr("git.action.abortRevert"), symbol: "xmark.circle", shortcut: nil, run: { ops.abortRevert() }),
                ]
            default:
                break
            }
            let commit = onCommit
            rows += [
                .action(title: tr("git.action.update"), symbol: "arrow.down.left", shortcut: "⌘T", run: { ops.updateProject() }),
                .action(title: tr("git.action.commit"), symbol: "checkmark", shortcut: "⌘K", run: commit),
                .action(title: tr("git.action.push"), symbol: "arrow.up.right", shortcut: "⇧⌘K", run: { ops.push() }),
                .action(title: tr("branches.action.new"), symbol: "plus", shortcut: "⌥⌘N", run: { ops.newBranch() }),
                .action(title: tr("branches.action.checkoutRevision"), symbol: "tag", shortcut: nil, run: { ops.checkoutRevisionDialog() }),
            ]
        }
        let favorites = BranchFavorites.get(model)
        var roots: [BranchTreeNode] = []
        // “最近”分组：最近签出过的本地分支，同样按 `/` 分文件夹，保持签出顺序；搜索时只保留匹配项（与 IDEA 一致）。
        // 未搜索且只有当前分支时不显示。
        let recentBranches = recent.compactMap { name in model.branches.first { $0.kind == .local && $0.name == name } }
        if query.isEmpty ? recentBranches.count > 1 : recentBranches.contains(where: matches) {
            let group = BranchTreeNode(.group, tr("branches.section.recent"), key: "recent")
            BranchTree.addBranches(group, recentBranches.filter(matches), favorites: favorites, keepOrder: true)
            roots.append(group)
        }
        for (kind, key, title) in [(BranchKind.local, "local", tr("branches.section.local")), (.remote, "remote", tr("branches.section.remote"))] {
            let group = BranchTreeNode(.group, title, key: key)
            BranchTree.addBranches(group, model.branches.filter { $0.kind == kind && matches($0) }, favorites: favorites)
            if !group.children.isEmpty { roots.append(group) }
        }
        let tags = BranchTreeNode(.group, tr("branches.section.tags"), key: "tags")
        BranchTree.addTags(tags, model.tags.filter { query.isEmpty || $0.name.lowercased().contains(query) })
        if !tags.children.isEmpty { roots.append(tags) }
        let searching = !query.isEmpty
        rows += BranchTree.flatten(roots, isExpanded: { Self.isExpanded($0.key) }, expandAll: searching).map { Row.node($0.node, depth: $0.depth) }
        self.favorites = favorites
        guard let toggled else {
            table.reloadData()
            return
        }
        let keys = rows.map(Self.key), oldKeys = previous.map(Self.key)
        let toggledKey = rows.compactMap { row -> String? in
            if case let .node(node, depth) = row, node.key == toggled { return "\(node.key)@\(depth)" }
            return nil
        }.first
        var prefix = 0
        while prefix < oldKeys.count, prefix < keys.count, oldKeys[prefix] == keys[prefix], keys[prefix] != toggledKey { prefix += 1 }
        var suffix = 0
        while suffix < oldKeys.count - prefix, suffix < keys.count - prefix,
              oldKeys[oldKeys.count - 1 - suffix] == keys[keys.count - 1 - suffix], keys[keys.count - 1 - suffix] != toggledKey {
            suffix += 1
        }
        table.beginUpdates()
        table.removeRows(at: IndexSet(prefix..<(oldKeys.count - suffix)), withAnimation: [])
        table.insertRows(at: IndexSet(prefix..<(keys.count - suffix)), withAnimation: [])
        table.endUpdates()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case let .action(_, _, _, run):
            popover?.close()
            run()
        case let .node(node, _) where node.isExpandable:
            toggle(node.key)
        case let .node(node, _):
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
            let point = NSPoint(x: cell.bounds.maxX - 20, y: cell.bounds.midY)
            if let branch = node.branch {
                branchMenu(for: branch).popUp(positioning: nil, at: point, in: cell)
            } else if let tag = node.tag {
                tagMenu(for: tag).popUp(positioning: nil, at: point, in: cell)
            }
        }
    }

    /// 展开或收起分组 / 文件夹（搜索中全部展开，不改变保存的状态），之后保持选中该行。
    private func toggle(_ key: String) {
        guard search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if key.hasPrefix("recent/") {
            if Self.collapsedRecent.contains(key) { Self.collapsedRecent.remove(key) } else { Self.collapsedRecent.insert(key) }
        } else if Self.expanded.contains(key) {
            Self.expanded.remove(key)
        } else {
            Self.expanded.insert(key)
        }
        rebuild(toggled: key)
        if let index = rows.firstIndex(where: { if case let .node(node, _) = $0 { return node.key == key }; return false }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    /// 行的标识：用于展开 / 收起时比较前后两次的行。
    private static func key(_ row: Row) -> String {
        switch row {
        case let .action(title, _, _, _): "action:" + title
        case let .node(node, depth): "\(node.key)@\(depth)"
        }
    }

    /// 分支操作菜单（与 Git 日志左侧分支面板的右键菜单共用）。
    private func branchMenu(for branch: BranchRef) -> NSMenu {
        BranchMenus.menu(for: branch, model: model, operations: operations) { [weak self] in self?.popover?.close() }
    }

    /// 标签操作菜单。
    private func tagMenu(for tag: TagInfo) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ops = operations
        let name = tag.name
        let current = model.currentBranchTitle
        let entries: [(String, @MainActor () -> Void)?] = [
            (tr("tags.menu.checkout"), { ops.checkout(.revision(name)) }),
            (tr("branches.menu.newFrom", name), { ops.newBranch(from: name) }),
            (tr("branches.menu.mergeInto", name, current), { ops.merge(name) }),
            nil,
            (tr("tags.menu.push"), { ops.pushTag(name) }),
            (tr("tags.menu.delete"), { ops.deleteTag(name) }),
        ]
        for entry in entries {
            guard let (title, action) = entry else {
                menu.addItem(.separator())
                continue
            }
            let handler = MenuAction { [weak self] in
                self?.popover?.close()
                action()
            }
            let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .action(title, symbol, shortcut, _):
            return BranchRowView(symbol: symbol, title: title, detail: shortcut)
        case let .node(node, depth):
            let searching = !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            let disclosure: Bool? = node.isExpandable ? (searching || Self.isExpanded(node.key)) : nil
            let highlight = searching ? search.stringValue.trimmingCharacters(in: .whitespaces) : ""
            let indent = CGFloat(depth) * 14
            switch node.kind {
            case .group:
                return BranchRowView(symbol: nil, title: node.title, detail: nil, bold: true, indent: indent, disclosure: disclosure)
            case .folder:
                return BranchRowView(symbol: "folder", title: node.title, detail: nil, indent: indent, disclosure: disclosure, highlight: highlight)
            case .tag:
                let view = BranchRowView(symbol: "tag", title: node.title, detail: node.tag.map { $0.message ?? String($0.target.prefix(8)) },
                                         indent: indent, hasSubmenu: true, highlight: highlight)
                view.toolTip = node.tag?.message
                return view
            case .branch, .head:
                guard let branch = node.branch else { return nil }
                // 与 IDEA 一致只显示上游分支；领先 / 落后由分支名后的箭头与数量表示。
                var detail: [String] = []
                if let upstream = branch.upstream { detail.append(upstream) }
                if branch.upstreamGone { detail.append(tr("branches.upstreamGone")) }
                let symbol = branch.isCurrent ? "tag.fill" : favorites.contains(branch.fullRef) ? "star.fill" : "arrow.triangle.branch"
                let tint = branch.isCurrent || favorites.contains(branch.fullRef) ? NSColor(hex: 0xE2A93C) : Theme.text
                let view = BranchRowView(symbol: symbol, tint: tint, title: node.title, detail: detail.joined(separator: "  "), bold: branch.isCurrent,
                                         indent: indent, aheadBehind: branch.kind == .local ? (branch.ahead, branch.behind) : nil, hasSubmenu: true,
                                         highlight: highlight)
                view.toolTip = branch.subject
                return view
            }
        }
    }
}

private final class BranchRowView: NSView {
    /// `indent`：树的缩进；`disclosure`：分组 / 文件夹的展开箭头（true 展开、false 收起、nil 不显示）。
    /// `aheadBehind`：本地分支的领先 / 落后提交数，在分支名后显示传入 / 传出箭头与数量。
    /// `hasSubmenu`：分支与标签行右侧显示 ›，点击展开操作子菜单（与 IDEA 一致）。
    init(symbol: String?, tint: NSColor = Theme.text, title: String, detail: String?, bold: Bool = false, indent: CGFloat = 0,
         disclosure: Bool? = nil, aheadBehind: (UInt32, UInt32)? = nil, hasSubmenu: Bool = false, highlight: String = "") {
        super.init(frame: .zero)
        var leading: [NSView] = []
        if let disclosure {
            let arrow = NSImageView(image: NSImage(systemSymbolName: disclosure ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
            arrow.contentTintColor = Theme.secondaryText
            arrow.widthAnchor.constraint(equalToConstant: 10).isActive = true
            leading.append(arrow)
        } else if indent > 0 || symbol == nil {
            // 与分组 / 文件夹的展开箭头对齐。
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
            leading.append(spacer)
        }
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
            icon.contentTintColor = tint
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            leading.append(icon)
        }
        let label = NSTextField.label(title, font: bold ? Theme.font(ofSize: 13, weight: .semibold) : Theme.uiFont)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        if !highlight.isEmpty {
            // 高亮与搜索内容匹配的部分（与 IDEA 一样以黄色底色标出）。
            let text = NSMutableAttributedString(string: title, attributes: [.font: label.font as Any, .foregroundColor: Theme.text])
            var searchRange = title.startIndex..<title.endIndex
            while let found = title.range(of: highlight, options: .caseInsensitive, range: searchRange) {
                text.addAttribute(.backgroundColor, value: NSColor(hex: 0xE2A93C).withAlphaComponent(0.55), range: NSRange(found, in: title))
                searchRange = found.upperBound..<title.endIndex
            }
            label.attributedStringValue = text
        }
        leading.append(label)
        if let (ahead, behind) = aheadBehind, ahead > 0 || behind > 0 {
            let indicator = IncomingOutgoingIndicator(showCounts: true)
            indicator.set(ahead: ahead, behind: behind)
            leading.append(indicator)
        }
        let stack = NSStackView(views: leading)
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let detailLabel = NSTextField.label(detail ?? "", font: Theme.smallFont, color: Theme.secondaryText)
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
        chevron.contentTintColor = Theme.secondaryText
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isHidden = !hasSubmenu
        for view in [stack, detailLabel, chevron] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + indent),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: hasSubmenu ? chevron.leadingAnchor : trailingAnchor, constant: hasSubmenu ? -6 : -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 以闭包作为菜单项动作；由菜单项的 representedObject 持有。
@MainActor
final class MenuAction: NSObject {
    private let block: @MainActor () -> Void

    init(_ block: @escaping @MainActor () -> Void) {
        self.block = block
    }

    @objc func invoke() {
        block()
    }
}
