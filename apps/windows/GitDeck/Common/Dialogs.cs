using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitDeck.Common;

public static class Dialogs
{
    /// 错误提示（对应 mac 端的 NSAlert 警告框）。
    public static async Task ShowError(XamlRoot root, Exception error) =>
        await ShowMessage(root, L10n.Tr("error.title"), L10n.Message(error));

    public static async Task ShowMessage(XamlRoot root, string title, string message)
    {
        var dialog = Create(root, title);
        dialog.Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        dialog.CloseButtonText = L10n.Tr("common.close");
        await dialog.ShowAsync();
    }

    public static ContentDialog Create(XamlRoot root, string title) => new()
    {
        XamlRoot = root,
        Title = title,
        RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
        DefaultButton = ContentDialogButton.Primary,
    };

    /// 选择文件夹；取消时返回 null。
    public static async Task<string?> PickFolder(Window window)
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(window.AppWindow.Id);
        var result = await picker.PickSingleFolderAsync();
        return result?.Path;
    }
}
