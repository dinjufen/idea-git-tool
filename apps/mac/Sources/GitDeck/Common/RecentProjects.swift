import Foundation

/// 最近打开的项目，最新的在前。
@MainActor
final class RecentProjects {
    static let shared = RecentProjects()

    private let key = "recentProjects"
    private let limit = 30

    var paths: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ path: String) {
        var list = paths.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    func remove(_ path: String) {
        UserDefaults.standard.set(paths.filter { $0 != path }, forKey: key)
    }
}
