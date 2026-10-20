using GitDeck.Common;
using GitDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Welcome;

/// IDEA 的 “Get from Version Control”：输入仓库地址与本地目录，克隆后打开项目（与 mac 端 CloneDialog 一致）。
public sealed class CloneDialog
{
    private const string ParentKey = "clone.parentDirectory";

    private readonly Window _owner;
    private readonly ContentDialog _dialog;
    private readonly TextBox _url = new() { PlaceholderText = "https://github.com/user/repo.git", MinWidth = 420 };
    private readonly TextBox _directory = new() { MinWidth = 330 };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap };

    /// 用户手动修改过目录后不再随地址自动更新。
    private bool _directoryEdited;
    private bool _updating;

    public CloneDialog(Window owner)
    {
        _owner = owner;
        _dialog = Dialogs.Create(owner.Content.XamlRoot, L10n.Tr("clone.title"));
        _dialog.PrimaryButtonText = L10n.Tr("clone.confirm");
        _dialog.CloseButtonText = L10n.Tr("common.cancel");
        Themed.Foreground(_error, "ErrorTextBrush");

        var browse = new Button { Content = L10n.Tr("clone.browse") };
        browse.Click += async (_, _) => await Browse();
        var directoryRow = new Grid { ColumnSpacing = 6 };
        directoryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        directoryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        directoryRow.Children.Add(_directory);
        Grid.SetColumn(browse, 1);
        directoryRow.Children.Add(browse);

        var grid = new Grid { RowSpacing = 8, ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < 3; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Add(grid, Label("clone.url"), 0, 0);
        Add(grid, _url, 0, 1);
        Add(grid, Label("clone.directory"), 1, 0);
        Add(grid, directoryRow, 1, 1);
        Add(grid, _error, 2, 1);
        _dialog.Content = grid;

        _directory.Text = DefaultParent;
        _url.TextChanged += (_, _) =>
        {
            if (!_directoryEdited) UpdateDirectory();
            Revalidate();
        };
        _directory.TextChanged += (_, _) =>
        {
            if (!_updating) _directoryEdited = true;
            Revalidate();
        };
        Revalidate();
    }

    public sealed record Request(string Url, string Directory);

    private static string DefaultParent =>
        Settings.GetString(ParentKey) ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public async Task<Request?> Run()
    {
        await PasteRepositoryUrl();
        _url.Focus(FocusState.Programmatic);
        if (await _dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        var directory = Path.GetFullPath(Environment.ExpandEnvironmentVariables(_directory.Text.Trim()));
        if (Path.GetDirectoryName(directory) is { } parent) Settings.Set(ParentKey, parent);
        return new Request(_url.Text.Trim(), directory);
    }

    /// 克隆进度（不确定进度的转圈 + 仓库地址），没有按钮，克隆结束后由调用方关闭。
    public static ContentDialog Progress(XamlRoot root, string url)
    {
        var dialog = Dialogs.Create(root, L10n.Tr("clone.title"));
        dialog.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Children =
            {
                new ProgressRing { IsActive = true, Width = 20, Height = 20 },
                new TextBlock { Text = L10n.Tr("clone.progress", url), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 420, VerticalAlignment = VerticalAlignment.Center },
            },
        };
        return dialog;
    }

    /// 与 IDEA 一致：剪贴板中是仓库地址时自动填入。
    private async Task PasteRepositoryUrl()
    {
        try
        {
            var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (!content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
            var text = (await content.GetTextAsync()).Trim();
            if (LooksLikeRepositoryUrl(text)) _url.Text = text;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            // 剪贴板被其他程序占用时忽略。
        }
    }

    private static bool LooksLikeRepositoryUrl(string text) =>
        !text.Contains('\n') && (text.StartsWith("https://", StringComparison.Ordinal) || text.StartsWith("http://", StringComparison.Ordinal)
            || text.StartsWith("ssh://", StringComparison.Ordinal) || text.StartsWith("git@", StringComparison.Ordinal)
            || text.EndsWith(".git", StringComparison.Ordinal));

    private async Task Browse()
    {
        // 文件夹选择器会挂在所属窗口上，此时对话框仍保持打开。
        if (await Dialogs.PickFolder(_owner) is not { } folder) return;
        var url = _url.Text.Trim();
        SetDirectory(url.Length == 0 ? folder : Path.Combine(folder, CoreApi.CloneDirectoryName(url)));
        _directoryEdited = true;
    }

    /// 目录 = 上次使用的父目录 + 从地址推断的名称。
    private void UpdateDirectory()
    {
        var url = _url.Text.Trim();
        SetDirectory(url.Length == 0 ? DefaultParent : Path.Combine(DefaultParent, CoreApi.CloneDirectoryName(url)));
    }

    private void SetDirectory(string path)
    {
        _updating = true;
        _directory.Text = path;
        _updating = false;
    }

    private void Revalidate()
    {
        var url = _url.Text.Trim();
        var directory = _directory.Text.Trim();
        string? error = null;
        if (url.Length > 0 && directory.Length > 0)
        {
            if (File.Exists(directory) || (Directory.Exists(directory) && Directory.EnumerateFileSystemEntries(directory).Any()))
            {
                error = L10n.Tr("clone.error.exists");
            }
        }
        _error.Text = error ?? "";
        _error.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
        _dialog.IsPrimaryButtonEnabled = url.Length > 0 && directory.Length > 0 && error is null;
    }

    private static TextBlock Label(string key) => new() { Text = L10n.Tr(key), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };

    private static void Add(Grid grid, FrameworkElement element, int row, int column)
    {
        Grid.SetRow(element, row);
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }
}
