import AppKit
import GitDeckCore

/// 默认 Changelist 的存储名称（显示时本地化为 “Changes”）。
private let DEFAULT_CHANGELIST = defaultChangelistName()

/// Commit 工具窗口（IDEA 非模态提交界面）：变更树 + 提交信息 + 提交按钮。
final class CommitToolWindow: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpenFile: ((URL) -> Void)?
    var onShowDiff: ((FileChange) -> Void)?
    /// “提交并推送” 成功提交后打开 Push 对话框。
    var onPushAfterCommit: (() -> Void)?
    /// 打开冲突文件的三栏合并。
    var onResolveConflict: ((FileChange) -> Void)?
    /// 打开 Conflicts 对话框。
    var onShowConflicts: (() -> Void)?
    var onShowHistory: ((String) -> Void)?
    /// 储藏选中的文件（打开 Stash Changes 对话框）。
    var onStashPaths: (([String]) -> Void)?
    /// 把选中的改动保存为补丁。
    var onCreatePatch: (([String]) -> Void)?
    /// Rollback：参数为选中的文件（为空时由对话框全选）。
    var onRollback: (([String]) -> Void)?
    /// 搁置：参数为文件与默认名称。
    var onShelve: (([String], String) -> Void)?
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
    /// 当前的 Changelist（从核心加载并与工作区同步）。
    private var changelists: Changelists?
    private var changelistTask: Task<Void, Never>?
    /// 最近一次从 Changelist 说明自动填入的提交信息。
    private var autoMessage: String?
    private var contentTop: NSLayoutYAxisAnchor?

    /// 变更树的分组节点，顺序与 IDEA 一致。
    final class Group {
        enum Kind { case conflicts, changes, unversioned }
        let kind: Kind
        var files: [FileChange] = []
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

    /// 文件节点。用类包装以便 NSOutlineView 按引用识别条目。
    final class FileItem {
        let change: FileChange
        init(_ change: FileChange) { self.change = change }
    }

    private let model: ProjectModel
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
    /// 勾选要提交的文件路径。
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

    init(model: ProjectModel) {
        self.model = model
        super.init(frame: .zero)
        buildLayout()
        observer = model.observe { [weak self] in self?.statusChanged() }
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

    private func statusChanged() {
        guard !model.isRefreshing else { return }
        prefillMergeMessage()
        // 与 IDEA 一致：新出现的已跟踪改动只在活动 Changelist 中默认勾选。
        let current = Set(model.status.changes.map(\.path))
        let tracked = model.status.changes.filter { !$0.isIgnored && !$0.isUntracked && $0.conflict == nil }
        let newPaths = Set(tracked.map(\.path)).subtracting(known)
        let inactive = Set((changelists?.lists ?? []).filter { $0.name != changelists?.active }.flatMap(\.paths))
        included.formUnion(newPaths.subtracting(inactive))
        included.formIntersection(current)
        known = current
        items = Dictionary(model.status.changes.map { ($0.path, FileItem($0)) }, uniquingKeysWith: { a, _ in a })
        rebuildGroups()
        loadChangelists()
    }

    /// 按 Changelist 分组：冲突、各 Changelist（活动列表中的新改动）、未跟踪文件。
    private func rebuildGroups() {
        let expandedLists = Set(groups.filter { outline.isItemExpanded($0) }.compactMap { $0.changelist?.name })
        let firstBuild = groups.isEmpty
        let conflicts = Group(.conflicts)
        let unversioned = Group(.unversioned)
        let state = changelists ?? Changelists(active: DEFAULT_CHANGELIST, lists: [Changelist(name: DEFAULT_CHANGELIST, comment: "", paths: [])])
        let lists = state.lists.map { list -> Group in
            let group = Group(.changes, changelist: list)
            group.isActive = list.name == state.active
            return group
        }
        let owner = Dictionary(state.lists.flatMap { list in list.paths.map { ($0, list.name) } }, uniquingKeysWith: { a, _ in a })
        for change in model.status.changes where !change.isIgnored {
            if change.conflict != nil {
                conflicts.files.append(change)
            } else if change.isUntracked {
                unversioned.files.append(change)
            } else {
                let name = owner[change.path] ?? state.active
                (lists.first { $0.changelist?.name == name } ?? lists.first)?.files.append(change)
            }
        }
        let sort: (FileChange, FileChange) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for group in [conflicts, unversioned] + lists { group.files.sort(by: sort) }

        // 冲突与未跟踪分组为空时隐藏；Changelist 分组始终显示。
        groups = ([conflicts] + lists + [unversioned]).filter { $0.kind == .changes || !$0.files.isEmpty }
        outline.reloadData()
        for group in groups where group.kind == .conflicts || (group.kind == .changes && (firstBuild || group.isActive || expandedLists.contains(group.changelist?.name ?? ""))) {
            outline.expandItem(group)
        }
        applyChangelistComment()
        updateCommitButtons()
    }

    /// 从核心加载 Changelist（会与工作区同步并保存），完成后重新分组。
    private func loadChangelists() {
        let repository = model.repository
        changelistTask?.cancel()
        changelistTask = Task {
            let result = await Task.detached { try? repository.changelists() }.value
            guard !Task.isCancelled, let result, result != changelists else { return }
            changelists = result
            rebuildGroups()
        }
    }

    /// 执行 Changelist 操作并刷新分组。
    private func changelistAction(_ work: @escaping @Sendable (Repository) throws -> Changelists) {
        let repository = model.repository
        Task {
            let result = await Task.detached { Result { try work(repository) } }.value
            switch result {
            case let .success(state):
                changelists = state
                rebuildGroups()
            case let .failure(error):
                model.post(errorMessage(error), isError: true)
            }
        }
    }

    @objc private func refresh() { model.refresh() }
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

    /// 勾选的、仍存在于当前变更中的文件。
    var includedPaths: [String] {
        model.status.changes.map(\.path).filter { included.contains($0) }
    }

    @objc private func aiReviewSelected() {
        aiReview?.reviewLocalChanges(paths: includedPaths)
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

    @objc private func commit() {
        guard commitButton.isEnabled else { return }
        let pushAfter = pushAfterCommit
        pushAfterCommit = false
        // 只提交仍存在于当前变更中的勾选文件。
        let paths = includedPaths
        let selections = paths.compactMap { path in lineSelections?.selection(for: path).map { (path, $0) } }
        var options = CommitOptions(
            message: messageView.string,
            paths: paths,
            amend: amendCheckbox.state == .on,
            signOff: signOff,
            skipHooks: !runHooks,
            author: nil,
            partial: []
        )
        isCommitting = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        updateCommitButtons()
        let repository = model.repository
        let reviewFirst = AISettings.reviewBeforeCommit && !paths.isEmpty ? aiReview : nil
        Task {
            // 提交前检查：AI 评审勾选的改动，发现问题时由用户决定是否继续。
            if let reviewFirst, await !reviewFirst.reviewBeforeCommit(paths: paths) {
                self.isCommitting = false
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.updateCommitButtons()
                return
            }
            // 部分提交：确认选择之后文件没有变化，再计算要提交的内容。
            if !selections.isEmpty {
                let root = self.model.rootURL
                let check = await Task.detached(priority: .userInitiated) {
                    selections.map { path, selection -> (String, Bool) in
                        let text = (try? Data(contentsOf: root.appendingPathComponent(path))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let base = ((try? repository.fileAtRevision(revision: "HEAD", path: path)) ?? nil) ?? ""
                        return (path, text == selection.text && base == selection.base)
                    }
                }.value
                let stale = check.filter { !$0.1 }.map(\.0)
                guard stale.isEmpty else {
                    self.lineSelections?.remove(stale)
                    self.isCommitting = false
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.updateCommitButtons()
                    let alert = NSAlert()
                    alert.messageText = tr("commit.partial.stale")
                    alert.informativeText = tr("commit.partial.stale.message", stale.joined(separator: "\n"))
                    if let window = self.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
                    return
                }
                for (path, selection) in selections {
                    let content = selection.content
                    if content == selection.base {
                        // 文件的改动全部不提交。
                        options.paths.removeAll { $0 == path }
                    } else {
                        options.partial.append(PartialFile(path: path, content: content))
                    }
                }
                if options.paths.isEmpty, !options.amend {
                    self.isCommitting = false
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.updateCommitButtons()
                    self.model.post(tr("commit.partial.nothing"), isError: true)
                    return
                }
            }
            let finalOptions = options
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.commit(options: finalOptions) }
            }.value
            self.isCommitting = false
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            switch result {
            case let .success(commit):
                self.lineSelections?.remove(paths)
                self.messageView.string = ""
                self.messageView.didChangeText()
                self.amendCheckbox.state = .off
                self.amendPrefill = nil
                self.autoMessage = nil
                let text = commit.fileCount == 1
                    ? tr("commit.done.one", commit.subject)
                    : tr("commit.done.many", "\(commit.fileCount)", commit.subject)
                self.model.post(text)
                if pushAfter { self.onPushAfterCommit?() }
            case let .failure(error):
                // 钩子输出等错误信息较长，用对话框完整展示。
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = tr("commit.failed")
                alert.informativeText = errorMessage(error)
                if let window = self.window {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
                self.model.post(tr("commit.failed"), isError: true)
            }
            self.model.refresh()
            self.updateCommitButtons()
        }
    }

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
            add(tr("changelist.delete"), #selector(deleteChangelist(_:)), enabled: (changelists?.lists.count ?? 1) > 1, object: list.name)
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
            let current = changelists?.lists.first { $0.paths.contains(file.change.path) }?.name ?? changelists?.active
            for list in changelists?.lists ?? [] where list.name != current {
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

    /// 右键时作用于点击的行，否则作用于选中行。
    private var targetItem: FileItem? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? FileItem
    }

    @objc private func showDiffForClicked() {
        switch outline.item(atRow: outline.clickedRow) {
        case let item as FileItem where item.change.conflict != nil:
            // 冲突文件双击打开合并工具（IDEA 同样如此）。
            onResolveConflict?(item.change)
        case let item as FileItem:
            onShowDiff?(item.change)
        case let group as Group where group.kind == .conflicts:
            onShowConflicts?()
        default:
            break
        }
    }

    @objc private func resolveConflicts() {
        if let item = targetItem, item.change.conflict != nil {
            onResolveConflict?(item.change)
        } else {
            onShowConflicts?()
        }
    }

    @objc func showDiffForSelection() {
        guard let item = targetItem else { return }
        onShowDiff?(item.change)
    }

    /// 回滚选中的文件（选中分组时为该组全部文件）；未选中时对话框中全选。
    @objc func rollbackSelected() {
        let rows = outline.selectedRowIndexes.contains(outline.clickedRow) || outline.clickedRow < 0
            ? outline.selectedRowIndexes
            : IndexSet(integer: outline.clickedRow)
        var paths: [String] = []
        for row in rows {
            switch outline.item(atRow: row) {
            case let item as FileItem: paths.append(item.change.path)
            case let group as Group: paths += group.files.map(\.path)
            default: break
            }
        }
        onRollback?(paths)
    }

    /// 选中的文件（选中分组时为该组全部文件）。
    private var selectedPaths: [String] {
        let rows = outline.selectedRowIndexes.contains(outline.clickedRow) || outline.clickedRow < 0
            ? outline.selectedRowIndexes
            : IndexSet(integer: outline.clickedRow)
        var paths: [String] = []
        for row in rows {
            switch outline.item(atRow: row) {
            case let item as FileItem: paths.append(item.change.path)
            case let group as Group: paths += group.files.map(\.path)
            default: break
            }
        }
        return paths
    }

    /// 搁置选中的文件（选中 Changelist 时以列表名为默认名称）；未选中时搁置勾选的文件。
    @objc func shelveSelected() {
        var paths = selectedPaths.filter { path in items[path]?.change.conflict == nil }
        if paths.isEmpty { paths = includedPaths }
        guard !paths.isEmpty else { return NSSound.beep() }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        let list = (outline.item(atRow: row) as? Group)?.changelist?.name
        let name = list.map { $0 == DEFAULT_CHANGELIST ? tr("shelf.defaultName") : $0 } ?? tr("shelf.defaultName")
        onShelve?(paths, name)
    }

    // MARK: - Changelist

    private var changelistNames: Set<String> { Set(changelists?.lists.map(\.name) ?? []) }

    @objc private func newChangelist() {
        ChangelistDialog(title: tr("changelist.new.title"), confirmTitle: tr("changelist.new.confirm"), name: "", comment: "", existing: changelistNames)
            .begin(for: window) { [weak self] name, comment in
                self?.changelistAction { repo in try repo.addChangelist(name: name, comment: comment, makeActive: false) }
            }
    }

    @objc private func moveToNewChangelist() {
        let paths = selectedPaths
        ChangelistDialog(title: tr("changelist.new.title"), confirmTitle: tr("changelist.new.confirm"), name: "", comment: "", existing: changelistNames)
            .begin(for: window) { [weak self] name, comment in
                self?.changelistAction { repo in
                    _ = try repo.addChangelist(name: name, comment: comment, makeActive: false)
                    return try repo.moveToChangelist(paths: paths, name: name)
                }
            }
    }

    @objc private func editChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let list = changelists?.lists.first(where: { $0.name == name }) else { return }
        let display = name == DEFAULT_CHANGELIST ? tr("commit.group.changes") : name
        ChangelistDialog(
            title: tr("changelist.edit.title"), confirmTitle: tr("changelist.edit.confirm"),
            name: display, comment: list.comment, existing: changelistNames.subtracting([name, display])
        ).begin(for: window) { [weak self] newName, comment in
            // 默认列表保持存储名称不变，只更新说明（除非用户真的改了显示名称）。
            let stored = name == DEFAULT_CHANGELIST && newName == display ? name : newName
            self?.changelistAction { repo in try repo.editChangelist(name: name, newName: stored, comment: comment) }
        }
    }

    /// IDEA 用 Changelist 的说明作为提交信息：勾选的文件都属于同一个有说明的列表、且提交信息为空
    /// （或仍是上次自动填入的说明）时，自动填入该说明。
    private func applyChangelistComment() {
        let paths = Set(includedPaths)
        guard !paths.isEmpty, let lists = changelists?.lists else { return }
        let owners = Set(lists.filter { !Set($0.paths).isDisjoint(with: paths) }.map(\.name))
        let comment = owners.count == 1 ? lists.first { owners.contains($0.name) }?.comment ?? "" : ""
        let current = messageView.string
        guard current.isEmpty || current == autoMessage else { return }
        guard comment != current else { return }
        messageView.string = comment
        messageView.didChangeText()
        autoMessage = comment.isEmpty ? nil : comment
    }

    @objc private func setActiveChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        changelistAction { repo in try repo.setActiveChangelist(name: name) }
    }

    @objc private func deleteChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        changelistAction { repo in try repo.removeChangelist(name: name) }
    }

    @objc private func moveToChangelist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let paths = selectedPaths
        changelistAction { repo in try repo.moveToChangelist(paths: paths, name: name) }
    }

    /// 储藏选中的已跟踪文件；没有选中文件时储藏全部。
    @objc private func stashSelected() {
        let rows = outline.selectedRowIndexes.contains(outline.clickedRow) || outline.clickedRow < 0
            ? outline.selectedRowIndexes
            : IndexSet(integer: outline.clickedRow)
        let paths = rows.compactMap { (outline.item(atRow: $0) as? FileItem)?.change }
            .filter { !$0.isUntracked && $0.conflict == nil }
            .map(\.path)
        onStashPaths?(paths)
    }

    /// 把选中的改动（含未跟踪文件）保存为补丁；未选中时保存全部改动。
    @objc private func createPatchSelected() {
        let rows = outline.selectedRowIndexes.contains(outline.clickedRow) || outline.clickedRow < 0
            ? outline.selectedRowIndexes
            : IndexSet(integer: outline.clickedRow)
        let paths = rows.compactMap { (outline.item(atRow: $0) as? FileItem)?.change }
            .filter { $0.conflict == nil }
            .map(\.path)
        onCreatePatch?(paths)
    }

    @objc private func showHistory() {
        guard let item = targetItem, !item.change.isUntracked else { return NSSound.beep() }
        onShowHistory?(item.change.path)
    }

    @objc private func jumpToSource() {
        guard let item = targetItem, !item.change.isDeleted else { return }
        onOpenFile?(model.rootURL.appendingPathComponent(item.change.path))
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0 else { return }
        let on = sender.state == .on
        switch outline.item(atRow: row) {
        case let group as Group:
            for file in group.files {
                if on { included.insert(file.path) } else { included.remove(file.path) }
            }
        case let item as FileItem:
            let path = item.change.path
            if lineSelections?.isPartial(path) == true, included.contains(path) {
                // 半选的文件再次点击：改为提交整个文件。
                lineSelections?.remove([path])
                included.insert(path)
            } else if on || sender.state == .mixed {
                included.insert(path)
            } else {
                included.remove(path)
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
        case let group as Group: group.files.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? Group {
            let path = group.files[index].path
            return items[path] ?? FileItem(group.files[index])
        }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ChangeCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeCellView ?? ChangeCellView(identifier: id)
        cell.checkbox.target = self
        cell.checkbox.action = #selector(checkboxToggled(_:))

        switch item {
        case let group as Group:
            let count = group.files.count
            let selected = group.files.filter { included.contains($0.path) }.count
            cell.checkbox.allowsMixedState = true
            cell.checkbox.state = selected == 0 ? .off : (selected == count ? .on : .mixed)
            cell.checkbox.isEnabled = count > 0 && group.kind != .conflicts
            cell.file.configure(
                icon: nil,
                name: group.title,
                detail: count == 1 ? tr("commit.group.oneFile") : tr("commit.group.files", "\(count)"),
                color: Theme.text,
                bold: group.kind != .changes || group.isActive
            )
            cell.toolTip = group.isActive ? tr("changelist.active.tooltip") : nil
        case let item as FileItem:
            let change = item.change
            let partial = lineSelections?.isPartial(change.path) ?? false
            cell.checkbox.allowsMixedState = partial
            cell.checkbox.state = included.contains(change.path) ? (partial ? .mixed : .on) : .off
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
