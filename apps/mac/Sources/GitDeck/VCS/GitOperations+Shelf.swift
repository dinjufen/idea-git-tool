import AppKit
import GitDeckCore

/// Shelve / Unshelve（IDEA 的搁置）：保存选中的改动并从工作区撤销，之后在 Shelf 标签中取回。
extension GitOperations {
    /// 询问名称后搁置 `paths`（为空时搁置全部改动）。
    func shelve(paths: [String], defaultName: String) {
        NameDialog(
            title: paths.isEmpty ? tr("shelf.dialog.title") : tr("shelf.dialog.titleSelected", "\(paths.count)"),
            message: tr("shelf.dialog.message"),
            initial: defaultName,
            confirmTitle: tr("shelf.dialog.confirm"),
            validate: { _ in nil }
        ).begin(for: window) { [self] result in
            run(tr("ops.progress.shelve"), { repo in try repo.shelveChanges(paths: paths, name: result.name) }) { [self] result in
                switch result {
                case let .success(entry): model.post(tr("shelf.done", entry.name, "\(entry.files.count)"))
                case let .failure(error): showError(tr("shelf.failed"), error)
                }
            }
        }
    }

    /// 取回搁置的改动；`paths` 为空时取回全部文件。`keep` 为 false 时从搁置中移除已取回的文件。
    func unshelve(_ entry: ShelfEntry, paths: [String], keep: Bool) {
        run(tr("ops.progress.unshelve", entry.name), { repo in
            try repo.unshelve(id: entry.id, paths: paths, keep: keep)
        }) { [self] result in
            switch result {
            case .success(let outcome) where outcome.conflicts:
                showConflicts(tr("shelf.unshelve.name"))
            case .success:
                model.post(tr("shelf.unshelved", entry.name))
            case let .failure(error):
                showError(tr("shelf.unshelve.failed"), error)
            }
        }
    }

    func deleteShelf(_ entry: ShelfEntry) {
        confirm(tr("shelf.delete.title"), tr("shelf.delete.message", entry.name), confirm: tr("shelf.delete.confirm")) { [self] in
            run(tr("ops.progress.deleteShelf"), { repo in try repo.deleteShelf(id: entry.id) }) { [self] result in
                if case let .failure(error) = result { showError(tr("shelf.delete.failed"), error) } else { model.post(tr("shelf.deleted")) }
            }
        }
    }

    func renameShelf(_ entry: ShelfEntry) {
        NameDialog(
            title: tr("shelf.rename.title"),
            message: nil,
            initial: entry.name,
            confirmTitle: tr("shelf.rename.confirm"),
            validate: { _ in nil }
        ).begin(for: window) { [self] result in
            run(tr("ops.progress.renameShelf"), { repo in try repo.renameShelf(id: entry.id, name: result.name) }) { [self] result in
                if case let .failure(error) = result { showError(tr("shelf.rename.failed"), error) }
            }
        }
    }
}
