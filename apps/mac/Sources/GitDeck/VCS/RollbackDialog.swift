import AppKit
import GitDeckCore

/// IDEA 的 “Rollback Changes” 对话框：勾选要回滚的文件，可选择是否删除新增文件的本地副本。
@MainActor
final class RollbackDialog: NSObject {
    private let alert = AppAlert()
    private let changes: [FileChange]
    private var checkboxes: [NSButton] = []
    private let deleteAdded = NSButton(checkboxWithTitle: tr("rollback.deleteAdded"), target: nil, action: nil)
    private var retainSelf: RollbackDialog?

    /// - Parameters:
    ///   - changes: 可回滚的改动（已跟踪文件）。
    ///   - selected: 初始勾选的路径；为空时全部勾选。
    init(changes: [FileChange], selected: Set<String>) {
        self.changes = changes
        super.init()
        alert.messageText = tr("rollback.title")
        alert.informativeText = tr("rollback.message")
        alert.addButton(withTitle: tr("rollback.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        for change in changes {
            let title = change.path + "  " + Self.kindTitle(change)
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggled))
            box.state = selected.isEmpty || selected.contains(change.path) ? .on : .off
            box.lineBreakMode = .byTruncatingMiddle
            box.toolTip = change.path
            checkboxes.append(box)
            list.addArrangedSubview(box)
        }
        let document = FlippedView()
        document.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(220, CGFloat(changes.count) * 22 + 8)))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.frame = NSRect(x: 0, y: 0, width: 400, height: CGFloat(changes.count) * 22 + 8)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            list.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -6),
        ])

        let hasAdded = changes.contains(where: Self.isAdded)
        deleteAdded.state = .off
        deleteAdded.isHidden = !hasAdded
        let container = NSStackView(views: [scroll, deleteAdded])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.frame = NSRect(x: 0, y: 0, width: 420, height: scroll.frame.height + (hasAdded ? 30 : 0))
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true
        alert.accessoryView = container
        toggled()
    }

    static func isAdded(_ change: FileChange) -> Bool {
        change.staged == .added || change.staged == .renamed || change.staged == .copied
    }

    private static func kindTitle(_ change: FileChange) -> String {
        if isAdded(change) { return tr("rollback.kind.added") }
        if change.isDeleted { return tr("rollback.kind.deleted") }
        return ""
    }

    @objc private func toggled() {
        alert.buttons.first?.isEnabled = checkboxes.contains { $0.state == .on }
    }

    func begin(for window: NSWindow?, completion: @escaping (_ paths: [String], _ deleteAdded: Bool) -> Void) {
        retainSelf = self
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            retainSelf = nil
            guard response == .alertFirstButtonReturn else { return }
            let paths = zip(changes, checkboxes).filter { $0.1.state == .on }.map(\.0.path)
            completion(paths, deleteAdded.state == .on)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

/// 自上而下排列内容的容器（滚动视图中的列表）。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
