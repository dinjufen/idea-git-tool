import AppKit
import GitDeckCore

/// 文件历史（IDEA 的 “Show History”）：左侧为该文件的修订列表（跟踪重命名），右侧为所选修订相对父提交的 Diff。
final class FileHistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// 在编辑器中打开某个修订的完整 Diff：提交哈希、第一个父提交、文件。
    var onOpenDiff: ((String, String?, ChangedFile) -> Void)?

    let path: String
    private let model: ProjectModel
    private let table = NSTableView()
    private let preview = NSView()
    private let statusLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private var revisions: [FileRevision] = []
    private var previewTask: Task<Void, Never>?

    init(model: ProjectModel, path: String) {
        self.model = model
        self.path = path
        super.init(frame: .zero)
        buildLayout()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        // 列顺序与 IDEA 文件历史一致：修订、日期、作者、提交信息（最后一列吸收剩余宽度）。
        for (id, width) in [("hash", 76.0), ("date", 120.0), ("author", 100.0), ("subject", 200.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            column.resizingMask = id == "subject" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = Theme.editorBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openDiff)
        table.setAccessibilityLabel(tr("history.accessibility", path))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let left = NSView()
        let title = NSTextField.label(path, font: .systemFont(ofSize: 12, weight: .semibold))
        for view in [title, scroll, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: left.topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(preview)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        addSubview(split)
        split.pinEdges(to: self)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }

    func load() {
        statusLabel.stringValue = tr("log.loading")
        let repository = model.repository
        let path = path
        Task {
            let result = await Task.detached { Result { try repository.fileHistory(path: path, maxCount: 0) } }.value
            switch result {
            case let .success(revisions):
                self.revisions = revisions
                table.reloadData()
                statusLabel.stringValue = revisions.count == 1 ? tr("history.count.one") : tr("history.count", "\(revisions.count)")
                if !revisions.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            case let .failure(error):
                statusLabel.stringValue = errorMessage(error)
            }
        }
    }

    private var selected: FileRevision? {
        revisions.indices.contains(table.selectedRow) ? revisions[table.selectedRow] : nil
    }

    /// 在右侧显示所选修订相对第一个父提交的 Diff。
    private func showPreview() {
        previewTask?.cancel()
        preview.subviews.forEach { $0.removeFromSuperview() }
        guard let revision = selected else { return }
        let repository = model.repository
        let basePath = revision.origPath ?? revision.path
        let parent = revision.parents.first
        previewTask = Task {
            let (base, text) = await Task.detached {
                let base = revision.kind == .added ? nil : parent.flatMap { try? repository.fileAtRevision(revision: $0, path: basePath) }
                let text = revision.kind == .deleted ? nil : try? repository.fileAtRevision(revision: revision.hash, path: revision.path)
                return (base ?? nil, text ?? nil)
            }.value
            guard !Task.isCancelled else { return }
            let diff = DiffView(
                left: DiffSide(title: parent.map { String($0.prefix(8)) } ?? tr("diff.title.empty"), text: base),
                right: DiffSide(title: String(revision.hash.prefix(8)), text: text),
                path: revision.path
            )
            preview.addSubview(diff)
            diff.pinEdges(to: preview)
        }
    }

    @objc private func openDiff() {
        guard let revision = revisions.indices.contains(table.clickedRow) ? revisions[table.clickedRow] : nil else { return }
        onOpenDiff?(
            revision.hash,
            revision.parents.first,
            ChangedFile(path: revision.path, origPath: revision.origPath, kind: revision.kind)
        )
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { revisions.count }

    func tableViewSelectionDidChange(_ notification: Notification) { showPreview() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let revision = revisions[row]
        let text: String
        var color = Theme.secondaryText
        var tooltip: String?
        switch tableColumn?.identifier.rawValue {
        case "hash":
            text = String(revision.hash.prefix(8))
        case "subject":
            text = revision.subject
            color = Theme.text
            if revision.kind == .renamed, let orig = revision.origPath { tooltip = tr("commit.renamedFrom", orig) }
        case "author":
            text = revision.authorName
            tooltip = "\(revision.authorName) <\(revision.authorEmail)>"
        default:
            text = LogDateFormatter.short(revision.authorTime)
            tooltip = LogDateFormatter.detailed(revision.authorTime)
        }
        let label = NSTextField.label(text, color: color)
        if tableColumn?.identifier.rawValue == "hash" {
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        let cell = NSTableCellView()
        cell.toolTip = tooltip
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
