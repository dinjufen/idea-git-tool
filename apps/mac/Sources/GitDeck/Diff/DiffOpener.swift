import AppKit
import GitDeckCore

/// 打开 Diff 页：在后台读取两侧内容，再在编辑器区域创建标签。
@MainActor
struct DiffOpener {
    let model: ProjectModel
    let editor: EditorAreaView
    /// 本地改动的 Diff 中可勾选要提交的改动（部分提交）。
    var lineSelections: LineSelectionStore?

    /// 本地变更：HEAD 与工作区文件比较（Commit 工具窗口中的 Show Diff）。
    func showLocalChange(_ change: FileChange) {
        let repository = model.repository
        let root = model.rootURL
        let basePath = change.origPath ?? change.path
        let headTitle = model.status.branch.oid.map { tr("diff.title.head", String($0.prefix(8))) } ?? "HEAD"
        Task {
            let (base, text) = await Task.detached(priority: .userInitiated) {
                let base = try? repository.fileAtRevision(revision: "HEAD", path: basePath)
                let text = change.isDeleted ? nil : Self.readWorkingFile(root.appendingPathComponent(change.path))
                return (base ?? nil, text)
            }.value
            editor.openDiff(
                key: "local:" + change.path,
                title: change.fileName,
                tooltip: tr("diff.tooltip.local", change.path)
            ) {
                DiffView(
                    left: DiffSide(title: headTitle, text: base),
                    right: DiffSide(title: tr("diff.title.local"), text: text),
                    path: change.path,
                    inclusion: change.conflict == nil ? lineSelections.map { DiffInclusion(store: $0, path: change.path) } : nil
                )
            }
        }
    }

    /// 某个修订（分支）中的文件与工作区文件比较（分支菜单的 Show Diff with Working Tree）。
    func showRevisionAgainstWorkingTree(revision: String, file: ChangedFile) {
        let repository = model.repository
        let root = model.rootURL
        let basePath = file.origPath ?? file.path
        Task {
            let (base, text) = await Task.detached(priority: .userInitiated) {
                let base = file.kind == .added ? nil : try? repository.fileAtRevision(revision: revision, path: basePath)
                let text = file.kind == .deleted ? nil : Self.readWorkingFile(root.appendingPathComponent(file.path))
                return (base ?? nil, text)
            }.value
            editor.openDiff(
                key: "revision:\(revision):\(file.path)",
                title: (file.path as NSString).lastPathComponent,
                tooltip: tr("diff.tooltip.revision", file.path, revision)
            ) {
                DiffView(
                    left: DiffSide(title: revision, text: base),
                    right: DiffSide(title: tr("diff.title.local"), text: text),
                    path: file.path
                )
            }
        }
    }

    /// 搁置中的文件：搁置时的版本与搁置的改动（Shelf 标签中双击文件）。
    func showShelfFile(_ entry: ShelfEntry, path: String) {
        let repository = model.repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try repository.shelfFileVersions(id: entry.id, path: path) }
            }.value
            guard case let .success(versions) = result else {
                NSSound.beep()
                return
            }
            editor.openDiff(
                key: "shelf:\(entry.id):\(path)",
                title: (path as NSString).lastPathComponent,
                tooltip: tr("diff.tooltip.shelf", path, entry.name)
            ) {
                DiffView(
                    left: DiffSide(title: tr("diff.title.shelfBase"), text: versions.base),
                    right: DiffSide(title: tr("diff.title.shelved", entry.name), text: versions.text),
                    path: path
                )
            }
        }
    }

    /// 历史提交中的文件：与第一个父提交比较（Log 详情中双击文件）。
    func showCommitFile(hash: String, parent: String?, file: ChangedFile, revealLine: Int? = nil) {
        let repository = model.repository
        let basePath = file.origPath ?? file.path
        Task {
            let (base, text) = await Task.detached(priority: .userInitiated) {
                let base = parent.flatMap { try? repository.fileAtRevision(revision: $0, path: basePath) }
                let text = file.kind == .deleted ? nil : try? repository.fileAtRevision(revision: hash, path: file.path)
                return (base ?? nil, text ?? nil)
            }.value
            let name = (file.path as NSString).lastPathComponent
            editor.openDiff(
                key: "commit:\(hash):\(file.path)",
                title: name,
                tooltip: tr("diff.tooltip.commit", file.path, String(hash.prefix(8)))
            ) {
                let view = DiffView(
                    left: DiffSide(title: parent.map { String($0.prefix(8)) } ?? tr("diff.title.empty"), text: base),
                    right: DiffSide(title: String(hash.prefix(8)), text: text),
                    path: file.path
                )
                if let revealLine {
                    DispatchQueue.main.async { view.reveal(line: revealLine) }
                }
                return view
            }
        }
    }

    /// 储藏中的文件：已跟踪文件相对储藏时的 HEAD，未跟踪文件与空内容比较。
    func showStashFile(_ stash: StashEntry, file: ChangedFile) {
        let repository = model.repository
        let revisions = stashRevisions(index: stash.index, untracked: file.kind == .untracked)
        let basePath = file.origPath ?? file.path
        Task {
            let (base, text) = await Task.detached(priority: .userInitiated) {
                let base = revisions.base.flatMap { file.kind == .added ? nil : try? repository.fileAtRevision(revision: $0, path: basePath) }
                let text = file.kind == .deleted ? nil : try? repository.fileAtRevision(revision: revisions.changed, path: file.path)
                return (base ?? nil, text ?? nil)
            }.value
            editor.openDiff(
                key: "stash:\(stash.hash):\(file.path)",
                title: (file.path as NSString).lastPathComponent,
                tooltip: tr("diff.tooltip.stash", file.path, stash.message)
            ) {
                DiffView(
                    left: DiffSide(title: tr("diff.title.stashBase"), text: base),
                    right: DiffSide(title: tr("diff.title.stash", stash.message), text: text),
                    path: file.path
                )
            }
        }
    }

    /// 读取工作区文件；非 UTF-8 内容按有损方式解码，与核心读取历史版本的处理一致。
    nonisolated private static func readWorkingFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
