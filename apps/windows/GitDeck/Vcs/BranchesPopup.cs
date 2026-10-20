using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Project;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace GitDeck.Vcs;

/// VCS 分支组件弹出的 Branches 弹窗：搜索框、常用操作、本地分支、远程分支与标签（与 mac 端 BranchesPopover 一致）。
public sealed class BranchesPopup
{
    private readonly ProjectModel _model;
    private readonly GitOperations _operations;
    private readonly Action _commit;
    // 弹窗限制在窗口内绘制（与 IDEA 一致），也便于调试截图。
    private readonly Flyout _flyout = new() { ShouldConstrainToRootBounds = true };
    private readonly TextBox _search = new() { PlaceholderText = L10n.Tr("branches.search.placeholder") };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };

    public BranchesPopup(ProjectModel model, GitOperations operations, Action commit)
    {
        _model = model;
        _operations = operations;
        _commit = commit;
        var root = new Grid { Width = 400, Height = 480, RowSpacing = 8 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_list, 1);
        root.Children.Add(_search);
        root.Children.Add(_list);
        _flyout.Content = root;
        var presenter = new Style(typeof(FlyoutPresenter));
        presenter.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(8)));
        presenter.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, 480.0));
        _flyout.FlyoutPresenterStyle = presenter;
        _search.TextChanged += (_, _) => Rebuild();
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Down && _list.Items.Count > 0)
            {
                _list.Focus(FocusState.Keyboard);
                e.Handled = true;
            }
        };
        _list.ItemClick += (_, e) => Activate(e.ClickedItem as ListViewItem);
        _list.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Activate(_list.SelectedItem as ListViewItem);
        };
        _flyout.Opened += (_, _) => _search.Focus(FocusState.Programmatic);
    }

    public void ShowAt(FrameworkElement anchor)
    {
        _search.Text = "";
        Rebuild();
        _flyout.ShowAt(anchor, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    private abstract record Row;

    private sealed record ActionRow(string Title, Common.Icon Icon, string? Shortcut, Func<Task> Run) : Row;

    private sealed record BranchRow(BranchRef Branch) : Row;

    private sealed record TagRow(TagInfo Tag) : Row;

    private void Rebuild()
    {
        var query = _search.Text.Trim();
        bool Matches(string name) => query.Length == 0 || name.Contains(query, StringComparison.OrdinalIgnoreCase);
        _list.Items.Clear();
        var ops = _operations;
        if (query.Length == 0)
        {
            // 合并 / 变基等进行中时，与 IDEA 一样在最上方提供继续与中止操作。
            switch (_model.Status.State)
            {
                case RepositoryState.Rebasing:
                    Add(new ActionRow(L10n.Tr("git.action.continueRebase"), Common.Icon.Refresh, null, ops.ContinueRebase));
                    Add(new ActionRow(L10n.Tr("git.action.abortRebase"), Common.Icon.Close, null, ops.AbortRebase));
                    break;
                case RepositoryState.Merging:
                    Add(new ActionRow(L10n.Tr("git.action.abortMerge"), Common.Icon.Close, null, ops.AbortMerge));
                    break;
                case RepositoryState.CherryPicking:
                    Add(new ActionRow(L10n.Tr("git.action.continueCherryPick"), Common.Icon.Refresh, null, ops.ContinueCherryPick));
                    Add(new ActionRow(L10n.Tr("git.action.abortCherryPick"), Common.Icon.Close, null, ops.AbortCherryPick));
                    break;
                case RepositoryState.Reverting:
                    Add(new ActionRow(L10n.Tr("git.action.continueRevert"), Common.Icon.Refresh, null, ops.ContinueRevert));
                    Add(new ActionRow(L10n.Tr("git.action.abortRevert"), Common.Icon.Close, null, ops.AbortRevert));
                    break;
            }
            Add(new ActionRow(L10n.Tr("git.action.update"), Common.Icon.Update, "Ctrl+T", ops.UpdateProject));
            Add(new ActionRow(L10n.Tr("git.action.commit"), Common.Icon.Commit, "Ctrl+K", () =>
            {
                _commit();
                return Task.CompletedTask;
            }));
            Add(new ActionRow(L10n.Tr("git.action.push"), Common.Icon.Push, "Ctrl+Shift+K", ops.Push));
            Add(new ActionRow(L10n.Tr("branches.action.new"), Common.Icon.Branch, "Ctrl+Alt+N", () => ops.NewBranch()));
            Add(new ActionRow(L10n.Tr("branches.action.checkoutRevision"), Common.Icon.Commit, null, ops.CheckoutRevisionDialog));
        }
        var local = _model.Branches.Where(b => b.Kind == BranchKind.Local && Matches(b.Name)).OrderByDescending(b => b.IsCurrent).ToList();
        var remote = _model.Branches.Where(b => b.Kind == BranchKind.Remote && Matches(b.Name)).ToList();
        var tags = _model.Tags.Where(t => Matches(t.Name)).ToList();
        if (local.Count > 0)
        {
            Section(L10n.Tr("branches.section.local"));
            foreach (var branch in local) Add(new BranchRow(branch));
        }
        if (remote.Count > 0)
        {
            Section(L10n.Tr("branches.section.remote"));
            foreach (var branch in remote) Add(new BranchRow(branch));
        }
        if (tags.Count > 0)
        {
            Section(L10n.Tr("branches.section.tags"));
            foreach (var tag in tags) Add(new TagRow(tag));
        }
    }

    private void Section(string title) => _list.Items.Add(new ListViewItem
    {
        IsEnabled = false,
        MinHeight = 26,
        Content = new TextBlock { Text = title, FontSize = 11, FontWeight = FontWeights.SemiBold, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] },
    });

    private void Add(Row row)
    {
        var (icon, title, detail, bold) = row switch
        {
            ActionRow a => (a.Icon, a.Title, a.Shortcut ?? "", false),
            BranchRow b => (Common.Icon.Branch, b.Branch.Name, BranchDetail(b.Branch), b.Branch.IsCurrent),
            TagRow t => (Common.Icon.Commit, t.Tag.Name, t.Tag.Message ?? t.Tag.Target[..Math.Min(8, t.Tag.Target.Length)], false),
            _ => (Common.Icon.File, "", "", false),
        };
        var content = new Grid { ColumnSpacing = 8 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal };
        var secondary = new TextBlock { Text = detail, Style = (Style)Application.Current.Resources["SecondaryTextStyle"], VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 };
        Grid.SetColumn(name, 1);
        Grid.SetColumn(secondary, 2);
        content.Children.Add(Icons.Create(icon, 14));
        content.Children.Add(name);
        content.Children.Add(secondary);
        var item = new ListViewItem { Content = content, Tag = row, MinHeight = 28, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        if (row is BranchRow branchRow) ToolTipService.SetToolTip(item, branchRow.Branch.Subject);
        _list.Items.Add(item);
    }

    private static string BranchDetail(BranchRef branch)
    {
        var parts = new List<string>();
        if (branch.Ahead > 0) parts.Add($"↑{branch.Ahead}");
        if (branch.Behind > 0) parts.Add($"↓{branch.Behind}");
        if (branch.Upstream is { } upstream) parts.Add(upstream);
        if (branch.UpstreamGone) parts.Add(L10n.Tr("branches.upstreamGone"));
        return string.Join("  ", parts);
    }

    private void Activate(ListViewItem? item)
    {
        switch (item?.Tag)
        {
            case ActionRow action:
                _flyout.Hide();
                _ = action.Run();
                break;
            case BranchRow branch:
                BranchMenu(branch.Branch).ShowAt(item, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
                break;
            case TagRow tag:
                TagMenu(tag.Tag).ShowAt(item, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
                break;
        }
    }

    private MenuFlyoutItem Item(string text, Func<Task>? action, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled && action is not null };
        if (action is not null)
        {
            item.Click += (_, _) =>
            {
                _flyout.Hide();
                _ = action();
            };
        }
        return item;
    }

    /// 分支操作菜单，项目与 IDEA 的分支子菜单一致；暂未实现的项显示为禁用。
    private MenuFlyout BranchMenu(BranchRef branch)
    {
        var name = branch.Name;
        var current = _model.CurrentBranchTitle;
        var isCurrent = branch.IsCurrent;
        var ops = _operations;
        var local = branch.Kind == BranchKind.Local;
        var menu = new MenuFlyout();
        menu.Items.Add(Item(L10n.Tr("branches.menu.checkout"),
            () => ops.Checkout(local ? GitOperations.TargetKind.Local : GitOperations.TargetKind.Remote, name), !isCurrent));
        menu.Items.Add(Item(L10n.Tr("branches.menu.newFrom", name), () => ops.NewBranch(name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.checkoutAndRebase", current), () => ops.CheckoutAndRebase(name), local && !isCurrent));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("branches.menu.compare", current), () => ops.CompareWithCurrent(name), !isCurrent));
        menu.Items.Add(Item(L10n.Tr("branches.menu.showDiff"), () => ops.ShowDiffWithWorkingTree(name)));
        // AI 评审在 W7 中启用。
        menu.Items.Add(Item(L10n.Tr("branches.menu.aiReview", current, name), null));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("branches.menu.rebaseOnto", current, name), () => ops.Rebase(name), !isCurrent));
        menu.Items.Add(Item(L10n.Tr("branches.menu.mergeInto", name, current), () => ops.Merge(name), !isCurrent));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (local)
        {
            menu.Items.Add(Item(L10n.Tr("branches.menu.update"), () => ops.UpdateBranch(name), branch.Upstream is not null));
            menu.Items.Add(Item(L10n.Tr("branches.menu.push"), ops.Push, isCurrent));
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

    private MenuFlyout TagMenu(TagInfo tag)
    {
        var ops = _operations;
        var name = tag.Name;
        var menu = new MenuFlyout();
        menu.Items.Add(Item(L10n.Tr("tags.menu.checkout"), () => ops.Checkout(GitOperations.TargetKind.Revision, name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.newFrom", name), () => ops.NewBranch(name)));
        menu.Items.Add(Item(L10n.Tr("branches.menu.mergeInto", name, _model.CurrentBranchTitle), () => ops.Merge(name)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(L10n.Tr("tags.menu.push"), () => ops.PushTag(name)));
        menu.Items.Add(Item(L10n.Tr("tags.menu.delete"), () => ops.DeleteTag(name)));
        return menu;
    }
}
