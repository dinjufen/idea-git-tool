import AppKit
import GitDeckCore

/// 欢迎页（对应 IDEA 的 Welcome to IntelliJ IDEA）：最近项目 + 新建 / 打开 / 克隆。
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private weak var appDelegate: AppDelegate?
    private let table = NSTableView()
    private let search = NSSearchField()
    private var projects: [String] = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = tr("welcome.title", L10n.productName)
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let query = search.stringValue.lowercased()
        projects = RecentProjects.shared.paths.filter { query.isEmpty || $0.lowercased().contains(query) }
        table.reloadData()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        // 左侧栏：产品名与版本、导航。
        let sidebar = ColoredView(Theme.toolWindowBackground)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField.label(L10n.productName, font: .systemFont(ofSize: 15, weight: .semibold))
        let version = NSTextField.label(tr("welcome.version", coreVersion()), font: Theme.smallFont, color: Theme.secondaryText)
        let nav = NSTextField.label(tr("welcome.nav.projects"), font: .systemFont(ofSize: 13, weight: .medium))
        let navBackground = ColoredView(Theme.selectedStripeButton)
        navBackground.translatesAutoresizingMaskIntoConstraints = false
        navBackground.layer?.cornerRadius = 6
        for view in [name, version, navBackground, nav] as [NSView] { sidebar.addSubview(view) }

        // 右侧：搜索框 + 按钮 + 最近项目。
        let main = ColoredView(Theme.editorBackground)
        main.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = tr("welcome.search.placeholder")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(title: tr("welcome.new"), target: appDelegate, action: #selector(AppDelegate.newProject(_:)))
        let openButton = NSButton(title: tr("welcome.open"), target: appDelegate, action: #selector(AppDelegate.openDocument(_:)))
        let cloneButton = NSButton(title: tr("welcome.clone"), target: nil, action: nil)
        cloneButton.isEnabled = false
        cloneButton.toolTip = tr("common.notImplemented")
        let buttons = NSStackView(views: [newButton, openButton, cloneButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("project")))
        table.headerView = nil
        table.rowHeight = 44
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.menu = rowMenu()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [search, buttons, scroll] as [NSView] { main.addSubview(view) }
        content.addSubview(sidebar)
        content.addSubview(main)
        let divider = SeparatorLine(.vertical)
        content.addSubview(divider)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            name.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
            name.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            version.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            version.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            navBackground.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 24),
            navBackground.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navBackground.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            navBackground.heightAnchor.constraint(equalToConstant: 30),
            nav.leadingAnchor.constraint(equalTo: navBackground.leadingAnchor, constant: 10),
            nav.centerYAnchor.constraint(equalTo: navBackground.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            main.topAnchor.constraint(equalTo: content.topAnchor),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            search.topAnchor.constraint(equalTo: main.topAnchor, constant: 44),
            search.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 20),
            buttons.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -10),
        ])
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("welcome.recent.open"), action: #selector(openSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("welcome.recent.reveal"), action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("welcome.recent.remove"), action: #selector(removeSelected), keyEquivalent: "").target = self
        return menu
    }

    private var targetRow: Int {
        table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    }

    @objc private func openSelected() {
        guard projects.indices.contains(targetRow) else { return }
        appDelegate?.openProject(at: URL(fileURLWithPath: projects[targetRow]))
    }

    @objc private func revealSelected() {
        guard projects.indices.contains(targetRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: projects[targetRow])])
    }

    @objc private func removeSelected() {
        guard projects.indices.contains(targetRow) else { return }
        RecentProjects.shared.remove(projects[targetRow])
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { projects.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = projects[row]
        let name = (path as NSString).lastPathComponent
        let cell = NSView()
        let badge = ProjectBadge()
        badge.text = ProjectBadge.initials(of: name)
        let title = NSTextField.label(name, font: .systemFont(ofSize: 13, weight: .semibold))
        let detail = NSTextField.label((path as NSString).abbreviatingWithTildeInPath, font: Theme.smallFont, color: Theme.secondaryText)
        let missing = !FileManager.default.fileExists(atPath: path)
        if missing { title.textColor = Theme.secondaryText }
        for view in [badge, title, detail] as [NSView] { cell.addSubview(view) }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
        ])
        return cell
    }
}
