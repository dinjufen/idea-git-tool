import AppKit

/// 工具窗口标识。顺序与 IDEA 默认布局一致。
enum ToolWindowID: String, CaseIterable {
    case project
    case commit
    case git
    case aiReview

    var title: String {
        switch self {
        case .project: tr("toolwindow.project")
        case .commit: tr("toolwindow.commit")
        case .git: tr("toolwindow.git")
        case .aiReview: tr("toolwindow.aiReview")
        }
    }

    var symbol: String {
        switch self {
        case .project: "folder"
        case .commit: "checkmark.circle"
        case .git: "arrow.triangle.branch"
        case .aiReview: "sparkles"
        }
    }

    /// 工具窗口停靠位置：Project / Commit 在左侧面板，Git 在底部面板，AI Review 在右侧面板。
    var anchor: Anchor {
        switch self {
        case .project, .commit: .left
        case .git: .bottom
        case .aiReview: .right
        }
    }

    enum Anchor { case left, bottom, right }
}

/// 窗口侧边的工具窗口图标条。左侧图标条：上半部分为左侧面板，下半部分为底部面板；右侧图标条对应右侧面板。
final class ToolWindowStripe: ColoredView {
    static let width: CGFloat = 40

    var onToggle: ((ToolWindowID) -> Void)?
    private var buttons: [ToolWindowID: IconButton] = [:]
    private var bottomStack: NSStackView?

    init(top: [ToolWindowID], bottom: [ToolWindowID]) {
        super.init(Theme.toolWindowBackground)
        translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView(views: top.map(makeButton))
        let bottomStack = NSStackView(views: bottom.map(makeButton))
        for stack in [topStack, bottomStack] {
            stack.orientation = .vertical
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        self.bottomStack = bottomStack
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            topStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            topStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            bottomStack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    /// 在图标条最下方加一个按钮（左下角的设置入口）。
    func addFooterButton(_ button: IconButton) {
        bottomStack?.addArrangedSubview(button)
    }

    func setActive(_ ids: Set<ToolWindowID>) {
        for (id, button) in buttons {
            button.isSelected = ids.contains(id)
        }
    }

    private func makeButton(_ id: ToolWindowID) -> IconButton {
        let button = IconButton(symbol: id.symbol, tooltip: id.title)
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        buttons[id] = button
        return button
    }

    @objc private func buttonClicked(_ sender: IconButton) {
        guard let raw = sender.identifier?.rawValue, let id = ToolWindowID(rawValue: raw) else { return }
        onToggle?(id)
    }
}
