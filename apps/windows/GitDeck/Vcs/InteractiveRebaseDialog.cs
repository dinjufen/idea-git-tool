using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitDeck.Vcs;

/// IDEA 的交互式变基对话框（与 mac 端 InteractiveRebaseDialog 一致）：最新的提交在最上方；
/// 为选中的提交设置动作、调整顺序、改写提交信息。
///
/// WinUI 同一窗口只能同时显示一个对话框，改写 / 压缩的提交信息在列表下方的编辑框中修改，而不是再弹出对话框。
public static class InteractiveRebaseDialog
{
    private sealed class Row(RebaseCommit commit)
    {
        public RebaseCommit Commit { get; } = commit;
        public RebaseAction Action { get; set; } = RebaseAction.Pick;

        /// 改写或压缩后使用的提交信息；null 表示保持原样（压缩时由 git 拼接）。
        public string? Message { get; set; }
    }

    /// 返回按执行顺序（从旧到新）排列的步骤；取消时返回 null。
    public static async Task<RebaseStep[]?> Show(XamlRoot root, RebaseCommit[] commits, string branch)
    {
        // 核心按从旧到新返回；对话框与 Log 一致，最新的在最上方。
        var rows = commits.Reverse().Select(c => new Row(c)).ToList();
        var dialog = Dialogs.Create(root, L10n.Tr("rebase.title", commits.Length, branch));
        dialog.Resources["ContentDialogMaxWidth"] = 820.0;
        var list = new ListView { SelectionMode = ListViewSelectionMode.Extended, Height = 260 };
        var warning = Themed.Foreground(new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center }, "StatusConflictBrush");
        var messageLabel = new TextBlock { Style = (Style)Application.Current.Resources["SecondaryTextStyle"] };
        var message = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 90, IsEnabled = false };
        var updating = false;

        List<int> Selected() =>
            [.. list.SelectedItems.Select(item => list.Items.IndexOf(item)).Where(i => i >= 0 && i < rows.Count).Order()];

        void Reload(IReadOnlyList<int>? select = null)
        {
            var selection = select ?? Selected();
            updating = true;
            list.Items.Clear();
            foreach (var row in rows) list.Items.Add(RowView(row));
            foreach (var index in selection) list.SelectRange(new Microsoft.UI.Xaml.Data.ItemIndexRange(index, 1));
            updating = false;
            Validate();
            ShowMessage();
        }

        // 执行顺序中第一个保留下来的提交不能被压缩或修整（没有可并入的上一个提交）。
        void Validate()
        {
            var firstKept = Enumerable.Reverse(rows).FirstOrDefault(r => r.Action != RebaseAction.Drop);
            var invalid = firstKept is { Action: RebaseAction.Squash or RebaseAction.Fixup };
            var allDropped = firstKept is null;
            warning.Text = invalid ? L10n.Tr("rebase.invalid.firstSquash") : allDropped ? L10n.Tr("rebase.invalid.allDropped") : "";
            dialog.IsPrimaryButtonEnabled = !invalid && !allDropped;
        }

        // 选中单个改写 / 压缩的提交时，在编辑框中显示并修改其提交信息。
        void ShowMessage()
        {
            var selected = Selected();
            var row = selected.Count == 1 ? rows[selected[0]] : null;
            var editable = row is { Action: RebaseAction.Reword or RebaseAction.Squash };
            updating = true;
            message.IsEnabled = editable;
            message.Text = editable ? row!.Message ?? row.Commit.Message : "";
            messageLabel.Text = editable ? L10n.Tr("rebase.message.title", row!.Commit.Hash[..Math.Min(8, row.Commit.Hash.Length)]) : L10n.Tr("rebase.hint");
            updating = false;
        }

        void Set(RebaseAction action)
        {
            var selected = Selected();
            foreach (var index in selected)
            {
                var row = rows[index];
                row.Action = action;
                switch (action)
                {
                    case RebaseAction.Reword:
                        row.Message ??= row.Commit.Message;
                        break;
                    case RebaseAction.Squash:
                        // 预填 “被并入的提交 + 本提交” 的信息，与 IDEA 一样可编辑合并后的信息。
                        var target = rows.Skip(index + 1).FirstOrDefault(r => r.Action is not (RebaseAction.Drop or RebaseAction.Squash or RebaseAction.Fixup));
                        row.Message = string.Join("\n\n", new[] { target?.Message ?? target?.Commit.Message, row.Commit.Message }.OfType<string>());
                        break;
                    default:
                        row.Message = null;
                        break;
                }
            }
            Reload(selected);
            if (action is RebaseAction.Reword or RebaseAction.Squash && selected.Count == 1) message.Focus(FocusState.Programmatic);
        }

        // 上移 = 在列表中靠上 = 执行顺序更晚。
        void Move(int offset)
        {
            var selected = Selected();
            if (selected.Count == 0) return;
            var ordered = offset < 0 ? selected : [.. Enumerable.Reverse(selected)];
            if (ordered[0] + offset < 0 || ordered[0] + offset >= rows.Count) return;
            foreach (var index in ordered) (rows[index], rows[index + offset]) = (rows[index + offset], rows[index]);
            Reload([.. selected.Select(i => i + offset)]);
        }

        Button ActionButton(string key, Action action)
        {
            var button = new Button { Content = L10n.Tr(key), Padding = new Thickness(10, 3, 10, 4) };
            button.Click += (_, _) => action();
            return button;
        }

        var toolbar = new Grid();
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Children =
            {
                ActionButton("rebase.action.pick", () => Set(RebaseAction.Pick)),
                ActionButton("rebase.action.edit", () => Set(RebaseAction.Edit)),
                ActionButton("rebase.action.reword", () => Set(RebaseAction.Reword)),
                ActionButton("rebase.action.squash", () => Set(RebaseAction.Squash)),
                ActionButton("rebase.action.fixup", () => Set(RebaseAction.Fixup)),
                ActionButton("rebase.action.drop", () => Set(RebaseAction.Drop)),
            },
        });
        var moves = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Children = { ActionButton("rebase.moveUp", () => Move(-1)), ActionButton("rebase.moveDown", () => Move(1)) },
        };
        Grid.SetColumn(moves, 1);
        toolbar.Children.Add(moves);

        list.SelectionChanged += (_, _) =>
        {
            if (!updating) ShowMessage();
        };
        message.TextChanged += (_, _) =>
        {
            if (updating || Selected() is not [var index]) return;
            if (message.Text.Trim().Length > 0) rows[index].Message = message.Text.Replace("\r\n", "\n").Replace('\r', '\n');
            var selection = Selected();
            // 只更新该行的标题显示，不重建列表（避免打断输入）。
            list.Items[index] = RowView(rows[index]);
            updating = true;
            foreach (var i in selection) list.SelectRange(new Microsoft.UI.Xaml.Data.ItemIndexRange(i, 1));
            updating = false;
        };

        var border = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Child = list };
        Themed.Brush(border, "SeparatorBrush", (b, brush) => b.BorderBrush = brush);
        dialog.Content = new StackPanel { Spacing = 8, Width = 760, Children = { toolbar, border, messageLabel, message, warning } };
        dialog.PrimaryButtonText = L10n.Tr("rebase.start");
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        Reload([0]);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        return [.. Enumerable.Reverse(rows).Select(r => new RebaseStep(r.Commit.Hash, r.Action, r.Message))];
    }

    private static Grid RowView(Row row)
    {
        var grid = new Grid { ColumnSpacing = 8, Height = 26 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        var action = Themed.Foreground(new TextBlock
        {
            Text = Title(row.Action),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        }, BrushKey(row.Action));
        var hash = Themed.Foreground(new TextBlock
        {
            Text = row.Commit.Hash[..Math.Min(8, row.Commit.Hash.Length)],
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            VerticalAlignment = VerticalAlignment.Center,
        }, "SecondaryTextBrush");
        var subject = Themed.Foreground(new TextBlock
        {
            Text = row.Message is { } message ? message.Split('\n')[0] : row.Commit.Subject,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            TextDecorations = row.Action == RebaseAction.Drop ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None,
        }, row.Message is not null ? "AccentBrush" : "PrimaryTextBrush");
        var author = Themed.Foreground(new TextBlock
        {
            Text = row.Commit.AuthorName,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        }, "SecondaryTextBrush");
        var column = 0;
        foreach (var cell in new FrameworkElement[] { action, hash, subject, author })
        {
            Grid.SetColumn(cell, column++);
            grid.Children.Add(cell);
        }
        return grid;
    }

    private static string Title(RebaseAction action) => action switch
    {
        RebaseAction.Pick => L10n.Tr("rebase.action.pick"),
        RebaseAction.Reword => L10n.Tr("rebase.action.reword"),
        RebaseAction.Edit => L10n.Tr("rebase.action.edit"),
        RebaseAction.Squash => L10n.Tr("rebase.action.squash"),
        RebaseAction.Fixup => L10n.Tr("rebase.action.fixup"),
        _ => L10n.Tr("rebase.action.drop"),
    };

    private static string BrushKey(RebaseAction action) => action switch
    {
        RebaseAction.Pick => "SecondaryTextBrush",
        RebaseAction.Reword or RebaseAction.Edit => "StatusModifiedBrush",
        RebaseAction.Squash or RebaseAction.Fixup => "StatusAddedBrush",
        _ => "StatusConflictBrush",
    };
}
