import AppKit
import GitDeckCore

/// 主工具栏下方的提示条：检测到项目中有尚未加入的 git 仓库时提示加入（IDEA 的 “Unregistered VCS roots detected”）。
final class WorkspaceBanner: ColoredView {
    var onAdd: (() -> Void)?
    var onIgnore: (() -> Void)?

    private let label = NSTextField.label("")
    private var height: NSLayoutConstraint!

    init() {
        super.init(Theme.dynamic(light: 0xEDF3FF, dark: 0x25324D))
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: tr("workspace.banner.add"), target: self, action: #selector(add))
        let ignore = NSButton(title: tr("workspace.banner.ignore"), target: self, action: #selector(ignore))
        for button in [add, ignore] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        add.keyEquivalent = ""
        let stack = NSStackView(views: [icon, label, NSView(), ignore, add])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = SeparatorLine(.horizontal)
        addSubview(bottom)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        clipsToBounds = true
        isHidden = true
    }

    /// 显示检测到的仓库；为空时隐藏。
    func show(_ candidates: [NestedRepository]) {
        isHidden = candidates.isEmpty
        height.constant = candidates.isEmpty ? 0 : 36
        guard !candidates.isEmpty else { return }
        let names = candidates.prefix(4).map(\.relativePath).joined(separator: ", ")
        let more = candidates.count > 4 ? " …" : ""
        label.stringValue = tr("workspace.banner.message", "\(candidates.count)", names + more)
        label.toolTip = candidates.map(\.relativePath).joined(separator: "\n")
    }

    @objc private func add() { onAdd?() }
    @objc private func ignore() { onIgnore?() }
}
