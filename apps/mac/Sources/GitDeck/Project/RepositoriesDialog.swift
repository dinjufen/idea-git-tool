import AppKit
import GitDeckCore

/// Git > 管理仓库（IDEA 的 Directory Mappings）：列出本项目中的仓库，可加入、移除或重新检测嵌套仓库。
@MainActor
final class RepositoriesDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let panel: NSPanel
    private let table = NSTableView()
    private let removeButton = NSButton(title: tr("repositories.remove"), target: nil, action: nil)
    private let hint = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private var observer: UUID?
    private var retainSelf: RepositoriesDialog?

    init(workspace: Workspace) {
        self.workspace = workspace
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 480, height: 280)
        super.init()
        let content = ColoredView(Theme.toolWindowBackground)
        panel.contentView = content

        let heading = NSTextField.label(tr("repositories.title"), font: .systemFont(ofSize: 13, weight: .semibold))
        for (id, title, width) in [("name", tr("repositories.column.name"), 180.0), ("branch", tr("repositories.column.branch"), 140.0), ("path", tr("repositories.column.path"), 260.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: tr("repositories.add"), target: self, action: #selector(add))
        let detect = NSButton(title: tr("repositories.detect"), target: self, action: #selector(detect))
        removeButton.target = self
        removeButton.action = #selector(remove)
        let close = NSButton(title: tr("common.close"), target: self, action: #selector(dismiss))
        close.keyEquivalent = "\u{1b}"
        for button in [add, detect, removeButton, close] { button.bezelStyle = .push }
        let buttons = NSStackView(views: [add, removeButton, detect, NSView(), close])
        buttons.spacing = 8

        for view in [heading, scroll, hint, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        observer = workspace.observe { [weak self] in self?.reload() }
        reload()
    }

    func begin(for window: NSWindow?) {
        retainSelf = self
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    private func reload() {
        table.reloadData()
        let pending = workspace.candidates.count
        hint.stringValue = pending == 0 ? tr("repositories.hint") : tr("repositories.pending", "\(pending)")
        updateButtons()
    }

    private func updateButtons() {
        // 主仓库不能移除。
        removeButton.isEnabled = table.selectedRow > 0
    }

    @objc private func add() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = workspace.primary.rootURL
        open.message = tr("workspace.add.message")
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            self?.workspace.add(paths: [url.path])
        }
    }

    @objc private func remove() {
        let row = table.selectedRow
        guard row > 0, workspace.models.indices.contains(row) else { return }
        workspace.remove(workspace.models[row])
    }

    /// 重新检测并加入所有找到的嵌套仓库（包括之前忽略的）。
    @objc private func detect() {
        let repository = workspace.primary.repository
        Task {
            let found = await Task.detached { (try? repository.nestedRepositories(maxDepth: 4)) ?? [] }.value
            workspace.add(paths: found.map(\.path))
        }
    }

    @objc private func dismiss() {
        if let observer { workspace.removeObserver(observer) }
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
        retainSelf = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { workspace.models.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let repository = workspace.models[row]
        let cell = AdaptiveCellView()
        var views: [NSView] = []
        switch tableColumn?.identifier.rawValue {
        case "name":
            views.append(NSImageView(image: RepositoryBranchesPopover.chip(workspace.color(for: repository))))
            let name = row == 0 ? "\(workspace.displayName(of: repository))  \(tr("repositories.primary"))" : workspace.displayName(of: repository)
            views.append(NSTextField.label(name))
        case "branch":
            views.append(NSTextField.label(repository.branchWidgetTitle, color: Theme.secondaryText))
        default:
            let path = NSTextField.label((repository.rootURL.path as NSString).abbreviatingWithTildeInPath, color: Theme.secondaryText)
            path.lineBreakMode = .byTruncatingMiddle
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(path)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = repository.rootURL.path
        return cell
    }
}
