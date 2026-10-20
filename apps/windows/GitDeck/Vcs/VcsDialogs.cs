using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Vcs;

/// Git 相关设置（与 mac 端 GitSettings 一致）。
public static class GitSettings
{
    private const string PathKey = "git.executable";
    private const string UpdateMethodKey = "update.method";
    private const string ShowUpdateDialogKey = "update.showDialog";

    /// 指定的 git 可执行文件；为空时自动查找。
    public static string? ExecutablePath
    {
        get => Settings.GetString(PathKey) is { Length: > 0 } path ? path : null;
        set
        {
            Settings.Set(PathKey, value ?? "");
            Apply();
        }
    }

    /// 把设置传给核心（启动时与修改后调用）；只影响之后打开的仓库。
    public static void Apply() => CoreApi.SetGitExecutable(ExecutablePath);

    public static UpdateMethod UpdateMethod
    {
        get => Settings.GetString(UpdateMethodKey) == "rebase" ? UpdateMethod.Rebase : UpdateMethod.Merge;
        set => Settings.Set(UpdateMethodKey, value == UpdateMethod.Rebase ? "rebase" : "merge");
    }

    /// Update Project 时是否显示选择更新方式的对话框（IDEA 的 “Don't show again”）。
    public static bool ShowUpdateDialog
    {
        get => Settings.GetBool(ShowUpdateDialogKey, true);
        set => Settings.Set(ShowUpdateDialogKey, value);
    }
}

/// 输入名称的对话框（新建分支、重命名、签出修订等），输入时实时校验，不合法时禁用确定按钮（与 mac 端 NameDialog 一致）。
public static class NameDialog
{
    public sealed record Result(string Name, bool Checked);

    /// <param name="validate">返回错误信息；合法时返回 null。</param>
    public static async Task<Result?> Show(XamlRoot root, string title, string? message, string initial, string confirm,
        Func<string, string?> validate, string? checkbox = null, bool isChecked = true)
    {
        // 调试参数 -debug.confirm：不显示对话框，直接按初始值确认（用于自动验证流程）。
        if (DebugOptions.Has("debug.confirm") && initial.Length > 0) return new Result(initial, isChecked);
        var dialog = Dialogs.Create(root, title);
        dialog.PrimaryButtonText = confirm;
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        var field = new TextBox { Text = initial, Width = 340 };
        var error = Themed.Foreground(new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap }, "ErrorTextBrush");
        var box = checkbox is null ? null : new CheckBox { Content = checkbox, IsChecked = isChecked };
        var stack = new StackPanel { Spacing = 6 };
        if (!string.IsNullOrEmpty(message)) stack.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        stack.Children.Add(field);
        stack.Children.Add(error);
        if (box is not null) stack.Children.Add(box);
        dialog.Content = stack;
        void Revalidate()
        {
            var name = field.Text.Trim();
            var problem = name.Length == 0 ? null : validate(name);
            error.Text = problem ?? "";
            error.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = name.Length > 0 && problem is null;
        }
        field.TextChanged += (_, _) => Revalidate();
        Revalidate();
        dialog.Opened += (_, _) =>
        {
            field.Focus(FocusState.Programmatic);
            field.SelectAll();
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        return new Result(field.Text.Trim(), box?.IsChecked == true);
    }
}

/// 确认对话框（破坏性操作前）。
public static class ConfirmDialog
{
    public static async Task<bool> Show(XamlRoot root, string title, string message, string confirm)
    {
        var dialog = Dialogs.Create(root, title);
        dialog.Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
        dialog.PrimaryButtonText = confirm;
        dialog.CloseButtonText = L10n.Tr("common.cancel");
        dialog.DefaultButton = ContentDialogButton.Close;
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}

/// 一组单选项：每项为简短的标题加一段可换行的说明（与 mac 端 RadioOptionsView 一致）。
public sealed class RadioOptions : StackPanel
{
    private readonly List<RadioButton> _buttons = [];

    public RadioOptions(IEnumerable<(string Title, string? Detail)> options, int selected)
    {
        Spacing = 6;
        var group = Guid.NewGuid().ToString();
        var index = 0;
        foreach (var (title, detail) in options)
        {
            var radio = new RadioButton { Content = title, GroupName = group, IsChecked = index++ == selected };
            _buttons.Add(radio);
            var item = new StackPanel { Children = { radio } };
            if (!string.IsNullOrEmpty(detail))
            {
                item.Children.Add(new TextBlock
                {
                    Text = detail,
                    Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(28, -2, 0, 0),
                });
            }
            Children.Add(item);
        }
    }

    public int SelectedIndex => _buttons.FindIndex(b => b.IsChecked == true);
}

/// 列表对话框：分组标题 + 可双击的行（Compare with Current、Show Diff with Working Tree 等，与 mac 端 ListSheet 一致）。
public static class ListDialog
{
    public abstract record Item;

    public sealed record Header(string Title) : Item;

    public sealed record Row(string Title, string Detail, Action Activate) : Item;

    public static async Task Show(XamlRoot root, string title, string message, IReadOnlyList<Item> items, string emptyText)
    {
        var dialog = Dialogs.Create(root, title);
        dialog.CloseButtonText = L10n.Tr("common.close");
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 380, Width = 560 };
        ContentDialog? self = dialog;
        foreach (var item in items)
        {
            switch (item)
            {
                case Header header:
                    list.Items.Add(new ListViewItem
                    {
                        IsEnabled = false,
                        Content = new TextBlock { Text = header.Title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                    });
                    break;
                case Row row:
                    var content = new StackPanel { Spacing = 1, Padding = new Thickness(0, 3, 0, 3) };
                    content.Children.Add(new TextBlock { Text = row.Title, TextTrimming = TextTrimming.CharacterEllipsis });
                    if (row.Detail.Length > 0)
                    {
                        content.Children.Add(new TextBlock { Text = row.Detail, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] });
                    }
                    var entry = new ListViewItem { Content = content, Tag = row };
                    list.Items.Add(entry);
                    break;
            }
        }
        list.DoubleTapped += (_, _) =>
        {
            if (list.SelectedItem is ListViewItem { Tag: Row row })
            {
                self.Hide();
                row.Activate();
            }
        };
        var hasRows = items.OfType<Row>().Any();
        dialog.Content = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = hasRows ? message : emptyText, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["SecondaryTextStyle"] },
                list,
            },
        };
        await dialog.ShowAsync();
    }
}
