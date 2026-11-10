import AppKit

/// 设置窗口（⌘,）：macOS 风格的工具栏分页——通用、编辑器、Git、AI 评审。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    enum Pane: Int {
        case general, editor, git, ai
    }

    private let tabs = NSTabViewController()

    private init() {
        // NSPanel 作为辅助窗，不会并进项目窗的标签组，也不会把项目窗的“主窗口”身份抢走。
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
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
        guard let window else { return }
        // 每次显示都重新禁止合并，若已被并进标签组则拆出来。
        window.tabbingMode = .disallowed
        if let group = window.tabbedWindows, group.count > 1 {
            window.moveTabToNewWindow(nil)
        }
        // 先把设置窗置前，再激活应用，避免激活时 AppKit 把项目窗抬回来盖住设置。
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // 让当前页保存尚未结束编辑的输入。
        window?.makeFirstResponder(nil)
        tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.viewWillDisappear()
    }
}
