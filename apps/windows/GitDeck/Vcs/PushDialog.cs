using GitDeck.Common;
using GitDeck.Core;
using GitDeck.Git;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// IDEA 的 Push 对话框：显示 “本地分支 → 远程 : 目标分支” 与待推送的提交，可选推送标签与强制推送（与 mac 端 PushDialog 一致）。
public static class PushDialog
{
    public static async Task<PushOptions?> Show(XamlRoot root, PushTarget target, IReadOnlyList<string> remotes, string projectName)
    {
        var dialog = Dialogs.Create(root, L10n.Tr("push.title", projectName));
        var remote = new ComboBox { MinWidth = 100, IsEnabled = remotes.Count > 1 };
        foreach (var name in remotes) remote.Items.Add(name);
        remote.SelectedItem = target.Remote is { } selected && remotes.Contains(selected) ? selected : remotes.FirstOrDefault();
        var branch = new TextBox { Text = target.RemoteBranch, MinWidth = 180 };
        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                new TextBlock { Text = target.LocalBranch, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                new TextBlock { Text = "→", VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] },
                remote,
                new TextBlock { Text = ":", VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] },
                branch,
            },
        };

        var commits = new ListView { SelectionMode = ListViewSelectionMode.None, Height = 220, BorderThickness = new Thickness(1) };
        Themed.Brush(commits, "SeparatorBrush", (l, b) => l.BorderBrush = b);
        foreach (var commit in target.Commits)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            row.Children.Add(new TextBlock { Text = commit.Subject, TextTrimming = TextTrimming.CharacterEllipsis });
            var author = new TextBlock { Text = commit.AuthorName, Style = (Style)Application.Current.Resources["SecondaryTextStyle"], TextTrimming = TextTrimming.CharacterEllipsis };
            var date = new TextBlock { Text = LogDates.Short(commit.AuthorTime), Style = (Style)Application.Current.Resources["SecondaryTextStyle"] };
            Grid.SetColumn(author, 1);
            Grid.SetColumn(date, 2);
            row.Children.Add(author);
            row.Children.Add(date);
            commits.Items.Add(new ListViewItem { Content = row, MinHeight = 26, Padding = new Thickness(8, 0, 8, 0), HorizontalContentAlignment = HorizontalAlignment.Stretch });
        }
        var summary = new TextBlock
        {
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            Text = target.Remote is null ? L10n.Tr("push.noRemote")
                : target.Commits.Length switch
                {
                    0 => L10n.Tr("push.noCommits"),
                    1 => L10n.Tr("push.oneCommit"),
                    var n => L10n.Tr("push.commits", n),
                },
        };
        var tags = new CheckBox { Content = L10n.Tr("push.tags") };
        // 没有上游的新分支默认设置上游（IDEA 推送新分支时同样会建立跟踪关系）。
        var upstream = new CheckBox { Content = L10n.Tr("push.setUpstream"), IsChecked = !target.HasUpstream, Visibility = target.HasUpstream ? Visibility.Collapsed : Visibility.Visible };
        dialog.Content = new StackPanel
        {
            Spacing = 10,
            Width = 600,
            Children = { header, commits, summary, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Children = { tags, upstream } } },
        };
        dialog.PrimaryButtonText = L10n.Tr("push.push");
        dialog.SecondaryButtonText = L10n.Tr("push.force");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        var canPush = target.Remote is not null;
        dialog.IsPrimaryButtonEnabled = canPush;
        dialog.IsSecondaryButtonEnabled = canPush && target.HasUpstream;
        branch.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = canPush && branch.Text.Trim().Length > 0;

        // 调试参数 -debug.confirm：不显示对话框，直接按默认选项推送（用于自动验证推送流程）。
        var result = DebugOptions.Has("debug.confirm") ? ContentDialogResult.Primary : await dialog.ShowAsync();
        if (result == ContentDialogResult.None || remote.SelectedItem is not string remoteName || branch.Text.Trim().Length == 0) return null;
        var force = result == ContentDialogResult.Secondary;
        var options = new PushOptions(target.LocalBranch, remoteName, branch.Text.Trim(), force, tags.IsChecked == true, upstream.IsChecked == true);
        // 强制推送前确认（IDEA 同样会提示覆盖远程提交的风险）。
        if (force && !await ConfirmDialog.Show(root, L10n.Tr("push.force.confirm.title"),
                L10n.Tr("push.force.confirm.message", $"{remoteName}/{options.RemoteBranch}"), L10n.Tr("push.force")))
        {
            return null;
        }
        return options;
    }
}
