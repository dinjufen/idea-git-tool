import AppKit

/// 新建 / 编辑 Changelist：名称（不能与已有列表重名）与说明（IDEA 用作该列表的默认提交信息）。
@MainActor
final class ChangelistDialog: NSObject, NSTextFieldDelegate {
    private let alert = AppAlert()
    private let nameField = NSTextField()
    private let commentView = NSTextView()
    private let errorLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.FileStatus.conflict)
    private let existing: Set<String>
    private var retainSelf: ChangelistDialog?

    init(title: String, confirmTitle: String, name: String, comment: String, existing: Set<String>) {
        self.existing = existing
        super.init()
        alert.messageText = title
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: tr("common.cancel"))

        nameField.stringValue = name
        nameField.placeholderString = tr("changelist.dialog.name")
        nameField.delegate = self
        commentView.string = comment
        commentView.font = Theme.uiFont
        commentView.isRichText = false
        commentView.textContainerInset = NSSize(width: 4, height: 4)
        commentView.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 72))
        scroll.documentView = commentView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        commentView.frame = NSRect(x: 0, y: 0, width: 336, height: 72)

        let commentLabel = NSTextField.label(tr("changelist.dialog.comment"), font: Theme.smallFont, color: Theme.secondaryText)
        let stack = NSStackView(views: [nameField, errorLabel, commentLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 150)
        nameField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField
        revalidate()
    }

    func begin(for window: NSWindow?, completion: @escaping (_ name: String, _ comment: String) -> Void) {
        retainSelf = self
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            retainSelf = nil
            guard response == .alertFirstButtonReturn else { return }
            completion(nameField.stringValue.trimmingCharacters(in: .whitespaces), commentView.string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    func controlTextDidChange(_ obj: Notification) { revalidate() }

    private func revalidate() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let duplicate = existing.contains(name)
        errorLabel.stringValue = duplicate ? tr("changelist.exists", name) : ""
        alert.buttons.first?.isEnabled = !name.isEmpty && !duplicate
    }
}
