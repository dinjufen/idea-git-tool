import AppKit
import GitDeckCore

/// Git 工具窗口的 Worktrees 标签（IDEA 2023.3+）：列出工作树，可新建、在新窗口中打开、删除。
final class WorktreesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let model: ProjectModel
    private let operations: GitOperations
    private let table = NSTableView()
    private let statusLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private var worktrees: [Worktree] = []
    private var actionButtons: [IconButton] = []
    private var observer: UUID?

    init(model: ProjectModel, operations: GitOperations) {
        self.model = model
        self.operations = operations
        super.init(frame: .zero)
        buildLayout()
        // 分支或 HEAD 变化（例如新建了工作树）后刷新。
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
        func button(_ symbol: String, _ tooltip: String, _ action: Selector, needsSelection: Bool) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 24, pointSize: 12)
            b.target = self
            b.action = action
            if needsSelection { actionButtons.append(b) }
            return b
        }
        let toolbar = NSStackView(views: [
            button("arrow.clockwise", tr("git.action.refresh"), #selector(reload), needsSelection: false),
            button("plus", tr("worktree.new"), #selector(newWorktree), needsSelection: false),
            button("macwindow.badge.plus", tr("worktree.open"), #selector(openSelected), needsSelection: true),
            button("trash", tr("worktree.remove"), #selector(removeSelected), needsSelection: true),
            NSView(), statusLabel,
        ])
        toolbar.spacing = 2
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        for (id, width) in [("branch", 180.0), ("path", 420.0), ("head", 90.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            column.resizingMask = id == "path" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = Theme.editorBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolbar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateButtons()
    }

    @objc func reload() {
        let repository = model.repository
        Task {
            let result = await Task.detached { Result { try repository.worktrees() } }.value
            switch result {
            case let .success(list):
                worktrees = list
                table.reloadData()
                statusLabel.stringValue = tr("worktree.count", "\(list.count)")
            case let .failure(error):
                statusLabel.stringValue = errorMessage(error)
            }
            updateButtons()
        }
    }

    private var selected: Worktree? {
        worktrees.indices.contains(table.selectedRow) ? worktrees[table.selectedRow] : nil
    }

    private func updateButtons() {
        let worktree = selected
        actionButtons.forEach { $0.isEnabled = worktree != nil && worktree?.isCurrent == false }
        // 主工作树不能删除。
        actionButtons.last?.isEnabled = worktree.map { !$0.isMain && !$0.isCurrent } ?? false
    }

    @objc private func newWorktree() { operations.newWorktree() }

    @objc private func openSelected() {
        guard let worktree = selected, !worktree.isCurrent else { return }
        (NSApp.delegate as? AppDelegate)?.openProject(at: URL(fileURLWithPath: worktree.path))
    }

    @objc private func removeSelected() {
        guard let worktree = selected, !worktree.isMain else { return }
        operations.removeWorktree(worktree) { [weak self] in self?.reload() }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { worktrees.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let worktree = worktrees[row]
        var text: String
        var color = Theme.secondaryText
        var font = Theme.uiFont
        switch tableColumn?.identifier.rawValue {
        case "branch":
            text = worktree.branch ?? tr("worktree.detached")
            color = Theme.text
            if worktree.isCurrent { font = .systemFont(ofSize: 13, weight: .semibold) }
            if worktree.isMain { text += "  " + tr("worktree.main") }
        case "path":
            text = (worktree.path as NSString).abbreviatingWithTildeInPath
            if worktree.prunable { text += "  " + tr("worktree.prunable"); color = Theme.FileStatus.conflict }
            if worktree.locked { text += "  🔒" }
        default:
            text = worktree.head.map { String($0.prefix(8)) } ?? ""
            font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        let label = NSTextField.label(text, font: font, color: color)
        let cell = AdaptiveCellView()
        cell.toolTip = worktree.path
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
