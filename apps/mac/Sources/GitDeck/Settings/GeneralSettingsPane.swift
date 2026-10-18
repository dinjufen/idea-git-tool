import AppKit

/// 设置 > 通用：界面语言与主题。
final class GeneralSettingsPane: NSViewController {
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tabsCheckbox = NSButton(checkboxWithTitle: tr("settings.tabs"), target: nil, action: nil)

    init() {
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.general")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        languagePopup.addItems(withTitles: LanguageSetting.allCases.map(\.title))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        themePopup.addItems(withTitles: AppearanceSetting.allCases.map(\.title))
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        SettingsForm.install([
            [SettingsForm.label("settings.language"), languagePopup],
            [NSGridCell.emptyContentView, SettingsForm.hint(tr("settings.language.hint"))],
            [SettingsForm.label("settings.theme"), themePopup],
            [SettingsForm.label("settings.projects"), tabsCheckbox],
            [NSGridCell.emptyContentView, SettingsForm.hint(tr("settings.tabs.hint"))],
        ], in: view)
        tabsCheckbox.target = self
        tabsCheckbox.action = #selector(tabsChanged)
        SettingsForm.fitPreferredSize(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        languagePopup.selectItem(at: LanguageSetting.allCases.firstIndex(of: .current) ?? 0)
        themePopup.selectItem(at: AppearanceSetting.allCases.firstIndex(of: .current) ?? 0)
        tabsCheckbox.state = GeneralSettings.openProjectsAsTabs ? .on : .off
    }

    @objc private func tabsChanged() {
        GeneralSettings.openProjectsAsTabs = tabsCheckbox.state == .on
    }

    @objc private func themeChanged() {
        AppearanceSetting.current = AppearanceSetting.allCases[max(0, themePopup.indexOfSelectedItem)]
    }

    /// 语言在重启后生效：询问是否立即重启。
    @objc private func languageChanged() {
        let setting = LanguageSetting.allCases[max(0, languagePopup.indexOfSelectedItem)]
        guard setting != .current else { return }
        LanguageSetting.set(setting)
        let alert = NSAlert()
        alert.messageText = tr("settings.language.restart.title")
        alert.informativeText = tr("settings.language.restart.message")
        alert.addButton(withTitle: tr("settings.language.restart.now"))
        alert.addButton(withTitle: tr("settings.language.restart.later"))
        let restart: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            AppRelauncher.relaunch()
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: restart) } else { restart(alert.runModal()) }
    }
}

/// 重新启动本应用（启动新实例后退出当前实例）。
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
