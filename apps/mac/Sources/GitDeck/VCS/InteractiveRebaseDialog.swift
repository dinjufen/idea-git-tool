import AppKit
import GitDeckCore

/// IDEA 的交互式变基对话框：最新的提交在最上方；为选中的提交设置动作、调整顺序、改写提交信息。
@MainActor
final class InteractiveRebaseDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let commit: RebaseCommit
        var action: RebaseAction = .pick
        /// 改写或压缩后使用的提交信息；`nil` 表示保持原样（压缩时由 git 拼接）。
        var message: String?
    }

    private var rows: [Row]
    private let panel: NSPanel
    private let table = NSTableView()
    private let warning = NSTextField.label("", font: Theme.smallFont, color: Theme.FileStatus.conflict)
    private let startButton = NSButton(title: tr("rebase.start"), target: nil, action: nil)
    private var completion: (([RebaseStep]) -> Void)?
    private weak var parent: NSWindow?
    private var retainSelf: InteractiveRebaseDialog?

    init(commits: [RebaseCommit], branch: String) {
        // 核心按从旧到新返回；对话框与 Log 一致，最新的在最上方。
        rows = commits.reversed().map { Row(commit: $0) }
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = tr("rebase.title", "\(commits.count)", branch)
        panel.minSize = NSSize(width: 600, height: 320)
        buildContent()
        validate()
    }

    func begin(for window: NSWindow?, completion: @escaping ([RebaseStep]) -> Void) {
        self.completion = completion
        retainSelf = self
        parent = window
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    private func buildContent() {
        guard let content = panel.contentView else { return }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .push
            b.controlSize = .small
            return b
        }
        let actions = NSStackView(views: [
            button(tr("rebase.action.pick"), #selector(setPick)),
            button(tr("rebase.action.edit"), #selector(setEdit)),
            button(tr("rebase.action.reword"), #selector(setReword)),
            button(tr("rebase.action.squash"), #selector(setSquash)),
            button(tr("rebase.action.fixup"), #selector(setFixup)),
            button(tr("rebase.action.drop"), #selector(setDrop)),
            NSView(),
            button(tr("rebase.moveUp"), #selector(moveUp)),
            button(tr("rebase.moveDown"), #selector(moveDown)),
        ])
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        for (id, width) in [("action", 80.0), ("hash", 80.0), ("subject", 380.0), ("author", 120.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            column.resizingMask = id == "subject" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editMessageOfClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField.label(tr("rebase.hint"), font: Theme.smallFont, color: Theme.secondaryText)
        let cancel = NSButton(title: tr("common.cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [warning, NSView(), cancel, startButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false

        for view in [actions, scroll, hint, buttons] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - 动作

    private var selectedIndexes: [Int] {
        table.selectedRowIndexes.filter { rows.indices.contains($0) }
    }

    private func set(_ action: RebaseAction) {
        for index in selectedIndexes {
            rows[index].action = action
            if action == .pick || action == .drop || action == .edit || action == .fixup { rows[index].message = nil }
        }
        reloadKeepingSelection()
    }

    @objc private func setPick() { set(.pick) }
    @objc private func setEdit() { set(.edit) }
    @objc private func setFixup() { set(.fixup) }
    @objc private func setDrop() { set(.drop) }

    /// 改写：逐个询问新的提交信息。
    @objc private func setReword() {
        guard let index = selectedIndexes.first else { return }
        promptMessage(for: index, initial: rows[index].message ?? rows[index].commit.message) { [self] message in
            rows[index].action = .reword
            rows[index].message = message
            reloadKeepingSelection()
        }
    }

    /// 压缩：预填 “被并入的提交 + 本提交” 的信息，与 IDEA 一样可编辑合并后的信息。
    @objc private func setSquash() {
        guard let index = selectedIndexes.first else { return }
        let target = rows[(index + 1)...].first { $0.action != .drop && $0.action != .squash && $0.action != .fixup }
        let combined = [target?.message ?? target?.commit.message, rows[index].commit.message]
            .compactMap { $0 }.joined(separator: "\n\n")
        promptMessage(for: index, initial: combined) { [self] message in
            rows[index].action = .squash
            rows[index].message = message
            reloadKeepingSelection()
        }
    }

    @objc private func editMessageOfClicked() {
        let index = table.clickedRow
        guard rows.indices.contains(index), rows[index].action == .reword || rows[index].action == .squash else {
            return setReword()
        }
        promptMessage(for: index, initial: rows[index].message ?? rows[index].commit.message) { [self] message in
            rows[index].message = message
            reloadKeepingSelection()
        }
    }

    private func promptMessage(for index: Int, initial: String, completion: @escaping (String) -> Void) {
        let alert = AppAlert()
        alert.messageText = tr("rebase.message.title", String(rows[index].commit.hash.prefix(8)))
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as! NSTextView
        textView.string = initial
        textView.font = Theme.uiFont
        textView.isRichText = false
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView
        alert.addButton(withTitle: tr("editMessage.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        alert.beginSheetModal(for: panel) { response in
            let text = textView.string
            guard response == .alertFirstButtonReturn, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            completion(text)
        }
    }

    /// 上移 = 在列表中靠上 = 执行顺序更晚。
    @objc private func moveUp() { move(by: -1) }
    @objc private func moveDown() { move(by: 1) }

    private func move(by offset: Int) {
        let indexes = selectedIndexes
        guard !indexes.isEmpty else { return }
        let ordered = offset < 0 ? indexes.sorted() : indexes.sorted(by: >)
        guard let edge = ordered.first, rows.indices.contains(edge + offset) else { return }
        for index in ordered { rows.swapAt(index, index + offset) }
        table.reloadData()
        table.selectRowIndexes(IndexSet(indexes.map { $0 + offset }), byExtendingSelection: false)
        validate()
    }

    private func reloadKeepingSelection() {
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        validate()
    }

    /// 执行顺序中第一个保留下来的提交不能被压缩或修整（没有可并入的上一个提交）。
    private func validate() {
        let firstKept = rows.reversed().first { $0.action != .drop }
        let invalid = firstKept.map { $0.action == .squash || $0.action == .fixup } ?? false
        let allDropped = firstKept == nil
        warning.stringValue = invalid ? tr("rebase.invalid.firstSquash") : (allDropped ? tr("rebase.invalid.allDropped") : "")
        startButton.isEnabled = !invalid && !allDropped
    }

    @objc private func start() {
        let steps = rows.reversed().map { RebaseStep(hash: $0.commit.hash, action: $0.action, message: $0.message) }
        close()
        completion?(steps)
    }

    @objc private func cancel() { close() }

    private func close() {
        if let parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        retainSelf = nil
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text: String
        var color = Theme.text
        var font = Theme.uiFont
        var strike = false
        switch tableColumn?.identifier.rawValue {
        case "action":
            text = Self.title(of: item.action)
            color = Self.color(of: item.action)
            font = Theme.font(ofSize: 12, weight: .semibold)
        case "hash":
            text = String(item.commit.hash.prefix(8))
            color = Theme.secondaryText
            font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        case "subject":
            text = item.message.map { $0.components(separatedBy: "\n").first ?? $0 } ?? item.commit.subject
            strike = item.action == .drop
            if item.message != nil { color = Theme.accent }
        default:
            text = item.commit.authorName
            color = Theme.secondaryText
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let label = NSTextField.label("")
        label.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
        let cell = NSTableCellView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func title(of action: RebaseAction) -> String {
        switch action {
        case .pick: tr("rebase.action.pick")
        case .reword: tr("rebase.action.reword")
        case .edit: tr("rebase.action.edit")
        case .squash: tr("rebase.action.squash")
        case .fixup: tr("rebase.action.fixup")
        case .drop: tr("rebase.action.drop")
        }
    }

    private static func color(of action: RebaseAction) -> NSColor {
        switch action {
        case .pick: Theme.secondaryText
        case .reword, .edit: Theme.FileStatus.modified
        case .squash, .fixup: Theme.FileStatus.added
        case .drop: Theme.FileStatus.conflict
        }
    }
}
