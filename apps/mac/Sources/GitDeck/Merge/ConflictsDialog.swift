import AppKit
import GitDeckCore

/// IDEA 的 Conflicts 对话框：列出冲突文件，可整体接受一方或打开三栏合并工具。冲突全部解决后自动关闭。
@MainActor
final class ConflictsDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let model: ProjectModel
    private let onMerge: (FileChange) -> Void
    private let panel: NSPanel
    private let table = NSTableView()
    private let acceptOurs = NSButton(title: "", target: nil, action: nil)
    private let acceptTheirs = NSButton(title: "", target: nil, action: nil)
    private let mergeButton = NSButton(title: tr("conflicts.merge"), target: nil, action: nil)
    private var conflicts: [FileChange] = []
    private var labels = ConflictLabels(ours: "", theirs: "")
    private var observer: UUID?
    private weak var parent: NSWindow?
    private var retainSelf: ConflictsDialog?
    private var isBusy = false

    init(model: ProjectModel, onMerge: @escaping (FileChange) -> Void) {
        self.model = model
        self.onMerge = onMerge
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = tr("conflicts.title")
        panel.minSize = NSSize(width: 520, height: 260)
        buildContent()
    }

    func begin(for window: NSWindow?) {
        retainSelf = self
        parent = window
        let repository = model.repository
        Task {
            labels = await Task.detached { repository.conflictLabels() }.value
            acceptOurs.title = tr("conflicts.acceptOurs", labels.ours)
            acceptTheirs.title = tr("conflicts.acceptTheirs", labels.theirs)
            if let column = table.tableColumn(withIdentifier: .init("ours")) { column.title = labels.ours }
            if let column = table.tableColumn(withIdentifier: .init("theirs")) { column.title = labels.theirs }
            table.reloadData()
        }
        observer = model.observe { [weak self] in self?.reload() }
        reload()
        if let window { window.beginSheet(panel) } else { panel.makeKeyAndOrderFront(nil) }
    }

    private func buildContent() {
        guard let content = panel.contentView else { return }
        let message = NSTextField.label(tr("conflicts.message"), color: Theme.secondaryText)
        message.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [("file", tr("conflicts.column.file"), 320.0), ("ours", "", 130.0), ("theirs", "", 130.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.resizingMask = id == "file" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(mergeSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [(acceptOurs, #selector(acceptOursSelected)), (acceptTheirs, #selector(acceptTheirsSelected)), (mergeButton, #selector(mergeSelected))] {
            button.target = self
            button.action = action
        }
        mergeButton.keyEquivalent = "\r"
        let close = NSButton(title: tr("conflicts.close"), target: self, action: #selector(closeDialog))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [close, NSView(), acceptOurs, acceptTheirs, mergeButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [message, scroll, buttons] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func reload() {
        guard !model.isRefreshing else { return }
        conflicts = model.status.changes
            .filter { $0.conflict != nil }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if conflicts.isEmpty, retainSelf != nil {
            closeDialog()
            return
        }
        table.reloadData()
        if table.selectedRowIndexes.isEmpty, !conflicts.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selected: [FileChange] {
        table.selectedRowIndexes.compactMap { conflicts.indices.contains($0) ? conflicts[$0] : nil }
    }

    private func updateButtons() {
        let hasSelection = !selected.isEmpty
        acceptOurs.isEnabled = hasSelection && !isBusy
        acceptTheirs.isEnabled = hasSelection && !isBusy
        // 三栏合并只适用于双方都有内容的单个文件。
        mergeButton.isEnabled = selected.count == 1 && selected[0].conflict.map(Self.bothSidesExist) == true && !isBusy
    }

    static func bothSidesExist(_ kind: ConflictKind) -> Bool {
        kind == .bothModified || kind == .bothAdded
    }

    @objc private func acceptOursSelected() { accept(.ours) }
    @objc private func acceptTheirsSelected() { accept(.theirs) }

    private func accept(_ side: ConflictSide) {
        let paths = selected.map(\.path)
        guard !paths.isEmpty else { return }
        isBusy = true
        updateButtons()
        let repository = model.repository
        Task {
            let result = await Task.detached {
                Result { for path in paths { try repository.acceptConflictSide(path: path, side: side) } }
            }.value
            isBusy = false
            if case let .failure(error) = result {
                let alert = AppAlert()
                alert.messageText = tr("conflicts.failed")
                alert.informativeText = errorMessage(error)
                alert.beginSheetModal(for: panel, completionHandler: nil)
            }
            model.refresh()
        }
    }

    @objc private func mergeSelected() {
        guard mergeButton.isEnabled, let change = selected.first else { return }
        onMerge(change)
    }

    @objc private func closeDialog() {
        if let observer { model.removeObserver(observer) }
        observer = nil
        if let parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        retainSelf = nil
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let change = conflicts[row]
        let kind = change.conflict ?? .bothModified
        let text: String
        let color: NSColor
        switch tableColumn?.identifier.rawValue {
        case "file": (text, color) = (change.path, Theme.FileStatus.conflict)
        case "ours": (text, color) = (Self.sideStatus(kind, ours: true), Theme.secondaryText)
        default: (text, color) = (Self.sideStatus(kind, ours: false), Theme.secondaryText)
        }
        let label = NSTextField.label(text, color: color)
        let cell = AdaptiveCellView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// 某一方对该文件做了什么：修改、新增或删除。
    private static func sideStatus(_ kind: ConflictKind, ours: Bool) -> String {
        switch (kind, ours) {
        case (.bothModified, _): tr("conflicts.status.modified")
        case (.bothAdded, _): tr("conflicts.status.added")
        case (.bothDeleted, _): tr("conflicts.status.deleted")
        case (.addedByUs, true), (.addedByThem, false): tr("conflicts.status.added")
        case (.addedByUs, false), (.addedByThem, true): "—"
        case (.deletedByUs, true), (.deletedByThem, false): tr("conflicts.status.deleted")
        case (.deletedByUs, false), (.deletedByThem, true): tr("conflicts.status.modified")
        }
    }
}
