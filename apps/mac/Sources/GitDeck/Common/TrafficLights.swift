import AppKit

/// 把窗口左上角的红绿灯按钮垂直居中到自定义主工具栏中（IDEA New UI 的主工具栏比系统标题栏高）。
///
/// AppKit 在调整窗口大小、进出全屏时会重新布局标题栏，因此在这些时机重新调整。
@MainActor
enum TrafficLights {
    static func center(in window: NSWindow, height: CGFloat, leading: CGFloat = 14) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview?.superview else { return }
        // 标题栏容器加高到工具栏高度，按钮在其中居中。
        var frame = titlebar.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        titlebar.frame = frame
        var x = leading
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            var buttonFrame = button.frame
            buttonFrame.origin.x = x
            buttonFrame.origin.y = (button.superview?.bounds.height ?? height) - (height + buttonFrame.height) / 2
            button.setFrameOrigin(buttonFrame.origin)
            x += buttonFrame.width + 6
        }
    }

    /// 在窗口调整大小、退出全屏后保持居中。
    static func keepCentered(in window: NSWindow, height: CGFloat) -> [NSObjectProtocol] {
        center(in: window, height: height)
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
        ]
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    center(in: window, height: height)
                }
            }
        }
    }
}
