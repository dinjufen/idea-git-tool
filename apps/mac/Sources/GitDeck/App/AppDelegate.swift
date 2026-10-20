import AppKit
import GitDeckCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: WelcomeWindowController?
    private var projects: [ProjectWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceSetting.current.apply()
        UIFonts.start()
        // git / ssh 需要凭据时调用本程序弹出输入框（见 AskPass）。
        setAskpassProgram(path: Bundle.main.executablePath)
        GitSettings.apply()
        NSApp.mainMenu = MainMenu.build()
        checkGitAvailable()

        // 与 IDEA 一致：启动时重新打开上次的项目，否则显示欢迎页。
        if let last = RecentProjects.shared.paths.first,
           FileManager.default.fileExists(atPath: last) {
            openProject(at: URL(fileURLWithPath: last))
        } else {
            showWelcome()
        }
        NSApp.activate()
        #if DEBUG
        // 仅 Debug：`-debug.openAlso <路径>` 启动后再打开一个项目（验证多项目标签页）。
        if let also = UserDefaults.standard.string(forKey: "debug.openAlso") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openProject(at: URL(fileURLWithPath: also)) }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWelcome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 项目窗口

    func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindowController(appDelegate: self)
        }
        welcome?.reload()
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    func openProject(at url: URL) {
        if let existing = projects.first(where: { $0.model.rootURL.standardizedFileURL == url.standardizedFileURL }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let repository = try Repository.open(path: url.path)
            presentProject(repository)
        } catch {
            presentError(error)
        }
    }

    func initProject(at url: URL) {
        do {
            presentProject(try Repository.`init`(path: url.path))
        } catch {
            presentError(error)
        }
    }

    func presentProject(_ repository: Repository) {
        let controller = ProjectWindowController(repository: repository)
        controller.onClose = { [weak self, weak controller] in
            self?.projects.removeAll { $0 === controller }
            if self?.projects.isEmpty == true { self?.showWelcome() }
        }
        projects.append(controller)
        RecentProjects.shared.add(controller.model.rootURL.path)
        controller.showWindow(nil)
        welcome?.close()
    }

    private func presentError(_ error: any Error) {
        let alert = AppAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("error.title")
        alert.informativeText = errorMessage(error)
        alert.runModal()
    }

    /// 找不到可用的 git 时提示，并可直接打开 设置 > Git 指定路径。
    private func checkGitAvailable() {
        do {
            _ = try gitInfo()
        } catch {
            let alert = AppAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("error.title")
            alert.informativeText = errorMessage(error)
            alert.addButton(withTitle: tr("settings.git.open"))
            alert.addButton(withTitle: tr("common.close"))
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsWindowController.shared.show(.git)
            }
        }
    }

    // MARK: - 菜单动作

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = tr("welcome.open.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    @objc func newProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("welcome.new.prompt")
        panel.message = tr("welcome.new.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        initProject(at: url)
    }

    /// 克隆仓库：克隆期间显示进度窗口，完成后打开项目。
    @objc func cloneProject(_ sender: Any?) {
        let parent = NSApp.keyWindow
        CloneDialog().begin(for: parent) { [weak self] url, directory in
            let progress = CloneProgressWindow(url: url)
            progress.show(over: parent)
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try cloneRepository(url: url, directory: directory) }
                }.value
                progress.close()
                switch result {
                case let .success(repository):
                    self?.presentProject(repository)
                case let .failure(error):
                    self?.presentError(error)
                }
            }
        }
    }

    @objc func showWelcomeWindow(_ sender: Any?) {
        showWelcome()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    // MARK: - 编辑器字体

    @objc func showEditorFontPanel(_ sender: Any?) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeEditorFont(_:))
        manager.setSelectedFont(EditorSettings.font, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    @objc func changeEditorFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        EditorSettings.apply(sender.convert(EditorSettings.font))
    }

    @objc func increaseEditorFont(_ sender: Any?) { EditorSettings.fontSize += 1 }
    @objc func decreaseEditorFont(_ sender: Any?) { EditorSettings.fontSize -= 1 }
    @objc func resetEditorFont(_ sender: Any?) { EditorSettings.reset() }

    @objc func selectLineSpacing(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        EditorSettings.lineSpacing = value
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let setting = AppearanceSetting(rawValue: raw) else { return }
        AppearanceSetting.current = setting
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectAppearance(_:)) {
            menuItem.state = menuItem.representedObject as? String == AppearanceSetting.current.rawValue ? .on : .off
        }
        if menuItem.action == #selector(selectLineSpacing(_:)) {
            menuItem.state = menuItem.representedObject as? CGFloat == EditorSettings.lineSpacing ? .on : .off
        }
        return true
    }
}
