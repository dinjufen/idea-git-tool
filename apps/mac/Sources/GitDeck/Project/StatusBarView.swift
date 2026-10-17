import AppKit

/// 底部状态栏：左侧为导航路径或消息，右侧为编辑器信息（行列、换行符、编码）。
final class StatusBarView: ColoredView {
    static let height: CGFloat = 26

    private let messageLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let editorInfoLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let spinner = NSProgressIndicator()

    init() {
        super.init(Theme.toolWindowBackground)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let top = SeparatorLine(.horizontal)
        for view in [top, messageLabel, editorInfoLabel, spinner] as [NSView] { addSubview(view) }
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(lessThanOrEqualTo: editorInfoLabel.leadingAnchor, constant: -12),
            editorInfoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            editorInfoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setMessage(_ text: String, isError: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? Theme.FileStatus.conflict : Theme.secondaryText
        messageLabel.toolTip = text
    }

    func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func setEditorInfo(_ text: String) {
        editorInfoLabel.stringValue = text
    }
}
