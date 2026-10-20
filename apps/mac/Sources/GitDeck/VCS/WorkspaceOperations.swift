import AppKit
import GitDeckCore

/// 跨仓库的 Fetch / Update Project / Push（IDEA 多 VCS 根项目中的同名操作）：
/// 依次对每个仓库执行，汇总结果后在状态栏通知；只有一个仓库时直接交给该仓库的操作。
@MainActor
final class WorkspaceOperations {
    let workspace: Workspace
    weak var window: NSWindow?
    /// 取得某个仓库的操作对象（由项目窗口创建并缓存）。
    let operationsFor: (ProjectModel) -> GitOperations
    /// 进度通知（状态栏），参数为 `nil` 表示结束。
    var onProgress: ((String?) -> Void)?
    private(set) var isRunning = false

    init(workspace: Workspace, operationsFor: @escaping (ProjectModel) -> GitOperations) {
        self.workspace = workspace
        self.operationsFor = operationsFor
    }

    private var primary: GitOperations { operationsFor(workspace.primary) }

    /// 依次对每个仓库执行 `work`，返回每个仓库的结果。
    private func runEach<T: Sendable>(
        _ title: String,
        _ models: [ProjectModel],
        _ work: @escaping @Sendable (Repository) throws -> T
    ) async -> [(ProjectModel, Result<T, any Error>)] {
        isRunning = true
        defer {
            isRunning = false
            onProgress?(nil)
            workspace.refreshAll()
        }
        var results: [(ProjectModel, Result<T, any Error>)] = []
        for model in models {
            onProgress?("\(title) — \(workspace.displayName(of: model))")
            let repository = model.repository
            let result = await Task.detached(priority: .userInitiated) { Result { try work(repository) } }.value
            results.append((model, result))
        }
        return results
    }

    /// 失败的仓库：报告第一个错误（附带仓库名）。
    private func reportFailures<T>(_ results: [(ProjectModel, Result<T, any Error>)], title: String) -> Bool {
        let failures = results.compactMap { model, result -> (ProjectModel, any Error)? in
            if case let .failure(error) = result { return (model, error) }
            return nil
        }
        guard let (model, error) = failures.first else { return false }
        let alert = AppAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("workspace.failedIn", title, workspace.displayName(of: model))
        alert.informativeText = errorMessage(error)
        primary.present(alert)
        workspace.primary.post(alert.messageText, isError: true)
        return true
    }

    func fetchAll() {
        guard workspace.isMultiRoot else { return primary.fetch() }
        guard !isRunning else { return NSSound.beep() }
        Task {
            let results = await runEach(tr("ops.progress.fetch"), workspace.models) { repo in try repo.fetch(prune: false) }
            guard !reportFailures(results, title: tr("git.action.fetch")) else { return }
            let total = results.reduce(0) { sum, item in sum + ((try? item.1.get()) ?? 0) }
            workspace.primary.post(total == 0 ? tr("ops.fetch.nothing") : tr("workspace.fetch.done", "\(total)", "\(results.count)"))
        }
    }

    /// 更新所有设置了上游的仓库；某个仓库出现冲突时停止并提示。
    func updateAll() {
        guard workspace.isMultiRoot else { return primary.updateProject() }
        guard !isRunning else { return NSSound.beep() }
        primary.chooseUpdateMethod { [self] method in
            let targets = workspace.models.filter { $0.status.branch.upstream != nil }
            guard !targets.isEmpty else {
                workspace.primary.post(tr("workspace.update.noUpstream"), isError: true)
                return
            }
            Task {
                var results: [(ProjectModel, Result<UpdateResult, any Error>)] = []
                for model in targets {
                    let result = await runEach(tr("ops.progress.update"), [model]) { repo in try repo.updateProject(method: method) }
                    results += result
                    if case let .success(update) = result.first?.1, update.outcome == .conflicts {
                        operationsFor(model).showConflicts(tr("ops.update.name"), stashKept: update.stashKept)
                        workspace.primary.post(tr("workspace.update.conflicts", workspace.displayName(of: model)), isError: true)
                        return
                    }
                }
                guard !reportFailures(results, title: tr("git.action.update")) else { return }
                let received = results.reduce(0) { sum, item in sum + Int((try? item.1.get())?.received ?? 0) }
                workspace.primary.post(received == 0
                    ? tr("ops.update.upToDate")
                    : tr("workspace.update.done", "\(received)", "\(results.count)"))
            }
        }
    }

    /// 有待推送提交的仓库：只有一个时打开其 Push 对话框，多个时列出供勾选后一起推送。
    func pushAll() {
        guard workspace.isMultiRoot else { return primary.push() }
        guard !isRunning else { return NSSound.beep() }
        Task {
            let targets = await runEach(tr("workspace.push.checking"), workspace.models) { repo in try repo.pushTarget() }
            let pending: [(ProjectModel, PushTarget)] = targets.compactMap { model, result in
                guard case let .success(target) = result, !target.commits.isEmpty, target.remote != nil else { return nil }
                return (model, target)
            }
            switch pending.count {
            case 0: workspace.primary.post(tr("workspace.push.nothing"))
            case 1: operationsFor(pending[0].0).push()
            default: askPush(pending)
            }
        }
    }

    private func askPush(_ pending: [(ProjectModel, PushTarget)]) {
        let alert = AppAlert()
        alert.messageText = tr("workspace.push.title")
        alert.informativeText = tr("workspace.push.message")
        var boxes: [NSButton] = []
        for (model, target) in pending {
            let destination = "\(target.remote ?? "")/\(target.remoteBranch)"
            let title = tr("workspace.push.item", workspace.displayName(of: model), target.localBranch, destination, "\(target.commits.count)")
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = .on
            boxes.append(box)
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 360, height: stack.fittingSize.height))
        alert.accessoryView = stack
        alert.addButton(withTitle: tr("workspace.push.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        primary.present(alert) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            for ((model, target), box) in zip(pending, boxes) where box.state == .on {
                operationsFor(model).performPush(PushOptions(
                    localBranch: target.localBranch,
                    remote: target.remote ?? "origin",
                    remoteBranch: target.remoteBranch,
                    force: false,
                    pushTags: false,
                    setUpstream: !target.hasUpstream
                ))
            }
        }
    }
}
