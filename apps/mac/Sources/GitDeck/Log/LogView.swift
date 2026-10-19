import AppKit
import GitDeckCore

/// Git 工具窗口的 Log 标签页：筛选栏 + 提交图表格 + 提交详情，布局对齐 IDEA。
final class LogView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    var onOpenFile: ((URL) -> Void)?
    /// 提交级操作（右键菜单）由项目窗口的 GitOperations 执行。
    weak var operations: GitOperations?
    /// 打开历史提交中某个文件的 Diff：提交哈希、第一个父提交、文件。
    var onShowCommitDiff: ((String, String?, ChangedFile) -> Void)?
    /// 多仓库：打开某个仓库中提交的文件 Diff（未设置时使用 `onShowCommitDiff`）。
    var onShowRepositoryCommitDiff: ((ProjectModel, String, String?, ChangedFile) -> Void)?
    /// 多仓库：取得某个仓库的操作对象（右键菜单作用于提交所在的仓库）。
    var operationsFor: ((ProjectModel) -> GitOperations)?

    /// 多仓库项目：Log 可以显示全部仓库（按时间合并、行首色条标识仓库）或只显示其中一个。
    var workspace: Workspace? {
        didSet {
            if let workspaceObserver { oldValue?.removeObserver(workspaceObserver) }
            workspaceObserver = workspace?.observe { [weak self] in self?.workspaceChanged() }
            workspaceChanged()
        }
    }

    private var workspaceObserver: UUID?
    private let repositoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 显示全部仓库的提交。
    private var showsAll = false
    /// 与 `commits` 一一对应的所属仓库。
    private var owners: [ProjectModel] = []
    var onShowHistory: ((String) -> Void)? {
        didSet { details.onShowHistory = onShowHistory }
    }

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

    /// 当前显示的仓库（显示全部仓库时为主仓库，用于分支筛选等）。
    private var model: ProjectModel
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
    /// 等待加载完成后要选中的提交（例如从 Annotate 跳转过来）。
    private var pendingReveal: String?
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
            self.onOpenFile?(self.selectedOwner.rootURL.appendingPathComponent(path))
        }
        details.onShowDiff = { [weak self] commit, file in
            guard let self else { return }
            let owner = self.selectedOwner
            if let open = self.onShowRepositoryCommitDiff, owner !== self.workspace?.primary {
                open(owner, commit.hash, commit.parents.first, file)
            } else {
                self.onShowCommitDiff?(commit.hash, commit.parents.first, file)
            }
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

        repositoryPopup.bezelStyle = .inline
        repositoryPopup.controlSize = .small
        repositoryPopup.font = Theme.smallFont
        repositoryPopup.target = self
        repositoryPopup.action = #selector(repositoryChanged)
        repositoryPopup.isHidden = true
        let filterBar = NSStackView(views: [search, repositoryPopup, branchPopup, userPopup, datePopup, refresh, NSView(), statusLabel])
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
        table.allowsMultipleSelection = true
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
        let items: [(String, Selector)?] = [
            ("log.menu.copyHash", #selector(copyHash)),
            nil,
            ("log.menu.checkout", #selector(checkoutRevision)),
            ("log.menu.newBranch", #selector(newBranchHere)),
            ("log.menu.newTag", #selector(newTagHere)),
            nil,
            ("log.menu.createPatch", #selector(createPatchSelected)),
            ("log.menu.aiReview", #selector(aiReviewSelected)),
            nil,
            ("log.menu.cherryPick", #selector(cherryPickSelected)),
            ("log.menu.revert", #selector(revertSelected)),
            ("log.menu.reset", #selector(resetHere)),
            nil,
            ("log.menu.undoCommit", #selector(undoCommit)),
            ("log.menu.editMessage", #selector(editMessage)),
            ("log.menu.drop", #selector(dropSelected)),
            ("log.menu.interactiveRebase", #selector(interactiveRebaseHere)),
        ]
        for item in items {
            guard let (key, action) = item else {
                menu.addItem(.separator())
                continue
            }
            menu.addItem(withTitle: tr(key), action: action, keyEquivalent: "").target = self
        }
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
        if let workspace { workspace.refreshAll() } else { model.refresh() }
        reload()
    }

    // MARK: - 仓库

    /// 仓库列表变化时重建仓库筛选；任一仓库的引用变化时重新加载。
    private func workspaceChanged() {
        guard let workspace else { return }
        repositoryPopup.isHidden = !workspace.isMultiRoot
        if workspace.isMultiRoot {
            let titles = [tr("log.filter.repo.all")] + workspace.models.map { workspace.displayName(of: $0) }
            if repositoryPopup.itemTitles != titles {
                repositoryPopup.removeAllItems()
                repositoryPopup.addItem(withTitle: titles[0])
                repositoryPopup.menu?.addItem(.separator())
                for repository in workspace.models {
                    let item = NSMenuItem(title: workspace.displayName(of: repository), action: nil, keyEquivalent: "")
                    item.image = RepositoryBranchesPopover.chip(workspace.color(for: repository))
                    repositoryPopup.menu?.addItem(item)
                }
                selectRepositoryItem()
            }
        } else if showsAll {
            showsAll = false
            model = workspace.primary
        }
        modelChanged()
    }

    private func selectRepositoryItem() {
        guard let workspace else { return }
        if showsAll {
            repositoryPopup.selectItem(at: 0)
        } else if let index = workspace.models.firstIndex(where: { $0 === model }) {
            repositoryPopup.selectItem(at: index + 2)
        }
    }

    @objc private func repositoryChanged() {
        guard let workspace else { return }
        let index = repositoryPopup.indexOfSelectedItem
        showsAll = index == 0
        if index >= 2, workspace.models.indices.contains(index - 2) {
            model = workspace.models[index - 2]
        } else {
            model = workspace.primary
        }
        lastSignature = nil
        maxCount = Self.pageSize
        modelChanged()
    }

    #if DEBUG
    func debugShowAll() {
        repositoryPopup.selectItem(at: 0)
        repositoryChanged()
    }
    #endif

    /// 显示全部仓库（多仓库项目中选择 “所有仓库”）。
    private var isCombined: Bool { showsAll && (workspace?.isMultiRoot ?? false) }

    /// 某行提交所属的仓库。
    private func owner(_ row: Int) -> ProjectModel {
        owners.indices.contains(row) ? owners[row] : model
    }

    /// 提交所在仓库的操作对象。
    private func operations(for repository: ProjectModel) -> GitOperations? {
        operationsFor?(repository) ?? operations
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
        let repositories = isCombined ? workspace?.models ?? [model] : [model]
        guard !repositories.contains(where: \.isRefreshing) else { return }
        let signature = (isCombined ? "all\n" : "") + repositories.map(\.refsSignature).joined(separator: "\u{1e}")
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
        let sources: [ProjectModel] = isCombined ? workspace?.models ?? [model] : [model]
        let repositories = sources.map(\.repository)
        let combined = isCombined
        isLoading = true
        statusLabel.stringValue = tr("log.loading")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[(Int, LogPage)], any Error> in
                if !combined {
                    return Result { [(0, try repositories[0].log(filter: filter))] }
                }
                // 合并显示：分支筛选只对含有该分支的仓库生效，其他仓库跳过。
                let pages = repositories.enumerated().compactMap { index, repository in
                    (try? repository.log(filter: filter)).map { (index, $0) }
                }
                return .success(pages)
            }.value
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result.map({ pages in self.merge(pages, sources: sources, limit: Int(filter.maxCount)) }) {
            case let .success(page):
                let selectedHash = self.selectedCommit?.hash
                self.commits = page.commits
                self.owners = page.owners
                self.hasMore = page.hasMore
                if !filtered { self.collectAuthors() }
                self.table.reloadData()
                // 保持原有选中；首次加载时选中 HEAD 所在提交（与 IDEA 一致）。
                let target = self.pendingReveal ?? selectedHash ?? (self.hasLoaded ? nil : self.model.status.branch.oid)
                self.pendingReveal = nil
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
                self.owners = []
                self.table.reloadData()
                self.statusLabel.stringValue = errorMessage(error)
            }
        }
    }

    /// 合并各仓库的日志：按提交时间从新到旧排列，提交图改为单个节点（不同仓库的分支线无法画在同一张图中）。
    private func merge(_ pages: [(Int, LogPage)], sources: [ProjectModel], limit: Int) -> (commits: [LogCommit], owners: [ProjectModel], hasMore: Bool) {
        guard isCombined else {
            let page = pages.first?.1
            return (page?.commits ?? [], Array(repeating: model, count: page?.commits.count ?? 0), page?.hasMore ?? false)
        }
        var rows: [(LogCommit, ProjectModel)] = []
        for (index, page) in pages {
            for var commit in page.commits {
                commit.graph = GraphRow(lane: 0, color: 0, edges: [], width: 1)
                rows.append((commit, sources[index]))
            }
        }
        rows.sort { $0.0.committerTime > $1.0.committerTime }
        let hasMore = pages.contains { $0.1.hasMore } || rows.count > limit
        rows = Array(rows.prefix(limit))
        return (rows.map(\.0), rows.map(\.1), hasMore)
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

    /// 选中提交所在的仓库。
    private var selectedOwner: ProjectModel { owner(table.selectedRow) }

    private func loadDetails() {
        detailsGeneration += 1
        let generation = detailsGeneration
        guard let hash = selectedCommit?.hash else {
            details.show(nil)
            return
        }
        let repository = selectedOwner.repository
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

    /// 选中并滚动到某个提交；当前筛选条件下不可见时清空筛选后重新加载。
    func reveal(_ hash: String) {
        if let row = commits.firstIndex(where: { $0.hash == hash }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return
        }
        search.stringValue = ""
        branchPopup.selectItem(at: 0)
        userPopup.selectItem(at: 0)
        datePopup.selectItem(at: 0)
        pendingReveal = hash
        maxCount = Self.pageSize
        reload()
    }

    /// 右键菜单作用的提交：点击行在选区内时为整个选区，否则只有点击的行；按列表顺序（从新到旧）。
    private var targetCommits: [LogCommit] {
        let clicked = table.clickedRow
        let rows = clicked >= 0 && !table.selectedRowIndexes.contains(clicked)
            ? IndexSet(integer: clicked)
            : table.selectedRowIndexes
        return rows.sorted().compactMap { commits.indices.contains($0) ? commits[$0] : nil }
    }

    private var targetCommit: LogCommit? {
        let targets = targetCommits
        return targets.count == 1 ? targets[0] : nil
    }

    /// 右键菜单作用的提交所在的仓库；跨多个仓库时为 `nil`（只允许复制哈希）。
    private var targetOwner: ProjectModel? {
        let clicked = table.clickedRow
        let rows = clicked >= 0 && !table.selectedRowIndexes.contains(clicked)
            ? IndexSet(integer: clicked)
            : table.selectedRowIndexes
        let repositories = rows.map(owner)
        guard let first = repositories.first else { return model }
        return repositories.allSatisfy { $0 === first } ? first : nil
    }

    /// 目标提交所在仓库的操作对象。
    private var targetOperations: GitOperations? {
        targetOwner.flatMap(operations(for:))
    }

    /// 提交是否在所在仓库的当前分支上（只有这些提交可以改写信息、删除或从此处交互式变基）。
    private func isOnCurrentBranch(_ commit: LogCommit) -> Bool {
        (targetOwner ?? model).repository.isAncestor(ancestor: commit.hash, descendant: "HEAD")
    }

    @objc private func copyHash() {
        let hashes = targetCommits.map(\.hash)
        guard !hashes.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hashes.joined(separator: "\n"), forType: .string)
    }

    @objc private func checkoutRevision() {
        guard let commit = targetCommit else { return }
        targetOperations?.checkout(.revision(commit.hash))
    }

    @objc private func newBranchHere() {
        guard let commit = targetCommit else { return }
        targetOperations?.newBranch(from: commit.hash)
    }

    @objc private func newTagHere() {
        guard let commit = targetCommit else { return }
        targetOperations?.newTag(at: commit.hash)
    }

    /// 补丁按从旧到新排列。
    @objc private func createPatchSelected() {
        targetOperations?.createPatch(commits: targetCommits.reversed().map(\.hash))
    }

    /// AI 评审选中的提交（按从旧到新传入）。
    @objc private func aiReviewSelected() {
        let targets = targetCommits
        guard !targets.isEmpty else { return }
        targetOperations?.aiReview?.reviewCommits(targets.reversed().map(\.hash), subject: targets.count == 1 ? targets[0].subject : nil, in: targetOwner)
    }

    /// 拣选按从旧到新应用。
    @objc private func cherryPickSelected() {
        targetOperations?.cherryPick(targetCommits.reversed().map(\.hash))
    }

    /// 还原按从新到旧进行，与 IDEA 一致。
    @objc private func revertSelected() {
        targetOperations?.revert(targetCommits.map(\.hash))
    }

    @objc private func resetHere() {
        guard let commit = targetCommit else { return }
        targetOperations?.resetDialog(to: commit.hash, subject: commit.subject)
    }

    @objc private func undoCommit() {
        guard let commit = targetCommit else { return }
        targetOperations?.undoCommit(commit.hash)
    }

    @objc private func editMessage() {
        guard let commit = targetCommit, let owner = targetOwner else { return }
        let repository = owner.repository
        let ops = operations(for: owner)
        Task {
            let message = await Task.detached { (try? repository.commitDetails(hash: commit.hash))?.message }.value
            ops?.editMessage(commit.hash, current: message ?? commit.subject)
        }
    }

    @objc private func dropSelected() {
        targetOperations?.dropCommits(targetCommits.map(\.hash))
    }

    @objc private func interactiveRebaseHere() {
        guard let commit = targetCommit else { return }
        targetOperations?.interactiveRebase(from: commit.hash)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let targets = targetCommits
        if menuItem.action == #selector(copyHash) { return !targets.isEmpty }
        // 选中的提交跨多个仓库时只能复制哈希。
        guard let ops = targetOperations, !ops.isRunning else { return false }
        switch menuItem.action {
        case #selector(copyHash), #selector(cherryPickSelected), #selector(revertSelected), #selector(createPatchSelected):
            return !targets.isEmpty
        case #selector(aiReviewSelected):
            return !targets.isEmpty && ops.aiReview?.isRunning == false
        case #selector(checkoutRevision), #selector(newBranchHere), #selector(newTagHere), #selector(resetHere):
            return targets.count == 1
        case #selector(undoCommit):
            // 与 IDEA 一致：只能撤销当前分支的最新提交。
            return targetCommit?.hash == (targetOwner ?? model).status.branch.oid
        case #selector(editMessage), #selector(interactiveRebaseHere):
            return targetCommit.map(isOnCurrentBranch) ?? false
        case #selector(dropSelected):
            return !targets.isEmpty && targets.allSatisfy(isOnCurrentBranch)
        default:
            return true
        }
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
            let repository = owner(row)
            cell.isHead = commit.hash == repository.status.branch.oid
            cell.stripeColor = isCombined ? workspace?.color(for: repository) : nil
            cell.commit = commit
            if isCombined, let workspace {
                cell.toolTip = "\(workspace.displayName(of: repository)) — \(commit.subject)"
                return cell
            }
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
