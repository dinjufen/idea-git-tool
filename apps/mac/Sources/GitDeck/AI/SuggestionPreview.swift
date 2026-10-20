import AppKit

/// 应用 AI 修改建议前的 Diff 预览（表单）：用户确认后才写入文件。
@MainActor
enum SuggestionPreview {
    static func present(on window: NSWindow, path: String, title: String, before: String, after: String, onApply: @escaping @MainActor () -> Void) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.minSize = NSSize(width: 640, height: 400)
        let content = ColoredView(Theme.toolWindowBackground)
        sheet.contentView = content

        let heading = NSTextField.label(tr("ai.apply.title", (path as NSString).lastPathComponent), font: Theme.font(ofSize: 13, weight: .semibold))
        let subtitle = NSTextField.label(title, font: Theme.smallFont, color: Theme.secondaryText)
        let diff = DiffView(
            left: DiffSide(title: tr("ai.apply.before"), text: before),
            right: DiffSide(title: tr("ai.apply.after"), text: after),
            path: path
        )
        diff.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: tr("common.cancel"), target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: tr("ai.apply.confirm"), target: nil, action: nil)
        apply.keyEquivalent = "\r"
        let cancelAction = MenuAction { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet, returnCode: .cancel) }
        }
        let applyAction = MenuAction { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet, returnCode: .OK) }
        }
        cancel.target = cancelAction
        cancel.action = #selector(MenuAction.invoke)
        apply.target = applyAction
        apply.action = #selector(MenuAction.invoke)
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.spacing = 8
        let header = NSStackView(views: [heading, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        for view in [header, diff, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            diff.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            diff.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            diff.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: diff.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        // 按钮动作对象需在表单显示期间保持存活。
        objc_setAssociatedObject(sheet, &actionsKey, [cancelAction, applyAction], .OBJC_ASSOCIATION_RETAIN)
        window.beginSheet(sheet) { response in
            if response == .OK { onApply() }
        }
    }

    nonisolated(unsafe) private static var actionsKey: UInt8 = 0
}
