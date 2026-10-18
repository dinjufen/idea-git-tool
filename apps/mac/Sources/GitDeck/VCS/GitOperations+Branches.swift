import AppKit
import GitDeckCore

/// 分支菜单中的 Checkout and Rebase、Compare with Current、Show Diff with Working Tree、Update 与删除远程分支。
extension GitOperations {
    /// 签出 `branch` 并变基到当前分支上。
    func checkoutAndRebase(_ branch: String) {
        let current = model.currentBranchTitle
        run(tr("ops.progress.checkoutAndRebase", branch, current), { repo in
            try repo.checkoutAndRebase(branch: branch, onto: current)
        }) { [self] result in
            report(result, operation: tr("ops.rebase.name"), failure: tr("ops.rebase.failed"))
        }
    }

    /// 快进非当前的本地分支到其上游；当前分支走 Update Project。
    func updateBranch(_ branch: String) {
        if branch == model.status.branch.head {
            updateProject()
            return
        }
        run(tr("ops.progress.updateBranch", branch), { repo in try repo.updateBranch(name: branch) }) { [self] result in
            switch result {
            case .success: model.post(tr("ops.updateBranch.done", branch))
            case let .failure(error): showError(tr("ops.updateBranch.failed", branch), error)
            }
        }
    }

    func deleteRemoteBranch(_ branch: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("ops.deleteRemote.title", branch)
        alert.informativeText = tr("ops.deleteRemote.message")
        alert.addButton(withTitle: tr("ops.deleteRemote.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            run(tr("ops.progress.deleteRemote", branch), { repo in try repo.deleteRemoteBranch(name: branch) }) { [self] result in
                switch result {
                case .success: model.post(tr("ops.deleteRemote.done", branch))
                case let .failure(error): showError(tr("ops.deleteRemote.failed"), error)
                }
            }
        }
    }

    /// IDEA 的 Compare with Current：分别列出只在对方分支 / 只在当前分支上的提交，双击在 Log 中定位。
    func compareWithCurrent(_ branch: String) {
        let current = model.currentBranchTitle
        let head = model.status.branch.head ?? "HEAD"
        let repository = model.repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let page: (String, String) throws -> [LogCommit] = { include, exclude in
                        try repository.log(filter: LogFilter(
                            revisions: [include, "^" + exclude], authors: [], since: nil, until: nil,
                            paths: [], text: nil, order: .topological, maxCount: 500
                        )).commits
                    }
                    return (try page(branch, head), try page(head, branch))
                }
            }.value
            switch result {
            case let .success((incoming, outgoing)):
                let reveal = onRevealCommit
                let row: (LogCommit) -> ListSheet.Item = { commit in
                    .row(.init(
                        symbol: nil,
                        title: commit.subject,
                        detail: "\(String(commit.hash.prefix(8)))  \(commit.authorName)  \(LogDateFormatter.short(commit.authorTime))",
                        action: { reveal?(commit.hash) }
                    ))
                }
                var items: [ListSheet.Item] = [.header(tr("compare.incoming", branch, current, "\(incoming.count)"))]
                items += incoming.map(row)
                items.append(.header(tr("compare.outgoing", current, branch, "\(outgoing.count)")))
                items += outgoing.map(row)
                ListSheet(
                    title: tr("compare.title", branch, current),
                    message: tr("compare.message"),
                    items: items,
                    emptyText: tr("compare.identical")
                ).begin(for: window)
            case let .failure(error):
                showError(tr("compare.failed"), error)
            }
        }
    }

    /// IDEA 的 Show Diff with Working Tree：列出工作区与该分支不同的文件，双击打开 Diff。
    func showDiffWithWorkingTree(_ branch: String) {
        let repository = model.repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.diffWithWorkingTree(revision: branch) }
            }.value
            switch result {
            case let .success(files):
                let showDiff = onShowRevisionFileDiff
                let items: [ListSheet.Item] = files.map { file in
                    .row(.init(
                        symbol: Self.symbol(for: file.kind),
                        title: file.path,
                        detail: file.origPath.map { tr("compare.renamedFrom", $0) } ?? "",
                        action: { showDiff?(branch, file) }
                    ))
                }
                ListSheet(
                    title: tr("compare.workingTree.title", branch),
                    message: tr("compare.workingTree.message", "\(files.count)"),
                    items: items,
                    emptyText: tr("compare.workingTree.none")
                ).begin(for: window)
            case let .failure(error):
                showError(tr("compare.failed"), error)
            }
        }
    }

    private static func symbol(for kind: ChangeKind) -> String {
        switch kind {
        case .added: "plus.circle"
        case .deleted: "minus.circle"
        case .renamed, .copied: "arrow.right.circle"
        default: "pencil.circle"
        }
    }
}
