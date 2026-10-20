using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace GitDeck.Common;

public static class WindowHelper
{
    /// 按逻辑像素设置窗口大小，并在当前显示器的工作区居中。
    public static void ResizeAndCenter(Window window, double width, double height)
    {
        var scale = Scale(window);
        var size = new SizeInt32((int)(width * scale), (int)(height * scale));
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        window.AppWindow.MoveAndResize(new RectInt32(
            area.X + Math.Max(0, (area.Width - size.Width) / 2),
            area.Y + Math.Max(0, (area.Height - size.Height) / 2),
            Math.Min(size.Width, area.Width),
            Math.Min(size.Height, area.Height)));
    }

    public static void SetMinimumSize(Window window, double width, double height)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            var scale = Scale(window);
            presenter.PreferredMinimumWidth = (int)(width * scale);
            presenter.PreferredMinimumHeight = (int)(height * scale);
        }
    }

    public static void SetIcon(Window window) =>
        window.AppWindow.SetIcon(Path.Combine(AppInfo.AppDirectory, "Assets", "GitDeck.ico"));

    public static double Scale(Window window) =>
        GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
