import AppKit

/// IDEA New UI 主工具栏：位于窗口标题栏区域，左侧为项目组件与 VCS 分支组件。
final class MainToolbarView: ColoredView {
    static let height: CGFloat = 40
    /// 为左上角红绿灯按钮预留的宽度。
    private static let trafficLightsInset: CGFloat = 78

    let projectWidget = ToolbarWidget(symbol: nil, tooltip: tr("toolbar.project.tooltip"))
    let vcsWidget = ToolbarWidget(symbol: "arrow.triangle.branch", tooltip: tr("toolbar.vcs.tooltip"))
    let refreshButton = IconButton(symbol: "arrow.clockwise", tooltip: tr("git.action.refresh"), size: 28, pointSize: 13)
    let updateButton = IconButton(symbol: "arrow.down.left", tooltip: tr("git.action.update"), size: 28, pointSize: 13)
    let commitButton = IconButton(symbol: "checkmark", tooltip: tr("git.action.commit"), size: 28, pointSize: 13)
    let pushButton = IconButton(symbol: "arrow.up.right", tooltip: tr("git.action.push"), size: 28, pointSize: 13)

    private let badge = ProjectBadge()

    init() {
        super.init(Theme.headerBackground)
        translatesAutoresizingMaskIntoConstraints = false

        let projectStack = NSStackView(views: [badge, projectWidget])
        projectStack.spacing = 0
        let left = NSStackView(views: [projectStack, vcsWidget])
        left.spacing = 4
        let right = NSStackView(views: [updateButton, commitButton, pushButton, refreshButton])
        right.spacing = 2

        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let bottom = SeparatorLine(.horizontal)
        addSubview(bottom)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trafficLightsInset),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setProjectName(_ name: String) {
        projectWidget.title = name
        badge.text = ProjectBadge.initials(of: name)
    }

    // 标题栏区域：空白处可拖动窗口，双击按系统设置缩放或最小化。
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if action == "Minimize" {
            window?.performMiniaturize(nil)
        } else {
            window?.performZoom(nil)
        }
    }
}

/// 项目组件左侧的彩色首字母方块。
final class ProjectBadge: NSView {
    var text = "" {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { "-_ .".contains($0) })
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    override func draw(_ dirtyRect: NSRect) {
        // 颜色由名称决定，同一项目每次显示一致。
        let palette: [UInt32] = [0x3574F0, 0x5FB865, 0xE55765, 0xC77D55, 0x955AE0, 0x2E9E9E]
        let index = text.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % palette.count
        NSColor(hex: palette[index]).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
