using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace GitDeck.Git;

/// Log 右侧的提交详情：上方为改动文件列表，下方为提交信息、作者、哈希与所在分支（与 mac 端 CommitDetailsView 一致）。
public sealed class CommitDetailsView : Grid
{
    private readonly ListView _files = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly RichTextBlock _message = new() { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 8, 10, 8) };
    private readonly TextBlock _empty = new()
    {
        Text = L10n.Tr("log.details.empty"),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Grid _content = new();
    private CommitDetails? _current;

    public CommitDetailsView()
    {
        Themed.Background(this, "ToolWindowBackgroundBrush");
        _empty.Style = (Style)Application.Current.Resources["SecondaryTextStyle"];
        _content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(45, GridUnitType.Star) });
        _content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        _content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(55, GridUnitType.Star) });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_files, L10n.Tr("log.details.files"));
        _files.DoubleTapped += (_, _) => ShowDiffForSelection();
        _files.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) ShowDiffForSelection();
        };
        _files.RightTapped += (_, e) =>
        {
            if (FindItem(e.OriginalSource) is { } item) _files.SelectedItem = item;
            FileMenu().ShowAt(_files, e.GetPosition(_files));
            e.Handled = true;
        };
        var divider = Themed.Background(new Border(), "SeparatorBrush");
        var scroll = new ScrollViewer { Content = _message };
        SetRow(divider, 1);
        SetRow(scroll, 2);
        _content.Children.Add(_files);
        _content.Children.Add(divider);
        _content.Children.Add(scroll);
        Children.Add(_content);
        Children.Add(_empty);
        Show(null);
    }

    public event Action<string>? OpenFile;

    public event Action<CommitDetails, ChangedFile>? ShowDiff;

    public event Action<string>? ShowHistory;

    /// 显示提交详情；null 显示空状态。`branches` 为包含该提交的分支，加载完成前为 null。
    public void Show(CommitDetails? details, string[]? branches = null)
    {
        _current = details;
        _content.Visibility = details is null ? Visibility.Collapsed : Visibility.Visible;
        _empty.Visibility = details is null ? Visibility.Visible : Visibility.Collapsed;
        _files.Items.Clear();
        _message.Blocks.Clear();
        if (details is null) return;
        foreach (var file in details.Files.OrderBy(f => f.Path, StringComparer.OrdinalIgnoreCase)) _files.Items.Add(FileRow(file));
        _message.Blocks.Add(Format(details, branches));
    }

    private ListViewItem FileRow(ChangedFile file)
    {
        var name = Themed.Brush(new TextBlock
        {
            Text = Path.GetFileName(file.Path),
            TextDecorations = file.Kind == ChangeKind.Deleted ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None,
        }, file.Kind.BrushKey(), (t, b) => t.Foreground = b);
        var directory = Path.GetDirectoryName(file.Path)?.Replace('\\', '/') ?? "";
        var detail = new TextBlock
        {
            Text = file.OrigPath is { } orig ? L10n.Tr("commit.renamedFrom", orig) : directory,
            Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { Icons.Create(Icon.File, 14), name, detail } };
        var item = new ListViewItem { Content = row, Tag = file, MinHeight = 24, Height = 24, Padding = new Thickness(8, 0, 4, 0) };
        ToolTipService.SetToolTip(item, file.Path);
        return item;
    }

    private Paragraph Format(CommitDetails d, string[]? branches)
    {
        var paragraph = new Paragraph();
        var lines = d.Message.Split('\n', 2);
        paragraph.Inlines.Add(new Run { Text = lines[0], FontWeight = FontWeights.SemiBold });
        paragraph.Inlines.Add(new LineBreak());
        if (lines.Length > 1 && lines[1].Trim('\n', '\r').Length > 0)
        {
            paragraph.Inlines.Add(new LineBreak());
            paragraph.Inlines.Add(new Run { Text = lines[1].Trim('\n', '\r') });
            paragraph.Inlines.Add(new LineBreak());
        }
        paragraph.Inlines.Add(new LineBreak());
        var secondary = Icons.ThemeBrush(this, "SecondaryTextBrush");
        void Secondary(string text)
        {
            paragraph.Inlines.Add(new Run { Text = text, Foreground = secondary, FontSize = 12 });
            paragraph.Inlines.Add(new LineBreak());
        }
        Secondary(L10n.Tr("log.details.author", d.Hash[..Math.Min(8, d.Hash.Length)], d.AuthorName, d.AuthorEmail, LogDates.Detailed(d.AuthorTime)));
        if (d.CommitterName != d.AuthorName || d.CommitterTime != d.AuthorTime)
        {
            Secondary(L10n.Tr("log.details.committer", d.CommitterName, LogDates.Detailed(d.CommitterTime)));
        }
        if (branches is not null)
        {
            var list = string.Join(", ", branches.Take(10));
            Secondary(branches.Length switch
            {
                0 => L10n.Tr("log.details.noBranches"),
                1 => L10n.Tr("log.details.oneBranch", list),
                _ => L10n.Tr("log.details.branches", branches.Length, list),
            });
        }
        return paragraph;
    }

    private ChangedFile? SelectedFile => (_files.SelectedItem as ListViewItem)?.Tag as ChangedFile;

    private void ShowDiffForSelection()
    {
        if (_current is { } current && SelectedFile is { } file) ShowDiff?.Invoke(current, file);
    }

    private MenuFlyout FileMenu()
    {
        var menu = new MenuFlyout();
        void Add(string key, Action action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = L10n.Tr(key), IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        var file = SelectedFile;
        Add("commit.action.showDiff", ShowDiffForSelection, file is not null);
        Add("commit.action.jumpToSource", () => OpenFile?.Invoke(file!.Path), file is { Kind: not ChangeKind.Deleted });
        Add("git.action.showHistory", () => ShowHistory?.Invoke(file!.Path), file is not null && ShowHistory is not null);
        return menu;
    }

    private static ListViewItem? FindItem(object source)
    {
        for (var element = source as DependencyObject; element is not null; element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            if (element is ListViewItem item) return item;
        }
        return null;
    }
}
