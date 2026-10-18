import AppKit
import GitDeckCore

/// 一个项目窗口中的所有仓库（IDEA 的多个 VCS 根）：项目根目录的仓库 + 用户加入的嵌套仓库 / 子模块。
///
/// 每个仓库仍由独立的 `ProjectModel` 表示；本类负责持久化仓库列表、检测未加入的嵌套仓库、
/// 按文件路径找到所属仓库，以及汇总各仓库的状态变化。
@MainActor
final class Workspace {
    let primary: ProjectModel
    private(set) var models: [ProjectModel]
    /// 检测到但尚未加入、也未被忽略的嵌套仓库（显示在提示条中）。
    private(set) var candidates: [NestedRepository] = []

    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var modelObservers: [ObjectIdentifier: UUID] = [:]

    /// 每个仓库在 Log、提交窗口与分支弹窗中的标识色（主仓库为第一种）。
    private static let palette: [NSColor] = [
        Theme.dynamic(light: 0x534AB7, dark: 0x8F87F1),
        Theme.dynamic(light: 0x1D9E75, dark: 0x4CC79C),
        Theme.dynamic(light: 0xD85A30, dark: 0xF0886A),
        Theme.dynamic(light: 0x378ADD, dark: 0x6AA8EC),
        Theme.dynamic(light: 0xBA7517, dark: 0xE4A548),
        Theme.dynamic(light: 0xD4537E, dark: 0xEC85A8),
    ]

    init(primary: ProjectModel) {
        self.primary = primary
        models = [primary]
        watch(primary)
    }

    var isMultiRoot: Bool { models.count > 1 }

    private var rootsKey: String { "workspace.roots:" + primary.rootURL.path }
    private var ignoredKey: String { "workspace.ignored:" + primary.rootURL.path }

    // MARK: - 观察

    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for handler in observers.values { handler() }
    }

    private func watch(_ model: ProjectModel) {
        modelObservers[ObjectIdentifier(model)] = model.observe { [weak self] in self?.notify() }
    }

    // MARK: - 仓库列表

    /// 打开上次加入的仓库，然后检测新的嵌套仓库。
    func load() {
        let saved = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        Task {
            let repositories = await Task.detached {
                saved.compactMap { try? Repository.open(path: $0) }
            }.value
            for repository in repositories where !self.contains(path: repository.root()) {
                self.append(ProjectModel(repository: repository))
            }
            self.detect()
        }
    }

    private func contains(path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return models.contains { $0.rootURL.standardizedFileURL.path == standardized }
    }

    private func append(_ model: ProjectModel) {
        models.append(model)
        watch(model)
        model.refresh()
        notify()
    }

    private func save() {
        UserDefaults.standard.set(models.dropFirst().map(\.rootURL.path), forKey: rootsKey)
    }

    /// 加入仓库（检测到的嵌套仓库或用户选择的目录）。
    func add(paths: [String]) {
        Task {
            let repositories = await Task.detached {
                paths.compactMap { try? Repository.open(path: $0) }
            }.value
            for repository in repositories where !self.contains(path: repository.root()) {
                self.append(ProjectModel(repository: repository))
            }
            self.save()
            self.candidates.removeAll { candidate in self.contains(path: candidate.path) }
            self.notify()
        }
    }

    func remove(_ model: ProjectModel) {
        guard model !== primary, let index = models.firstIndex(where: { $0 === model }) else { return }
        models.remove(at: index)
        if let id = modelObservers.removeValue(forKey: ObjectIdentifier(model)) { model.removeObserver(id) }
        save()
        notify()
    }

    /// 不再提示这些嵌套仓库。
    func ignore(paths: [String]) {
        var ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredKey) ?? [])
        ignored.formUnion(paths)
        UserDefaults.standard.set(Array(ignored), forKey: ignoredKey)
        candidates.removeAll { paths.contains($0.path) }
        notify()
    }

    /// 检测项目目录中尚未加入的仓库（子模块与嵌套仓库）。
    func detect() {
        let repository = primary.repository
        let ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredKey) ?? [])
        Task {
            let found = await Task.detached { (try? repository.nestedRepositories(maxDepth: 4)) ?? [] }.value
            self.candidates = found.filter { !ignored.contains($0.path) && !self.contains(path: $0.path) }
            self.notify()
        }
    }

    // MARK: - 查询

    /// 包含该文件的仓库（嵌套仓库优先，即根目录最长的那个）；不在任何仓库内时为主仓库。
    func model(containing url: URL) -> ProjectModel {
        let path = url.standardizedFileURL.path
        return models
            .filter { path == $0.rootURL.standardizedFileURL.path || path.hasPrefix($0.rootURL.standardizedFileURL.path + "/") }
            .max { $0.rootURL.path.count < $1.rootURL.path.count } ?? primary
    }

    func color(for model: ProjectModel) -> NSColor {
        let index = models.firstIndex { $0 === model } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    /// 仓库的显示名：相对主仓库的路径（主仓库为项目名）。
    func displayName(of model: ProjectModel) -> String {
        guard model !== primary else { return primary.projectName }
        let root = primary.rootURL.standardizedFileURL.path + "/"
        let path = model.rootURL.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : model.projectName
    }

    /// 分支组件标题：各仓库在同一分支时显示分支名，否则显示主仓库分支并注明仓库数（IDEA 的多仓库分支组件）。
    var branchWidgetTitle: String {
        guard isMultiRoot else { return primary.branchWidgetTitle }
        let heads = Set(models.map(\.currentBranchTitle))
        if heads.count == 1 {
            return tr("workspace.branch.same", primary.branchWidgetTitle, "\(models.count)")
        }
        return tr("workspace.branch.mixed", primary.currentBranchTitle, "\(models.count)")
    }

    var isRefreshing: Bool { models.contains(where: \.isRefreshing) }

    func refreshAll() {
        models.forEach { $0.refresh() }
    }
}

/// 多仓库的同步分支控制（IDEA 的 “Synchronous branch control”）：在一个仓库中签出或新建分支时，
/// 对其他仓库执行相同的操作。
@MainActor
enum SyncBranchControl {
    private static let key = "workspace.syncBranches"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
