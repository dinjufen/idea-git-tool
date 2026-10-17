import AppKit

/// 底部 Git 工具窗口，包含 Log 与 Console 两个标签页。
final class GitToolWindow: NSView {
    var onOpenFile: ((URL) -> Void)? {
        didSet { logView.onOpenFile = onOpenFile }
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

        let top = SeparatorLine(.horizontal)
        for view in [top, header, tabs, logView, consolePlaceholder] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: top.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabs.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 60),
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
        let showLog = tabs.selectedSegment == 0
        logView.isHidden = !showLog
        consolePlaceholder.isHidden = showLog
    }
}
