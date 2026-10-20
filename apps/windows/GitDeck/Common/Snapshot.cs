using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace GitDeck.Common;

/// 调试用：把窗口内容渲染为 PNG（不依赖屏幕状态，显示器休眠或锁屏时也可用）。
/// 有打开的弹出层（对话框、菜单）时截取最上层的弹出内容，与 mac 端截取表单的做法一致。
public static class Snapshot
{
    public static void Schedule(Window window, Action? afterwards = null)
    {
        var path = DebugOptions.Get("debug.snapshot");
        if (path is null) return;
        var delay = DebugOptions.Double("debug.snapshotDelay", 2);
        // 编辑器组件加载后 DispatcherQueueTimer 会停止触发（WinUIEdit 的问题），这里用 XAML 的 DispatcherTimer。
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(delay) };
        timer.Tick += async (_, _) =>
        {
            timer.Stop();
            try
            {
                await Render(window, path);
            }
            catch (Exception e)
            {
                Log.Error("snapshot failed", e);
            }
            finally
            {
                afterwards?.Invoke();
                if (DebugOptions.Has("debug.exit")) AppController.Shared.ExitApplication();
            }
        };
        timer.Start();
    }

    public static async Task Render(Window window, string path)
    {
        if (window.Content is not UIElement content) return;
        // 对话框的弹出层包含半透明遮罩，截取其中的对话框本体；否则截取最上层的弹出内容（菜单等）。
        var popups = VisualTreeHelper.GetOpenPopupsForXamlRoot(content.XamlRoot).Where(p => p.Child is not null).ToList();
        var target = popups.Select(p => p.Child as FrameworkElement).OfType<FrameworkElement>().Select(FindDialog).OfType<FrameworkElement>().LastOrDefault()
            ?? popups.LastOrDefault()?.Child
            ?? content;

        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(target);
        var pixels = await bitmap.GetPixelsAsync();
        var scale = content.XamlRoot.RasterizationScale;
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96 * scale, 96 * scale, pixels.ToArray());
        await encoder.FlushAsync();
        stream.Seek(0);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        await using var file = File.Create(path);
        await stream.AsStreamForRead().CopyToAsync(file);
    }

    private static FrameworkElement? FindDialog(FrameworkElement root)
    {
        if (root is Microsoft.UI.Xaml.Controls.ContentDialog dialog)
        {
            return dialog.FindName("BackgroundElement") as FrameworkElement ?? dialog;
        }
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            if (VisualTreeHelper.GetChild(root, i) is FrameworkElement child && FindDialog(child) is { } found) return found;
        }
        return null;
    }
}
