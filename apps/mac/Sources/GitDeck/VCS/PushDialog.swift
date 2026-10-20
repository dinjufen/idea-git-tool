import AppKit
import GitDeckCore

/// IDEA 的 Push 对话框：显示 “本地分支 → 远程 : 目标分支” 与待推送的提交，可选推送标签与强制推送。
@MainActor
final class PushDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let target: PushTarget
    private let remotes: [String]
    private let panel: NSPanel
    private let remotePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let branchField = NSTextField()
    private let tagsCheckbox = NSButton(checkboxWithTitle: tr("push.tags"), target: nil, action: nil)
    private let upstreamCheckbox = NSButton(checkboxWithTitle: tr("push.setUpstream"), target: nil, action: nil)
    private let pushButton = NSButton(title: tr("push.push"), target: nil, action: nil)
    private let forceButton = NSButton(title: tr("push.force"), target: nil, action: nil)
    private var completion: ((PushOptions) -> Void)?
    private var parent: NSWindow?
    private var retainSelf: PushDialog?

    init(target: PushTarget, remotes: [String], projectName: String) {
        self.target = target
        self.remotes = remotes
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = tr("push.title", projectName)
        panel.minSize = NSSize(width: 480, height: 320)
        buildContent()
    }

    func begin(for window: NSWindow?, completion: @escaping (PushOptions) -> Void) {
        self.completion = completion
        retainSelf = self
        parent = window
        if let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func buildContent() {
        guard let content = panel.contentView else { return }

        // 第一行：main → origin : main
        let local = NSTextField.label(target.localBranch, font: Theme.font(ofSize: 13, weight: .semibold))
        let arrow = NSTextField.label("→", color: Theme.secondaryText)
        for remote in remotes { remotePopup.addItem(withTitle: remote) }
        if let remote = target.remote { remotePopup.selectItem(withTitle: remote) }
        remotePopup.isEnabled = remotes.count > 1
        let colon = NSTextField.label(":", color: Theme.secondaryText)
        branchField.stringValue = target.remoteBranch
        branchField.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [local, arrow, remotePopup, colon, branchField])
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        for (id, width) in [("subject", 300.0), ("author", 110.0), ("date", 130.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            column.resizingMask = id == "subject" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        // 标题列吸收多余宽度，作者与日期列保持完整显示。
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let summary = NSTextField.label(summaryText, font: Theme.smallFont, color: Theme.secondaryText)

        // 没有上游的新分支默认设置上游（IDEA 推送新分支时同样会建立跟踪关系）。
        upstreamCheckbox.state = target.hasUpstream ? .off : .on
        upstreamCheckbox.isHidden = target.hasUpstream

        let cancel = NSButton(title: tr("common.cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        forceButton.target = self
        forceButton.action = #selector(forcePush)
        pushButton.target = self
        pushButton.action = #selector(push)
        pushButton.keyEquivalent = "\r"
        let canPush = target.remote != nil
        pushButton.isEnabled = canPush
        forceButton.isEnabled = canPush && target.hasUpstream

        let options = NSStackView(views: [tagsCheckbox, upstreamCheckbox])
        options.spacing = 16
        let buttons = NSStackView(views: [options, NSView(), cancel, forceButton, pushButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, scroll, summary, buttons] as [NSView] { content.addSubview(view) }
        summary.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            branchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            summary.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private var summaryText: String {
        if target.remote == nil { return tr("push.noRemote") }
        switch target.commits.count {
        case 0: return tr("push.noCommits")
        case 1: return tr("push.oneCommit")
        default: return tr("push.commits", "\(target.commits.count)")
        }
    }

    private func options(force: Bool) -> PushOptions? {
        guard let remote = remotePopup.titleOfSelectedItem else { return nil }
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return nil }
        return PushOptions(
            localBranch: target.localBranch,
            remote: remote,
            remoteBranch: branch,
            force: force,
            pushTags: tagsCheckbox.state == .on,
            setUpstream: upstreamCheckbox.state == .on
        )
    }

    private func close() {
        if let parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        retainSelf = nil
    }

    @objc private func cancel() {
        close()
    }

    @objc private func push() {
        guard let options = options(force: false) else { return NSSound.beep() }
        close()
        completion?(options)
    }

    /// 强制推送前确认（IDEA 同样会提示覆盖远程提交的风险）。
    @objc private func forcePush() {
        guard let options = options(force: true) else { return NSSound.beep() }
        let alert = AppAlert()
        alert.alertStyle = .critical
        alert.messageText = tr("push.force.confirm.title")
        alert.informativeText = tr("push.force.confirm.message", "\(options.remote)/\(options.remoteBranch)")
        alert.addButton(withTitle: tr("push.force"))
        alert.addButton(withTitle: tr("common.cancel"))
        alert.beginSheetModal(for: panel) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            close()
            completion?(options)
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { target.commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let commit = target.commits[row]
        let text: String
        let color: NSColor
        switch tableColumn?.identifier.rawValue {
        case "subject": (text, color) = (commit.subject, Theme.text)
        case "author": (text, color) = (commit.authorName, Theme.secondaryText)
        default: (text, color) = (LogDateFormatter.short(commit.authorTime), Theme.secondaryText)
        }
        let label = NSTextField.label(text, color: color)
        let cell = NSTableCellView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
