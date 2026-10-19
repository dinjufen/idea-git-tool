import AppKit
import GitDeckCore

/// 默认 Changelist 的存储名称（显示时本地化为 “Changes”）。
private let DEFAULT_CHANGELIST = defaultChangelistName()

/// Commit 工具窗口（IDEA 非模态提交界面）：变更树 + 提交信息 + 提交按钮。
///
/// 多仓库项目中显示所有仓库的改动：每个 Changelist 下按仓库分组，提交时每个仓库各提交一次（同一提交信息）。
/// 条目以 “相对项目根目录的路径” 作为键（嵌套仓库中的文件带仓库路径前缀），在窗口内唯一。
final class CommitToolWindow: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// 按仓库分组的文件（仓库内的相对路径）。
    typealias RepositoryPaths = [(model: ProjectModel, paths: [String])]

    var onOpenFile: ((URL) -> Void)?
    /// 打开本地改动的 Diff；第三个参数为部分提交选择使用的键。
    var onShowDiff: ((ProjectModel, FileChange, String) -> Void)?
    /// “提交并推送” 成功提交后打开 Push 对话框。
    var onPushAfterCommit: (() -> Void)?
    /// 打开冲突文件的三栏合并。
    var onResolveConflict: ((ProjectModel, FileChange) -> Void)?
    /// 打开某个仓库的 Conflicts 对话框。
    var onShowConflicts: ((ProjectModel) -> Void)?
    var onShowHistory: ((ProjectModel, String) -> Void)?
    /// 储藏选中的文件（打开 Stash Changes 对话框）。
    var onStashPaths: ((RepositoryPaths) -> Void)?
    /// 把选中的改动保存为补丁。
    var onCreatePatch: ((RepositoryPaths) -> Void)?
    /// Rollback：选中的文件（为空时由对话框全选主仓库的改动）。
    var onRollback: ((RepositoryPaths) -> Void)?
    /// 搁置：文件与默认名称。
    var onShelve: ((RepositoryPaths, String) -> Void)?
    /// AI 评审：评审勾选的改动、生成提交信息、提交前检查。
    weak var aiReview: AIReviewController?

    /// 部分提交的行选择；文件只提交部分改动时复选框显示为半选。
    var lineSelections: LineSelectionStore? {
        didSet {
            if let selectionObserver { oldValue?.removeObserver(selectionObserver) }
            selectionObserver = lineSelections?.observe { [weak self] in
                self?.outline.reloadData()
                self?.updateCommitButtons()
            }
        }
    }

    private var selectionObserver: UUID?

    // “提交 / 储藏” 标签（IDEA New UI 的 Commit 工具窗口）。
    private let tabs = NSSegmentedControl(labels: [tr("commit.tab.commit"), tr("commit.tab.stash"), tr("commit.tab.shelf")], trackingMode: .selectOne, target: nil, action: nil)
    private var commitContent: [NSView] = []
    private var stashesView: StashesView?
    private var shelfView: ShelfView?
    /// 各仓库的 Changelist（从核心加载并与工作区同步）；多仓库时以主仓库的列表为准统一显示。
    private var changelistsByRepo: [ObjectIdentifier: Changelists] = [:]
    private var changelistTask: Task<Void, Never>?
    /// 最近一次从 Changelist 说明自动填入的提交信息。
    private var autoMessage: String?
    private var contentTop: NSLayoutYAxisAnchor?

    /// 一个改动：所属仓库、该仓库中的变更，以及在窗口内唯一的键。
    struct Entry {
        let model: ProjectModel
        let change: FileChange
        let key: String
    }

    /// 变更树的分组节点，顺序与 IDEA 一致。
    final class Group {
        enum Kind { case conflicts, changes, unversioned }
        let kind: Kind
        var files: [Entry] = []
        /// 多仓库时按仓库分出的子分组。
        var repositories: [RepositoryGroup] = []
        /// Changes 分组对应的 Changelist（每个列表一个分组）。
        var changelist: Changelist?
        var isActive = false
        init(_ kind: Kind, changelist: Changelist? = nil) {
            self.kind = kind
            self.changelist = changelist
        }

        var title: String {
            switch kind {
            case .conflicts: tr("commit.group.conflicts")
            case .changes:
                changelist.map { $0.name == DEFAULT_CHANGELIST ? tr("commit.group.changes") : $0.name } ?? tr("commit.group.changes")
            case .unversioned: tr("commit.group.unversioned")
            }
        }
    }

    /// 分组下按仓库的子分组（多仓库项目）。
    final class RepositoryGroup {
        let model: ProjectModel
        var files: [Entry] = []
        init(_ model: ProjectModel) { self.model = model }
    }

    /// 文件节点。用类包装以便 NSOutlineView 按引用识别条目。
    final class FileItem {
        let entry: Entry
        var change: FileChange { entry.change }
        init(_ entry: Entry) { self.entry = entry }
    }

    /// 主仓库。
    private let model: ProjectModel
    private let workspace: Workspace
    private let outline = NSOutlineView()
    private let messageView = PlaceholderTextView()
    private let amendCheckbox = NSButton(checkboxWithTitle: tr("commit.amend"), target: nil, action: nil)
    private let commitButton = NSButton(title: tr("commit.button.commit"), target: nil, action: nil)
    private let commitPushButton = NSButton(title: tr("commit.button.commitAndPush"), target: nil, action: nil)
    private let optionsButton = IconButton(symbol: "gearshape", tooltip: tr("commit.options"), size: 24, pointSize: 12)
    private let generateButton = IconButton(symbol: "sparkles", tooltip: tr("ai.message.generate"), size: 22, pointSize: 11)
    private let generateSpinner = NSProgressIndicator()
    private let spinner = NSProgressIndicator()

    private var groups: [Group] = []
    private var items: [String: FileItem] = [:]
    /// 当前所有改动（键 → 条目）。
    private var entries: [String: Entry] = [:]
    /// 勾选要提交的文件的键。
    private var included: Set<String> = []
    /// 已见过的路径；新出现的已跟踪变更默认勾选，未跟踪文件默认不勾选（与 IDEA 一致）。
    private var known: Set<String> = []
    private var observer: UUID?

    // 提交选项（IDEA 提交区齿轮菜单中的 Sign-off 与 Run Git hooks），在会话内保留。
    private var signOff = false
    private var runHooks = true
    private var isCommitting = false
    private var pushAfterCommit = false
    /// 勾选 Amend 时自动填入的上一次提交信息；取消勾选时若未被修改则清空。
    private var amendPrefill: String?

    init(workspace: Workspace) {
        self.workspace = workspace
        model = workspace.primary
        super.init(frame: .zero)
        buildLayout()
        observer = workspace.observe { [weak self] in self?.statusChanged() }
        statusChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 加入 “储藏” 标签的内容（依赖 GitOperations，由项目窗口创建后传入）。
    func attachStashes(_ view: StashesView) {
        guard let contentTop else { return }
        stashesView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentTop),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        tabChanged()
    }

    /// 加入 “搁置” 标签的内容。
    func attachShelf(_ view: ShelfView) {
        guard let contentTop else { return }
        shelfView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentTop),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        tabChanged()
    }

    func showShelfTab() {
        tabs.selectedSegment = 2
        tabChanged()
    }

    func showStashTab() {
        tabs.selectedSegment = 1
        tabChanged()
    }

    @objc private func tabChanged() {
        let tab = tabs.selectedSegment
        commitContent.forEach { $0.isHidden = tab != 0 }
        stashesView?.isHidden = tab != 1
        shelfView?.isHidden = tab != 2
    }

    func focusMessage() {
        tabs.selectedSegment = 0
        tabChanged()
        window?.makeFirstResponder(messageView)
    }

    // MARK: - 布局

    private func buildLayout() {
        let background = ColoredView(Theme.toolWindowBackground)
        addSubview(background)
        background.pinEdges(to: self)

        let header = ToolWindowHeader(title: "")
        tabs.segmentStyle = .texturedRounded
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            tabs.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        contentTop = header.bottomAnchor
        let toolbar = makeToolbar()

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
        // 与 IDEA 一致：双击打开 Diff，右键菜单可跳到源码。
        outline.doubleAction = #selector(showDiffForClicked)
        outline.allowsMultipleSelection = true
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityLabel(tr("commit.changes.accessibility"))

        let treeScroll = NSScrollView()
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.drawsBackground = false

        messageView.placeholder = tr("commit.message.placeholder")
        messageView.font = Theme.uiFont
        messageView.textColor = Theme.text
        messageView.backgroundColor = Theme.editorBackground
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.textContainerInset = NSSize(width: 6, height: 6)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.setAccessibilityLabel(tr("commit.message.placeholder"))
        messageView.onTextChange = { [weak self] in self?.updateCommitButtons() }
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .noBorder
        messageView.autoresizingMask = [.width]
        messageView.isVerticallyResizable = true
        messageView.textContainer?.widthTracksTextView = true
        // 提交信息框右上角的 “生成提交信息”（IDEA 的 AI Assistant 按钮位置）。
        generateButton.target = self
        generateButton.action = #selector(generateMessage)
        generateSpinner.style = .spinning
        generateSpinner.controlSize = .small
        generateSpinner.isDisplayedWhenStopped = false
        generateSpinner.translatesAutoresizingMaskIntoConstraints = false

        treeScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        let messageDivider = SeparatorLine(.horizontal)

        commitButton.bezelStyle = .push
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.toolTip = tr("commit.button.commit.tooltip")
        // 推送在后续步骤实现，届时“提交并推送”会在提交成功后打开 Push 对话框。
        commitPushButton.bezelStyle = .push
        commitPushButton.target = self
        commitPushButton.action = #selector(commitAndPush)
        amendCheckbox.target = self
        amendCheckbox.action = #selector(amendToggled)
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        // 面板较窄时优先截断“提交并推送”，保证主按钮完整显示。
        commitButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        amendCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        commitPushButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [commitButton, commitPushButton, spinner, NSView(), amendCheckbox, optionsButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        commitContent = [toolbar, treeScroll, messageDivider, messageScroll, buttons]
        for view in [header, toolbar, treeScroll, messageDivider, messageScroll, buttons, generateButton, generateSpinner] as [NSView] { addSubview(view) }
        commitContent += [generateButton, generateSpinner]
        // 变更树占满剩余空间，提交信息区固定高度（拖拽调整高度在后续 UI 打磨阶段加入）。
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            treeScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            treeScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            messageDivider.topAnchor.constraint(equalTo: treeScroll.bottomAnchor),
            messageDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: messageDivider.bottomAnchor),
            messageScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageScroll.heightAnchor.constraint(equalToConstant: 140),
            generateButton.topAnchor.constraint(equalTo: messageScroll.topAnchor, constant: 4),
            generateButton.trailingAnchor.constraint(equalTo: messageScroll.trailingAnchor, constant: -18),
            generateSpinner.centerXAnchor.constraint(equalTo: generateButton.centerXAnchor),
            generateSpinner.centerYAnchor.constraint(equalTo: generateButton.centerYAnchor),
            buttons.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func makeToolbar() -> NSStackView {
        func button(_ symbol: String, _ tooltip: String, _ action: Selector?) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 26, pointSize: 12)
            b.target = self
            b.action = action
            b.isEnabled = action != nil
            return b
        }
        let stack = NSStackView(views: [
            button("arrow.clockwise", tr("git.action.refresh"), #selector(refresh)),
            button("arrow.uturn.backward", tr("commit.action.rollback"), #selector(rollbackSelected)),
            button("plus.forwardslash.minus", tr("commit.action.showDiff"), #selector(showDiffForSelection)),
            button("tray.and.arrow.down", tr("commit.action.shelve"), #selector(shelveSelected)),
            button("sparkles", tr("ai.action.reviewSelected"), #selector(aiReviewSelected)),
            button("arrow.up.left.and.arrow.down.right", tr("tree.expandAll"), #selector(expandAll)),
            button("arrow.down.right.and.arrow.up.left", tr("tree.collapseAll"), #selector(collapseAll)),
        ])
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - 数据

    /// 条目的键：主仓库中为相对路径，其他仓库为 “仓库路径/文件路径”。
    private func key(_ model: ProjectModel, _ path: String) -> String {
        model === self.model ? path : workspace.displayName(of: model) + "/" + path
    }

    /// 主仓库中属于其他已加入仓库的未跟踪目录（嵌套仓库本身），不作为主仓库的改动显示。
    private func isNestedRepositoryPath(_ change: FileChange) -> Bool {
        guard change.isUntracked, workspace.isMultiRoot else { return false }
        let path = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
        return workspace.models.dropFirst().contains { other in
            let relative = workspace.displayName(of: other)
            return path == relative || relative.hasPrefix(path + "/") || path.hasPrefix(relative + "/")
        }
    }

    private func statusChanged() {
        guard !workspace.isRefreshing else { return }
        prefillMergeMessage()
        var all: [Entry] = []
        for repository in workspace.models {
            for change in repository.status.changes where !change.isIgnored {
                if repository === model, isNestedRepositoryPath(change) { continue }
                all.append(Entry(model: repository, change: change, key: key(repository, change.path)))
            }
        }
        entries = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // 与 IDEA 一致：新出现的已跟踪改动只在活动 Changelist 中默认勾选。
        let current = Set(entries.keys)
        let newKeys = Set(all.filter { !$0.change.isUntracked && $0.change.conflict == nil }.map(\.key)).subtracting(known)
        let inactive = Set(all.filter { changelistName(of: $0) != activeChangelist }.map(\.key))
        included.formUnion(newKeys.subtracting(inactive))
        included.formIntersection(current)
        known = current
        // 复用未变化的节点，使 NSOutlineView 保持选中状态。
        items = Dictionary(all.map { entry in
            (entry.key, items[entry.key].flatMap { $0.change == entry.change && $0.entry.model === entry.model ? $0 : nil } ?? FileItem(entry))
        }, uniquingKeysWith: { a, _ in a })
        rebuildGroups()
        loadChangelists()
    }

    // MARK: - Changelist（每个仓库各自保存，界面上统一显示）

    /// 统一显示的 Changelist：主仓库的列表顺序在前，其他仓库独有的列表追加在后。
    private var displayedChangelists: [Changelist] {
        var lists = changelistsByRepo[ObjectIdentifier(model)]?.lists ?? []
        for repository in workspace.models.dropFirst() {
            for list in changelistsByRepo[ObjectIdentifier(repository)]?.lists ?? [] where !lists.contains(where: { $0.name == list.name }) {
                lists.append(list)
            }
        }
        return lists.isEmpty ? [Changelist(name: DEFAULT_CHANGELIST, comment: "", paths: [])] : lists
    }

    private var activeChangelist: String {
        changelistsByRepo[ObjectIdentifier(model)]?.active ?? DEFAULT_CHANGELIST
    }

    /// 条目所在的 Changelist（未记录时为该仓库的活动列表）。
    private func changelistName(of entry: Entry) -> String {
        guard let state = changelistsByRepo[ObjectIdentifier(entry.model)] else { return activeChangelist }
        return state.lists.first { $0.paths.contains(entry.change.path) }?.name ?? state.active
    }

    /// 按 Changelist 分组：冲突、各 Changelist、未跟踪文件；多仓库时每组下再按仓库分组。
    private func rebuildGroups() {
        let expandedLists = Set(groups.filter { outline.isItemExpanded($0) }.compactMap { $0.changelist?.name })
        let firstBuild = groups.isEmpty
        let conflicts = Group(.conflicts)
        let unversioned = Group(.unversioned)
        let lists = displayedChangelists.map { list -> Group in
            let group = Group(.changes, changelist: list)
            group.isActive = list.name == activeChangelist
            return group
        }
        for entry in entries.values {
            if entry.change.conflict != nil {
                conflicts.files.append(entry)
            } else if entry.change.isUntracked {
                unversioned.files.append(entry)
            } else {
                let name = changelistName(of: entry)
                (lists.first { $0.changelist?.name == name } ?? lists.first)?.files.append(entry)
            }
        }
        let order = { (entry: Entry) in self.workspace.models.firstIndex { $0 === entry.model } ?? 0 }
        for group in [conflicts, unversioned] + lists {
            group.files.sort { lhs, rhs in
                order(lhs) != order(rhs) ? order(lhs) < order(rhs)
                    : lhs.change.path.localizedStandardCompare(rhs.change.path) == .orderedAscending
            }
            if workspace.isMultiRoot {
                group.repositories = workspace.models.compactMap { repository in
                    let files = group.files.filter { $0.model === repository }
                    guard !files.isEmpty else { return nil }
                    let child = RepositoryGroup(repository)
                    child.files = files
                    return child
                }
            }
        }

        // 冲突与未跟踪分组为空时隐藏；Changelist 分组始终显示。
        groups = ([conflicts] + lists + [unversioned]).filter { $0.kind == .changes || !$0.files.isEmpty }
        outline.reloadData()
        for group in groups where group.kind == .conflicts || (group.kind == .changes && (firstBuild || group.isActive || expandedLists.contains(group.changelist?.name ?? ""))) {
            outline.expandItem(group, expandChildren: true)
        }
        applyChangelistComment()
        updateCommitButtons()
    }

    /// 从核心加载各仓库的 Changelist（会与工作区同步并保存），完成后重新分组。
    private func loadChangelists() {
        let repositories = workspace.models.map { ($0, $0.repository) }
        changelistTask?.cancel()
        changelistTask = Task {
            var loaded: [ObjectIdentifier: Changelists] = [:]
            for (owner, repository) in repositories {
                if let state = await Task.detached(operation: { try? repository.changelists() }).value {
                    loaded[ObjectIdentifier(owner)] = state
                }
            }
            guard !Task.isCancelled, loaded != changelistsByRepo else { return }
            changelistsByRepo = loaded
            rebuildGroups()
        }
    }

    /// 在每个仓库上执行 Changelist 操作（保持各仓库的列表一致），完成后重新分组。
    private func changelistAction(in repositories: [ProjectModel]? = nil, _ work: @escaping @Sendable (Repository) throws -> Changelists) {
        let targets = (repositories ?? workspace.models).map { ($0, $0.repository) }
        Task {
            for (owner, repository) in targets {
                let result = await Task.detached { Result { try work(repository) } }.value
                switch result {
                case let .success(state): changelistsByRepo[ObjectIdentifier(owner)] = state
                case let .failure(error): model.post(errorMessage(error), isError: true)
                }
            }
            rebuildGroups()
        }
    }

    @objc private func refresh() { workspace.refreshAll() }
    @objc private func expandAll() { outline.expandItem(nil, expandChildren: true) }
    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }

    // MARK: - 提交

    /// 合并进行中且提交信息为空时，填入 git 准备好的合并提交信息（与 IDEA 一致）。
    private func prefillMergeMessage() {
        guard model.status.state == .merging, messageView.string.isEmpty, !isCommitting else { return }
        let repository = model.repository
        Task {
            let message = await Task.detached { repository.mergeMessage() }.value
            guard let message, self.messageView.string.isEmpty else { return }
            self.messageView.string = message
            self.messageView.didChangeText()
        }
    }

    private func updateCommitButtons() {
        let hasMessage = !messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFiles = !included.isEmpty || amendCheckbox.state == .on
        commitButton.isEnabled = hasMessage && hasFiles && !isCommitting
        commitPushButton.isEnabled = commitButton.isEnabled
    }

    @objc private func amendToggled() {
        updateCommitButtons()
        if amendCheckbox.state == .on {
            guard messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let repository = model.repository
            Task {
                let message = await Task.detached { try? repository.lastCommitMessage() }.value
                guard let message, self.amendCheckbox.state == .on, self.messageView.string.isEmpty else { return }
                self.messageView.string = message
                self.amendPrefill = message
                self.messageView.didChangeText()
            }
        } else if let prefill = amendPrefill, messageView.string == prefill {
            messageView.string = ""
            amendPrefill = nil
            messageView.didChangeText()
        }
    }

    @objc private func showOptions() {
        let menu = NSMenu()
        let signOffItem = NSMenuItem(title: tr("commit.option.signOff"), action: #selector(toggleSignOff), keyEquivalent: "")
        signOffItem.state = signOff ? .on : .off
        signOffItem.target = self
        let hooksItem = NSMenuItem(title: tr("commit.option.runHooks"), action: #selector(toggleHooks), keyEquivalent: "")
        hooksItem.state = runHooks ? .on : .off
        hooksItem.target = self
        let aiItem = NSMenuItem(title: tr("commit.option.aiReview"), action: #selector(toggleAIReview), keyEquivalent: "")
        aiItem.state = AISettings.reviewBeforeCommit ? .on : .off
        aiItem.target = self
        menu.items = [signOffItem, hooksItem, .separator(), aiItem]
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.height + 4), in: optionsButton)
    }

    @objc private func toggleSignOff() { signOff.toggle() }
    @objc private func toggleHooks() { runHooks.toggle() }
    @objc private func toggleAIReview() { AISettings.reviewBeforeCommit.toggle() }

    /// 勾选的条目，按仓库顺序与路径排列。
    private var includedEntries: [Entry] {
        let order = { (entry: Entry) in self.workspace.models.firstIndex { $0 === entry.model } ?? 0 }
        return entries.values.filter { included.contains($0.key) }.sorted { lhs, rhs in
            order(lhs) != order(rhs) ? order(lhs) < order(rhs) : lhs.change.path < rhs.change.path
        }
    }

    /// 主仓库中勾选的文件（AI 评审、生成提交信息使用）。
    var includedPaths: [String] {
        includedEntries.filter { $0.model === model }.map(\.change.path)
    }

    /// 按仓库分组。
    private func grouped(_ list: [Entry]) -> RepositoryPaths {
        workspace.models.compactMap { repository in
            let paths = list.filter { $0.model === repository }.map(\.change.path)
            return paths.isEmpty ? nil : (repository, paths)
        }
    }

    /// AI 评审勾选的改动：只涉及一个仓库时直接评审，涉及多个仓库时先选择仓库。
    @objc private func aiReviewSelected() {
        let groups = grouped(includedEntries)
        guard groups.count > 1 else {
            let (repository, paths) = groups.first ?? (model, [])
            aiReview?.reviewLocalChanges(paths: paths, in: repository)
            return
        }
        let menu = NSMenu(title: tr("ai.pickRepository"))
        menu.addItem(withTitle: tr("ai.pickRepository"), action: nil, keyEquivalent: "").isEnabled = false
        for (repository, paths) in groups {
            let handler = MenuAction { [weak self] in self?.aiReview?.reviewLocalChanges(paths: paths, in: repository) }
            let item = NSMenuItem(title: "\(workspace.displayName(of: repository))  (\(paths.count))", action: #selector(MenuAction.invoke), keyEquivalent: "")
            item.image = RepositoryBranchesPopover.chip(workspace.color(for: repository))
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        let anchor = NSApp.currentEvent.map { convert($0.locationInWindow, from: nil) } ?? NSPoint(x: 40, y: bounds.height - 60)
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    /// 根据勾选的文件生成提交信息；生成中再次点击取消。
    @objc func generateMessage() {
        guard let aiReview else { return }
        let paths = includedPaths
        guard !paths.isEmpty || aiReview.isGeneratingMessage else {
            NSSound.beep()
            return
        }
        Task {
            let wasGenerating = aiReview.isGeneratingMessage
            let generating = !wasGenerating
            generateSpinner.isHidden = !generating
            generateButton.alphaValue = generating ? 0 : 1
            if generating { generateSpinner.startAnimation(nil) }
            let message = await aiReview.generateCommitMessage(paths: paths)
            guard !wasGenerating else { return }
            generateSpinner.stopAnimation(nil)
            generateButton.alphaValue = 1
            if let message {
                messageView.string = message
                messageView.didChangeText()
                window?.makeFirstResponder(messageView)
            }
        }
    }

    #if DEBUG
    /// 仅 Debug：以指定提交信息提交勾选的文件（验证提交流程）。
    func debugCommit(message: String) {
        messageView.string = message
        messageView.didChangeText()
        commit()
    }
    #endif

    @objc private func commitAndPush() {
        guard commitButton.isEnabled else { return }
        pushAfterCommit = true
        commit()
    }

    private func finishCommitting() {
        isCommitting = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        updateCommitButtons()
    }

    /// 一个仓库要提交的内容：勾选的文件与部分提交的内容。
    private struct RepositoryCommit {
        let model: ProjectModel
        var options: CommitOptions
    }

    /// 提交勾选的文件：每个仓库各提交一次，使用同一提交信息。
    @objc private func commit() {
        guard commitButton.isEnabled else { return }
        let pushAfter = pushAfterCommit
        pushAfterCommit = false
        let chosen = includedEntries
        let message = messageView.string
        let amend = amendCheckbox.state == .on
        var commits: [RepositoryCommit] = grouped(chosen).map { repository, paths in
            RepositoryCommit(model: repository, options: CommitOptions(
                message: message, paths: paths, amend: amend, signOff: signOff,
                skipHooks: !runHooks, author: nil, partial: []
            ))
        }
        // 只勾选 Amend、没有文件时只修改主仓库的上一次提交信息。
        if commits.isEmpty, amend {
            commits = [RepositoryCommit(model: model, options: CommitOptions(
                message: message, paths: [], amend: true, signOff: signOff, skipHooks: !runHooks, author: nil, partial: []
            ))]
        }
        let selections = chosen.compactMap { entry in lineSelections?.selection(for: entry.key).map { (entry, $0) } }
        isCommitting = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        updateCommitButtons()
        let primaryPaths = includedPaths
        let reviewFirst = AISettings.reviewBeforeCommit && !primaryPaths.isEmpty ? aiReview : nil
        Task {
            // 提交前检查：AI 评审主仓库中勾选的改动，发现问题时由用户决定是否继续。
            if let reviewFirst, await !reviewFirst.reviewBeforeCommit(paths: primaryPaths) {
                self.finishCommitting()
                return
            }
            // 部分提交：确认选择之后文件没有变化，再计算要提交的内容。
            if !selections.isEmpty {
                let check = await Task.detached(priority: .userInitiated) {
                    selections.map { entry, selection -> (String, Bool) in
                        let url = entry.model.rootURL.appendingPathComponent(entry.change.path)
                        let text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let base = ((try? entry.model.repository.fileAtRevision(revision: "HEAD", path: entry.change.path)) ?? nil) ?? ""
                        return (entry.key, text == selection.text && base == selection.base)
                    }
                }.value
                let stale = check.filter { !$0.1 }.map(\.0)
                guard stale.isEmpty else {
                    self.lineSelections?.remove(stale)
                    self.finishCommitting()
                    let alert = NSAlert()
                    alert.messageText = tr("commit.partial.stale")
                    alert.informativeText = tr("commit.partial.stale.message", stale.joined(separator: "\n"))
                    if let window = self.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
                    return
                }
                for (entry, selection) in selections {
                    guard let index = commits.firstIndex(where: { $0.model === entry.model }) else { continue }
                    let content = selection.content
                    if content == selection.base {
                        // 文件的改动全部不提交。
                        commits[index].options.paths.removeAll { $0 == entry.change.path }
                    } else {
                        commits[index].options.partial.append(PartialFile(path: entry.change.path, content: content))
                    }
                }
                commits.removeAll { $0.options.paths.isEmpty && !$0.options.amend }
                guard !commits.isEmpty else {
                    self.finishCommitting()
                    self.model.post(tr("commit.partial.nothing"), isError: true)
                    return
                }
            }

            var committed: [(ProjectModel, CommitResult)] = []
            var failure: (ProjectModel, any Error)?
            for item in commits {
                let repository = item.model.repository
                let options = item.options
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try repository.commit(options: options) }
                }.value
                switch result {
                case let .success(commit): committed.append((item.model, commit))
                case let .failure(error): failure = (item.model, error)
                }
                if failure != nil { break }
            }
            self.finishCommitting()
            if !committed.isEmpty {
                let done = Set(committed.map { ObjectIdentifier($0.0) })
                self.lineSelections?.remove(chosen.filter { done.contains(ObjectIdentifier($0.model)) }.map(\.key))
                if failure == nil {
                    self.messageView.string = ""
                    self.messageView.didChangeText()
                    self.amendCheckbox.state = .off
                    self.amendPrefill = nil
                    self.autoMessage = nil
                }
                let files = committed.reduce(0) { $0 + Int($1.1.fileCount) }
                let subject = committed[0].1.subject
                let text: String
                if committed.count > 1 {
                    text = tr("commit.done.repositories", "\(files)", "\(committed.count)", subject)
                } else {
                    text = files == 1 ? tr("commit.done.one", subject) : tr("commit.done.many", "\(files)", subject)
                }
                self.model.post(text)
            }
            if let (repository, error) = failure {
                // 钩子输出等错误信息较长，用对话框完整展示。
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = self.workspace.isMultiRoot
                    ? tr("workspace.failedIn", tr("commit.failed"), self.workspace.displayName(of: repository))
                    : tr("commit.failed")
                alert.informativeText = errorMessage(error)
                if let window = self.window {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
                self.model.post(alert.messageText, isError: true)
            } else if pushAfter {
                self.onPushAfterCommit?()
            }
            self.workspace.refreshAll()
            self.updateCommitButtons()
        }
    }

    // MARK: - 右键菜单

    /// 右键菜单随点击的行变化：文件行可移到其他 Changelist，Changelist 行可编辑、设为活动或删除。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.item(atRow: outline.clickedRow)
        func add(_ title: String, _ action: Selector, enabled: Bool = true, object: Any? = nil) {
            let item = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = object
        }
        if let group = clicked as? Group, let list = group.changelist {
            add(tr("changelist.new"), #selector(newChangelist))
            add(tr("changelist.edit"), #selector(editChangelist(_:)), object: list.name)
            add(tr("changelist.setActive"), #selector(setActiveChangelist(_:)), enabled: !group.isActive, object: list.name)
            add(tr("changelist.delete"), #selector(deleteChangelist(_:)), enabled: displayedChangelists.count > 1, object: list.name)
            menu.addItem(.separator())
            add(tr("commit.action.rollback"), #selector(rollbackSelected), enabled: !group.files.isEmpty)
            add(tr("commit.action.shelve"), #selector(shelveSelected), enabled: !group.files.isEmpty)
            return
        }
        for item in changeMenu().items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
        if let file = clicked as? FileItem, !file.change.isUntracked, file.change.conflict == nil {
            let move = NSMenu()
            let current = changelistName(of: file.entry)
            for list in displayedChangelists where list.name != current {
                let entry = move.addItem(withTitle: list.name == DEFAULT_CHANGELIST ? tr("commit.group.changes") : list.name, action: #selector(moveToChangelist(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = list.name
            }
            if !move.items.isEmpty { move.addItem(.separator()) }
            let newItem = move.addItem(withTitle: tr("changelist.new"), action: #selector(moveToNewChangelist), keyEquivalent: "")
            newItem.target = self
            menu.insertItem(.separator(), at: 3)
            let moveItem = NSMenuItem(title: tr("changelist.move"), action: nil, keyEquivalent: "")
            moveItem.submenu = move
            menu.insertItem(moveItem, at: 4)
        }
    }

    private func changeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("commit.action.showDiff"), action: #selector(showDiffForSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("commit.action.jumpToSource"), action: #selector(jumpToSource), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("git.action.showHistory"), action: #selector(showHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("commit.action.rollback"), action: #selector(rollbackSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("commit.action.shelve"), action: #selector(shelveSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("stash.action.stashSelected"), action: #selector(stashSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("patch.menu.createSelected"), action: #selector(createPatchSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("git.action.resolveConflicts"), action: #selector(resolveConflicts), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - 选择与动作

    /// 右键时作用于点击的行，否则作用于选中行。
    private var targetItem: FileItem? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? FileItem
    }

    /// 右键点击的行不在选中范围内时只作用于该行，否则作用于所有选中行。
    private var targetRows: IndexSet {
        outline.selectedRowIndexes.contains(outline.clickedRow) || outline.clickedRow < 0
            ? outline.selectedRowIndexes
            : IndexSet(integer: outline.clickedRow)
    }

    /// 选中的条目（选中分组或仓库子分组时为其全部文件）。
    private var selectedEntries: [Entry] {
        var list: [Entry] = []
        for row in targetRows {
            switch outline.item(atRow: row) {
            case let item as FileItem: list.append(item.entry)
            case let group as Group: list += group.files
            case let repository as RepositoryGroup: list += repository.files
            default: break
            }
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.key).inserted }
    }

    @objc private func showDiffForClicked() {
        switch outline.item(atRow: outline.clickedRow) {
        case let item as FileItem where item.change.conflict != nil:
            // 冲突文件双击打开合并工具（IDEA 同样如此）。
            onResolveConflict?(item.entry.model, item.change)
        case let item as FileItem:
            onShowDiff?(item.entry.model, item.change, item.entry.key)
        case let group as Group where group.kind == .conflicts:
            onShowConflicts?(group.files.first?.model ?? model)
        default:
            break
        }
    }

    @objc private func resolveConflicts() {
        if let item = targetItem, item.change.conflict != nil {
            onResolveConflict?(item.entry.model, item.change)
        } else {
            onShowConflicts?(targetItem?.entry.model ?? model)
        }
    }

    @objc func showDiffForSelection() {
        guard let item = targetItem else { return }
        onShowDiff?(item.entry.model, item.change, item.entry.key)
    }

    /// 回滚选中的文件（选中分组时为该组全部文件）；未选中时对话框中全选。
    @objc func rollbackSelected() {
        onRollback?(grouped(selectedEntries))
    }

    /// 搁置选中的文件（选中 Changelist 时以列表名为默认名称）；未选中时搁置勾选的文件。
    @objc func shelveSelected() {
        var list = selectedEntries.filter { $0.change.conflict == nil }
        if list.isEmpty { list = includedEntries }
        guard !list.isEmpty else { return NSSound.beep() }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        let changelist = (outline.item(atRow: row) as? Group)?.changelist?.name
        let name = changelist.map { $0 == DEFAULT_CHANGELIST ? tr("shelf.defaultName") : $0 } ?? tr("shelf.defaultName")
        onShelve?(grouped(list), name)
    }

    // MARK: - Changelist 操作

    private var changelistNames: Set<String> { Set(displayedChangelists.map(\.name)) }

    @objc private func newChangelist() {
        ChangelistDialog(title: tr("changelist.new.title"), confirmTitle: tr("changelist.new.confirm"), name: "", comment: "", existing: changelistNames)
            .begin(for: window) { [weak self] name, comment in
                self?.changelistAction { repo in try repo.addChangelist(name: name, comment: comment, makeActive: false) }
            }
    }

    /// 把选中的文件移到列表中；某个仓库还没有该列表时先创建。
    private func move(_ list: [Entry], to name: String, comment: String = "") {
        for (repository, paths) in grouped(list) {
            changelistAction(in: [repository]) { repo in
                if !(try repo.changelists()).lists.contains(where: { $0.name == name }) {
                    _ = try repo.addChangelist(name: name, comment: comment, makeActive: false)
                }
                return try repo.moveToChangelist(paths: paths, name: name)
            }
        }
    }

    @objc private func moveToNewChangelist() {
        let list = selectedEntries
        ChangelistDialog(title: tr("changelist.new.title"), confirmTitle: tr("changelist.new.confirm"), name: "", comment: "", existing: changelistNames)
            .begin(for: window) { [weak self] name, comment in
                self?.move(list, to: name, comment: comment)
            }
    }

    @objc private func editChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let list = displayedChangelists.first(where: { $0.name == name }) else { return }
        let display = name == DEFAULT_CHANGELIST ? tr("commit.group.changes") : name
        ChangelistDialog(
            title: tr("changelist.edit.title"), confirmTitle: tr("changelist.edit.confirm"),
            name: display, comment: list.comment, existing: changelistNames.subtracting([name, display])
        ).begin(for: window) { [weak self] newName, comment in
            // 默认列表保持存储名称不变，只更新说明（除非用户真的改了显示名称）。
            let stored = name == DEFAULT_CHANGELIST && newName == display ? name : newName
            self?.changelistAction { repo in
                guard (try repo.changelists()).lists.contains(where: { $0.name == name }) else { return try repo.changelists() }
                return try repo.editChangelist(name: name, newName: stored, comment: comment)
            }
        }
    }

    /// IDEA 用 Changelist 的说明作为提交信息：勾选的文件都属于同一个有说明的列表、且提交信息为空
    /// （或仍是上次自动填入的说明）时，自动填入该说明。
    private func applyChangelistComment() {
        let chosen = includedEntries
        guard !chosen.isEmpty else { return }
        let owners = Set(chosen.map(changelistName(of:)))
        let comment = owners.count == 1 ? displayedChangelists.first { owners.contains($0.name) }?.comment ?? "" : ""
        let current = messageView.string
        guard current.isEmpty || current == autoMessage else { return }
        guard comment != current else { return }
        messageView.string = comment
        messageView.didChangeText()
        autoMessage = comment.isEmpty ? nil : comment
    }

    @objc private func setActiveChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        changelistAction { repo in
            if !(try repo.changelists()).lists.contains(where: { $0.name == name }) {
                _ = try repo.addChangelist(name: name, comment: "", makeActive: false)
            }
            return try repo.setActiveChangelist(name: name)
        }
    }

    @objc private func deleteChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        changelistAction { repo in
            let state = try repo.changelists()
            guard state.lists.contains(where: { $0.name == name }), state.lists.count > 1 else { return state }
            return try repo.removeChangelist(name: name)
        }
    }

    @objc private func moveToChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        move(selectedEntries, to: name)
    }

    /// 储藏选中的已跟踪文件；没有选中文件时储藏全部。
    @objc private func stashSelected() {
        onStashPaths?(grouped(selectedEntries.filter { !$0.change.isUntracked && $0.change.conflict == nil }))
    }

    /// 把选中的改动（含未跟踪文件）保存为补丁；未选中时保存全部改动。
    @objc private func createPatchSelected() {
        onCreatePatch?(grouped(selectedEntries.filter { $0.change.conflict == nil }))
    }

    @objc private func showHistory() {
        guard let item = targetItem, !item.change.isUntracked else { return NSSound.beep() }
        onShowHistory?(item.entry.model, item.change.path)
    }

    @objc private func jumpToSource() {
        guard let item = targetItem, !item.change.isDeleted else { return }
        onOpenFile?(item.entry.model.rootURL.appendingPathComponent(item.change.path))
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0 else { return }
        let on = sender.state == .on
        switch outline.item(atRow: row) {
        case let group as Group:
            for file in group.files {
                if on { included.insert(file.key) } else { included.remove(file.key) }
            }
        case let repository as RepositoryGroup:
            for file in repository.files {
                if on { included.insert(file.key) } else { included.remove(file.key) }
            }
        case let item as FileItem:
            let key = item.entry.key
            if lineSelections?.isPartial(key) == true, included.contains(key) {
                // 半选的文件再次点击：改为提交整个文件。
                lineSelections?.remove([key])
                included.insert(key)
            } else if on || sender.state == .mixed {
                included.insert(key)
            } else {
                included.remove(key)
            }
        default:
            break
        }
        outline.reloadData()
        applyChangelistComment()
        updateCommitButtons()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: groups.count
        case let group as Group: workspace.isMultiRoot ? group.repositories.count : group.files.count
        case let repository as RepositoryGroup: repository.files.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let group as Group:
            if workspace.isMultiRoot { return group.repositories[index] }
            let entry = group.files[index]
            return items[entry.key] ?? FileItem(entry)
        case let repository as RepositoryGroup:
            let entry = repository.files[index]
            return items[entry.key] ?? FileItem(entry)
        default:
            return groups[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group || item is RepositoryGroup
    }

    // MARK: - NSOutlineViewDelegate

    private func checkState(_ files: [Entry]) -> NSControl.StateValue {
        let selected = files.filter { included.contains($0.key) }.count
        return selected == 0 ? .off : (selected == files.count ? .on : .mixed)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChangeCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeCellView ?? ChangeCellView(identifier: id)
        cell.checkbox.target = self
        cell.checkbox.action = #selector(checkboxToggled(_:))
        cell.toolTip = nil

        switch item {
        case let group as Group:
            let count = group.files.count
            cell.checkbox.allowsMixedState = true
            cell.checkbox.state = checkState(group.files)
            cell.checkbox.isEnabled = count > 0 && group.kind != .conflicts
            cell.file.configure(
                icon: nil,
                name: group.title,
                detail: count == 1 ? tr("commit.group.oneFile") : tr("commit.group.files", "\(count)"),
                color: Theme.text,
                bold: group.kind != .changes || group.isActive
            )
            cell.toolTip = group.isActive ? tr("changelist.active.tooltip") : nil
        case let repository as RepositoryGroup:
            let count = repository.files.count
            cell.checkbox.allowsMixedState = true
            cell.checkbox.state = checkState(repository.files)
            cell.checkbox.isEnabled = !repository.files.contains { $0.change.conflict != nil }
            cell.file.configure(
                icon: RepositoryBranchesPopover.chip(workspace.color(for: repository.model)),
                name: workspace.displayName(of: repository.model),
                detail: "\(repository.model.currentBranchTitle)  " + (count == 1 ? tr("commit.group.oneFile") : tr("commit.group.files", "\(count)")),
                color: Theme.text
            )
            cell.toolTip = repository.model.rootURL.path
        case let item as FileItem:
            let change = item.change
            let partial = lineSelections?.isPartial(item.entry.key) ?? false
            cell.checkbox.allowsMixedState = partial
            cell.checkbox.state = included.contains(item.entry.key) ? (partial ? .mixed : .on) : .off
            if partial { cell.toolTip = tr("commit.partial.tooltip") }
            cell.checkbox.isEnabled = change.conflict == nil
            var detail = change.directory
            if let conflict = change.conflict {
                detail = [detail, conflict.title].filter { !$0.isEmpty }.joined(separator: "  ")
            } else if let orig = change.origPath {
                detail = tr("commit.renamedFrom", orig)
            }
            cell.file.configure(
                icon: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)),
                name: change.fileName,
                detail: detail,
                color: change.statusColor,
                strikethrough: change.isDeleted
            )
        default:
            return nil
        }
        return cell
    }
}

/// 变更树单元格：复选框 + 文件单元格。
final class ChangeCellView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let file: FileCellView

    init(identifier: NSUserInterfaceItemIdentifier) {
        file = FileCellView(identifier: identifier)
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        file.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        addSubview(file)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            file.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 2),
            file.trailingAnchor.constraint(equalTo: trailingAnchor),
            file.topAnchor.constraint(equalTo: topAnchor),
            file.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 带占位文字的文本视图（提交信息输入框）。
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.uiFont,
            .foregroundColor: Theme.secondaryText,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attrs)
    }

    var onTextChange: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onTextChange?()
    }
}
