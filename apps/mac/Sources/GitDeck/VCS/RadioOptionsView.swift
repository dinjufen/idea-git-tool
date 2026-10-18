import AppKit

/// 对话框中的一组单选项：每项为简短的标题加一段可换行的说明（对齐在单选按钮文字下方）。
///
/// 系统提示框（NSAlert）较窄，长标题的单选按钮会被截断；把说明放到标题下方并按宽度换行即可完整显示。
@MainActor
final class RadioOptionsView: NSStackView {
    private(set) var buttons: [NSButton] = []
    private var group: RadioGroup?

    /// - Parameters:
    ///   - options: 每项的标题与说明（说明可为空）。
    ///   - selected: 初始选中项。
    ///   - width: 视图宽度；说明文字按此宽度换行。
    init(options: [(title: String, detail: String?)], selected: Int, width: CGFloat = 260) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        for (index, option) in options.enumerated() {
            let radio = NSButton(radioButtonWithTitle: option.title, target: nil, action: nil)
            radio.state = index == selected ? .on : .off
            buttons.append(radio)
            var views: [NSView] = [radio]
            if let detail = option.detail, !detail.isEmpty {
                let label = NSTextField(wrappingLabelWithString: detail)
                label.font = Theme.smallFont
                label.textColor = Theme.secondaryText
                label.preferredMaxLayoutWidth = width - 20
                // 说明与单选按钮的文字左对齐。
                let indented = NSStackView(views: [label])
                indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                views.append(indented)
            }
            let item = NSStackView(views: views)
            item.orientation = .vertical
            item.alignment = .leading
            item.spacing = 1
            addArrangedSubview(item)
        }
        group = RadioGroup(buttons)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        frame = NSRect(origin: .zero, size: NSSize(width: width, height: fittingSize.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var selectedIndex: Int? { buttons.firstIndex { $0.state == .on } }
}
