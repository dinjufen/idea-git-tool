import AppKit
import GitDeckCore

/// 项目主窗口，布局对齐 IDEA New UI：
///
/// ```
/// ┌ 主工具栏（项目组件 · VCS 分支组件 · 操作按钮）────────────┐
/// │ 图标条 │ 左侧工具窗口 │ 编辑器区域                          │
/// │        ├──────────────┴──────────────────────────────────── │
/// │        │ 底部工具窗口（Git: Log / Console）                  │
/// └ 状态栏 ─────────────────────────────────────────────────────┘
/// ```
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    let model: ProjectModel
    var onClose: (() -> Void)?

    private let toolbar = MainToolbarView()
    private let stripe = ToolWindowStripe(top: [.project, .commit], bottom: [.git])
    private let statusBar = StatusBarView()
    private let verticalSplit = NSSplitView()
    private let horizontalSplit = NSSplitView()
    private let leftPanel = NSView()
    private let bottomPanel = NSView()
    private lazy var editor = EditorAreaView(model: model)
    private lazy var diffOpener = DiffOpener(model: model, editor: editor)
    private lazy var operations = GitOperations(model: model)
    private lazy var conflictResolver = ConflictResolver(model: model)

    private lazy var projectToolWindow = ProjectToolWindow(model: model)
    private lazy var commitToolWindow = CommitToolWindow(model: model)
    private lazy var gitToolWindow = GitToolWindow(model: model)

    // 工具窗口布局在各项目间共用并持久化，与 IDEA 重启后恢复布局的行为一致。
    private var leftToolWindow: ToolWindowID? = ToolWindowLayout.left {
        didSet { ToolWindowLayout.left = leftToolWindow }
    }

    private var bottomVisible = ToolWindowLayout.bottomVisible {
        didSet { ToolWindowLayout.bottomVisible = bottomVisible }
    }
    private var leftWidth: CGFloat = 300
    private var bottomHeight: CGFloat = 260
    private var observer: UUID?
    private var branchesPopover: NSPopover?

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
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("project:" + model.rootURL.path)
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }

        buildLayout()
        wireActions()
        observer = model.observe { [weak self] in self?.modelChanged() }
        applyToolWindowState()
        model.refresh()
        editor.restoreSession()
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
        horizontalSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        horizontalSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)

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
        for view in [toolbar, stripe, stripeDivider, verticalSplit, statusBar] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            stripe.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            stripe.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stripe.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            stripeDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            stripeDivider.leadingAnchor.constraint(equalTo: stripe.trailingAnchor),
            stripeDivider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            verticalSplit.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            verticalSplit.leadingAnchor.constraint(equalTo: stripeDivider.trailingAnchor),
            verticalSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            verticalSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func wireActions() {
        stripe.onToggle = { [weak self] id in self?.toggle(id) }
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
        operations.onProgress = { [weak self] title in
            guard let self else { return }
            self.statusBar.setBusy(title != nil || self.model.isRefreshing)
            if let title { self.statusBar.setMessage(title) }
        }
        commitToolWindow.onPushAfterCommit = { [weak self] in self?.operations.push() }
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
    }

    // MARK: - 工具窗口

    /// 点击图标条：同一位置只显示一个工具窗口，再次点击已激活的按钮则隐藏。
    private func toggle(_ id: ToolWindowID) {
        switch id.anchor {
        case .left:
            leftToolWindow = leftToolWindow == id ? nil : id
        case .bottom:
            bottomVisible.toggle()
        }
        applyToolWindowState()
    }

    private func show(_ id: ToolWindowID) {
        switch id.anchor {
        case .left: leftToolWindow = id
        case .bottom: bottomVisible = true
        }
        applyToolWindowState()
    }

    private func applyToolWindowState() {
        if !leftPanel.isHidden, leftPanel.frame.width > 0 { leftWidth = leftPanel.frame.width }
        if !bottomPanel.isHidden, bottomPanel.frame.height > 0 { bottomHeight = bottomPanel.frame.height }

        leftPanel.subviews.forEach { $0.removeFromSuperview() }
        if let id = leftToolWindow {
            let view: NSView = id == .commit ? commitToolWindow : projectToolWindow
            leftPanel.addSubview(view)
            view.pinEdges(to: leftPanel)
        }
        leftPanel.isHidden = leftToolWindow == nil
        bottomPanel.isHidden = !bottomVisible
        // 首次调用时窗口尚未布局，分割视图尺寸为 0，需先布局才能设置分隔条位置。
        window?.contentView?.layoutSubtreeIfNeeded()
        horizontalSplit.adjustSubviews()
        verticalSplit.adjustSubviews()
        if !leftPanel.isHidden { horizontalSplit.setPosition(leftWidth, ofDividerAt: 0) }
        if !bottomPanel.isHidden { verticalSplit.setPosition(verticalSplit.bounds.height - bottomHeight, ofDividerAt: 0) }

        var active = Set<ToolWindowID>()
        if let id = leftToolWindow { active.insert(id) }
        if bottomVisible { active.insert(.git) }
        stripe.setActive(active)
    }

    // MARK: - 模型变化

    #if DEBUG
    /// 仅 Debug 构建：启动参数 `-debug.openLocalDiff <相对路径>` 在状态加载后自动打开该文件的本地 Diff，便于界面验证。
    private var debugDiffPath = UserDefaults.standard.string(forKey: "debug.openLocalDiff")
    /// 仅 Debug 构建：启动参数 `-debug.action <branches|push|update|newBranch|conflicts|merge|annotate|history|stashes>（history 需配合 `-debug.historyPath <路径>`）` 在状态加载后自动执行对应操作。
    private var debugAction = UserDefaults.standard.string(forKey: "debug.action")
    private weak var debugStashes: StashesView?

    /// 仅 Debug 构建：`-debug.snapshot <路径>` 在执行调试动作约 2 秒后把窗口内容渲染为 PNG。
    /// 不依赖屏幕状态（显示器休眠或锁屏时也可用），用于界面验证。
    private func scheduleDebugSnapshot() {
        guard let path = UserDefaults.standard.string(forKey: "debug.snapshot") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let content = window?.contentView else { return }
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
            case "branches": showBranchesPopup(nil)
            case "push": operations.push()
            case "update": operations.updateProject()
            case "newBranch": operations.newBranch()
            case "conflicts": conflictResolver.showConflicts()
            case "annotate": editor.toggleAnnotations()
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
        toolbar.vcsWidget.title = model.branchWidgetTitle
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

    @objc func refreshStatus(_ sender: Any?) { model.refresh() }

    @objc func showBranchesPopup(_ sender: Any?) {
        if let popover = branchesPopover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = BranchesPopover(model: model, operations: operations) { [weak self] in
            self?.showCommitToolWindow(nil)
        }
        controller.popover = popover
        popover.contentViewController = controller
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
    @objc func nextDifference(_ sender: Any?) { editor.activeDiff?.nextDifference() }
    @objc func previousDifference(_ sender: Any?) { editor.activeDiff?.previousDifference() }
    @objc func findNext(_ sender: Any?) { editor.activeEditor?.findNext() }
    @objc func findPrevious(_ sender: Any?) { editor.activeEditor?.findPrevious() }

    @objc func pushChanges(_ sender: Any?) { operations.push() }
    @objc func updateProject(_ sender: Any?) { operations.updateProject() }
    @objc func fetchChanges(_ sender: Any?) { operations.fetch() }
    @objc func newBranch(_ sender: Any?) { operations.newBranch() }
    @objc func checkoutRevision(_ sender: Any?) { operations.checkoutRevisionDialog() }
    @objc func continueRebase(_ sender: Any?) { operations.continueRebase() }
    @objc func abortRebase(_ sender: Any?) { operations.abortRebase() }
    @objc func abortMerge(_ sender: Any?) { operations.abortMerge() }
    @objc func resolveConflicts(_ sender: Any?) { conflictResolver.showConflicts() }
    @objc func toggleAnnotations(_ sender: Any?) { editor.toggleAnnotations() }
    @objc func stashChanges(_ sender: Any?) { operations.stashChanges() }

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
             #selector(newBranch(_:)), #selector(checkoutRevision(_:)), #selector(stashChanges(_:)):
            !operations.isRunning
        case #selector(continueRebase(_:)), #selector(abortRebase(_:)):
            !operations.isRunning && model.status.state == .rebasing
        case #selector(toggleAnnotations(_:)), #selector(showHistoryForCurrentFile(_:)):
            editor.activeRelativePath != nil
        case #selector(resolveConflicts(_:)):
            conflictResolver.hasConflicts
        case #selector(abortMerge(_:)):
            !operations.isRunning && model.status.state == .merging
        case #selector(showFindBar(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)):
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
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 与 IDEA 一致：窗口重新获得焦点时刷新 VCS 状态（文件监听在后续步骤加入）。
        model.refresh()
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === horizontalSplit ? 180 : 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return splitView === horizontalSplit ? total - 300 : total - 120
    }
}

/// 工具窗口布局的持久化（UserDefaults）。
private enum ToolWindowLayout {
    private static let leftKey = "toolWindow.left"
    private static let bottomKey = "toolWindow.bottomVisible"

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
}
