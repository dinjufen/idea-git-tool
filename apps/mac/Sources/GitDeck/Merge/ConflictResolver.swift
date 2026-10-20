import AppKit
import GitDeckCore

/// 打开 Conflicts 对话框与三栏合并窗口（读取各方版本与计算分块在后台进行）。
@MainActor
final class ConflictResolver {
    private let model: ProjectModel
    weak var window: NSWindow?
    /// 已打开的合并窗口，按文件路径索引；同一文件只打开一个。
    private var mergeWindows: [String: MergeWindowController] = [:]
    private var conflictsDialog: ConflictsDialog?
    /// 已请求打开 Conflicts 对话框时，还要等待的刷新次数。请求时可能已有一次旧的刷新在进行，
    /// 其结果尚不含冲突，因此最多等两次刷新完成。
    private var pendingRefreshes = 0
    private var observer: UUID?

    init(model: ProjectModel) {
        self.model = model
        observer = model.observe { [weak self] in self?.modelChanged() }
    }

    private func modelChanged() {
        guard pendingRefreshes > 0, !model.isRefreshing else { return }
        if hasConflicts {
            pendingRefreshes = 0
            showConflicts()
        } else {
            pendingRefreshes -= 1
        }
    }

    /// 操作刚产生冲突时调用：刷新状态后再打开对话框。
    func requestConflicts() {
        pendingRefreshes = 2
        model.refresh()
    }

    var hasConflicts: Bool {
        model.status.changes.contains { $0.conflict != nil }
    }

    func showConflicts() {
        guard hasConflicts, window?.attachedSheet == nil else { return }
        let dialog = ConflictsDialog(model: model) { [weak self] change in self?.openMerge(change) }
        conflictsDialog = dialog
        dialog.begin(for: window)
    }

    /// 打开某个冲突文件的三栏合并；一方已删除或为二进制文件时改为打开 Conflicts 对话框。
    func openMerge(_ change: FileChange) {
        guard let kind = change.conflict, ConflictsDialog.bothSidesExist(kind) else {
            showConflicts()
            return
        }
        if let existing = mergeWindows[change.path] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let repository = model.repository
        let path = change.path
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let versions = try repository.conflictVersions(path: path)
                    let labels = repository.conflictLabels()
                    let chunks = mergeChunks(base: versions.base ?? "", ours: versions.ours ?? "", theirs: versions.theirs ?? "")
                    return (versions, labels, chunks)
                }
            }.value
            guard let self else { return }
            switch result {
            case let .success((versions, labels, chunks)):
                let binary = [versions.base, versions.ours, versions.theirs].contains { $0?.contains("\0") == true }
                guard !binary else {
                    showConflicts()
                    return
                }
                let controller = MergeWindowController(model: model, path: path, versions: versions, labels: labels, chunks: chunks)
                controller.onClose = { [weak self] in self?.mergeWindows[path] = nil }
                mergeWindows[path] = controller
                controller.showWindow(nil)
                #if DEBUG
                // 仅 Debug 构建：`-debug.mergeApplyNonConflicting YES` 打开后自动应用所有不冲突的更改，便于验证。
                if UserDefaults.standard.bool(forKey: "debug.mergeApplyNonConflicting") {
                    controller.perform(Selector(("applyNonConflicting")))
                    // `-debug.mergeUndo YES`：随后撤销一次，验证被撤销的块恢复为可应用。
                    if UserDefaults.standard.bool(forKey: "debug.mergeUndo") {
                        controller.debugUndo()
                    }
                }
                #endif
            case let .failure(error):
                let alert = AppAlert()
                alert.messageText = tr("conflicts.failed")
                alert.informativeText = errorMessage(error)
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }
}
