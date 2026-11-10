import AppKit

/// 设置窗口（⌘,）：macOS 风格的工具栏分页——通用、编辑器、Git、AI 评审。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    enum Pane: Int {
        case general, editor, git, ai
    }

    private let tabs = NSTabViewController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        // 独立标签标识 + 禁止合并：避免设置窗被并进项目窗标签组（阴影一闪后“消失”）。
        window.tabbingIdentifier = "GitDeckSettings"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(), "gearshape"),
            (EditorSettingsPane(), "textformat"),
            (GitSettingsPane(), "arrow.triangle.branch"),
            (AISettingsPane(), "sparkles"),
        ]
        for (controller, symbol) in panes {
            let item = NSTabViewItem(viewController: controller)
            item.label = controller.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: controller.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.title = tr("settings.title")
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 显示设置窗口；`pane` 为空时保留上次的页。
    func show(_ pane: Pane? = nil) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 让当前页保存尚未结束编辑的输入。
        window?.makeFirstResponder(nil)
        tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.viewWillDisappear()
    }
}
