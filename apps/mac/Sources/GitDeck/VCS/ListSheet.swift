import AppKit

/// 只读列表表单：分组标题 + 行（图标、标题、说明），双击行执行该行的动作并关闭表单。
/// 用于分支菜单的 Compare with Current 与 Show Diff with Working Tree。
@MainActor
final class ListSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        let symbol: String?
        let title: String
        let detail: String
        let action: (@MainActor () -> Void)?
    }

    enum Item {
        case header(String)
        case row(Row)
    }

    private let panel: NSPanel
    private let table = NSTableView()
    private let items: [Item]
    private var retainSelf: ListSheet?

    init(title: String, message: String, items: [Item], emptyText: String) {
        self.items = items
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 420, height: 260)
        super.init()
        let content = ColoredView(Theme.toolWindowBackground)
        panel.contentView = content

        let heading = NSTextField.label(title, font: .systemFont(ofSize: 13, weight: .semibold))
        let subtitle = NSTextField.label(message, font: Theme.smallFont, color: Theme.secondaryText)
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.backgroundColor = Theme.editorBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let empty = NSTextField.label(emptyText, color: Theme.secondaryText)
        empty.isHidden = items.contains { if case .row = $0 { true } else { false } }
        let close = NSButton(title: tr("common.close"), target: self, action: #selector(dismiss))
        close.keyEquivalent = "\u{1b}"
        close.bezelStyle = .push
        for view in [heading, subtitle, scroll, empty, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            close.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    func begin(for window: NSWindow?) {
        retainSelf = self
        if let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func dismiss() {
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
        retainSelf = nil
    }

    @objc private func activate() {
        guard items.indices.contains(table.clickedRow), case let .row(row) = items[table.clickedRow], let action = row.action else { return }
        dismiss()
        action()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { false } else { true }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let views: [NSView]
        switch items[row] {
        case let .header(text):
            views = [NSTextField.label(text, font: .systemFont(ofSize: 12, weight: .semibold), color: Theme.secondaryText)]
        case let .row(item):
            let title = NSTextField.label(item.title)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField.label(item.detail, font: Theme.smallFont, color: Theme.secondaryText)
            var list: [NSView] = [title, detail]
            if let symbol = item.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let icon = NSImageView(image: image)
                icon.contentTintColor = Theme.secondaryText
                list.insert(icon, at: 0)
            }
            views = list
            cell.toolTip = item.title
        }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
