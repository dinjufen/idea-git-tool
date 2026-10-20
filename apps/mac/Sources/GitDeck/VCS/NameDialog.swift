import AppKit

/// 输入名称的表单对话框（新建分支、重命名、签出修订等），输入时实时校验，不合法时禁用确定按钮。
@MainActor
final class NameDialog: NSObject, NSTextFieldDelegate {
    struct Result {
        let name: String
        /// 附加复选框的状态（例如 “签出分支”）；没有复选框时为 false。
        let checked: Bool
    }

    private let alert = AppAlert()
    private let field = NSTextField()
    private let checkbox: NSButton?
    private let errorLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.FileStatus.conflict)
    private let validate: (String) -> String?
    /// 对话框显示期间保持自身存活。
    private var retainSelf: NameDialog?

    /// - Parameter validate: 返回错误信息；合法时返回 `nil`。
    init(title: String, message: String?, initial: String, confirmTitle: String,
         checkbox checkboxTitle: String? = nil, checked: Bool = true,
         validate: @escaping (String) -> String?) {
        self.validate = validate
        checkbox = checkboxTitle.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        super.init()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: tr("common.cancel"))

        field.stringValue = initial
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        checkbox?.state = checked ? .on : .off
        let stack = NSStackView(views: [field, errorLabel] + (checkbox.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: checkbox == nil ? 48 : 72)
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        revalidate()
    }

    func begin(for window: NSWindow?, completion: @escaping (Result) -> Void) {
        retainSelf = self
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            retainSelf = nil
            guard response == .alertFirstButtonReturn else { return }
            completion(Result(
                name: field.stringValue.trimmingCharacters(in: .whitespaces),
                checked: checkbox?.state == .on
            ))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        revalidate()
    }

    private func revalidate() {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let error = name.isEmpty ? nil : validate(name)
        errorLabel.stringValue = error ?? ""
        alert.buttons.first?.isEnabled = !name.isEmpty && error == nil
    }
}
