import AppKit
import GitDeckCore

/// 项目主窗口，布局对齐 IDEA New UI：
///
/// ```
/// ┌ 主工具栏（项目组件 · VCS 分支组件 · 操作按钮）────────────┐
/// │ 图标条 │ 左侧工具窗口 │ 编辑器区域          │ 右侧工具窗口 │ 图标条 │
/// │        ├──────────────┴─────────────────────┴──────────────┤        │
/// │        │ 底部工具窗口（Git: Log / Console）                  │        │
/// └ 状态栏 ─────────────────────────────────────────────────────┘
/// ```
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    let model: ProjectModel
    var onClose: (() -> Void)?

    private let toolbar = MainToolbarView()
    private let stripe = ToolWindowStripe(top: [.project, .commit], bottom: [.git])
    private let rightStripe = ToolWindowStripe(top: [.aiReview], bottom: [])
    private let statusBar = StatusBarView()
    private let banner = WorkspaceBanner()
    /// 本窗口中的所有仓库（主仓库 + 加入的嵌套仓库 / 子模块）。
    private lazy var workspace = Workspace(primary: model)
    private lazy var workspaceOperations = WorkspaceOperations(workspace: workspace) { [unowned self] model in
        self.operations(for: model)
    }
    /// 非主仓库的操作对象（按仓库缓存）。
    private var extraOperations: [ObjectIdentifier: GitOperations] = [:]
    private var workspaceObserver: UUID?
    private let verticalSplit = NSSplitView()
    private let horizontalSplit = NSSplitView()
    private let leftPanel = NSView()
    private let bottomPanel = NSView()
    private let rightPanel = NSView()
    private lazy var editor = EditorAreaView(model: model)
    private let lineSelections = LineSelectionStore()
    private lazy var diffOpener = DiffOpener(model: model, editor: editor, lineSelections: lineSelections)
    private lazy var operations = GitOperations(model: model)
    private lazy var conflictResolver = ConflictResolver(model: model)

    private lazy var projectToolWindow = ProjectToolWindow(model: model)
    private lazy var commitToolWindow = CommitToolWindow(model: model)
    private lazy var gitToolWindow = GitToolWindow(model: model)
    private lazy var aiReview = AIReviewController(model: model)
    private lazy var aiToolWindow = AIReviewToolWindow(controller: aiReview)

    // 工具窗口布局在各项目间共用并持久化，与 IDEA 重启后恢复布局的行为一致。
    private var leftToolWindow: ToolWindowID? = ToolWindowLayout.left {
        didSet { ToolWindowLayout.left = leftToolWindow }
    }

    private var bottomVisible = ToolWindowLayout.bottomVisible {
        didSet { ToolWindowLayout.bottomVisible = bottomVisible }
    }
    private var rightVisible = ToolWindowLayout.rightVisible {
        didSet { ToolWindowLayout.rightVisible = rightVisible }
    }
    private var leftWidth: CGFloat = 300
    private var rightWidth: CGFloat = 380
    private var bottomHeight: CGFloat = 260
    private var observer: UUID?
    private var branchesPopover: NSPopover?
    private var fileWatcher: FileWatcher?
    private var trafficLightObservers: [NSObjectProtocol] = []

    init(repository: Repository) {
        model = ProjectModel(repository: repository)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 480)
        window.backgroundColor = Theme.headerBackground
        window.title = model.projectName
        window.representedURL = model.rootURL
        // 多个项目可以合并为同一窗口中的标签页（窗口 > 合并所有窗口）；设置中可选择总是以标签页打开。
        window.tabbingIdentifier = "GitDeckProject"
        window.tabbingMode = GeneralSettings.openProjectsAsTabs ? .preferred : .automatic
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("project:" + model.rootURL.path)
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }

        buildLayout()
        wireActions()
        observer = model.observe { [weak self] in self?.modelChanged() }
        workspaceObserver = workspace.observe { [weak self] in self?.workspaceChanged() }
        applyToolWindowState()
        model.refresh()
        workspace.load()
        editor.restoreSession()
        fileWatcher = FileWatcher(root: model.rootURL) { [weak self] paths in
            self?.workspace.refreshAll()
            self?.editor.reloadFromDisk(paths: paths)
        }
        fileWatcher?.start()
        trafficLightObservers = TrafficLights.keepCentered(in: window, height: MainToolbarView.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        toolbar.setProjectName(model.projectName)

        horizontalSplit.isVertical = true
        horizontalSplit.dividerStyle = .thin
        horizontalSplit.delegate = self
        horizontalSplit.addArrangedSubview(leftPanel)
        horizontalSplit.addArrangedSubview(editor)
        horizontalSplit.addArrangedSubview(rightPanel)
        horizontalSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        horizontalSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        horizontalSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        rightPanel.addSubview(aiToolWindow)
        aiToolWindow.pinEdges(to: rightPanel)

        verticalSplit.isVertical = false
        verticalSplit.dividerStyle = .thin
        verticalSplit.delegate = self
        verticalSplit.addArrangedSubview(horizontalSplit)
        verticalSplit.addArrangedSubview(bottomPanel)
        verticalSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        verticalSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        verticalSplit.translatesAutoresizingMaskIntoConstraints = false

        bottomPanel.addSubview(gitToolWindow)
        gitToolWindow.pinEdges(to: bottomPanel)

        let stripeDivider = SeparatorLine(.vertical)
        let rightStripeDivider = SeparatorLine(.vertical)
        for view in [toolbar, banner, stripe, stripeDivider, verticalSplit, rightStripeDivider, rightStripe, statusBar] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            banner.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stripe.topAnchor.constraint(equalTo: banner.bottomAnchor),
            stripe.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stripe.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            stripeDivider.topAnchor.constraint(equalTo: banner.bottomAnchor),
            stripeDivider.leadingAnchor.constraint(equalTo: stripe.trailingAnchor),
            stripeDivider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            verticalSplit.topAnchor.constraint(equalTo: banner.bottomAnchor),
            verticalSplit.leadingAnchor.constraint(equalTo: stripeDivider.trailingAnchor),
            verticalSplit.trailingAnchor.constraint(equalTo: rightStripeDivider.leadingAnchor),
            rightStripeDivider.topAnchor.constraint(equalTo: banner.bottomAnchor),
            rightStripeDivider.trailingAnchor.constraint(equalTo: rightStripe.leadingAnchor),
            rightStripeDivider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            rightStripe.topAnchor.constraint(equalTo: banner.bottomAnchor),
            rightStripe.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightStripe.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            verticalSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func wireActions() {
        stripe.onToggle = { [weak self] id in self?.toggle(id) }
        rightStripe.onToggle = { [weak self] id in self?.toggle(id) }
        toolbar.vcsWidget.target = self
        toolbar.vcsWidget.action = #selector(showBranchesPopup(_:))
        toolbar.projectWidget.target = self
        toolbar.projectWidget.action = #selector(showProjectMenu(_:))
        toolbar.refreshButton.target = self
        toolbar.refreshButton.action = #selector(refreshStatus(_:))
        toolbar.commitButton.target = self
        toolbar.commitButton.action = #selector(showCommitToolWindow(_:))
        toolbar.updateButton.target = self
        toolbar.updateButton.action = #selector(updateProject(_:))
        toolbar.pushButton.target = self
        toolbar.pushButton.action = #selector(pushChanges(_:))

        operations.window = window
        gitToolWindow.operations = operations
        gitToolWindow.attachWorktrees(operations: operations)
        commitToolWindow.onCreatePatch = { [weak self] paths in self?.operations.createPatch(paths: paths) }
        operations.onProgress = { [weak self] title in
            guard let self else { return }
            self.statusBar.setBusy(title != nil || self.model.isRefreshing)
            if let title { self.statusBar.setMessage(title) }
        }
        operations.peers = { [weak self] in self?.allOperations ?? [] }
        projectToolWindow.workspace = workspace
        workspaceOperations.window = window
        workspaceOperations.onProgress = operations.onProgress
        banner.onAdd = { [weak self] in
            guard let self else { return }
            self.workspace.add(paths: self.workspace.candidates.map(\.path))
        }
        banner.onIgnore = { [weak self] in
            guard let self else { return }
            self.workspace.ignore(paths: self.workspace.candidates.map(\.path))
        }
        commitToolWindow.onPushAfterCommit = { [weak self] in self?.operations.push() }
        commitToolWindow.onRollback = { [weak self] paths in self?.operations.rollback(selected: paths) }
        commitToolWindow.lineSelections = lineSelections
        operations.onRevealCommit = { [weak self] hash in
            self?.show(.git)
            self?.gitToolWindow.reveal(commit: hash)
        }
        operations.onShowRevisionFileDiff = { [weak self] revision, file in self?.diffOpener.showRevisionAgainstWorkingTree(revision: revision, file: file) }
        conflictResolver.window = window
        operations.onConflicts = { [weak self] in self?.conflictResolver.requestConflicts() }
        commitToolWindow.onResolveConflict = { [weak self] change in self?.conflictResolver.openMerge(change) }
        commitToolWindow.onShowConflicts = { [weak self] in self?.conflictResolver.showConflicts() }
        let stashes = StashesView(model: model, operations: operations)
        #if DEBUG
        debugStashes = stashes
        #endif
        stashes.onShowFileDiff = { [weak self] stash, file in self?.diffOpener.showStashFile(stash, file: file) }
        commitToolWindow.attachStashes(stashes)
        let shelf = ShelfView(model: model, operations: operations)
        #if DEBUG
        debugShelf = shelf
        #endif
        shelf.onShowFileDiff = { [weak self] entry, path in self?.diffOpener.showShelfFile(entry, path: path) }
        commitToolWindow.attachShelf(shelf)
        commitToolWindow.onShelve = { [weak self] paths, name in self?.operations.shelve(paths: paths, defaultName: name) }
        commitToolWindow.onStashPaths = { [weak self] paths in self?.operations.stashChanges(paths: paths) }
        let showHistory: (String) -> Void = { [weak self] path in self?.showFileHistory(path) }
        editor.onShowHistory = showHistory
        commitToolWindow.onShowHistory = showHistory
        projectToolWindow.onShowHistory = showHistory
        gitToolWindow.onShowHistory = showHistory
        editor.onShowCommit = { [weak self] hash in
            self?.show(.git)
            self?.gitToolWindow.reveal(commit: hash)
        }

        let openFile: (URL) -> Void = { [weak self] url in self?.editor.open(url) }
        projectToolWindow.onOpenFile = openFile
        commitToolWindow.onOpenFile = openFile
        gitToolWindow.onOpenFile = openFile
        commitToolWindow.onShowDiff = { [weak self] change in self?.diffOpener.showLocalChange(change) }
        gitToolWindow.onShowCommitDiff = { [weak self] hash, parent, file in
            self?.diffOpener.showCommitFile(hash: hash, parent: parent, file: file)
        }
        editor.onCaretChange = { [weak self] info in self?.statusBar.setEditorInfo(info) }

        aiReview.window = window
        aiReview.onReveal = { [weak self] in self?.show(.aiReview) }
        operations.aiReview = aiReview
        commitToolWindow.aiReview = aiReview
        editor.aiReview = aiReview
        editor.onReviewMarkerClick = { [weak self] index in
            self?.show(.aiReview)
            self?.aiToolWindow.select(findingIndex: index)
        }
        aiToolWindow.onReviewLocalChanges = { [weak self] in self?.reviewLocalChanges(nil) }
        aiToolWindow.onOpenFinding = { [weak self] index in self?.openFinding(index) }
        aiToolWindow.onApplySuggestion = { [weak self] index in self?.applySuggestion(index) }
    }

    // MARK: - 工具窗口

    /// 点击图标条：同一位置只显示一个工具窗口，再次点击已激活的按钮则隐藏。
    private func toggle(_ id: ToolWindowID) {
        switch id.anchor {
        case .left:
            leftToolWindow = leftToolWindow == id ? nil : id
        case .bottom:
            bottomVisible.toggle()
        case .right:
            rightVisible.toggle()
        }
        applyToolWindowState()
    }

    private func show(_ id: ToolWindowID) {
        switch id.anchor {
        case .left: leftToolWindow = id
        case .bottom: bottomVisible = true
        case .right: rightVisible = true
        }
        applyToolWindowState()
    }

    private func applyToolWindowState() {
        if !leftPanel.isHidden, leftPanel.frame.width > 0 { leftWidth = leftPanel.frame.width }
        if !bottomPanel.isHidden, bottomPanel.frame.height > 0 { bottomHeight = bottomPanel.frame.height }
        if !rightPanel.isHidden, rightPanel.frame.width > 0 { rightWidth = rightPanel.frame.width }

        leftPanel.subviews.forEach { $0.removeFromSuperview() }
        if let id = leftToolWindow {
            let view: NSView = id == .commit ? commitToolWindow : projectToolWindow
            leftPanel.addSubview(view)
            view.pinEdges(to: leftPanel)
        }
        leftPanel.isHidden = leftToolWindow == nil
        bottomPanel.isHidden = !bottomVisible
        rightPanel.isHidden = !rightVisible
        // 首次调用时窗口尚未布局，分割视图尺寸为 0，需先布局才能设置分隔条位置。
        window?.contentView?.layoutSubtreeIfNeeded()
        horizontalSplit.adjustSubviews()
        verticalSplit.adjustSubviews()
        if !leftPanel.isHidden { horizontalSplit.setPosition(leftWidth, ofDividerAt: 0) }
        if !rightPanel.isHidden { horizontalSplit.setPosition(horizontalSplit.bounds.width - rightWidth, ofDividerAt: 1) }
        if !bottomPanel.isHidden { verticalSplit.setPosition(verticalSplit.bounds.height - bottomHeight, ofDividerAt: 0) }

        var active = Set<ToolWindowID>()
        if let id = leftToolWindow { active.insert(id) }
        if bottomVisible { active.insert(.git) }
        stripe.setActive(active)
        rightStripe.setActive(rightVisible ? [.aiReview] : [])
    }

    // MARK: - 模型变化

    #if DEBUG
    /// 仅 Debug 构建：启动参数 `-debug.openLocalDiff <相对路径>` 在状态加载后自动打开该文件的本地 Diff，便于界面验证。
    private var debugDiffPath = UserDefaults.standard.string(forKey: "debug.openLocalDiff")
    /// 仅 Debug 构建：启动参数 `-debug.action <branches|push|update|newBranch|conflicts|merge|annotate|history|stashes|rebase|console|worktrees|aiReview|aiMessage|settings|commit|shelf|rollback|clone|compare|branchDiff|replace>（compare / branchDiff 配合 `-debug.branch`，replace 配合 `-debug.historyPath`）（history 需配合 `-debug.historyPath <路径>`）` 在状态加载后自动执行对应操作。
    private var debugAction = UserDefaults.standard.string(forKey: "debug.action")
    private weak var debugStashes: StashesView?
    private weak var debugShelf: ShelfView?

    /// 仅 Debug 构建：`-debug.snapshot <路径>` 在执行调试动作约 2 秒后把窗口内容渲染为 PNG。
    /// 不依赖屏幕状态（显示器休眠或锁屏时也可用），用于界面验证。
    private func scheduleDebugSnapshot() {
        guard let path = UserDefaults.standard.string(forKey: "debug.snapshot") else { return }
        Task {
            let delay = UserDefaults.standard.double(forKey: "debug.snapshotDelay")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
            // 设置窗口打开时截取设置窗口；有表单（对话框）时截取表单，否则截取主窗口。
            let settings = SettingsWindowController.shared.window.flatMap { $0.isVisible ? $0 : nil }
            // 打开着的分支弹窗：截取弹窗内容。
            let popoverView = branchesPopover?.contentViewController?.view
            guard let content = popoverView ?? (settings ?? window?.attachedSheet ?? window)?.contentView else { return }
            let bounds = content.bounds
            guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            content.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    private func modelChanged() {
        #if DEBUG
        if let path = debugDiffPath, !model.isRefreshing,
           let change = model.status.changes.first(where: { $0.path == path }) {
            debugDiffPath = nil
            diffOpener.showLocalChange(change)
        }
        if let action = debugAction, !model.isRefreshing, !model.branches.isEmpty {
            debugAction = nil
            scheduleDebugSnapshot()
            switch action {
            case "branches":
                // 等加入的仓库加载完成（多仓库时显示带仓库选择的弹窗）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.showBranchesPopup(nil) }
            case "push": operations.push()
            case "update": operations.updateProject()
            case "newBranch": operations.newBranch()
            case "conflicts": conflictResolver.showConflicts()
            case "annotate":
                if let path = UserDefaults.standard.string(forKey: "debug.historyPath") {
                    editor.open(model.rootURL.appendingPathComponent(path))
                }
                editor.toggleAnnotations()
                // `-debug.annotateInsert YES`：注释加载后在文件开头插入两行，验证注释随编辑对齐。
                if UserDefaults.standard.bool(forKey: "debug.annotateInsert") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.editor.activeEditor?.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// inserted 1\n// inserted 2\n")
                    }
                }
            case "console": showGitConsole(nil)
            case "aiReview":
                // `-debug.aiApply YES`：评审结束后选中第一个发现、跳转到源码并打开应用建议的预览。
                aiReview.start(scope: .localChanges(paths: []), title: tr("ai.scope.local", "\(model.status.changes.count)")) { [weak self] result in
                    guard let self, result != nil, UserDefaults.standard.bool(forKey: "debug.aiApply") else { return }
                    self.aiToolWindow.select(findingIndex: 0)
                    self.openFinding(0)
                    self.applySuggestion(0)
                }
            case "settings":
                // `-debug.settingsPane <0-3>`：通用 / 编辑器 / Git / AI 评审。
                let pane = SettingsWindowController.Pane(rawValue: UserDefaults.standard.integer(forKey: "debug.settingsPane")) ?? .general
                SettingsWindowController.shared.show(pane)
            case "commit": show(.commit)
            case "checkoutBranch":
                // 等加入的仓库加载后在主仓库签出 `-debug.branch`（验证同步分支控制）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.operations.checkout(.local(UserDefaults.standard.string(forKey: "debug.branch") ?? ""))
                }
            case "addRepos":
                // 等检测完成后点 “加入”，再显示 Project 工具窗口。
                show(.project)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.workspace.add(paths: self.workspace.candidates.map(\.path))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.projectToolWindow.expandAllForDebug() }
                }
            case "shelf":
                showShelf(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.debugShelf?.expandFirst() }
            case "partialCommit":
                show(.commit)
                // 等 Diff 计算完成、选择生效后提交。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.commitToolWindow.debugCommit(message: "Partial commit test") }
            case "rollback":
                show(.commit)
                commitToolWindow.rollbackSelected()
            case "clone": (NSApp.delegate as? AppDelegate)?.cloneProject(nil)
            case "compare": operations.compareWithCurrent(UserDefaults.standard.string(forKey: "debug.branch") ?? "")
            case "branchDiff": operations.showDiffWithWorkingTree(UserDefaults.standard.string(forKey: "debug.branch") ?? "")
            case "replace":
                if let path = UserDefaults.standard.string(forKey: "debug.historyPath") {
                    editor.open(model.rootURL.appendingPathComponent(path))
                    DispatchQueue.main.async { self.editor.activeEditor?.showFindBar(replace: true) }
                }
            case "aiMessage":
                showCommitToolWindow(nil)
                // 等提交工具窗口按最新状态勾选好文件。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.commitToolWindow.generateMessage() }
            case "worktrees":
                show(.git)
                gitToolWindow.showWorktrees()
            case "rebase":
                if let from = UserDefaults.standard.string(forKey: "debug.rebaseFrom"),
                   let hash = try? model.repository.rebaseCommits(from: from).first?.hash {
                    operations.interactiveRebase(from: hash)
                }
            case "stashes":
                unstashChanges(nil)
                debugStashes?.expandFirst()
            case "history":
                if let path = UserDefaults.standard.string(forKey: "debug.historyPath") { showFileHistory(path) }
            case "merge":
                if let change = model.status.changes.first(where: { $0.conflict != nil }) {
                    conflictResolver.openMerge(change)
                }
            default: break
            }
        }
        #endif
        toolbar.vcsWidget.title = workspace.branchWidgetTitle
        statusBar.setBusy(model.isRefreshing)
        if let error = model.lastError {
            statusBar.setMessage(error, isError: true)
        } else if let notification = model.notification {
            statusBar.setMessage(notification.text, isError: notification.isError)
        }
    }

    // MARK: - 动作（菜单与工具栏）

    @objc func showProjectToolWindow(_ sender: Any?) { show(.project) }

    @objc func showCommitToolWindow(_ sender: Any?) {
        show(.commit)
        commitToolWindow.focusMessage()
    }

    @objc func showGitToolWindow(_ sender: Any?) { show(.git) }

    @objc func showAIReviewToolWindow(_ sender: Any?) { show(.aiReview) }

    /// AI 评审本地改动：Commit 工具窗口中勾选了文件时只评审勾选的文件。
    @objc func reviewLocalChanges(_ sender: Any?) {
        aiReview.reviewLocalChanges(paths: commitToolWindow.includedPaths)
    }

    /// 跳转到发现所在位置：工作区版本在编辑器中打开，历史版本打开该提交中文件的 Diff。
    private func openFinding(_ index: Int) {
        guard let result = aiReview.result, result.findings.indices.contains(index) else { return }
        let finding = result.findings[index]
        let line = Int(finding.line) - 1
        if aiReview.isWorkingTreeResult(for: finding.file) {
            let url = model.rootURL.appendingPathComponent(finding.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                NSSound.beep()
                return
            }
            editor.open(url, line: line)
        } else if let revision = result.revision {
            diffOpener.showCommitFile(
                hash: revision,
                parent: revision + "^",
                file: ChangedFile(path: finding.file, origPath: nil, kind: .modified),
                revealLine: line
            )
        }
    }

    /// 预览并应用修改建议：在当前内容（含未保存的编辑）中定位原文，确认后写入。
    private func applySuggestion(_ index: Int) {
        guard let window, let result = aiReview.result, result.findings.indices.contains(index) else { return }
        let finding = result.findings[index]
        guard let suggestion = finding.suggestion, aiReview.isWorkingTreeResult(for: finding.file) else { return }
        let url = model.rootURL.appendingPathComponent(finding.file)
        guard let current = editor.text(of: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else {
            NSSound.beep()
            return
        }
        guard let updated = applyReviewSuggestion(
            content: current, line: finding.line, original: suggestion.original, replacement: suggestion.replacement
        ) else {
            let alert = NSAlert()
            alert.messageText = tr("ai.apply.notFound")
            alert.informativeText = tr("ai.apply.notFound.message")
            alert.beginSheetModal(for: window)
            return
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.aiApplyNow") {
            writeSuggestion(index, url: url, text: updated)
            return
        }
        #endif
        SuggestionPreview.present(on: window, path: finding.file, title: finding.title, before: current, after: updated) { [weak self] in
            self?.writeSuggestion(index, url: url, text: updated)
        }
    }

    private func writeSuggestion(_ index: Int, url: URL, text: String) {
        do {
            try editor.applyEdit(to: url, newText: text)
            aiReview.markApplied(index)
            model.refresh()
        } catch {
            statusBar.setMessage(error.localizedDescription, isError: true)
        }
    }

    @objc func refreshStatus(_ sender: Any?) { model.refresh() }

    @objc func showBranchesPopup(_ sender: Any?) {
        if let popover = branchesPopover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let onCommit: @MainActor () -> Void = { [weak self] in self?.showCommitToolWindow(nil) }
        if workspace.isMultiRoot {
            // 多仓库：默认选中当前编辑的文件所在的仓库。
            let selected = editor.activeFileURL.map(workspace.model(containing:)) ?? model
            let controller = RepositoryBranchesPopover(workspace: workspace, selected: selected, operationsFor: { [unowned self] in self.operations(for: $0) }, onCommit: onCommit)
            popover.contentViewController = controller
            controller.popover = popover
        } else {
            let controller = BranchesPopover(model: model, operations: operations, onCommit: onCommit)
            controller.popover = popover
            popover.contentViewController = controller
        }
        popover.show(relativeTo: toolbar.vcsWidget.bounds, of: toolbar.vcsWidget, preferredEdge: .maxY)
        branchesPopover = popover
    }

    @objc private func showProjectMenu(_ sender: Any?) {
        let menu = NSMenu()
        for path in RecentProjects.shared.paths.prefix(10) where path != model.rootURL.path {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            item.target = self
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: tr("menu.file.new"), action: #selector(AppDelegate.newProject(_:)), keyEquivalent: "")
        menu.addItem(withTitle: tr("menu.file.open"), action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "")
        let widget = toolbar.projectWidget
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: widget.bounds.height + 4), in: widget)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.openProject(at: URL(fileURLWithPath: path))
    }

    @objc func saveDocument(_ sender: Any?) {
        do {
            try editor.saveActive()
            model.refresh()
        } catch {
            statusBar.setMessage(error.localizedDescription, isError: true)
        }
    }

    @objc func closeEditorTab(_ sender: Any?) { editor.closeActive() }

    @objc func showFindBar(_ sender: Any?) { editor.activeEditor?.showFindBar() }
    @objc func showReplaceBar(_ sender: Any?) { editor.activeEditor?.showFindBar(replace: true) }
    @objc func nextDifference(_ sender: Any?) { editor.activeDiff?.nextDifference() }
    @objc func previousDifference(_ sender: Any?) { editor.activeDiff?.previousDifference() }
    @objc func findNext(_ sender: Any?) { editor.activeEditor?.findNext() }
    @objc func findPrevious(_ sender: Any?) { editor.activeEditor?.findPrevious() }

    @objc func pushChanges(_ sender: Any?) { workspaceOperations.pushAll() }
    @objc func updateProject(_ sender: Any?) { workspaceOperations.updateAll() }
    @objc func fetchChanges(_ sender: Any?) { workspaceOperations.fetchAll() }

    /// 把选择的目录作为仓库加入本项目（Git > 加入仓库）。
    @objc func addRepository(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.rootURL
        panel.message = tr("workspace.add.message")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.workspace.add(paths: [url.path])
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// 某个仓库的操作对象：主仓库用窗口的 `operations`，其他仓库按需创建并共享窗口回调。
    func operations(for repositoryModel: ProjectModel) -> GitOperations {
        if repositoryModel === model { return operations }
        let key = ObjectIdentifier(repositoryModel)
        if let existing = extraOperations[key] { return existing }
        let ops = GitOperations(model: repositoryModel)
        ops.window = window
        ops.aiReview = aiReview
        ops.onProgress = operations.onProgress
        ops.onRevealCommit = operations.onRevealCommit
        ops.peers = { [weak self] in self?.allOperations ?? [] }
        extraOperations[key] = ops
        return ops
    }

    private var allOperations: [GitOperations] { workspace.models.map(operations(for:)) }

    /// 仓库列表或任一仓库状态变化：更新分支组件与提示条。
    private func workspaceChanged() {
        toolbar.vcsWidget.title = workspace.branchWidgetTitle
        statusBar.setBusy(workspace.isRefreshing || operations.isRunning || workspaceOperations.isRunning)
        banner.show(workspace.candidates)
    }
    @objc func newBranch(_ sender: Any?) { operations.newBranch() }
    @objc func checkoutRevision(_ sender: Any?) { operations.checkoutRevisionDialog() }
    @objc func continueRebase(_ sender: Any?) { operations.continueRebase() }
    @objc func abortRebase(_ sender: Any?) { operations.abortRebase() }
    @objc func abortMerge(_ sender: Any?) { operations.abortMerge() }
    @objc func resolveConflicts(_ sender: Any?) { conflictResolver.showConflicts() }
    @objc func toggleAnnotations(_ sender: Any?) { editor.toggleAnnotations() }
    @objc func stashChanges(_ sender: Any?) { operations.stashChanges() }
    @objc func rollbackChanges(_ sender: Any?) { commitToolWindow.rollbackSelected() }
    @objc func shelveChanges(_ sender: Any?) { commitToolWindow.shelveSelected() }

    @objc func showShelf(_ sender: Any?) {
        show(.commit)
        commitToolWindow.showShelfTab()
    }
    @objc func newTag(_ sender: Any?) { operations.newTag(at: nil) }
    @objc func manageRemotes(_ sender: Any?) { operations.manageRemotes() }
    @objc func manageSubmodules(_ sender: Any?) { operations.manageSubmodules() }
    @objc func createPatch(_ sender: Any?) { operations.createPatch(paths: []) }
    @objc func applyPatch(_ sender: Any?) { operations.applyPatch() }

    @objc func newWorktree(_ sender: Any?) {
        show(.git)
        gitToolWindow.showWorktrees()
        operations.newWorktree()
    }

    @objc func showGitConsole(_ sender: Any?) {
        show(.git)
        gitToolWindow.showConsole()
    }
    @objc func continueCherryPick(_ sender: Any?) { operations.continueCherryPick() }
    @objc func abortCherryPick(_ sender: Any?) { operations.abortCherryPick() }
    @objc func continueRevert(_ sender: Any?) { operations.continueRevert() }
    @objc func abortRevert(_ sender: Any?) { operations.abortRevert() }

    /// IDEA 的 “Unstash Changes”：打开提交工具窗口的储藏标签。
    @objc func unstashChanges(_ sender: Any?) {
        show(.commit)
        commitToolWindow.showStashTab()
    }

    @objc func showHistoryForCurrentFile(_ sender: Any?) {
        guard let path = editor.activeRelativePath else { return }
        showFileHistory(path)
    }

    /// 在底部 Git 工具窗口中打开文件历史标签页。
    func showFileHistory(_ path: String) {
        show(.git)
        gitToolWindow.showHistory(path: path)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAnnotations(_:)) {
            menuItem.state = editor.isActiveAnnotated ? .on : .off
        }
        return switch menuItem.action {
        case #selector(pushChanges(_:)), #selector(updateProject(_:)), #selector(fetchChanges(_:)),
             #selector(newBranch(_:)), #selector(checkoutRevision(_:)), #selector(stashChanges(_:)), #selector(newTag(_:)),
             #selector(manageRemotes(_:)), #selector(manageSubmodules(_:)), #selector(createPatch(_:)), #selector(applyPatch(_:)),
             #selector(newWorktree(_:)):
            !operations.isRunning
        case #selector(rollbackChanges(_:)), #selector(shelveChanges(_:)):
            !operations.isRunning && model.status.changes.contains { !$0.isUntracked && $0.conflict == nil }
        case #selector(reviewLocalChanges(_:)):
            !aiReview.isRunning && !model.status.changes.isEmpty
        case #selector(continueRebase(_:)), #selector(abortRebase(_:)):
            !operations.isRunning && model.status.state == .rebasing
        case #selector(toggleAnnotations(_:)), #selector(showHistoryForCurrentFile(_:)):
            editor.activeRelativePath != nil
        case #selector(resolveConflicts(_:)):
            conflictResolver.hasConflicts
        case #selector(continueCherryPick(_:)), #selector(abortCherryPick(_:)):
            !operations.isRunning && model.status.state == .cherryPicking
        case #selector(continueRevert(_:)), #selector(abortRevert(_:)):
            !operations.isRunning && model.status.state == .reverting
        case #selector(abortMerge(_:)):
            !operations.isRunning && model.status.state == .merging
        case #selector(showFindBar(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(showReplaceBar(_:)):
            editor.activeEditor != nil
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)):
            editor.activeDiff != nil
        default:
            true
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let observer { model.removeObserver(observer) }
        fileWatcher?.stop()
        trafficLightObservers.forEach(NotificationCenter.default.removeObserver)
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 与 IDEA 一致：窗口重新获得焦点时刷新所有仓库的状态。
        workspace.refreshAll()
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === horizontalSplit else { return 200 }
        // 右侧面板的分隔条：编辑器至少保留 300 点宽。
        return dividerIndex == 0 ? 180 : (leftPanel.isHidden ? 0 : leftPanel.frame.maxX) + 300
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard splitView === horizontalSplit else { return total - 120 }
        if dividerIndex == 0 {
            return total - 300 - (rightPanel.isHidden ? 0 : rightPanel.frame.width)
        }
        return total - 260
    }
}

/// 工具窗口布局的持久化（UserDefaults）。
private enum ToolWindowLayout {
    private static let leftKey = "toolWindow.left"
    private static let bottomKey = "toolWindow.bottomVisible"
    private static let rightKey = "toolWindow.rightVisible"

    static var left: ToolWindowID? {
        get {
            // 未设置过时默认打开 Project；显式关闭时保存为空串。
            guard let raw = UserDefaults.standard.string(forKey: leftKey) else { return .project }
            return ToolWindowID(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: leftKey) }
    }

    static var bottomVisible: Bool {
        get { UserDefaults.standard.bool(forKey: bottomKey) }
        set { UserDefaults.standard.set(newValue, forKey: bottomKey) }
    }

    static var rightVisible: Bool {
        get { UserDefaults.standard.bool(forKey: rightKey) }
        set { UserDefaults.standard.set(newValue, forKey: rightKey) }
    }
}
