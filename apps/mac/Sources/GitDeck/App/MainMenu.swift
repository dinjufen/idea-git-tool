import AppKit

/// 主菜单。结构与快捷键对齐 IDEA 的 macOS 键位（Commit ⌘K、Push ⇧⌘K、Update Project ⌘T）。
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(gitMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: tr("menu.help"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let name = L10n.productName
        let menu = NSMenu(title: name)
        menu.addItem(withTitle: tr("menu.app.about", name), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(withTitle: tr("menu.app.services"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("menu.app.hide", name), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(item(tr("menu.app.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(withTitle: tr("menu.app.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("menu.app.quit", name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.file"))
        menu.addItem(item(tr("menu.file.new"), #selector(AppDelegate.newProject(_:)), "n", [.command, .shift]))
        menu.addItem(item(tr("menu.file.open"), #selector(AppDelegate.openDocument(_:)), "o"))
        menu.addItem(item(tr("menu.file.welcome"), #selector(AppDelegate.showWelcomeWindow(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.file.save"), #selector(ProjectWindowController.saveDocument(_:)), "s"))
        menu.addItem(item(tr("menu.file.closeTab"), #selector(ProjectWindowController.closeEditorTab(_:)), "w"))
        menu.addItem(item(tr("menu.file.closeProject"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.edit"))
        menu.addItem(withTitle: tr("menu.edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(item(tr("menu.edit.redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("menu.edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: tr("menu.edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: tr("menu.edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: tr("menu.edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.edit.find"), #selector(ProjectWindowController.showFindBar(_:)), "f"))
        menu.addItem(item(tr("menu.edit.findNext"), #selector(ProjectWindowController.findNext(_:)), "g"))
        menu.addItem(item(tr("menu.edit.findPrevious"), #selector(ProjectWindowController.findPrevious(_:)), "g", [.command, .shift]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.view"))
        let toolWindows = NSMenu(title: tr("menu.view.toolWindows"))
        toolWindows.addItem(item(tr("toolwindow.project"), #selector(ProjectWindowController.showProjectToolWindow(_:)), "1"))
        toolWindows.addItem(item(tr("toolwindow.commit"), #selector(ProjectWindowController.showCommitToolWindow(_:)), "0"))
        toolWindows.addItem(item(tr("toolwindow.git"), #selector(ProjectWindowController.showGitToolWindow(_:)), "9"))
        menu.addItem(withTitle: tr("menu.view.toolWindows"), action: nil, keyEquivalent: "").submenu = toolWindows
        let theme = NSMenu(title: tr("menu.view.theme"))
        for setting in AppearanceSetting.allCases {
            let item = NSMenuItem(title: setting.title, action: #selector(AppDelegate.selectAppearance(_:)), keyEquivalent: "")
            item.representedObject = setting.rawValue
            theme.addItem(item)
        }
        menu.addItem(withTitle: tr("menu.view.theme"), action: nil, keyEquivalent: "").submenu = theme
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.view.editorFont"), #selector(AppDelegate.showEditorFontPanel(_:)), "t", [.command, .shift]))
        menu.addItem(item(tr("menu.view.fontIncrease"), #selector(AppDelegate.increaseEditorFont(_:)), "="))
        menu.addItem(item(tr("menu.view.fontDecrease"), #selector(AppDelegate.decreaseEditorFont(_:)), "-"))
        menu.addItem(item(tr("menu.view.fontReset"), #selector(AppDelegate.resetEditorFont(_:)), "0"))
        let spacing = NSMenu(title: tr("menu.view.lineSpacing"))
        for value in EditorSettings.lineSpacingOptions {
            let entry = NSMenuItem(title: String(format: "%.1f", value), action: #selector(AppDelegate.selectLineSpacing(_:)), keyEquivalent: "")
            entry.representedObject = value
            spacing.addItem(entry)
        }
        menu.addItem(withTitle: tr("menu.view.lineSpacing"), action: nil, keyEquivalent: "").submenu = spacing
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.view.fullScreen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func gitMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.git"))
        menu.addItem(item(tr("git.action.commit"), #selector(ProjectWindowController.showCommitToolWindow(_:)), "k"))
        menu.addItem(item(tr("git.action.push"), #selector(ProjectWindowController.pushChanges(_:)), "k", [.command, .shift]))
        menu.addItem(item(tr("git.action.update"), #selector(ProjectWindowController.updateProject(_:)), "t"))
        menu.addItem(item(tr("git.action.fetch"), #selector(ProjectWindowController.fetchChanges(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item(tr("git.action.branches"), #selector(ProjectWindowController.showBranchesPopup(_:)), "b", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item(tr("git.action.refresh"), #selector(ProjectWindowController.refreshStatus(_:)), "r", [.command, .option]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.window"))
        menu.addItem(withTitle: tr("menu.window.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: tr("menu.window.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
