import AppKit
import GitDeckCore

/// 界面语言（设置 > 通用 > 语言）。通过本应用的 `AppleLanguages` 覆盖系统语言，重启后生效。
enum LanguageSetting: String, CaseIterable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    private static let key = "AppleLanguages"

    var title: String {
        switch self {
        case .system: tr("settings.language.system")
        case .english: "English"
        case .chinese: "简体中文"
        }
    }

    /// 只读取本应用域中的设置（不受全局语言列表影响）。
    static var current: LanguageSetting {
        let value = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        return value?.first.flatMap(LanguageSetting.init) ?? .system
    }

    static func set(_ setting: LanguageSetting) {
        if setting == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([setting.rawValue], forKey: key)
        }
    }
}

/// 通用设置中与窗口相关的选项。
@MainActor
enum GeneralSettings {
    private static let tabsKey = "projects.openAsTabs"

    /// 新打开的项目作为现有窗口中的标签页（否则遵循系统的 “打开文稿时首选标签页” 设置）。
    static var openProjectsAsTabs: Bool {
        get { UserDefaults.standard.bool(forKey: tabsKey) }
        set { UserDefaults.standard.set(newValue, forKey: tabsKey) }
    }
}

/// Git 设置（设置 > Git）。
@MainActor
enum GitSettings {
    private static let pathKey = "git.executable"
    static let updateMethodKey = "update.method"
    private static let showUpdateDialogKey = "update.showDialog"

    /// 指定的 git 可执行文件；为空时自动查找。
    static var executablePath: String? {
        get { UserDefaults.standard.string(forKey: pathKey).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: pathKey)
            apply()
        }
    }

    /// 把设置传给核心（启动时与修改后调用）；只影响之后打开的仓库。
    static func apply() {
        setGitExecutable(path: executablePath)
    }

    static var updateMethod: UpdateMethod {
        get { UserDefaults.standard.string(forKey: updateMethodKey) == "rebase" ? .rebase : .merge }
        set { UserDefaults.standard.set(newValue == .rebase ? "rebase" : "merge", forKey: updateMethodKey) }
    }

    /// Update Project 时是否显示选择更新方式的对话框（IDEA 的 “Don't show again”）。
    static var showUpdateDialog: Bool {
        get { UserDefaults.standard.object(forKey: showUpdateDialogKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showUpdateDialogKey) }
    }
}

/// 设置页的表单：右对齐的标签列 + 控件列。
@MainActor
enum SettingsForm {
    static func label(_ key: String) -> NSTextField {
        let label = NSTextField.label(tr(key))
        label.alignment = .right
        return label
    }

    static func hint(_ text: String, width: CGFloat = 380) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = Theme.smallFont
        hint.textColor = Theme.secondaryText
        hint.preferredMaxLayoutWidth = width
        return hint
    }

    /// 生成表单并铺满 `view`（四周留白 20）。
    @discardableResult
    static func install(_ rows: [[NSView]], in view: NSView, controlWidth: CGFloat = 400) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = controlWidth
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
        ])
        return grid
    }

    /// 设置窗口按每页内容的大小调整（工具栏分页切换时动画过渡）。
    static func fitPreferredSize(_ controller: NSViewController) {
        controller.view.layoutSubtreeIfNeeded()
        controller.preferredContentSize = controller.view.fittingSize
    }
}
