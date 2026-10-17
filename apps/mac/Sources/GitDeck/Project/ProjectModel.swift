import AppKit
import GitDeckCore

/// 一个项目窗口对应的仓库状态。所有 git 调用在后台执行，结果回到主线程后通知观察者。
@MainActor
final class ProjectModel {
    let repository: Repository
    let rootURL: URL

    private(set) var status = RepoStatus(branch: BranchStatus(head: nil, oid: nil, upstream: nil, ahead: 0, behind: 0), changes: [])
    private(set) var branches: [BranchRef] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?

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
                Result { (try repository.status(), try repository.branches()) }
            }.value
            switch result {
            case let .success((status, branches)):
                self.status = status
                self.branches = branches
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
