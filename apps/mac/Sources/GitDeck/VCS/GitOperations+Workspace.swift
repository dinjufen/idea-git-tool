import AppKit
import GitDeckCore
import UniformTypeIdentifiers

/// 工作树、远程、子模块与补丁操作。
extension GitOperations {
    // MARK: - 工作树

    /// IDEA 的 “New Worktree” 对话框：分支（已有分支直接检出，新名称则从 HEAD 新建）与位置。
    func newWorktree() {
        let localBranches = model.branches.filter { $0.kind == .local }.map(\.name)
        let alert = NSAlert()
        alert.messageText = tr("worktree.new.title")
        alert.informativeText = tr("worktree.new.message")
        let branch = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        branch.addItems(withObjectValues: localBranches)
        branch.placeholderString = tr("worktree.new.branch")
        branch.completes = true
        let location = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        location.placeholderString = tr("worktree.new.location")
        let stack = NSStackView(views: [branch, location])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = branch
        alert.addButton(withTitle: tr("worktree.new.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = branch.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            // 默认放在仓库旁边：<父目录>/<仓库名>-<分支名>。
            let defaultPath = model.rootURL.deletingLastPathComponent()
                .appendingPathComponent("\(model.projectName)-\(name.replacingOccurrences(of: "/", with: "-"))").path
            let path = location.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
                ? defaultPath
                : (location.stringValue as NSString).expandingTildeInPath
            let existing = localBranches.contains(name)
            run(tr("ops.progress.worktree"), { repo in
                try repo.addWorktree(path: path, branch: existing ? name : nil, newBranch: existing ? nil : name, startPoint: nil)
            }) { [self] result in
                switch result {
                case .success: model.post(tr("worktree.new.done", path))
                case let .failure(error): showError(tr("worktree.new.failed"), error)
                }
            }
        }
    }

    func removeWorktree(_ worktree: Worktree, force: Bool = false, completion: @escaping () -> Void) {
        let perform = { [self] in
            run(tr("ops.progress.worktree"), { repo in try repo.removeWorktree(path: worktree.path, force: force) }) { [self] result in
                switch result {
                case .success:
                    model.post(tr("worktree.remove.done", worktree.path))
                    completion()
                case let .failure(CoreError.CommandFailed(_, _, stderr)) where !force && stderr.contains("modified or untracked"):
                    // 工作树中有未提交的改动：再次确认后强制删除。
                    confirm(tr("worktree.remove.dirty.title"), tr("worktree.remove.dirty.message"), confirm: tr("worktree.remove.force")) { [self] in
                        removeWorktree(worktree, force: true, completion: completion)
                    }
                case let .failure(error):
                    showError(tr("worktree.remove.failed"), error)
                }
            }
        }
        if force { return perform() }
        confirm(tr("worktree.remove.title"), worktree.path, confirm: tr("worktree.remove")) { perform() }
    }

    // MARK: - 远程

    /// 新建或编辑远程：`existing` 为空时新建。
    func editRemote(_ existing: Remote?, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? tr("remotes.add.title") : tr("remotes.edit.title", existing!.name)
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        name.placeholderString = tr("remotes.name")
        name.stringValue = existing?.name ?? (model.branches.contains { $0.remote == "origin" } ? "" : "origin")
        let url = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        url.placeholderString = tr("remotes.url")
        url.stringValue = existing?.url ?? ""
        let stack = NSStackView(views: [name, url])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = existing == nil ? name : url
        alert.addButton(withTitle: tr("remotes.save"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            let newName = name.stringValue.trimmingCharacters(in: .whitespaces)
            let newURL = url.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !newName.isEmpty, !newURL.isEmpty else { return }
            run(tr("ops.progress.remotes"), { repo in
                if let existing {
                    if existing.name != newName { try repo.renameRemote(oldName: existing.name, newName: newName) }
                    if existing.url != newURL { try repo.setRemoteUrl(name: newName, url: newURL) }
                } else {
                    try repo.addRemote(name: newName, url: newURL)
                }
            }) { [self] result in
                if case let .failure(error) = result { showError(tr("remotes.failed"), error) }
                completion()
            }
        }
    }

    func removeRemote(_ remote: Remote, completion: @escaping () -> Void) {
        confirm(tr("remotes.remove.title", remote.name), remote.url, confirm: tr("remotes.remove")) { [self] in
            run(tr("ops.progress.remotes"), { repo in try repo.removeRemote(name: remote.name) }) { [self] result in
                if case let .failure(error) = result { showError(tr("remotes.failed"), error) }
                completion()
            }
        }
    }

    func manageRemotes() {
        RemotesDialog(model: model, operations: self).begin(for: window)
    }

    // MARK: - 子模块

    func manageSubmodules() {
        SubmodulesDialog(model: model, operations: self).begin(for: window)
    }

    func updateSubmodules(_ paths: [String], completion: @escaping () -> Void) {
        run(tr("ops.progress.submodules"), { repo in try repo.updateSubmodules(paths: paths, recursive: true) }) { [self] result in
            switch result {
            case .success: model.post(tr("submodules.updated"))
            case let .failure(error): showError(tr("submodules.failed"), error)
            }
            completion()
        }
    }

    // MARK: - 补丁

    /// 把本地改动（`paths` 为空时为全部）保存为补丁文件。
    func createPatch(paths: [String]) {
        savePatch(defaultName: "\(model.projectName).patch") { repo in try repo.createPatch(paths: paths) }
    }

    /// 把提交（从旧到新）保存为补丁文件。
    func createPatch(commits hashes: [String]) {
        let name = hashes.count == 1 ? "\(String(hashes[0].prefix(8))).patch" : "\(model.projectName)-\(hashes.count)-commits.patch"
        savePatch(defaultName: name) { repo in try repo.createPatchFromCommits(hashes: hashes) }
    }

    private func savePatch(defaultName: String, make: @escaping @Sendable (Repository) throws -> String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        let handle: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else { return }
            run(tr("ops.progress.patch"), { repo in
                let patch = try make(repo)
                try patch.write(to: url, atomically: true, encoding: .utf8)
                return patch.isEmpty
            }) { [self] result in
                switch result {
                case .success(true): model.post(tr("patch.empty"), isError: true)
                case .success(false): model.post(tr("patch.created", url.lastPathComponent))
                case let .failure(error): showError(tr("patch.failed"), error)
                }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// IDEA 的 “Apply Patch”：选择补丁文件，确认涉及的文件后应用；不能直接应用时用三方合并。
    func applyPatch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText, UTType(filenameExtension: "diff") ?? .plainText, .plainText]
        let repository = model.repository
        let handle: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            let patch = String(decoding: data, as: UTF8.self)
            Task {
                let result = await Task.detached {
                    Result { (try repository.patchFiles(patch: patch), repository.canApplyPatch(patch: patch)) }
                }.value
                switch result {
                case let .success((files, clean)):
                    confirmApply(patch: patch, name: url.lastPathComponent, files: files, clean: clean)
                case let .failure(error):
                    showError(tr("patch.apply.failed"), error)
                }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func confirmApply(patch: String, name: String, files: [PatchFile], clean: Bool) {
        let list = files.prefix(20).map { "\($0.path)  (+\($0.added) −\($0.deleted))" }.joined(separator: "\n")
        let more = files.count > 20 ? "\n…" : ""
        var message = tr("patch.apply.files", "\(files.count)") + "\n\n" + list + more
        if !clean { message += "\n\n" + tr("patch.apply.threeWay") }
        confirm(tr("patch.apply.title", name), message, confirm: tr("patch.apply.confirm")) { [self] in
            run(tr("ops.progress.patch"), { repo in try repo.applyPatch(patch: patch, threeWay: true) }) { [self] result in
                switch result {
                case let .success(outcome) where outcome.conflicts: showConflicts(tr("patch.apply.name"))
                case .success: model.post(tr("patch.applied", name))
                case let .failure(error): showError(tr("patch.apply.failed"), error)
                }
            }
        }
    }
}

// MARK: - Manage Remotes 对话框

/// IDEA 的 “Git Remotes” 对话框：列表 + 添加 / 编辑 / 删除。
@MainActor
final class RemotesDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let model: ProjectModel
    private let operations: GitOperations
    private let panel: NSPanel
    private let table = NSTableView()
    private var remotes: [Remote] = []
    private weak var parent: NSWindow?
    private var retainSelf: RemotesDialog?

    init(model: ProjectModel, operations: GitOperations) {
        self.model = model
        self.operations = operations
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("remotes.title")
        buildContent()
    }

    func begin(for window: NSWindow?) {
        retainSelf = self
        parent = window
        reload()
        if let window { window.beginSheet(panel) } else { panel.makeKeyAndOrderFront(nil) }
    }

    private func buildContent() {
        guard let content = panel.contentView else { return }
        for (id, width) in [("name", 120.0), ("url", 420.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = id == "name" ? tr("remotes.name") : tr("remotes.url")
            column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: tr("remotes.add"), target: self, action: #selector(addRemote))
        let edit = NSButton(title: tr("remotes.edit"), target: self, action: #selector(editSelected))
        let remove = NSButton(title: tr("remotes.remove"), target: self, action: #selector(removeSelected))
        let done = NSButton(title: tr("conflicts.close"), target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [add, edit, remove, NSView(), done])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func reload() {
        let repository = model.repository
        Task {
            remotes = await Task.detached { (try? repository.remotes()) ?? [] }.value
            table.reloadData()
        }
    }

    private var selected: Remote? { remotes.indices.contains(table.selectedRow) ? remotes[table.selectedRow] : nil }

    // 对话框作为表单显示时，后续的确认框附着在本面板上。
    @objc private func addRemote() { withPanel { $0.editRemote(nil) { [weak self] in self?.reload() } } }
    @objc private func editSelected() { guard let remote = selected else { return }; withPanel { $0.editRemote(remote) { [weak self] in self?.reload() } } }
    @objc private func removeSelected() { guard let remote = selected else { return }; withPanel { $0.removeRemote(remote) { [weak self] in self?.reload() } } }

    private func withPanel(_ action: (GitOperations) -> Void) {
        let original = operations.window
        operations.window = panel
        action(operations)
        operations.window = original
    }

    @objc private func close() {
        if let parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        retainSelf = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { remotes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let remote = remotes[row]
        let isName = tableColumn?.identifier.rawValue == "name"
        let label = NSTextField.label(isName ? remote.name : remote.url, color: isName ? Theme.text : Theme.secondaryText)
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

// MARK: - Submodules 对话框

/// 子模块列表：路径、状态与 URL，可初始化并更新或作为项目打开。
@MainActor
final class SubmodulesDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let model: ProjectModel
    private let operations: GitOperations
    private let panel: NSPanel
    private let table = NSTableView()
    private let emptyLabel = NSTextField.label(tr("submodules.empty"), color: Theme.secondaryText)
    private var submodules: [Submodule] = []
    private weak var parent: NSWindow?
    private var retainSelf: SubmodulesDialog?

    init(model: ProjectModel, operations: GitOperations) {
        self.model = model
        self.operations = operations
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("submodules.title")
        buildContent()
    }

    func begin(for window: NSWindow?) {
        retainSelf = self
        parent = window
        reload()
        if let window { window.beginSheet(panel) } else { panel.makeKeyAndOrderFront(nil) }
    }

    private func buildContent() {
        guard let content = panel.contentView else { return }
        for (id, title, width) in [("path", tr("submodules.path"), 200.0), ("state", tr("submodules.state"), 110.0), ("url", tr("remotes.url"), 280.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let update = NSButton(title: tr("submodules.update"), target: self, action: #selector(updateSelected))
        let open = NSButton(title: tr("submodules.open"), target: self, action: #selector(openSelected))
        let done = NSButton(title: tr("conflicts.close"), target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [update, open, NSView(), done])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, buttons, emptyLabel] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private func reload() {
        let repository = model.repository
        Task {
            submodules = await Task.detached { (try? repository.submodules()) ?? [] }.value
            table.reloadData()
            emptyLabel.isHidden = !submodules.isEmpty
        }
    }

    private var selected: [Submodule] {
        table.selectedRowIndexes.compactMap { submodules.indices.contains($0) ? submodules[$0] : nil }
    }

    /// 更新选中的子模块；未选中时更新全部。
    @objc private func updateSelected() {
        let paths = selected.map(\.path)
        let original = operations.window
        operations.window = panel
        operations.updateSubmodules(paths) { [weak self] in self?.reload() }
        operations.window = original
    }

    @objc private func openSelected() {
        guard let submodule = selected.first, submodule.state != .uninitialized else { return NSSound.beep() }
        (NSApp.delegate as? AppDelegate)?.openProject(at: model.rootURL.appendingPathComponent(submodule.path))
    }

    @objc private func close() {
        if let parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        retainSelf = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { submodules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let submodule = submodules[row]
        let text: String
        var color = Theme.secondaryText
        switch tableColumn?.identifier.rawValue {
        case "path":
            text = submodule.path
            color = Theme.text
        case "state":
            switch submodule.state {
            case .upToDate: text = tr("submodules.state.upToDate")
            case .modified: text = tr("submodules.state.modified"); color = Theme.FileStatus.modified
            case .uninitialized: text = tr("submodules.state.uninitialized"); color = Theme.FileStatus.untracked
            case .conflict: text = tr("submodules.state.conflict"); color = Theme.FileStatus.conflict
            }
        default:
            text = submodule.url ?? ""
        }
        let label = NSTextField.label(text, color: color)
        let cell = NSTableCellView()
        cell.toolTip = "\(submodule.name)  \(String(submodule.head.prefix(8)))"
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
