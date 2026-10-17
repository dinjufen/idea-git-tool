import AppKit
import GitDeckCore

/// VCS 分支组件弹出的 Branches 弹窗：搜索框、常用操作、本地分支与远程分支。
final class BranchesPopover: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case action(title: String, symbol: String, shortcut: String?)
        case section(String)
        case branch(BranchRef)
    }

    private let model: ProjectModel
    private let search = NSSearchField()
    private let table = NSTableView()
    private var rows: [Row] = []

    init(model: ProjectModel) {
        self.model = model
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

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        rebuild()
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
            rows += [
                .action(title: tr("git.action.update"), symbol: "arrow.down.left", shortcut: "⌘T"),
                .action(title: tr("git.action.commit"), symbol: "checkmark", shortcut: "⌘K"),
                .action(title: tr("git.action.push"), symbol: "arrow.up.right", shortcut: "⇧⌘K"),
                .action(title: tr("branches.action.new"), symbol: "plus", shortcut: "⌥⌘N"),
                .action(title: tr("branches.action.checkoutRevision"), symbol: "tag", shortcut: nil),
            ]
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
        table.reloadData()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), case let .branch(branch) = rows[row],
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        branchMenu(for: branch).popUp(positioning: nil, at: NSPoint(x: cell.bounds.maxX - 20, y: cell.bounds.midY), in: cell)
    }

    /// 分支操作菜单；各操作在后续阶段接入核心实现。
    private func branchMenu(for branch: BranchRef) -> NSMenu {
        let menu = NSMenu()
        let name = branch.name
        let current = model.currentBranchTitle
        var titles: [String?] = [
            tr("branches.menu.checkout"),
            tr("branches.menu.newFrom", name),
            tr("branches.menu.checkoutAndRebase", current),
            nil,
            tr("branches.menu.compare", current),
            tr("branches.menu.showDiff"),
            nil,
            tr("branches.menu.rebaseOnto", current, name),
            tr("branches.menu.mergeInto", name, current),
            nil,
        ]
        if branch.kind == .local {
            titles += [tr("branches.menu.update"), tr("branches.menu.push"), nil, tr("branches.menu.rename"), tr("branches.menu.delete")]
        } else {
            titles += [tr("branches.menu.pull", name, current), tr("branches.menu.delete")]
        }
        for title in titles {
            guard let title else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = tr("common.notImplemented")
            menu.addItem(item)
        }
        menu.autoenablesItems = false
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
            let label = NSTextField.label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: Theme.secondaryText)
            return wrap(label, leading: 12)
        case let .action(title, symbol, shortcut):
            return BranchRowView(symbol: symbol, title: title, detail: shortcut, enabled: false)
        case let .branch(branch):
            var detail: [String] = []
            if branch.ahead > 0 { detail.append("↑\(branch.ahead)") }
            if branch.behind > 0 { detail.append("↓\(branch.behind)") }
            if let upstream = branch.upstream { detail.append(upstream) }
            if branch.upstreamGone { detail.append(tr("branches.upstreamGone")) }
            let symbol = branch.isCurrent ? "tag.fill" : "arrow.triangle.branch"
            let view = BranchRowView(symbol: symbol, title: branch.name, detail: detail.joined(separator: "  "), enabled: true)
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
    init(symbol: String, title: String, detail: String?, enabled: Bool) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
        icon.contentTintColor = enabled ? Theme.text : Theme.secondaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label(title, color: enabled ? Theme.text : Theme.secondaryText)
        let detailLabel = NSTextField.label(detail ?? "", font: Theme.smallFont, color: Theme.secondaryText)
        detailLabel.alignment = .right
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for view in [icon, label, detailLabel] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
