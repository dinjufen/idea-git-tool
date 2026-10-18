import AppKit
import GitDeckCore

/// 一个项目窗口对应的仓库状态。所有 git 调用在后台执行，结果回到主线程后通知观察者。
@MainActor
final class ProjectModel {
    let repository: Repository
    let rootURL: URL

    private(set) var status = RepoStatus(
        branch: BranchStatus(head: nil, oid: nil, upstream: nil, ahead: 0, behind: 0),
        changes: [],
        state: .normal
    )
    private(set) var branches: [BranchRef] = []
    private(set) var stashes: [StashEntry] = []
    private(set) var tags: [TagInfo] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// 最近一条通知（例如提交结果），显示在状态栏，对应 IDEA 的事件通知。
    private(set) var notification: (text: String, isError: Bool)?

    /// 相对路径 → 变更，供 Project 树着色。
    private(set) var changesByPath: [String: FileChange] = [:]

    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var pendingRefresh = false

    init(repository: Repository) {
        self.repository = repository
        rootURL = URL(fileURLWithPath: repository.root(), isDirectory: true)
    }

    var projectName: String { rootURL.lastPathComponent }

    /// 当前分支显示名：分离 HEAD 时显示短提交号，与 IDEA 一致。
    var currentBranchTitle: String {
        if let head = status.branch.head { return head }
        if let oid = status.branch.oid { return String(oid.prefix(8)) }
        return tr("vcs.noBranch")
    }

    /// VCS 分支组件标题：分支名 + 进行中的操作 + 与上游的差异（IDEA 样式，例如 `main ↑1 ↓2`）。
    var branchWidgetTitle: String {
        var parts = [currentBranchTitle]
        switch status.state {
        case .normal: break
        case .merging: parts.append(tr("vcs.state.merging"))
        case .rebasing: parts.append(tr("vcs.state.rebasing"))
        case .cherryPicking: parts.append(tr("vcs.state.cherryPicking"))
        case .reverting: parts.append(tr("vcs.state.reverting"))
        }
        if status.branch.ahead > 0 { parts.append("↑\(status.branch.ahead)") }
        if status.branch.behind > 0 { parts.append("↓\(status.branch.behind)") }
        return parts.joined(separator: " ")
    }

    /// 引用或 HEAD 发生变化时改变，用于判断 Log 是否需要重新加载。
    var refsSignature: String {
        ([status.branch.oid ?? "", status.branch.head ?? ""] + branches.map { $0.fullRef + "=" + $0.target })
            .joined(separator: "\n")
    }

    func post(_ text: String, isError: Bool = false) {
        notification = (text, isError)
        notify()
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// 刷新 status 与分支。刷新进行中再次调用时会在结束后补刷一次。
    func refresh() {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        notify()
        let repository = repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { (try repository.status(), try repository.branches(), try repository.stashes(), try repository.tags()) }
            }.value
            switch result {
            case let .success((status, branches, stashes, tags)):
                self.status = status
                self.branches = branches
                self.stashes = stashes
                self.tags = tags
                self.changesByPath = Dictionary(status.changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.lastError = nil
            case let .failure(error):
                self.lastError = errorMessage(error)
            }
            self.isRefreshing = false
            self.notify()
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh()
            }
        }
    }

    private func notify() {
        for handler in observers.values { handler() }
    }
}

// MARK: - 文件状态展示

extension FileChange {
    /// 在 Commit / Project 视图中使用的状态颜色。
    var statusColor: NSColor {
        if conflict != nil { return Theme.FileStatus.conflict }
        switch (staged, unstaged) {
        case (_, .untracked): return Theme.FileStatus.untracked
        case (_, .ignored): return Theme.FileStatus.ignored
        case (.added, _), (_, .added): return Theme.FileStatus.added
        case (.deleted, _), (_, .deleted): return Theme.FileStatus.deleted
        case (.renamed, _), (.copied, _): return Theme.FileStatus.renamed
        default: return Theme.FileStatus.modified
        }
    }

    var isUntracked: Bool { unstaged == .untracked }
    var isIgnored: Bool { unstaged == .ignored }
    var isDeleted: Bool { staged == .deleted || unstaged == .deleted }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

extension ConflictKind {
    var title: String {
        switch self {
        case .bothDeleted: tr("conflict.bothDeleted")
        case .addedByUs: tr("conflict.addedByUs")
        case .deletedByThem: tr("conflict.deletedByThem")
        case .addedByThem: tr("conflict.addedByThem")
        case .deletedByUs: tr("conflict.deletedByUs")
        case .bothAdded: tr("conflict.bothAdded")
        case .bothModified: tr("conflict.bothModified")
        }
    }
}
