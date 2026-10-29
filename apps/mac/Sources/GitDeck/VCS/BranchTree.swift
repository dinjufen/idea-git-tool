import Foundation
import GitDeckCore

/// 分支树中的节点：HEAD、分组（最近 / 本地 / 远程 / 标签）、按 `/` 拆出的文件夹、分支或标签。
final class BranchTreeNode: NSObject {
    enum Kind { case head, group, folder, branch, tag }

    let kind: Kind
    let title: String
    /// 展开状态的键（分组与文件夹）；分支与标签为完整引用名。
    let key: String
    let branch: BranchRef?
    let tag: TagInfo?
    var children: [BranchTreeNode] = []
    /// 排序用：当前分支 0、收藏 1、其余 3；文件夹取其中最靠前的一项（含当前或收藏分支的文件夹排在前面）。
    var rank = 3

    init(_ kind: Kind, _ title: String, key: String, branch: BranchRef? = nil, tag: TagInfo? = nil) {
        self.kind = kind
        self.title = title
        self.key = key
        self.branch = branch
        self.tag = tag
    }

    var isExpandable: Bool { kind == .group || kind == .folder }
}

/// 按 IDEA 的方式组织分支：名称中的 `/` 拆成文件夹；同一层按“当前分支、收藏、其余”排序，
/// 同一档内文件夹在前、分支在后，再按名称排序（分支弹窗与 Git 日志左侧的分支面板共用）。
enum BranchTree {
    private enum Item {
        case branch(BranchRef)
        case tag(TagInfo)
    }

    /// `keepOrder`：同一档内保持传入的顺序而不按名称排序（“最近”分组按签出顺序）。
    static func addBranches(_ parent: BranchTreeNode, _ branches: [BranchRef], favorites: Set<String>, keepOrder: Bool = false) {
        add(parent, branches.map { ($0.name, Item.branch($0)) }, prefix: parent.key, favorites: favorites, keepOrder: keepOrder)
    }

    static func addTags(_ parent: BranchTreeNode, _ tags: [TagInfo]) {
        add(parent, tags.map { ($0.name, Item.tag($0)) }, prefix: parent.key, favorites: [], keepOrder: false)
    }

    private static func add(_ parent: BranchTreeNode, _ items: [(String, Item)], prefix: String, favorites: Set<String>, keepOrder: Bool) {
        var nodes: [BranchTreeNode] = []
        var folders: [String: [(String, Item)]] = [:]
        var folderOrder: [String] = []
        for (path, item) in items {
            if let slash = path.firstIndex(of: "/"), slash != path.startIndex, path.index(after: slash) != path.endIndex {
                let folder = String(path[..<slash])
                if folders[folder] == nil { folderOrder.append(folder) }
                folders[folder, default: []].append((String(path[path.index(after: slash)...]), item))
                continue
            }
            switch item {
            case let .branch(branch):
                let node = BranchTreeNode(.branch, path, key: branch.fullRef, branch: branch)
                node.rank = branch.isCurrent ? 0 : favorites.contains(branch.fullRef) ? 1 : 3
                nodes.append(node)
            case let .tag(tag):
                nodes.append(BranchTreeNode(.tag, path, key: "refs/tags/" + tag.name, tag: tag))
            }
        }
        for folder in folderOrder {
            let key = prefix + "/" + folder
            let node = BranchTreeNode(.folder, folder, key: key)
            add(node, folders[folder] ?? [], prefix: key, favorites: favorites, keepOrder: keepOrder)
            node.rank = node.children.map(\.rank).min() ?? 3
            nodes.append(node)
        }
        // keepOrder 时同一档内保持传入的顺序（按原位置排序，结果稳定）。
        let indexed = Array(nodes.enumerated())
        parent.children += indexed.sorted { a, b in
            let ka = (a.element.rank, a.element.kind == .folder ? 0 : 1)
            let kb = (b.element.rank, b.element.kind == .folder ? 0 : 1)
            if ka != kb { return ka < kb }
            return keepOrder ? a.offset < b.offset : a.element.title.lowercased() < b.element.title.lowercased()
        }.map(\.element)
    }

    /// 把树按展开状态展开为可见行（深度从 0 开始）。`expandAll` 为 true 时（搜索中）展开全部。
    static func flatten(_ roots: [BranchTreeNode], isExpanded: (BranchTreeNode) -> Bool, expandAll: Bool) -> [(node: BranchTreeNode, depth: Int)] {
        var rows: [(BranchTreeNode, Int)] = []
        func visit(_ node: BranchTreeNode, _ depth: Int) {
            rows.append((node, depth))
            guard node.isExpandable, expandAll || isExpanded(node) else { return }
            for child in node.children { visit(child, depth + 1) }
        }
        for root in roots { visit(root, 0) }
        return rows
    }
}

/// 收藏的分支（每个仓库单独保存）。未设置过时与 IDEA 一样默认收藏 main 与 master。
@MainActor
enum BranchFavorites {
    private static func key(_ model: ProjectModel) -> String { "branches.favorites:" + model.rootURL.path.lowercased() }

    static func get(_ model: ProjectModel) -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: key(model)) { return Set(saved) }
        return ["refs/heads/main", "refs/heads/master"]
    }

    static func toggle(_ model: ProjectModel, _ fullRef: String) {
        var set = get(model)
        if set.contains(fullRef) { set.remove(fullRef) } else { set.insert(fullRef) }
        UserDefaults.standard.set(set.sorted(), forKey: key(model))
    }
}
