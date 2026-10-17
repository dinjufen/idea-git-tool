import AppKit
import GitDeckCore

/// Log 右侧的提交详情：上方为改动文件列表，下方为提交信息、作者、哈希与所在分支。
final class CommitDetailsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenFile: ((String) -> Void)?

    private let filesTable = NSTableView()
    private let messageView = NSTextView()
    private let emptyLabel = NSTextField.label(tr("log.details.empty"), color: Theme.secondaryText)
    private var files: [ChangedFile] = []
    private var content = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let background = ColoredView(Theme.toolWindowBackground)
        addSubview(background)
        background.pinEdges(to: self)

        filesTable.addTableColumn(NSTableColumn(identifier: .init("file")))
        filesTable.headerView = nil
        filesTable.rowHeight = 22
        filesTable.style = .plain
        filesTable.backgroundColor = .clear
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.target = self
        filesTable.doubleAction = #selector(openFile)
        filesTable.setAccessibilityLabel(tr("log.details.files"))
        let filesScroll = NSScrollView()
        filesScroll.documentView = filesTable
        filesScroll.hasVerticalScroller = true
        filesScroll.drawsBackground = false
        filesScroll.translatesAutoresizingMaskIntoConstraints = false

        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.drawsBackground = false
        messageView.textContainerInset = NSSize(width: 10, height: 8)
        messageView.autoresizingMask = [.width]
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.drawsBackground = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false

        let divider = SeparatorLine(.horizontal)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [filesScroll, divider, messageScroll] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            filesScroll.topAnchor.constraint(equalTo: content.topAnchor),
            filesScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filesScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filesScroll.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.45),
            divider.topAnchor.constraint(equalTo: filesScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            messageScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            messageScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        addSubview(content)
        addSubview(emptyLabel)
        content.pinEdges(to: self)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 显示提交详情；`nil` 显示空状态。`branches` 为包含该提交的分支，加载完成前为 `nil`。
    func show(_ details: CommitDetails?, branches: [String]? = nil) {
        content.isHidden = details == nil
        emptyLabel.isHidden = details != nil
        files = details?.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } ?? []
        filesTable.reloadData()
        messageView.textStorage?.setAttributedString(details.map { format($0, branches: branches) } ?? NSAttributedString())
    }

    private func format(_ d: CommitDetails, branches: [String]?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: Theme.uiFont, .foregroundColor: Theme.text]
        let secondary: [NSAttributedString.Key: Any] = [.font: Theme.smallFont, .foregroundColor: Theme.secondaryText]

        let lines = d.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = lines.first.map(String.init) ?? ""
        result.append(NSAttributedString(string: subject + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text,
        ]))
        if lines.count > 1 {
            let rest = lines[1].trimmingCharacters(in: .newlines)
            if !rest.isEmpty { result.append(NSAttributedString(string: "\n" + rest + "\n", attributes: body)) }
        }
        result.append(NSAttributedString(string: "\n", attributes: body))

        let author = tr("log.details.author", String(d.hash.prefix(8)), d.authorName, d.authorEmail, LogDateFormatter.detailed(d.authorTime))
        result.append(NSAttributedString(string: author + "\n", attributes: secondary))
        if d.committerName != d.authorName || d.committerTime != d.authorTime {
            let committer = tr("log.details.committer", d.committerName, LogDateFormatter.detailed(d.committerTime))
            result.append(NSAttributedString(string: committer + "\n", attributes: secondary))
        }
        if let branches {
            let list = branches.prefix(10).joined(separator: ", ")
            let text = switch branches.count {
            case 0: tr("log.details.noBranches")
            case 1: tr("log.details.oneBranch", list)
            default: tr("log.details.branches", "\(branches.count)", list)
            }
            result.append(NSAttributedString(string: text + "\n", attributes: secondary))
        }
        return result
    }

    @objc private func openFile() {
        let row = filesTable.clickedRow
        guard files.indices.contains(row), files[row].kind != .deleted else { return }
        onOpenFile?(files[row].path)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let id = NSUserInterfaceItemIdentifier("ChangedFile")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileCellView ?? FileCellView(identifier: id)
        let name = (file.path as NSString).lastPathComponent
        var detail = (file.path as NSString).deletingLastPathComponent
        if let orig = file.origPath { detail = tr("commit.renamedFrom", orig) }
        cell.configure(
            icon: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)),
            name: name,
            detail: detail,
            color: file.kind.statusColor,
            strikethrough: file.kind == .deleted
        )
        return cell
    }
}

extension ChangeKind {
    /// 历史提交中文件改动的颜色，与本地变更使用相同的 File Status Colors。
    var statusColor: NSColor {
        switch self {
        case .added, .copied: Theme.FileStatus.added
        case .deleted: Theme.FileStatus.deleted
        case .renamed: Theme.FileStatus.renamed
        default: Theme.FileStatus.modified
        }
    }
}
