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

    var onShowHistory: ((String) -> Void)? {
        didSet { logView.onShowHistory = onShowHistory }
    }

    private let tabs = NSSegmentedControl(
        labels: [tr("git.tab.log"), tr("git.tab.console")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let logView: LogView
    private let consolePlaceholder = NSTextField.label(tr("git.console.placeholder"), color: Theme.secondaryText)

    init(model: ProjectModel) {
        self.model = model
        logView = LogView(model: model)
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
        consolePlaceholder.alignment = .center

        closeHistoryButton.target = self
        closeHistoryButton.action = #selector(closeHistory)
        closeHistoryButton.isHidden = true

        let top = SeparatorLine(.horizontal)
        for view in [top, header, tabs, closeHistoryButton, logView, consolePlaceholder] as [NSView] { addSubview(view) }
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
            consolePlaceholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            consolePlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 18),
        ])
        tabChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tabChanged() {
        let selected = tabs.selectedSegment
        logView.isHidden = selected != 0
        consolePlaceholder.isHidden = selected != 1
        historyView?.isHidden = selected != 2
    }

    /// 在 Log 标签页中定位某个提交。
    func reveal(commit hash: String) {
        tabs.selectedSegment = 0
        tabChanged()
        logView.reveal(hash)
    }

    /// 打开（或替换）文件历史标签页。
    func showHistory(path: String) {
        historyView?.removeFromSuperview()
        let view = FileHistoryView(model: model, path: path)
        view.onOpenDiff = onShowCommitDiff
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
        if tabs.segmentCount < 3 { tabs.segmentCount = 3 }
        tabs.setLabel(title, forSegment: 2)
        tabs.setWidth(0, forSegment: 2)
        tabs.selectedSegment = 2
        closeHistoryButton.isHidden = false
        tabChanged()
    }

    @objc private func closeHistory() {
        historyView?.removeFromSuperview()
        historyView = nil
        tabs.segmentCount = 2
        tabs.selectedSegment = 0
        closeHistoryButton.isHidden = true
        tabChanged()
    }
}
