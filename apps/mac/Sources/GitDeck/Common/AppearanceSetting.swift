import AppKit

/// 界面主题，对应 IDEA 设置中的 Theme（含 “Sync with OS”）。
enum AppearanceSetting: String, CaseIterable {
    case system
    case light
    case dark

    private static let key = "appearance"

    @MainActor static var current: AppearanceSetting {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppearanceSetting.init) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            newValue.apply()
        }
    }

    var title: String {
        switch self {
        case .system: tr("theme.system")
        case .light: tr("theme.light")
        case .dark: tr("theme.dark")
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
