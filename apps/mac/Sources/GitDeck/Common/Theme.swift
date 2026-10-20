import AppKit

/// IDEA New UI 配色（Light / Dark），通过动态 NSColor 跟随系统外观。
enum Theme {
    static let headerBackground = dynamic(light: 0xF7F8FA, dark: 0x2B2D30)
    static let toolWindowBackground = dynamic(light: 0xF7F8FA, dark: 0x2B2D30)
    static let editorBackground = dynamic(light: 0xFFFFFF, dark: 0x1E1F22)
    static let border = dynamic(light: 0xEBECF0, dark: 0x1E1F22)
    static let text = dynamic(light: 0x000000, dark: 0xDFE1E5)
    static let secondaryText = dynamic(light: 0x818594, dark: 0x6F737A)
    static let hover = dynamic(light: 0xDFE1E5, dark: 0x393B40)
    static let selectedStripeButton = dynamic(light: 0xDFE1E5, dark: 0x43454A)
    static let accent = NSColor(hex: 0x3574F0)

    /// 文件状态颜色，对应 IDEA 的 File Status Colors。
    enum FileStatus {
        static let modified = dynamic(light: 0x0032A0, dark: 0x6897BB)
        static let added = dynamic(light: 0x067D17, dark: 0x629755)
        static let deleted = dynamic(light: 0x6C6C6C, dark: 0x6C6C6C)
        static let untracked = dynamic(light: 0x993300, dark: 0xD1675A)
        static let ignored = dynamic(light: 0x8C8C00, dark: 0x848504)
        static let conflict = dynamic(light: 0xFF0000, dark: 0xD5756C)
        static let renamed = dynamic(light: 0x007878, dark: 0x3A8484)
    }

    /// 界面字体（随 设置 > 通用 > 界面字体 变化）；字号按系统默认 13pt 的设计给出，自定义字号时同步缩放。
    @MainActor static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        UIFonts.font(ofSize: size, weight: weight)
    }

    @MainActor static var uiFont: NSFont { font(ofSize: 13) }
    @MainActor static var smallFont: NSFont { font(ofSize: 12) }
    @MainActor static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// 带背景色的视图；在外观切换时自动刷新图层颜色。
class ColoredView: NSView {
    var backgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }

    init(_ color: NSColor? = nil) {
        backgroundColor = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor?.cgColor
        }
    }
}

/// 1px 分隔线。
final class SeparatorLine: ColoredView {
    enum Axis { case horizontal, vertical }

    init(_ axis: Axis) {
        super.init(Theme.border)
        translatesAutoresizingMaskIntoConstraints = false
        switch axis {
        case .horizontal: heightAnchor.constraint(equalToConstant: 1).isActive = true
        case .vertical: widthAnchor.constraint(equalToConstant: 1).isActive = true
        }
    }
}
