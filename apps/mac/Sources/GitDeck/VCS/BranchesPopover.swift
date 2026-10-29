import AppKit
import GitDeckCore

/// VCS 分支组件弹出的 Branches 弹窗：搜索框、常用操作、本地分支与远程分支。
final class BranchesPopover: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case action(title: String, symbol: String, shortcut: String?, run: @MainActor () -> Void)
        case section(String)
        case branch(BranchRef)
        case tag(TagInfo)
    }

    /// 弹窗所在的 popover；执行操作前先关闭，使后续对话框附着在项目窗口上。
    weak var popover: NSPopover?

    private let model: ProjectModel
    private let operations: GitOperations
    private let onCommit: @MainActor () -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private var rows: [Row] = []
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

    private func rebuild() {
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
        // “最近”分组：最近签出过的本地分支（只有当前分支时不显示），与 IDEA 一致只在未搜索时显示。
        if query.isEmpty {
            let recentBranches = recent.compactMap { name in model.branches.first { $0.kind == .local && $0.name == name } }
            if recentBranches.count > 1 {
                rows.append(.section(tr("branches.section.recent")))
                rows += recentBranches.map(Row.branch)
            }
        }
        let local = model.branches.filter { $0.kind == .local && matches($0) }
        let remote = model.branches.filter { $0.kind == .remote && matches($0) }
        if !local.isEmpty {
            rows.append(.section(tr("branches.section.local")))
            // 当前分支置顶，与 IDEA 一致。
            rows += local.sorted { $0.isCurrent && !$1.isCurrent }.map(Row.branch)
        }
        if !remote.isEmpty {
            rows.append(.section(tr("branches.section.remote")))
            rows += remote.map(Row.branch)
        }
        let tags = model.tags.filter { query.isEmpty || $0.name.lowercased().contains(query) }
        if !tags.isEmpty {
            rows.append(.section(tr("branches.section.tags")))
            rows += tags.map(Row.tag)
        }
        table.reloadData()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case let .action(_, _, _, run):
            popover?.close()
            run()
        case let .branch(branch):
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
            branchMenu(for: branch).popUp(positioning: nil, at: NSPoint(x: cell.bounds.maxX - 20, y: cell.bounds.midY), in: cell)
        case let .tag(tag):
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
            tagMenu(for: tag).popUp(positioning: nil, at: NSPoint(x: cell.bounds.maxX - 20, y: cell.bounds.midY), in: cell)
        case .section:
            break
        }
    }

    /// 分支操作菜单，项目与 IDEA 的分支子菜单一致；暂未实现的项显示为禁用。
    private func branchMenu(for branch: BranchRef) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let name = branch.name
        let current = model.currentBranchTitle
        let isCurrent = branch.isCurrent
        let ops = operations

        func add(_ title: String, enabled: Bool = true, _ action: (@MainActor () -> Void)?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let action, enabled {
                let handler = MenuAction { [weak self] in
                    self?.popover?.close()
                    action()
                }
                item.target = handler
                item.action = #selector(MenuAction.invoke)
                item.representedObject = handler
            } else {
                item.isEnabled = false
                if action == nil { item.toolTip = tr("common.notImplemented") }
            }
            menu.addItem(item)
        }

        if branch.kind == .local {
            add(tr("branches.menu.checkout"), enabled: !isCurrent) { ops.checkout(.local(name)) }
        } else {
            add(tr("branches.menu.checkout")) { ops.checkout(.remote(name)) }
        }
        add(tr("branches.menu.newFrom", name)) { ops.newBranch(from: name) }
        add(tr("branches.menu.checkoutAndRebase", current), enabled: branch.kind == .local && !isCurrent) {
            ops.checkoutAndRebase(name)
        }
        menu.addItem(.separator())
        add(tr("branches.menu.compare", current), enabled: !isCurrent) { ops.compareWithCurrent(name) }
        add(tr("branches.menu.showDiff")) { ops.showDiffWithWorkingTree(name) }
        add(tr("branches.menu.aiReview", current, name), enabled: !isCurrent && ops.aiReview != nil) {
            ops.aiReview?.reviewBranch(against: name, in: ops.model)
        }
        menu.addItem(.separator())
        add(tr("branches.menu.rebaseOnto", current, name), enabled: !isCurrent) { ops.rebase(onto: name) }
        add(tr("branches.menu.mergeInto", name, current), enabled: !isCurrent) { ops.merge(name) }
        menu.addItem(.separator())
        if branch.kind == .local {
            add(tr("branches.menu.update"), enabled: branch.upstream != nil) { ops.updateBranch(name) }
            add(tr("branches.menu.push"), enabled: isCurrent) { ops.push() }
            menu.addItem(.separator())
            add(tr("branches.menu.rename")) { ops.rename(name) }
            add(tr("branches.menu.delete"), enabled: !isCurrent) { ops.delete(name) }
        } else {
            add(tr("branches.menu.pull", name, current)) { ops.merge(name) }
            add(tr("branches.menu.delete")) { ops.deleteRemoteBranch(name) }
        }
        return menu
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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[row] { return 26 }
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .section(title):
            let label = NSTextField.label(title, font: Theme.font(ofSize: 11, weight: .semibold), color: Theme.secondaryText)
            return wrap(label, leading: 12)
        case let .action(title, symbol, shortcut, _):
            return BranchRowView(symbol: symbol, title: title, detail: shortcut, enabled: true)
        case let .tag(tag):
            let view = BranchRowView(symbol: "tag", title: tag.name, detail: tag.message ?? String(tag.target.prefix(8)), enabled: true, hasSubmenu: true)
            view.toolTip = tag.message
            return view
        case let .branch(branch):
            // 与 IDEA 一致只显示上游分支；领先 / 落后改由分支名后的箭头表示（悬停显示提交数）。
            var detail: [String] = []
            if let upstream = branch.upstream { detail.append(upstream) }
            if branch.upstreamGone { detail.append(tr("branches.upstreamGone")) }
            let symbol = branch.isCurrent ? "tag.fill" : "arrow.triangle.branch"
            let view = BranchRowView(symbol: symbol, title: branch.name, detail: detail.joined(separator: "  "), enabled: true,
                                     aheadBehind: branch.kind == .local ? (branch.ahead, branch.behind) : nil, hasSubmenu: true)
            view.toolTip = branch.subject
            return view
        }
    }

    private func wrap(_ view: NSView, leading: CGFloat) -> NSView {
        let container = NSView()
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

private final class BranchRowView: NSView {
    /// `aheadBehind`：本地分支的领先 / 落后提交数，在分支名后显示传入 / 传出箭头。
    /// `hasSubmenu`：分支与标签行右侧显示 ›，点击展开操作子菜单（与 IDEA 一致）。
    init(symbol: String, title: String, detail: String?, enabled: Bool, aheadBehind: (UInt32, UInt32)? = nil, hasSubmenu: Bool = false) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
        icon.contentTintColor = enabled ? Theme.text : Theme.secondaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label(title, color: enabled ? Theme.text : Theme.secondaryText)
        let detailLabel = NSTextField.label(detail ?? "", font: Theme.smallFont, color: Theme.secondaryText)
        detailLabel.alignment = .right
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let indicator = IncomingOutgoingIndicator(showCounts: true)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        if let (ahead, behind) = aheadBehind { indicator.set(ahead: ahead, behind: behind) }
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
        chevron.contentTintColor = Theme.secondaryText
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isHidden = !hasSubmenu
        for view in [icon, label, indicator, detailLabel, chevron] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: hasSubmenu ? chevron.leadingAnchor : trailingAnchor, constant: hasSubmenu ? -6 : -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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
