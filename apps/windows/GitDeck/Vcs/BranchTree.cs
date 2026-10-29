using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;

namespace GitDeck.Vcs;

/// 分支树中的节点：分组（最近 / 本地 / 远程 / 标签）、按 `/` 拆出的文件夹、分支或标签。
public sealed class BranchTreeNode(BranchTreeNode.NodeKind kind, string title, string key, BranchRef? branch = null, TagInfo? tag = null)
{
    public enum NodeKind { Head, Group, Folder, Branch, Tag }

    public NodeKind Kind { get; } = kind;

    public string Title { get; } = title;

    /// 展开状态的键（分组与文件夹）；分支与标签为完整引用名。
    public string Key { get; } = key;

    public BranchRef? Branch { get; } = branch;

    public TagInfo? Tag { get; } = tag;

    public List<BranchTreeNode> Children { get; } = [];

    /// 排序用：当前分支 0、收藏 1、其余 3；文件夹取其中最靠前的一项（含当前或收藏分支的文件夹排在前面）。
    public int Rank { get; set; } = 3;

    public bool IsExpandable => Kind is NodeKind.Group or NodeKind.Folder;
}

/// 按 IDEA 的方式组织分支：名称中的 `/` 拆成文件夹；同一层按“当前分支、收藏、其余”排序，
/// 同一档内文件夹在前、分支在后，再按名称排序（分支弹窗与 Git 日志左侧的分支面板共用）。
public static class BranchTree
{
    /// `keepOrder`：同一档内保持传入的顺序而不按名称排序（“最近”分组按签出顺序）。
    public static void AddBranches(BranchTreeNode parent, IEnumerable<BranchRef> branches, ISet<string> favorites, bool keepOrder = false) =>
        Add(parent, branches.Select(b => (b.Name, (object)b)), parent.Key, favorites, keepOrder);

    public static void AddTags(BranchTreeNode parent, IEnumerable<TagInfo> tags) =>
        Add(parent, tags.Select(t => (t.Name, (object)t)), parent.Key, new HashSet<string>(), keepOrder: false);

    private static void Add(BranchTreeNode parent, IEnumerable<(string Path, object Item)> items, string keyPrefix, ISet<string> favorites, bool keepOrder)
    {
        var leaves = new List<BranchTreeNode>();
        var folders = new Dictionary<string, List<(string, object)>>(StringComparer.Ordinal);
        foreach (var (path, item) in items)
        {
            var slash = path.IndexOf('/');
            if (slash > 0 && slash < path.Length - 1)
            {
                var folder = path[..slash];
                if (!folders.TryGetValue(folder, out var children)) folders[folder] = children = [];
                children.Add((path[(slash + 1)..], item));
                continue;
            }
            leaves.Add(item switch
            {
                BranchRef branch => new BranchTreeNode(BranchTreeNode.NodeKind.Branch, path, branch.FullRef, branch: branch)
                {
                    Rank = branch.IsCurrent ? 0 : favorites.Contains(branch.FullRef) ? 1 : 3,
                },
                TagInfo tag => new BranchTreeNode(BranchTreeNode.NodeKind.Tag, path, "refs/tags/" + tag.Name, tag: tag),
                _ => throw new ArgumentException("unexpected item"),
            });
        }
        var nodes = new List<BranchTreeNode>(leaves);
        foreach (var (folder, children) in folders)
        {
            var key = keyPrefix + "/" + folder;
            var node = new BranchTreeNode(BranchTreeNode.NodeKind.Folder, folder, key);
            Add(node, children, key, favorites, keepOrder);
            node.Rank = node.Children.Count == 0 ? 3 : node.Children.Min(c => c.Rank);
            nodes.Add(node);
        }
        var ordered = nodes.OrderBy(n => n.Rank).ThenBy(n => n.Kind == BranchTreeNode.NodeKind.Folder ? 0 : 1);
        // OrderBy 是稳定排序：keepOrder 时同一档内保持传入的顺序。
        parent.Children.AddRange(keepOrder ? ordered : ordered.ThenBy(n => n.Title, StringComparer.OrdinalIgnoreCase));
    }

    /// 把树按展开状态展开为可见行（深度从 0 开始）。`expandAll` 为 true 时（搜索中）展开全部。
    public static List<(BranchTreeNode Node, int Depth)> Flatten(IEnumerable<BranchTreeNode> roots, Func<BranchTreeNode, bool> isExpanded, bool expandAll)
    {
        var rows = new List<(BranchTreeNode, int)>();
        void Visit(BranchTreeNode node, int depth)
        {
            rows.Add((node, depth));
            if (!node.IsExpandable || !(expandAll || isExpanded(node))) return;
            foreach (var child in node.Children) Visit(child, depth + 1);
        }
        foreach (var root in roots) Visit(root, 0);
        return rows;
    }
}

/// 收藏的分支（每个仓库单独保存）。未设置过时与 IDEA 一样默认收藏 main 与 master。
public static class BranchFavorites
{
    private static string Key(ProjectModel model) => "branches.favorites:" + model.RootPath.ToLowerInvariant();

    public static HashSet<string> Get(ProjectModel model) =>
        Settings.Contains(Key(model)) ? [.. Settings.GetStringList(Key(model))] : ["refs/heads/main", "refs/heads/master"];

    public static void Toggle(ProjectModel model, string fullRef)
    {
        var favorites = Get(model);
        if (!favorites.Remove(fullRef)) favorites.Add(fullRef);
        Settings.Set(Key(model), favorites.OrderBy(f => f, StringComparer.Ordinal));
    }
}
