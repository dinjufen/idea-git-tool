using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// 分支操作菜单，项目与 IDEA 的分支子菜单一致；分支弹窗与 Git 日志左侧的分支面板共用。
public static class BranchMenus
{
    /// `beforeAction`：执行操作前调用（例如关闭弹窗）；`reviewBranch`：AI 评审某个分支相对当前分支的改动。
    public static MenuFlyout ForBranch(BranchRef branch, ProjectModel model, GitOperations ops, Action? beforeAction = null,
        Func<ProjectModel, string, Task>? reviewBranch = null)
    {
        MenuFlyoutItem Item(string text, Func<Task>? action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled && action is not null };
            if (action is not null)
            {
                item.Click += (_, _) =>
                {
                    beforeAction?.Invoke();
                    _ = action();
                };
            }
            return item;
        }

        var name = branch.Name;
        var current = model.CurrentBranchTitle;
        var isCurrent = branch.IsCurrent;
        var local = branch.Kind == BranchKind.Local;
        var menu = new MenuFlyout();
        menu.Items.Add(Item(L10n.Tr("branches.menu.checkout"),
            () => ops.Checkout(local ? GitOperations.TargetKind.Local : GitOperations.TargetKind.Remote, name), !isCurrent));
        menu.Items.Add(Item(L10n.Tr("branches.menu.newFrom", name), () => ops.NewBranch(name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.checkoutAndRebase", current), () => ops.CheckoutAndRebase(name), local && !isCurrent));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("branches.menu.compare", current), () => ops.CompareWithCurrent(name), !isCurrent));
        menu.Items.Add(Item(L10n.Tr("branches.menu.showDiff"), () => ops.ShowDiffWithWorkingTree(name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.aiReview", current, name), reviewBranch is { } review ? () => review(model, name) : null, !isCurrent));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("branches.menu.rebaseOnto", current, name), () => ops.Rebase(name), !isCurrent));
        menu.Items.Add(Item(L10n.Tr("branches.menu.mergeInto", name, current), () => ops.Merge(name), !isCurrent));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (local)
        {
            menu.Items.Add(Item(L10n.Tr("branches.menu.update"), () => ops.UpdateBranch(name), branch.Upstream is not null));
            // 与 IDEA 一致，任何本地分支都可以推送。
            menu.Items.Add(Item(L10n.Tr("branches.menu.push"), () => ops.Push(name)));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item(L10n.Tr("branches.menu.rename"), () => ops.Rename(name)));
            menu.Items.Add(Item(L10n.Tr("branches.menu.delete"), () => ops.Delete(name), !isCurrent));
        }
        else
        {
            menu.Items.Add(Item(L10n.Tr("branches.menu.pull", name, current), () => ops.Merge(name)));
            menu.Items.Add(Item(L10n.Tr("branches.menu.delete"), () => ops.DeleteRemoteBranch(name)));
        }
        return menu;
    }
}
