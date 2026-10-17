import AppKit
import GitDeckCore

/// Git 工具窗口的 Log 标签页：筛选栏 + 提交图表格 + 提交详情，布局对齐 IDEA。
final class LogView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    var onOpenFile: ((URL) -> Void)?

    private enum Column: String {
        case subject, author, date
    }

    /// Date 筛选的预设范围（秒）。
    private static let dateRanges: [(key: String, seconds: Int64?)] = [
        ("log.filter.date.all", nil),
        ("log.filter.date.day", 86_400),
        ("log.filter.date.week", 7 * 86_400),
        ("log.filter.date.month", 30 * 86_400),
        ("log.filter.date.year", 365 * 86_400),
    ]

    private static let pageSize: UInt32 = 2000

    private let model: ProjectModel
    private let search = NSSearchField()
    private let branchPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let userPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let details = CommitDetailsView()
    private let statusLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)

    private var commits: [LogCommit] = []
    private var hasMore = false
    private var maxCount = LogView.pageSize
    private var isLoading = false
    private var hasLoaded = false
    private var loadGeneration = 0
    private var detailsGeneration = 0
    private var lastSignature: String?
    private var knownAuthors: [String] = []
    private var searchDebounce: Task<Void, Never>?
    private var observer: UUID?

    init(model: ProjectModel) {
        self.model = model
        super.init(frame: .zero)
        buildLayout()
        details.onOpenFile = { [weak self] path in
            guard let self else { return }
            self.onOpenFile?(self.model.rootURL.appendingPathComponent(path))
        }
        observer = model.observe { [weak self] in self?.modelChanged() }
        modelChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    private func buildLayout() {
        search.placeholderString = tr("log.filter.search")
        search.delegate = self
        search.sendsWholeSearchString = false
        search.translatesAutoresizingMaskIntoConstraints = false

        for popup in [branchPopup, userPopup, datePopup] {
            popup.bezelStyle = .inline
            popup.controlSize = .small
            popup.font = Theme.smallFont
            popup.target = self
            popup.action = #selector(filterChanged)
        }
        for range in Self.dateRanges {
            datePopup.addItem(withTitle: tr(range.key))
        }
        rebuildBranchPopup()
        rebuildUserPopup()

        let refresh = IconButton(symbol: "arrow.clockwise", tooltip: tr("git.action.refresh"), size: 24, pointSize: 12)
        refresh.target = self
        refresh.action = #selector(refreshClicked)

        let filterBar = NSStackView(views: [search, branchPopup, userPopup, datePopup, refresh, NSView(), statusLabel])
        filterBar.spacing = 6
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        for (column, title, width) in [(Column.subject, "", 400.0), (.author, "", 150.0), (.date, "", 150.0)] {
            let col = NSTableColumn(identifier: .init(column.rawValue))
            col.title = title
            col.width = width
            col.minWidth = column == .subject ? 200 : 80
            col.resizingMask = column == .subject ? .autoresizingMask : .userResizingMask
            table.addTableColumn(col)
        }
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = Theme.editorBackground
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.menu = contextMenu()
        table.setAccessibilityLabel(tr("git.tab.log"))
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(details)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        details.translatesAutoresizingMaskIntoConstraints = false

        let divider = SeparatorLine(.horizontal)
        for view in [filterBar, divider, split] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            filterBar.heightAnchor.constraint(equalToConstant: 28),
            search.widthAnchor.constraint(equalToConstant: 200),
            divider.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: divider.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            details.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            details.widthAnchor.constraint(equalToConstant: 360).withPriority(.defaultLow),
        ])
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("log.menu.copyHash"), action: #selector(copyHash), keyEquivalent: "").target = self
        menu.addItem(.separator())
        // 以下操作在二期实现。
        for key in ["log.menu.checkout", "log.menu.newBranch", "log.menu.newTag", "-",
                    "log.menu.cherryPick", "log.menu.revert", "log.menu.reset", "-",
                    "log.menu.undoCommit", "log.menu.editMessage"] {
            if key == "-" {
                menu.addItem(.separator())
            } else {
                let item = NSMenuItem(title: tr(key), action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip = tr("common.notImplemented")
                menu.addItem(item)
            }
        }
        menu.autoenablesItems = false
        return menu
    }

    // MARK: - 筛选

    private func rebuildBranchPopup() {
        let selected = branchPopup.selectedItem?.representedObject as? String
        branchPopup.removeAllItems()
        branchPopup.addItem(withTitle: tr("log.filter.branch.all"))
        let groups: [(BranchKind, String)] = [(.local, tr("branches.section.local")), (.remote, tr("branches.section.remote"))]
        for (kind, title) in groups {
            let branches = model.branches.filter { $0.kind == kind }
            guard !branches.isEmpty else { continue }
            branchPopup.menu?.addItem(.separator())
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            branchPopup.menu?.addItem(header)
            for branch in branches {
                let item = NSMenuItem(title: tr("log.filter.branch.value", branch.name), action: nil, keyEquivalent: "")
                item.representedObject = branch.fullRef
                branchPopup.menu?.addItem(item)
            }
        }
        if let selected, let item = branchPopup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            branchPopup.select(item)
        } else {
            branchPopup.selectItem(at: 0)
        }
    }

    private func rebuildUserPopup() {
        let selected = userPopup.selectedItem?.representedObject as? String
        userPopup.removeAllItems()
        userPopup.addItem(withTitle: tr("log.filter.user.all"))
        if !knownAuthors.isEmpty { userPopup.menu?.addItem(.separator()) }
        for author in knownAuthors {
            let item = NSMenuItem(title: tr("log.filter.user.value", author), action: nil, keyEquivalent: "")
            item.representedObject = author
            userPopup.menu?.addItem(item)
        }
        if let selected, let item = userPopup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            userPopup.select(item)
        } else {
            userPopup.selectItem(at: 0)
        }
    }

    private var currentFilter: LogFilter {
        let text = search.stringValue.trimmingCharacters(in: .whitespaces)
        let range = Self.dateRanges[max(0, datePopup.indexOfSelectedItem)].seconds
        return LogFilter(
            revisions: (branchPopup.selectedItem?.representedObject as? String).map { [$0] } ?? [],
            authors: (userPopup.selectedItem?.representedObject as? String).map { [$0] } ?? [],
            since: range.map { Int64(Date().timeIntervalSince1970) - $0 },
            until: nil,
            paths: [],
            text: text.isEmpty ? nil : text,
            order: .topological,
            maxCount: maxCount
        )
    }

    private var isFiltered: Bool {
        let f = currentFilter
        return !f.revisions.isEmpty || !f.authors.isEmpty || f.since != nil || f.text != nil
    }

    @objc private func filterChanged() {
        maxCount = Self.pageSize
        reload()
    }

    @objc private func refreshClicked() {
        model.refresh()
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        // 输入停顿后再查询，避免每个按键都触发 git log。
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.filterChanged()
        }
    }

    // MARK: - 加载

    private func modelChanged() {
        guard !model.isRefreshing else { return }
        let signature = model.refsSignature
        guard signature != lastSignature else { return }
        lastSignature = signature
        rebuildBranchPopup()
        reload()
    }

    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let filter = currentFilter
        let filtered = isFiltered
        let repository = model.repository
        isLoading = true
        statusLabel.stringValue = tr("log.loading")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.log(filter: filter) }
            }.value
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case let .success(page):
                let selectedHash = self.selectedCommit?.hash
                self.commits = page.commits
                self.hasMore = page.hasMore
                if !filtered { self.collectAuthors() }
                self.table.reloadData()
                // 保持原有选中；首次加载时选中 HEAD 所在提交（与 IDEA 一致）。
                let target = selectedHash ?? (self.hasLoaded ? nil : self.model.status.branch.oid)
                self.hasLoaded = true
                if let target, let row = self.commits.firstIndex(where: { $0.hash == target }) {
                    self.table.selectRowIndexes([row], byExtendingSelection: false)
                    self.table.scrollRowToVisible(row)
                } else {
                    self.details.show(nil)
                }
                self.statusLabel.stringValue = page.hasMore
                    ? tr("log.count.more", "\(page.commits.count)")
                    : tr("log.count", "\(page.commits.count)")
            case let .failure(error):
                self.commits = []
                self.table.reloadData()
                self.statusLabel.stringValue = errorMessage(error)
            }
        }
    }

    /// 从未筛选的结果中收集作者，按提交数排序，供 User 筛选使用。
    private func collectAuthors() {
        var counts: [String: Int] = [:]
        for commit in commits { counts[commit.authorName, default: 0] += 1 }
        knownAuthors = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(50).map(\.key)
        rebuildUserPopup()
    }

    private func loadMoreIfNeeded(row: Int) {
        guard hasMore, !isLoading, row >= commits.count - 50 else { return }
        maxCount += Self.pageSize
        reload()
    }

    private var selectedCommit: LogCommit? {
        commits.indices.contains(table.selectedRow) ? commits[table.selectedRow] : nil
    }

    private func loadDetails() {
        detailsGeneration += 1
        let generation = detailsGeneration
        guard let hash = selectedCommit?.hash else {
            details.show(nil)
            return
        }
        let repository = model.repository
        Task {
            let result = await Task.detached { Result { try repository.commitDetails(hash: hash) } }.value
            guard generation == self.detailsGeneration, case let .success(commit) = result else { return }
            self.details.show(commit)
            // 查询所在分支较慢，详情先显示，分支信息随后补上。
            let branches = await Task.detached { try? repository.branchesContaining(hash: hash) }.value
            guard generation == self.detailsGeneration, let branches else { return }
            self.details.show(commit, branches: branches)
        }
    }

    @objc private func copyHash() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard commits.indices.contains(row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commits[row].hash, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(copyHash) || table.clickedRow >= 0 || table.selectedRow >= 0
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadDetails()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        loadMoreIfNeeded(row: row)
        let commit = commits[row]
        switch Column(rawValue: tableColumn?.identifier.rawValue ?? "") {
        case .subject:
            let id = NSUserInterfaceItemIdentifier("LogSubject")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? LogSubjectCellView ?? {
                let v = LogSubjectCellView()
                v.identifier = id
                return v
            }()
            cell.isHead = commit.hash == model.status.branch.oid
            cell.commit = commit
            cell.toolTip = commit.subject
            return cell
        case .author:
            return textCell(commit.authorName, id: "LogAuthor", tooltip: "\(commit.authorName) <\(commit.authorEmail)>")
        case .date:
            return textCell(LogDateFormatter.short(commit.authorTime), id: "LogDate", tooltip: LogDateFormatter.detailed(commit.authorTime))
        case nil:
            return nil
        }
    }

    private func textCell(_ text: String, id: String, tooltip: String) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField.label("", color: Theme.secondaryText)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = text
        cell.toolTip = tooltip
        return cell
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
