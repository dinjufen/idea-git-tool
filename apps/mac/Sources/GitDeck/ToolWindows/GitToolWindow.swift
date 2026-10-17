import AppKit

/// 底部 Git 工具窗口，包含 Log 与 Console 两个标签页（内容在后续步骤实现）。
final class GitToolWindow: NSView {
    private let tabs = NSSegmentedControl(
        labels: [tr("git.tab.log"), tr("git.tab.console")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let placeholder = NSTextField.label("", color: Theme.secondaryText)

    init() {
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
        placeholder.alignment = .center

        for view in [header, tabs, placeholder] as [NSView] { addSubview(view) }
        let top = SeparatorLine(.horizontal)
        addSubview(top)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: top.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabs.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 60),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 18),
        ])
        tabChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tabChanged() {
        placeholder.stringValue = tabs.selectedSegment == 0 ? tr("git.log.placeholder") : tr("git.console.placeholder")
    }
}
