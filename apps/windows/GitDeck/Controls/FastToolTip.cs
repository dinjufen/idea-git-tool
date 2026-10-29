using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace GitDeck.Controls;

/// 更快显示的悬停提示：WinUI 的提示约 1 秒后才出现，且没有可调的延迟。纯图标按钮靠提示说明用途，
/// 指针停留 0.4 秒就打开元素上已设置的提示（与 mac 端 NSInitialToolTipDelay 一致），移开或按下时关闭。
public static class FastToolTip
{
    private static readonly TimeSpan Delay = TimeSpan.FromMilliseconds(400);

    public static void Attach(FrameworkElement element)
    {
        // 编辑器组件加载后 DispatcherQueueTimer 会停止触发（WinUIEdit 的问题），这里用 XAML 的 DispatcherTimer。
        var timer = new DispatcherTimer { Interval = Delay };
        ToolTip? opened = null;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (ToolTipFor(element) is not { } tip) return;
            tip.IsOpen = true;
            opened = tip;
        };
        void Close()
        {
            timer.Stop();
            if (opened is not null) opened.IsOpen = false;
            opened = null;
        }
        element.PointerEntered += (_, e) =>
        {
            if (e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse) timer.Start();
        };
        element.AddHandler(UIElement.PointerExitedEvent, new PointerEventHandler((_, _) => Close()), true);
        element.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => Close()), true);
        element.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => Close()), true);
        element.Unloaded += (_, _) => Close();
    }

    /// 元素上的提示；设置的是文字时包装成 ToolTip 对象（系统的提示服务随后也使用同一个对象）。
    private static ToolTip? ToolTipFor(FrameworkElement element)
    {
        switch (ToolTipService.GetToolTip(element))
        {
            case ToolTip tip:
                return tip;
            case null:
                return null;
            case var content:
                var wrapped = new ToolTip { Content = content };
                ToolTipService.SetToolTip(element, wrapped);
                return wrapped;
        }
    }
}
