import AppKit
import GitDeckCore

/// 分支与远程操作的交互流程：在后台执行 git，处理确认对话框、错误与结果通知。
///
/// 同一项目同一时间只运行一个操作，与 IDEA 的后台任务行为一致。
@MainActor
final class GitOperations {
    private let model: ProjectModel
    weak var window: NSWindow?
    /// 操作开始 / 结束时通知（状态栏显示进度）；参数为进行中的操作标题，结束时为 `nil`。
    var onProgress: ((String?) -> Void)?

    private(set) var runningTitle: String?

    init(model: ProjectModel) {
        self.model = model
    }

    var isRunning: Bool { runningTitle != nil }

    // MARK: - 执行框架

    /// 在后台执行 `work`，完成后刷新状态并在主线程回调。
    private func run<T: Sendable>(
        _ title: String,
        _ work: @escaping @Sendable (Repository) throws -> T,
        completion: @escaping (Result<T, any Error>) -> Void
    ) {
        guard runningTitle == nil else {
            NSSound.beep()
            return
        }
        runningTitle = title
        onProgress?(title)
        let repository = model.repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try work(repository) }
            }.value
            self.runningTitle = nil
            self.onProgress?(nil)
            completion(result)
            self.model.refresh()
        }
    }

    private func showError(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = errorMessage(error)
        present(alert)
        model.post(title, isError: true)
    }

    private func present(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion?(alert.runModal())
        }
    }

    // MARK: - 签出

    enum CheckoutTarget {
        case local(String)
        case remote(String)
        case revision(String)

        var name: String {
            switch self {
            case let .local(n), let .remote(n), let .revision(n): n
            }
        }
    }

    func checkout(_ target: CheckoutTarget, mode: CheckoutMode = .normal) {
        run(tr("ops.progress.checkout", target.name), { repo in
            switch target {
            case let .local(name): try repo.checkoutBranch(name: name, mode: mode)
            case let .remote(name): try repo.checkoutRemoteBranch(remoteBranch: name, mode: mode)
            case let .revision(rev): try repo.checkoutRevision(revision: rev, mode: mode)
            }
        }) { [self] result in
            switch result {
            case let .success(outcome):
                model.post(outcome.stashConflicts
                    ? tr("ops.checkout.stashConflicts", target.name)
                    : tr("ops.checkout.done", target.name), isError: outcome.stashConflicts)
            case let .failure(CoreError.LocalChangesWouldBeOverwritten(files)):
                askCheckoutProblem(target, files: files)
            case let .failure(error):
                showError(tr("ops.checkout.failed"), error)
            }
        }
    }

    /// IDEA 的 “Git Checkout Problem” 对话框：Smart Checkout 或 Force Checkout。
    private func askCheckoutProblem(_ target: CheckoutTarget, files: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("ops.checkoutProblem.title")
        alert.informativeText = tr("ops.checkoutProblem.message", files.prefix(20).joined(separator: "\n"))
        alert.addButton(withTitle: tr("ops.checkoutProblem.smart"))
        alert.addButton(withTitle: tr("ops.checkoutProblem.force"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            switch response {
            case .alertFirstButtonReturn: checkout(target, mode: .smart)
            case .alertSecondButtonReturn: checkout(target, mode: .force)
            default: break
            }
        }
    }

    func checkoutRevisionDialog() {
        NameDialog(
            title: tr("ops.checkoutRevision.title"),
            message: tr("ops.checkoutRevision.message"),
            initial: "",
            confirmTitle: tr("ops.checkoutRevision.confirm"),
            validate: { _ in nil }
        ).begin(for: window) { [self] result in
            checkout(.revision(result.name))
        }
    }

    // MARK: - 新建 / 重命名 / 删除

    /// IDEA 的 “Create New Branch” 对话框：名称 + “Checkout branch” 复选框。
    func newBranch(from startPoint: String? = nil) {
        let repository = model.repository
        let existing = Set(model.branches.filter { $0.kind == .local }.map(\.name))
        NameDialog(
            title: tr("ops.newBranch.title"),
            message: startPoint.map { tr("ops.newBranch.from", $0) },
            initial: "",
            confirmTitle: tr("ops.newBranch.confirm"),
            checkbox: tr("ops.newBranch.checkout"),
            validate: { name in
                if existing.contains(name) { return tr("ops.validate.exists", name) }
                return repository.isValidBranchName(name: name) ? nil : tr("ops.validate.invalid")
            }
        ).begin(for: window) { [self] result in
            run(tr("ops.progress.newBranch", result.name), { repo in
                try repo.createBranch(name: result.name, startPoint: startPoint, checkout: result.checked)
            }) { [self] outcome in
                switch outcome {
                case .success: model.post(tr("ops.newBranch.done", result.name))
                case let .failure(error): showError(tr("ops.newBranch.failed"), error)
                }
            }
        }
    }

    func rename(_ branch: String) {
        let repository = model.repository
        let existing = Set(model.branches.filter { $0.kind == .local }.map(\.name))
        NameDialog(
            title: tr("ops.rename.title", branch),
            message: nil,
            initial: branch,
            confirmTitle: tr("ops.rename.confirm"),
            validate: { name in
                if name != branch && existing.contains(name) { return tr("ops.validate.exists", name) }
                return repository.isValidBranchName(name: name) ? nil : tr("ops.validate.invalid")
            }
        ).begin(for: window) { [self] result in
            guard result.name != branch else { return }
            run(tr("ops.progress.rename", branch), { repo in
                try repo.renameBranch(oldName: branch, newName: result.name)
            }) { [self] outcome in
                switch outcome {
                case .success: model.post(tr("ops.rename.done", branch, result.name))
                case let .failure(error): showError(tr("ops.rename.failed"), error)
                }
            }
        }
    }

    func delete(_ branch: String, force: Bool = false) {
        run(tr("ops.progress.delete", branch), { repo in
            try repo.deleteBranch(name: branch, force: force)
        }) { [self] result in
            switch result {
            case .success:
                model.post(tr("ops.delete.done", branch))
            case .failure(CoreError.BranchNotFullyMerged):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = tr("ops.delete.notMerged.title", branch)
                alert.informativeText = tr("ops.delete.notMerged.message")
                alert.addButton(withTitle: tr("ops.delete.force"))
                alert.addButton(withTitle: tr("common.cancel"))
                present(alert) { [self] response in
                    if response == .alertFirstButtonReturn { delete(branch, force: true) }
                }
            case let .failure(error):
                showError(tr("ops.delete.failed"), error)
            }
        }
    }

    // MARK: - 合并 / 变基

    func merge(_ branch: String) {
        let current = model.currentBranchTitle
        run(tr("ops.progress.merge", branch, current), { repo in
            try repo.mergeBranch(branch: branch)
        }) { [self] result in
            report(result, operation: tr("ops.merge.name"), failure: tr("ops.merge.failed"))
        }
    }

    func rebase(onto branch: String) {
        let current = model.currentBranchTitle
        run(tr("ops.progress.rebase", current, branch), { repo in
            try repo.rebaseOnto(upstream: branch)
        }) { [self] result in
            report(result, operation: tr("ops.rebase.name"), failure: tr("ops.rebase.failed"))
        }
    }

    func continueRebase() {
        run(tr("ops.progress.continueRebase"), { repo in try repo.continueRebase() }) { [self] result in
            report(result, operation: tr("ops.rebase.name"), failure: tr("ops.rebase.failed"))
        }
    }

    func abortRebase() {
        run(tr("ops.progress.abort"), { repo in try repo.abortRebase() }) { [self] result in
            if case let .failure(error) = result { showError(tr("ops.abort.failed"), error) } else { model.post(tr("ops.abort.rebaseDone")) }
        }
    }

    func abortMerge() {
        run(tr("ops.progress.abort"), { repo in try repo.abortMerge() }) { [self] result in
            if case let .failure(error) = result { showError(tr("ops.abort.failed"), error) } else { model.post(tr("ops.abort.mergeDone")) }
        }
    }

    private func report(_ result: Result<MergeOutcome, any Error>, operation: String, failure: String) {
        switch result {
        case .success(.upToDate): model.post(tr("ops.upToDate"))
        case .success(.fastForward), .success(.merged): model.post(tr("ops.done", operation))
        case .success(.conflicts): showConflicts(operation)
        case let .failure(error): showError(failure, error)
        }
    }

    /// 出现冲突：提示用户在 Commit 工具窗口中解决（三栏合并在后续步骤加入）。
    private func showConflicts(_ operation: String, stashKept: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("ops.conflicts.title", operation)
        var text = tr("ops.conflicts.message")
        if stashKept { text += "\n\n" + tr("ops.conflicts.stashKept") }
        alert.informativeText = text
        present(alert)
        model.post(tr("ops.conflicts.title", operation), isError: true)
    }

    // MARK: - Fetch / Update / Push

    func fetch() {
        run(tr("ops.progress.fetch"), { repo in try repo.fetch(prune: false) }) { [self] result in
            switch result {
            case let .success(count): model.post(count == 0 ? tr("ops.fetch.nothing") : tr("ops.fetch.done", "\(count)"))
            case let .failure(error): showError(tr("ops.fetch.failed"), error)
            }
        }
    }

    private static let updateMethodKey = "update.method"

    /// IDEA 的 “Update Project” 对话框：选择 Merge 或 Rebase，记住上次的选择。
    func updateProject() {
        let alert = NSAlert()
        alert.messageText = tr("ops.update.title")
        alert.informativeText = tr("ops.update.message")
        let merge = NSButton(radioButtonWithTitle: tr("ops.update.merge"), target: nil, action: nil)
        let rebase = NSButton(radioButtonWithTitle: tr("ops.update.rebase"), target: nil, action: nil)
        // 单选按钮需要共享 action 才会互斥。
        let toggle = RadioGroup([merge, rebase])
        let rememberedRebase = UserDefaults.standard.string(forKey: Self.updateMethodKey) == "rebase"
        (rememberedRebase ? rebase : merge).state = .on
        let stack = NSStackView(views: [merge, rebase])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 48)
        alert.accessoryView = stack
        alert.addButton(withTitle: tr("ops.update.confirm"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            // 单选按钮的 target 是弱引用：在对话框关闭前保持 RadioGroup 存活。
            withExtendedLifetime(toggle) {}
            guard response == .alertFirstButtonReturn else { return }
            let method: UpdateMethod = rebase.state == .on ? .rebase : .merge
            UserDefaults.standard.set(method == .rebase ? "rebase" : "merge", forKey: Self.updateMethodKey)
            performUpdate(method)
        }
    }

    private func performUpdate(_ method: UpdateMethod) {
        run(tr("ops.progress.update"), { repo in try repo.updateProject(method: method) }) { [self] result in
            switch result {
            case let .success(update):
                switch update.outcome {
                case .upToDate: model.post(tr("ops.update.upToDate"))
                case .conflicts: showConflicts(tr("ops.update.name"), stashKept: update.stashKept)
                case .fastForward, .merged:
                    model.post(update.stashConflicts
                        ? tr("ops.update.stashConflicts", "\(update.received)")
                        : tr("ops.update.done", "\(update.received)"), isError: update.stashConflicts)
                }
            case let .failure(error):
                showError(tr("ops.update.failed"), error)
            }
        }
    }

    /// 打开 Push 对话框：先在后台读取推送目标与待推送提交。
    func push() {
        guard !isRunning else {
            NSSound.beep()
            return
        }
        let repository = model.repository
        Task {
            let result = await Task.detached { Result { (try repository.pushTarget(), try repository.remotes()) } }.value
            switch result {
            case let .success((target, remotes)):
                PushDialog(target: target, remotes: remotes.map(\.name), projectName: model.projectName)
                    .begin(for: window) { [self] options in performPush(options) }
            case let .failure(error):
                showError(tr("ops.push.failed"), error)
            }
        }
    }

    private func performPush(_ options: PushOptions) {
        let destination = "\(options.remote)/\(options.remoteBranch)"
        run(tr("ops.progress.push", destination), { repo in try repo.push(options: options) }) { [self] result in
            switch result {
            case let .success(push):
                model.post(push.upToDate
                    ? tr("ops.push.upToDate")
                    : tr("ops.push.done", "\(push.pushedCommits)", destination))
            case let .failure(CoreError.PushRejected(reason)):
                askPushRejected(reason)
            case let .failure(error):
                showError(tr("ops.push.failed"), error)
            }
        }
    }

    /// IDEA 的 “Push Rejected” 对话框：远程有本地没有的提交时，建议先更新。
    private func askPushRejected(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("ops.pushRejected.title")
        alert.informativeText = tr("ops.error.pushRejected", reason)
        alert.addButton(withTitle: tr("ops.pushRejected.update"))
        alert.addButton(withTitle: tr("common.cancel"))
        present(alert) { [self] response in
            if response == .alertFirstButtonReturn { updateProject() }
        }
        model.post(tr("ops.pushRejected.title"), isError: true)
    }
}

/// 让一组单选按钮互斥（AppKit 中同一父视图且 action 相同的单选按钮才互斥）。
@MainActor
final class RadioGroup: NSObject {
    private let buttons: [NSButton]

    init(_ buttons: [NSButton]) {
        self.buttons = buttons
        super.init()
        for button in buttons {
            button.target = self
            button.action = #selector(select(_:))
        }
    }

    @objc private func select(_ sender: NSButton) {
        for button in buttons { button.state = button === sender ? .on : .off }
    }
}
