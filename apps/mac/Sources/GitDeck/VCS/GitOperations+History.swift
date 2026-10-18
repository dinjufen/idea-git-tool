import AppKit
import GitDeckCore

/// 提交级操作（Log 右键菜单）与标签操作。
extension GitOperations {
    // MARK: - Cherry-pick / Revert

    /// 拣选提交；`hashes` 按从旧到新的顺序应用。
    func cherryPick(_ hashes: [String]) {
        run(tr("ops.progress.cherryPick"), { repo in try repo.cherryPick(hashes: hashes) }) { [self] result in
            report(result, operation: tr("ops.cherryPick.name"), failure: tr("ops.cherryPick.failed"))
        }
    }

    func continueCherryPick() {
        run(tr("ops.progress.cherryPick"), { repo in try repo.continueCherryPick() }) { [self] result in
            report(result, operation: tr("ops.cherryPick.name"), failure: tr("ops.cherryPick.failed"))
        }
    }

    func abortCherryPick() {
        run(tr("ops.progress.abort"), { repo in try repo.abortCherryPick() }) { [self] result in
            if case let .failure(error) = result { showError(tr("ops.abort.failed"), error) } else { model.post(tr("ops.abort.cherryPickDone")) }
        }
    }

    /// 还原提交；`hashes` 按从新到旧的顺序还原。
    func revert(_ hashes: [String]) {
        run(tr("ops.progress.revert"), { repo in try repo.revertCommits(hashes: hashes) }) { [self] result in
            report(result, operation: tr("ops.revert.name"), failure: tr("ops.revert.failed"))
        }
    }

    func continueRevert() {
        run(tr("ops.progress.revert"), { repo in try repo.continueRevert() }) { [self] result in
            report(result, operation: tr("ops.revert.name"), failure: tr("ops.revert.failed"))
        }
    }

    func abortRevert() {
        run(tr("ops.progress.abort"), { repo in try repo.abortRevert() }) { [self] result in
            if case let .failure(error) = result { showError(tr("ops.abort.failed"), error) } else { model.post(tr("ops.abort.revertDone")) }
        }
    }

    // MARK: - Reset / Undo / Edit / Drop

    /// IDEA 的 “Git Reset” 对话框：选择 Soft / Mixed / Hard / Keep。
    func resetDialog(to hash: String, subject: String) {
        let alert = NSAlert()
        alert.messageText = tr("reset.title", model.currentBranchTitle, String(hash.prefix(8)))
        alert.informativeText = subject
        let modes: [(ResetMode, String, String)] = [
            (.soft, tr("reset.soft"), tr("reset.soft.help")),
            (.mixed, tr("reset.mixed"), tr("reset.mixed.help")),
            (.hard, tr("reset.hard"), tr("reset.hard.help")),
            (.keep, tr("reset.keep"), tr("reset.keep.help")),
        ]
        var buttons: [NSButton] = []
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for (_, title, help) in modes {
            let radio = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
            buttons.append(radio)
            let helpLabel = NSTextField.label(help, font: Theme.smallFont, color: Theme.secondaryText)
            helpLabel.translatesAutoresizingMaskIntoConstraints = true
            stack.addArrangedSubview(radio)
            stack.addArrangedSubview(helpLabel)
        }
        let group = RadioGroup(buttons)
        buttons[1].state = .on
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 160)
        alert.accessoryView = stack
        alert.addButton(withTitle: tr("reset.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            withExtendedLifetime(group) {}
            guard response == .alertFirstButtonReturn,
                  let index = buttons.firstIndex(where: { $0.state == .on }) else { return }
            let mode = modes[index].0
            run(tr("ops.progress.reset"), { repo in try repo.resetTo(revision: hash, mode: mode) }) { [self] result in
                switch result {
                case .success: model.post(tr("reset.done", String(hash.prefix(8))))
                case let .failure(error): showError(tr("reset.failed"), error)
                }
            }
        }
    }

    /// 撤销最近一次提交（改动回到暂存区）；已推送时先确认。
    func undoCommit(_ hash: String) {
        warnIfPushed([hash]) { [self] in
            run(tr("ops.progress.undo"), { repo in try repo.undoLastCommit() }) { [self] result in
                switch result {
                case .success: model.post(tr("undo.done"))
                case let .failure(error): showError(tr("undo.failed"), error)
                }
            }
        }
    }

    /// IDEA 的 “Edit Commit Message”：多行编辑框，已推送时先确认。
    func editMessage(_ hash: String, current: String) {
        let alert = NSAlert()
        alert.messageText = tr("editMessage.title", String(hash.prefix(8)))
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as! NSTextView
        textView.string = current
        textView.font = Theme.uiFont
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView
        alert.addButton(withTitle: tr("editMessage.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let message = textView.string
            guard message.trimmingCharacters(in: .whitespacesAndNewlines) != current.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            warnIfPushed([hash]) { [self] in
                run(tr("ops.progress.editMessage"), { repo in try repo.editCommitMessage(hash: hash, message: message) }) { [self] result in
                    report(result, operation: tr("editMessage.name"), failure: tr("editMessage.failed"))
                }
            }
        }
    }

    func dropCommits(_ hashes: [String]) {
        confirm(tr("drop.title", "\(hashes.count)"), tr("drop.message"), confirm: tr("drop.confirm")) { [self] in
            warnIfPushed(hashes) { [self] in
                run(tr("ops.progress.drop"), { repo in try repo.dropCommits(hashes: hashes) }) { [self] result in
                    report(result, operation: tr("drop.name"), failure: tr("drop.failed"))
                }
            }
        }
    }

    // MARK: - 交互式变基

    /// IDEA 的 “Interactively Rebase from Here”：读取候选提交后打开编辑对话框。
    func interactiveRebase(from hash: String) {
        let repository = model.repository
        Task {
            let result = await Task.detached { Result { try repository.rebaseCommits(from: hash) } }.value
            switch result {
            case let .success(commits):
                InteractiveRebaseDialog(commits: commits, branch: model.currentBranchTitle).begin(for: window) { [self] steps in
                    warnIfPushed(commits.map(\.hash)) { [self] in
                        run(tr("ops.progress.rebase", model.currentBranchTitle, String(hash.prefix(8))), { repo in
                            try repo.interactiveRebase(from: hash, steps: steps)
                        }) { [self] result in
                            report(result, operation: tr("ops.rebase.name"), failure: tr("ops.rebase.failed"))
                        }
                    }
                }
            case let .failure(error):
                showError(tr("ops.rebase.failed"), error)
            }
        }
    }

    /// 改写已推送到远程的提交前提醒（IDEA 同样会警告改写已推送的历史）。
    private func warnIfPushed(_ hashes: [String], then action: @escaping () -> Void) {
        let repository = model.repository
        Task {
            let pushed = await Task.detached {
                hashes.contains { (try? repository.isPushed(hash: $0)) == true }
            }.value
            guard pushed else { return action() }
            confirm(tr("pushedWarning.title"), tr("pushedWarning.message"), confirm: tr("pushedWarning.confirm"), action: action)
        }
    }

    // MARK: - 标签

    /// IDEA 的 “Create New Tag” 对话框：名称 + 可选说明（填写说明则创建附注标签）。
    func newTag(at target: String?) {
        let existing = Set(model.tags.map(\.name))
        let alert = NSAlert()
        alert.messageText = tr("tag.new.title")
        alert.informativeText = target.map { tr("tag.new.on", String($0.prefix(8))) } ?? tr("tag.new.onHead")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        name.placeholderString = tr("tag.new.name")
        let message = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        message.placeholderString = tr("tag.new.message")
        let stack = NSStackView(views: [name, message])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        alert.addButton(withTitle: tr("tag.new.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let tagName = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !existing.contains(tagName) else {
                return showError(tr("tag.new.failed"), CoreError.InvalidTagName(name: tagName))
            }
            let text = message.stringValue.trimmingCharacters(in: .whitespaces)
            run(tr("ops.progress.tag", tagName), { repo in
                try repo.createTag(name: tagName, target: target, message: text.isEmpty ? nil : text)
            }) { [self] result in
                switch result {
                case .success: model.post(tr("tag.new.done", tagName))
                case let .failure(error): showError(tr("tag.new.failed"), error)
                }
            }
        }
    }

    func deleteTag(_ name: String) {
        confirm(tr("tag.delete.title", name), tr("tag.delete.message"), confirm: tr("tag.delete.confirm")) { [self] in
            run(tr("ops.progress.tag", name), { repo in try repo.deleteTag(name: name) }) { [self] result in
                switch result {
                case .success: model.post(tr("tag.delete.done", name))
                case let .failure(error): showError(tr("tag.delete.failed"), error)
                }
            }
        }
    }

    /// 推送标签到默认远程（origin，没有则第一个远程）。
    func pushTag(_ name: String) {
        let repository = model.repository
        Task {
            let remotes = await Task.detached { (try? repository.remotes()) ?? [] }.value
            guard let remote = remotes.first(where: { $0.name == "origin" }) ?? remotes.first else {
                let alert = NSAlert()
                alert.messageText = tr("tag.push.failed")
                alert.informativeText = tr("push.noRemote")
                return present(alert)
            }
            run(tr("ops.progress.push", "\(remote.name)/\(name)"), { repo in
                try repo.pushTag(remote: remote.name, name: name)
            }) { [self] result in
                switch result {
                case .success: model.post(tr("tag.push.done", name, remote.name))
                case let .failure(error): showError(tr("tag.push.failed"), error)
                }
            }
        }
    }
}
