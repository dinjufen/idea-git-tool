import AppKit

/// 设置 > 通用：界面语言、主题与界面字体。
final class GeneralSettingsPane: NSViewController {
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let uiFontCheckbox = NSButton(checkboxWithTitle: tr("settings.uiFont.custom"), target: nil, action: nil)
    private let uiFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let uiFontSizeField = NSTextField()
    private let uiFontSizeStepper = NSStepper()
    /// 界面字体族；第一项（`nil`）为系统字体。
    private var uiFontFamilies: [String?] = []
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
            [SettingsForm.label("settings.uiFont"), uiFontCheckbox],
            [NSGridCell.emptyContentView, uiFontRow()],
            [NSGridCell.emptyContentView, SettingsForm.hint(tr("settings.uiFont.hint"))],
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
        loadUIFont()
    }

    // MARK: - 界面字体

    private func uiFontRow() -> NSView {
        uiFontFamilies = [nil] + NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        uiFontPopup.addItems(withTitles: [tr("settings.uiFont.system")] + uiFontFamilies.dropFirst().compactMap { $0 })
        uiFontPopup.target = self
        uiFontPopup.action = #selector(uiFontFamilyChanged)
        uiFontCheckbox.target = self
        uiFontCheckbox.action = #selector(uiFontToggled)
        uiFontSizeStepper.minValue = Double(UIFontSettings.sizeRange.lowerBound)
        uiFontSizeStepper.maxValue = Double(UIFontSettings.sizeRange.upperBound)
        uiFontSizeStepper.increment = 1
        uiFontSizeStepper.target = self
        uiFontSizeStepper.action = #selector(uiFontSizeStepped)
        uiFontSizeField.target = self
        uiFontSizeField.action = #selector(uiFontSizeEdited)
        uiFontSizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [uiFontPopup, NSTextField.label(tr("settings.editor.size")), uiFontSizeField, uiFontSizeStepper])
        row.spacing = 6
        row.setCustomSpacing(16, after: uiFontPopup)
        row.setCustomSpacing(4, after: uiFontSizeField)
        return row
    }

    private func loadUIFont() {
        let custom = UIFontSettings.useCustom
        uiFontCheckbox.state = custom ? .on : .off
        let family = UIFontSettings.family
        if let family, !uiFontFamilies.contains(family) {
            // 设置的字体已不在系统中：仍显示其名称（实际回退为系统字体）。
            uiFontFamilies.insert(family, at: 1)
            uiFontPopup.insertItem(withTitle: family, at: 1)
        }
        uiFontPopup.selectItem(at: uiFontFamilies.firstIndex(of: family) ?? 0)
        uiFontSizeField.integerValue = Int(UIFontSettings.size)
        uiFontSizeStepper.integerValue = Int(UIFontSettings.size)
        for control in [uiFontPopup, uiFontSizeField, uiFontSizeStepper] as [NSControl] { control.isEnabled = custom }
    }

    /// 字体立即生效；字号变化后按新的内容大小调整设置窗口。
    private func uiFontApplied() {
        loadUIFont()
        SettingsForm.fitPreferredSize(self)
    }

    @objc private func uiFontToggled() {
        UIFontSettings.useCustom = uiFontCheckbox.state == .on
        uiFontApplied()
    }

    @objc private func uiFontFamilyChanged() {
        UIFontSettings.family = uiFontFamilies[max(0, uiFontPopup.indexOfSelectedItem)]
        uiFontApplied()
    }

    @objc private func uiFontSizeStepped() {
        UIFontSettings.size = CGFloat(uiFontSizeStepper.integerValue)
        uiFontApplied()
    }

    @objc private func uiFontSizeEdited() {
        guard uiFontSizeField.integerValue > 0, CGFloat(uiFontSizeField.integerValue) != UIFontSettings.size else {
            loadUIFont()
            return
        }
        UIFontSettings.size = CGFloat(uiFontSizeField.integerValue)
        uiFontApplied()
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
        let alert = AppAlert()
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
