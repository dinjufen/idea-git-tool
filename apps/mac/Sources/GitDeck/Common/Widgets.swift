import AppKit

/// IDEA New UI 风格的图标按钮：无边框、悬停时出现圆角底色，可切换选中态。
final class IconButton: NSControl {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    var image: NSImage? {
        didSet { imageView.image = image }
    }

    private let imageView = NSImageView()
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    private let size: CGFloat

    init(symbol: String, tooltip: String, size: CGFloat = 30, pointSize: CGFloat = 15) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        imageView.image = image
        imageView.contentTintColor = Theme.text
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { imageView.alphaValue = isEnabled ? 1 : 0.4 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = isSelected ? Theme.selectedStripeButton : (isHovered && isEnabled ? Theme.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// 顶部主工具栏中的下拉组件（项目组件、VCS 分支组件）。
final class ToolbarWidget: NSControl {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(symbol: String?, tooltip: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(tooltip)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = Theme.secondaryText

        let stack = NSStackView(views: [label, chevron])
        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            iconView.contentTintColor = Theme.text
            stack.insertView(iconView, at: 0, in: .leading)
        }
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// 工具窗口标题栏：左侧标题，右侧动作按钮（对应 IDEA 工具窗口的 header）。
final class ToolWindowHeader: ColoredView {
    init(title: String, actions: [IconButton] = []) {
        super.init(Theme.toolWindowBackground)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text

        let stack = NSStackView(views: [label, NSView()] + actions)
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

extension NSTextField {
    static func label(_ text: String, font: NSFont = Theme.uiFont, color: NSColor = Theme.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// 表格单元：所在行被强调选中（蓝底）时，内部文字与图标改为选中前景色，取消选中后恢复原色。
/// 用于文字颜色固定（状态色、次要文字）的表格。
final class AdaptiveCellView: NSTableCellView {
    private var originalColors: [ObjectIdentifier: NSColor] = [:]
    private var originalTints: [ObjectIdentifier: NSColor?] = [:]

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        let selected = backgroundStyle == .emphasized
        for label in descendants(of: NSTextField.self) {
            let id = ObjectIdentifier(label)
            if originalColors[id] == nil { originalColors[id] = label.textColor ?? Theme.text }
            label.textColor = selected ? .alternateSelectedControlTextColor : originalColors[id]
        }
        for image in descendants(of: NSImageView.self) {
            let id = ObjectIdentifier(image)
            if originalTints[id] == nil { originalTints[id] = .some(image.contentTintColor) }
            image.contentTintColor = selected ? .alternateSelectedControlTextColor : originalTints[id] ?? nil
        }
    }

    private func descendants<T: NSView>(of type: T.Type) -> [T] {
        var result: [T] = []
        var stack: [NSView] = subviews
        while let view = stack.popLast() {
            if let match = view as? T { result.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }
}
