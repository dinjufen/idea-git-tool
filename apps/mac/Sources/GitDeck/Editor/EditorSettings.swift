import AppKit
import GitDeckCore

/// 编辑器字体与行距设置（对应 IDEA 的 Settings > Editor > Font），持久化在 UserDefaults。
@MainActor
enum EditorSettings {
    static let didChange = Notification.Name("EditorSettingsDidChange")

    static let defaultSize: CGFloat = 13
    static let sizeRange: ClosedRange<CGFloat> = 8...40
    static let lineSpacingOptions: [CGFloat] = [1.0, 1.2, 1.4, 1.6]

    private enum Key {
        static let family = "editor.fontFamily"
        static let size = "editor.fontSize"
        static let lineSpacing = "editor.lineSpacing"
        static let inlineBlame = "editor.inlineBlame"
    }

    /// 字体族；为空时使用系统等宽字体（SF Mono）。
    static var fontFamily: String? {
        get { UserDefaults.standard.string(forKey: Key.family) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.family)
            post()
        }
    }

    static var fontSize: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: Key.size)
            return value > 0 ? value : defaultSize
        }
        set {
            UserDefaults.standard.set(min(max(newValue, sizeRange.lowerBound), sizeRange.upperBound), forKey: Key.size)
            post()
        }
    }

    static var lineSpacing: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: Key.lineSpacing)
            return value > 0 ? value : 1.2
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.lineSpacing)
            post()
        }
    }

    /// 在光标所在行的行尾显示该行最近一次提交（与 VSCode / GitLens 的 current line blame 一致），默认开启。
    static var inlineBlame: Bool {
        get { UserDefaults.standard.object(forKey: Key.inlineBlame) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.inlineBlame)
            post()
        }
    }

    static var font: NSFont {
        if let family = fontFamily, let font = NSFont(name: family, size: fontSize) {
            return font
        }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// 从字体面板选择的字体更新设置。
    static func apply(_ font: NSFont) {
        UserDefaults.standard.set(font.fontName, forKey: Key.family)
        fontSize = font.pointSize
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: Key.family)
        UserDefaults.standard.removeObject(forKey: Key.size)
        post()
    }

    private static func post() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// 语法配色，对应 IDEA 默认配色方案：浅色主题为 IntelliJ Light，深色主题为 New UI Dark。
enum SyntaxTheme {
    static let text = Theme.dynamic(light: 0x080808, dark: 0xBCBEC4)
    static let currentLine = Theme.dynamic(light: 0xF5F8FE, dark: 0x26282E)
    static let selection = Theme.dynamic(light: 0xA6D2FF, dark: 0x214283)
    static let lineNumber = Theme.dynamic(light: 0xAEB3C2, dark: 0x4B5059)
    static let currentLineNumber = Theme.dynamic(light: 0x767A8A, dark: 0xA1A3AB)

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: Theme.dynamic(light: 0x0033B3, dark: 0xCF8E6D)
        case .string: Theme.dynamic(light: 0x067D17, dark: 0x6AAB73)
        case .stringSpecial: Theme.dynamic(light: 0x264EFF, dark: 0x42C3D4)
        case .escape: Theme.dynamic(light: 0x0037A6, dark: 0xCF8E6D)
        case .comment: Theme.dynamic(light: 0x8C8C8C, dark: 0x7A7E85)
        case .number: Theme.dynamic(light: 0x1750EB, dark: 0x2AACB8)
        case .constant: Theme.dynamic(light: 0x871094, dark: 0xC77DBB)
        case .function: Theme.dynamic(light: 0x00627A, dark: 0x56A8F5)
        case .type: Theme.dynamic(light: 0x000000, dark: 0xBCBEC4)
        case .parameter: Theme.dynamic(light: 0x080808, dark: 0xBCBEC4)
        case .property: Theme.dynamic(light: 0x871094, dark: 0xC77DBB)
        case .operator, .punctuation: text
        case .tag: Theme.dynamic(light: 0x0033B3, dark: 0xD5B778)
        case .attribute: Theme.dynamic(light: 0x174AD4, dark: 0xBABABA)
        case .namespace: Theme.dynamic(light: 0x000000, dark: 0xBCBEC4)
        case .label: Theme.dynamic(light: 0x9E880D, dark: 0xB3AE60)
        case .heading: Theme.dynamic(light: 0x0033B3, dark: 0xCF8E6D)
        }
    }
}
