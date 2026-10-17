import AppKit
import GitDeckCore

/// 文件树节点，子节点按需加载。
@MainActor
final class FileNode {
    let url: URL
    let isDirectory: Bool
    /// 相对仓库根目录的路径（根节点为空串）。
    let relativePath: String
    private(set) var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool, relativePath: String) {
        self.url = url
        self.isDirectory = isDirectory
        self.relativePath = relativePath
    }

    var name: String { url.lastPathComponent }

    var children: [FileNode] {
        if let loadedChildren { return loadedChildren }
        let loaded = scan(reusing: [:])
        loadedChildren = loaded
        return loaded
    }

    /// 重新扫描已加载的目录，按名称复用节点以保留展开状态。
    func reload() {
        guard let old = loadedChildren else { return }
        let byName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        loadedChildren = scan(reusing: byName)
        loadedChildren?.forEach { $0.reload() }
    }

    private func scan(reusing existing: [String: FileNode]) -> [FileNode] {
        guard isDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        let nodes = urls
            .filter { $0.lastPathComponent != ".git" && $0.lastPathComponent != ".DS_Store" }
            .map { child -> FileNode in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if let reused = existing[child.lastPathComponent], reused.isDirectory == isDir { return reused }
                let rel = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
                return FileNode(url: child, isDirectory: isDir, relativePath: rel)
            }
        // 与 IDEA 一致：目录在前，名称不区分大小写排序。
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Project 工具窗口：仓库文件树，按 git 状态着色，双击在编辑器中打开。
final class ProjectToolWindow: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?
    var onShowHistory: ((String) -> Void)?

    private let model: ProjectModel
    private let root: FileNode
    private let outline = NSOutlineView()
    private var observer: UUID?

    init(model: ProjectModel) {
        self.model = model
        root = FileNode(url: model.rootURL, isDirectory: true, relativePath: "")
        super.init(frame: .zero)

        let collapse = IconButton(symbol: "arrow.down.right.and.arrow.up.left", tooltip: tr("tree.collapseAll"), size: 24, pointSize: 12)
        collapse.target = self
        collapse.action = #selector(collapseAll)
        let header = ToolWindowHeader(title: tr("toolwindow.project"), actions: [collapse])

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
        outline.doubleAction = #selector(openSelected)
        outline.menu = treeMenu()
        outline.setAccessibilityLabel(tr("toolwindow.project"))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let background = ColoredView(Theme.toolWindowBackground)
        addSubview(background)
        background.pinEdges(to: self)
        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        outline.reloadData()
        outline.expandItem(root)
        observer = model.observe { [weak self] in self?.statusChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 重新扫描文件系统（新增/删除的文件），并刷新着色。
    func reloadFiles() {
        root.reload()
        outline.reloadData()
    }

    private func statusChanged() {
        guard !model.isRefreshing else { return }
        reloadFiles()
    }

    private func treeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("git.action.showHistory"), action: #selector(showHistory), keyEquivalent: "").target = self
        return menu
    }

    /// 文件历史跟踪重命名，只对单个文件有效。
    @objc private func showHistory() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? FileNode, !node.isDirectory else { return NSSound.beep() }
        onShowHistory?(node.relativePath)
    }

    @objc private func collapseAll() {
        outline.collapseItem(nil, collapseChildren: true)
        outline.expandItem(root)
    }

    @objc private func openSelected() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpenFile?(node.url)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return root }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? FileCellView ?? FileCellView(identifier: id)
        let isRoot = node === root
        cell.configure(
            icon: icon(for: node),
            name: node.name,
            detail: isRoot ? (model.rootURL.path as NSString).abbreviatingWithTildeInPath : nil,
            color: color(for: node),
            bold: isRoot
        )
        return cell
    }

    private func icon(for node: FileNode) -> NSImage? {
        NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    private func color(for node: FileNode) -> NSColor {
        if let change = model.changesByPath[node.relativePath] { return change.statusColor }
        // 目录下有变更时目录名也着色（IDEA 的 “Highlight directories that contain modified files”）。
        if node.isDirectory, !node.relativePath.isEmpty {
            let prefix = node.relativePath + "/"
            if model.status.changes.contains(where: { $0.path.hasPrefix(prefix) && !$0.isIgnored }) {
                return Theme.FileStatus.modified
            }
        }
        return Theme.text
    }
}

/// 树单元格：图标 + 名称 + 灰色附加信息。Commit 工具窗口复用。
final class FileCellView: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField.label("")
    private let detailLabel = NSTextField.label("", color: Theme.secondaryText)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = Theme.secondaryText
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, nameLabel, detailLabel])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(icon image: NSImage?, name: String, detail: String?, color: NSColor, bold: Bool = false, strikethrough: Bool = false) {
        icon.image = image
        icon.isHidden = image == nil
        let font = bold ? NSFont.systemFont(ofSize: 13, weight: .semibold) : Theme.uiFont
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        nameLabel.attributedStringValue = NSAttributedString(string: name, attributes: attrs)
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail?.isEmpty ?? true
    }
}
