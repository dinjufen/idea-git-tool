import AppKit
import GitDeckCore

/// 底部 Git 工具窗口：Log、Console 标签页，以及按需打开的文件历史标签页（同一时间一个）。
final class GitToolWindow: NSView {
    private let model: ProjectModel
    private var historyView: FileHistoryView?
    private let closeHistoryButton = IconButton(symbol: "xmark", tooltip: tr("git.tab.closeHistory"), size: 20, pointSize: 9)

    var onOpenFile: ((URL) -> Void)? {
        didSet { logView.onOpenFile = onOpenFile }
    }

    var onShowCommitDiff: ((String, String?, ChangedFile) -> Void)? {
        didSet {
            logView.onShowCommitDiff = onShowCommitDiff
            historyView?.onOpenDiff = onShowCommitDiff
        }
    }

    var operations: GitOperations? {
        get { logView.operations }
        set { logView.operations = newValue }
    }

    var onShowHistory: ((String) -> Void)? {
        didSet { logView.onShowHistory = onShowHistory }
    }

    private let tabs = NSSegmentedControl(
        labels: [tr("git.tab.log"), tr("git.tab.console"), tr("git.tab.worktrees")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let logView: LogView
    private let consoleView: ConsoleView
    private var worktreesView: WorktreesView?
    /// 文件历史标签页的下标（日志、控制台、工作树之后）。
    private static let historyTab = 3

    init(model: ProjectModel) {
        self.model = model
        logView = LogView(model: model)
        consoleView = ConsoleView(root: model.repository.root())
        super.init(frame: .zero)
        let background = ColoredView(Theme.toolWindowBackground)
        addSubview(background)
        background.pinEdges(to: self)

        let header = ToolWindowHeader(title: tr("toolwindow.git"))
        tabs.segmentStyle = .texturedRounded
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        logView.translatesAutoresizingMaskIntoConstraints = false
        consoleView.translatesAutoresizingMaskIntoConstraints = false

        closeHistoryButton.target = self
        closeHistoryButton.action = #selector(closeHistory)
        closeHistoryButton.isHidden = true

        let top = SeparatorLine(.horizontal)
        for view in [top, header, tabs, closeHistoryButton, logView, consoleView] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: top.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabs.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 60),
            closeHistoryButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            closeHistoryButton.leadingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: 4),
            logView.topAnchor.constraint(equalTo: header.bottomAnchor),
            logView.leadingAnchor.constraint(equalTo: leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: trailingAnchor),
            logView.bottomAnchor.constraint(equalTo: bottomAnchor),
            consoleView.topAnchor.constraint(equalTo: header.bottomAnchor),
            consoleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            consoleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            consoleView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        tabChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 加入工作树标签（依赖 GitOperations，由项目窗口创建后传入）。
    func attachWorktrees(operations: GitOperations) {
        let view = WorktreesView(model: model, operations: operations)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: logView.topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        worktreesView = view
        tabChanged()
    }

    @objc private func tabChanged() {
        let selected = tabs.selectedSegment
        logView.isHidden = selected != 0
        consoleView.isHidden = selected != 1
        worktreesView?.isHidden = selected != 2
        historyView?.isHidden = selected != Self.historyTab
    }

    func showConsole() {
        tabs.selectedSegment = 1
        tabChanged()
    }

    func showWorktrees() {
        tabs.selectedSegment = 2
        tabChanged()
    }

    /// 在 Log 标签页中定位某个提交。
    func reveal(commit hash: String) {
        tabs.selectedSegment = 0
        tabChanged()
        logView.reveal(hash)
    }

    /// 打开（或替换）文件历史标签页。
    /// 显示文件历史；`repository` 为文件所属的仓库（多仓库项目中可能不是主仓库），
    /// 此时 `onOpenDiff` 打开该仓库中的提交 Diff。
    func showHistory(path: String, in repository: ProjectModel? = nil, onOpenDiff: ((String, String?, ChangedFile) -> Void)? = nil) {
        historyView?.removeFromSuperview()
        let view = FileHistoryView(model: repository ?? model, path: path)
        view.onOpenDiff = onOpenDiff ?? onShowCommitDiff
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: logView.topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        historyView = view
        let title = tr("git.tab.history", (path as NSString).lastPathComponent)
        if tabs.segmentCount <= Self.historyTab { tabs.segmentCount = Self.historyTab + 1 }
        tabs.setLabel(title, forSegment: Self.historyTab)
        tabs.setWidth(0, forSegment: Self.historyTab)
        tabs.selectedSegment = Self.historyTab
        closeHistoryButton.isHidden = false
        tabChanged()
    }

    @objc private func closeHistory() {
        historyView?.removeFromSuperview()
        historyView = nil
        tabs.segmentCount = Self.historyTab
        tabs.selectedSegment = 0
        closeHistoryButton.isHidden = true
        tabChanged()
    }
}
