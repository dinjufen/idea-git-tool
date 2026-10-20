import AppKit
import GitDeckCore

/// IDEA 的 “Get from Version Control”：输入仓库地址与本地目录，克隆后打开项目。
@MainActor
final class CloneDialog: NSObject, NSTextFieldDelegate {
    private let alert = AppAlert()
    private let urlField = NSTextField()
    private let directoryField = NSTextField()
    private let errorLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.FileStatus.conflict)
    private var retainSelf: CloneDialog?
    /// 用户手动修改过目录后不再随地址自动更新。
    private var directoryEdited = false

    private static let parentKey = "clone.parentDirectory"

    private static var defaultParent: String {
        UserDefaults.standard.string(forKey: parentKey)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    override init() {
        super.init()
        alert.messageText = tr("clone.title")
        alert.addButton(withTitle: tr("clone.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))

        urlField.placeholderString = "https://github.com/user/repo.git"
        urlField.delegate = self
        directoryField.delegate = self
        directoryField.stringValue = Self.defaultParent
        let browse = NSButton(title: tr("clone.browse"), target: self, action: #selector(browse))
        browse.bezelStyle = .push
        let directoryRow = NSStackView(views: [directoryField, browse])
        directoryRow.spacing = 6

        let grid = NSGridView(views: [
            [NSTextField.label(tr("clone.url")), urlField],
            [NSTextField.label(tr("clone.directory")), directoryRow],
            [NSGridCell.emptyContentView, errorLabel],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        urlField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        directoryField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 470, height: 84)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = urlField
        if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.looksLikeRepositoryURL(pasted) {
            // 与 IDEA 一致：剪贴板中是仓库地址时自动填入。
            urlField.stringValue = pasted
            updateDirectory()
        }
        revalidate()
    }

    private static func looksLikeRepositoryURL(_ text: String) -> Bool {
        !text.contains("\n") && (text.hasPrefix("https://") || text.hasPrefix("http://") || text.hasPrefix("ssh://")
            || text.hasPrefix("git@") || text.hasSuffix(".git"))
    }

    func begin(for window: NSWindow?, completion: @escaping (_ url: String, _ directory: String) -> Void) {
        retainSelf = self
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            retainSelf = nil
            guard response == .alertFirstButtonReturn else { return }
            let directory = (directoryField.stringValue as NSString).expandingTildeInPath
            UserDefaults.standard.set((directory as NSString).deletingLastPathComponent, forKey: Self.parentKey)
            completion(urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), directory)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("clone.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = cloneDirectoryName(url: urlField.stringValue)
        directoryField.stringValue = urlField.stringValue.isEmpty ? url.path : url.appendingPathComponent(name).path
        directoryEdited = true
        revalidate()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === directoryField {
            directoryEdited = true
        } else if !directoryEdited {
            updateDirectory()
        }
        revalidate()
    }

    /// 目录 = 上次使用的父目录 + 从地址推断的名称。
    private func updateDirectory() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        directoryField.stringValue = url.isEmpty
            ? Self.defaultParent
            : (Self.defaultParent as NSString).appendingPathComponent(cloneDirectoryName(url: url))
    }

    private func revalidate() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (directoryField.stringValue as NSString).expandingTildeInPath
        var error: String?
        var isDirectory: ObjCBool = false
        if !url.isEmpty, FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            let empty = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.isEmpty ?? false
            if !isDirectory.boolValue || !empty { error = tr("clone.error.exists") }
        }
        errorLabel.stringValue = error ?? ""
        alert.buttons.first?.isEnabled = !url.isEmpty && !directory.isEmpty && error == nil
    }
}

/// 克隆进度窗口（不确定进度的转圈 + 仓库地址）。
@MainActor
final class CloneProgressWindow {
    private let panel: NSPanel

    init(url: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = tr("clone.title")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField.label(tr("clone.progress", url))
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            ])
        }
    }

    func show(over window: NSWindow?) {
        if let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
    }
}
