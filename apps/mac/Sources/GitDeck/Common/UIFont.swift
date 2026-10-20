import AppKit

/// 界面字体设置（设置 > 通用 > 界面字体，对应 IDEA 的 外观 > “使用自定义字体”）。
/// 作用于工具窗口、树、列表、对话框与右键菜单；编辑器字体在“编辑器”页单独设置，系统菜单栏不受影响。
/// 键名与 Windows 端一致。
@MainActor
enum UIFontSettings {
    static let didChange = Notification.Name("UIFontSettingsDidChange")

    /// macOS 控件的标准字号；自定义字号与它的差值加到界面中的每种字号上（小号、标题字随之缩放）。
    static let defaultSize: CGFloat = 13
    static let sizeRange: ClosedRange<CGFloat> = 10 ... 24

    private static let customKey = "ui.font.custom"
    private static let familyKey = "ui.font.family"
    private static let sizeKey = "ui.font.size"

    static var useCustom: Bool {
        get { UserDefaults.standard.bool(forKey: customKey) }
        set { UserDefaults.standard.set(newValue, forKey: customKey); changed() }
    }

    /// 字体族；`nil` 为系统字体（只改字号）。
    static var family: String? {
        get { UserDefaults.standard.string(forKey: familyKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue ?? "", forKey: familyKey); changed() }
    }

    static var size: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: sizeKey)
            return value > 0 ? min(max(CGFloat(value).rounded(), sizeRange.lowerBound), sizeRange.upperBound) : defaultSize
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue.rounded(), sizeRange.lowerBound), sizeRange.upperBound)), forKey: sizeKey)
            changed()
        }
    }

    /// 当前生效的正文字号。
    static var effectiveSize: CGFloat { useCustom ? size : defaultSize }

    private static func changed() {
        UIFonts.settingsChanged()
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// 按界面字体设置生成字体，并把窗口中已有的界面文字换成当前字体（修改设置后立即生效）。
///
/// 代码中的界面字体都经 `Theme.font(ofSize:weight:)` 取得；未指定字体的控件（按钮、复选框、弹出菜单等）
/// 使用系统默认字体，由 `apply(to:)` 在显示前换掉。为区分“本类生成的字体”与“系统默认字体”，
/// 生成的字体都是独立的对象并记录其基准字号与字重，因此可以反复换算而不会累计放大。
@MainActor
enum UIFonts {
    private struct Base: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    /// 当前设置下已生成的字体（按基准字号与字重缓存）。
    private static var current: [Base: NSFont] = [:]
    /// 历次生成的字体 → 基准；保留强引用，使对象标识在应用运行期间不被复用。
    private static var produced: [ObjectIdentifier: (font: NSFont, base: Base)] = [:]
    private static let systemFamily = NSFont.systemFont(ofSize: UIFontSettings.defaultSize).familyName
    private static let baseRowHeights = NSMapTable<NSTableView, NSNumber>.weakToStrongObjects()

    /// 是否需要换算：启用了自定义字体，或曾经启用过（关闭后要换回系统字体）。
    private static var isActive: Bool { UIFontSettings.useCustom || !produced.isEmpty }

    /// 基准字号（按系统默认 13pt 设计的字号）对应的界面字体。
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard UIFontSettings.useCustom else { return .systemFont(ofSize: size, weight: weight) }
        let base = Base(size: size, weight: weight.rawValue)
        if let font = current[base] { return font }
        let target = max(6, size + UIFontSettings.size - UIFontSettings.defaultSize)
        var font = UIFontSettings.family.flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: managerWeight(weight), size: target)
        } ?? .systemFont(ofSize: target, weight: weight)
        // 加一个不改变显示效果的特性设置，得到独立的字体对象（系统字体对象是共享的，无法区分来源）。
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: 0, NSFontDescriptor.FeatureKey.selectorIdentifier: 0,
        ]]])
        font = NSFont(descriptor: descriptor, size: target) ?? font
        current[base] = font
        produced[ObjectIdentifier(font)] = (font, base)
        return font
    }

    /// `NSFont.Weight`（-1…1）对应到 `NSFontManager` 的字重（0…15，5 为常规、9 为粗体）。
    private static func managerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight.rawValue {
        case ..<(-0.5): 3
        case ..<(-0.1): 4
        case ..<0.1: 5
        case ..<0.27: 6
        case ..<0.35: 8
        case ..<0.5: 9
        default: 11
        }
    }

    private static func base(of font: NSFont) -> Base? {
        if let entry = produced[ObjectIdentifier(font)], entry.font === font { return entry.base }
        guard font.familyName == systemFamily, !font.isFixedPitch else { return nil }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return Base(size: font.pointSize, weight: traits?[.weight] as? CGFloat ?? 0)
    }

    /// 界面文字应换成的字体；不是界面字体（等宽、编辑器字体等）或已是当前字体时为 `nil`。
    private static func converted(_ font: NSFont) -> NSFont? {
        guard let base = base(of: font) else { return nil }
        let result = self.font(ofSize: base.size, weight: NSFont.Weight(base.weight))
        return result === font ? nil : result
    }

    // MARK: - 应用到视图

    /// 启动时调用：每轮事件处理结束、绘制之前把新出现的界面文字换成当前字体。
    static func start() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { sweep() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // 右键菜单与弹出菜单在显示时才确定字体。
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                if let menu { apply(to: menu) }
            }
        }
    }

    private static func sweep(redraw: Bool = false) {
        guard isActive else { return }
        // 只处理内容区：标题栏与工具栏（如设置窗口的分页按钮）由系统排版，换字体会被截断。
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { apply(to: content, redraw: redraw) }
        }
    }

    fileprivate static func settingsChanged() {
        current = [:]
        // 自绘的视图（Log 行、标签等）在重绘时取新字体。
        sweep(redraw: true)
    }

    /// 把视图树中的界面文字换成当前字体，并按字号调整列表行高。
    static func apply(to view: NSView, redraw: Bool = false) {
        guard isActive else { return }
        if let table = view as? NSTableView {
            scaleRowHeight(table)
        } else if let control = view as? NSControl {
            if let font = control.font, let new = converted(font) { control.font = new }
            // 设置了富文本的标签（如树节点的粗体名称）：字体在文字属性中。只在修改设置时处理，
            // 之后新配置的内容本来就使用当前字体。
            if redraw, let field = control as? NSTextField, let text = converted(field.attributedStringValue) {
                field.attributedStringValue = text
            }
        } else if let text = view as? NSTextView {
            apply(to: text)
        }
        if let menu = view.menu { apply(to: menu) }
        if redraw { view.needsDisplay = true }
        for subview in view.subviews { apply(to: subview, redraw: redraw) }
    }

    /// 换算富文本中的字体；没有需要换的字体时为 `nil`。
    private static func converted(_ text: NSAttributedString) -> NSAttributedString? {
        guard text.length > 0 else { return nil }
        var result: NSMutableAttributedString?
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, let new = converted(font) else { return }
            if result == nil { result = NSMutableAttributedString(attributedString: text) }
            result?.addAttribute(.font, value: new, range: range)
        }
        return result
    }

    private static func apply(to text: NSTextView) {
        if let storage = text.textStorage, storage.length > 0 {
            var changes: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let font = value as? NSFont, let new = converted(font) { changes.append((range, new)) }
            }
            if !changes.isEmpty {
                storage.beginEditing()
                for (range, font) in changes { storage.addAttribute(.font, value: font, range: range) }
                storage.endEditing()
            }
        }
        if let font = text.typingAttributes[.font] as? NSFont, let new = converted(font) {
            text.typingAttributes[.font] = new
        }
    }

    /// 右键菜单与弹出菜单（不含系统菜单栏）。
    static func apply(to menu: NSMenu) {
        guard isActive else { return }
        var root: NSMenu? = menu
        while let parent = root?.supermenu { root = parent }
        if root === NSApp.mainMenu { return }
        if let new = converted(menu.font) { menu.font = new }
        for item in menu.items {
            if let submenu = item.submenu { apply(to: submenu) }
        }
    }

    /// 行高按正文字号同比缩放（基准为创建时设置的行高）。
    private static func scaleRowHeight(_ table: NSTableView) {
        let base: CGFloat
        if let stored = baseRowHeights.object(forKey: table) {
            base = CGFloat(stored.doubleValue)
        } else {
            base = table.rowHeight
            baseRowHeights.setObject(NSNumber(value: Double(base)), forKey: table)
        }
        let target = (base * UIFontSettings.effectiveSize / UIFontSettings.defaultSize).rounded()
        if table.rowHeight != target { table.rowHeight = target }
    }

    /// 对话框：在 NSAlert 首次排版前换好字体，使其按新字体计算大小。
    fileprivate static func prepare(_ alert: NSAlert) {
        guard isActive, let content = alert.window.contentView else { return }
        apply(to: content)
        if let accessory = alert.accessoryView {
            let before = accessory.fittingSize
            apply(to: accessory)
            if let control = accessory as? NSControl {
                control.sizeToFit()
            } else if !accessory.subviews.isEmpty {
                let fitting = accessory.fittingSize
                if fitting != before {
                    accessory.setFrameSize(NSSize(width: max(accessory.frame.width, fitting.width), height: fitting.height))
                }
            }
        }
        // 重新设置文字，NSAlert 才会按新字体计算文字区域的高度。
        let message = alert.messageText
        alert.messageText = ""
        alert.messageText = message
        let informative = alert.informativeText
        alert.informativeText = ""
        alert.informativeText = informative
    }
}

/// 本应用的提示框：使用界面字体设置（见 `UIFonts.prepare`）。
final class AppAlert: NSAlert {
    override func layout() {
        UIFonts.prepare(self)
        super.layout()
    }

    @discardableResult
    override func runModal() -> NSApplication.ModalResponse {
        layout()
        return super.runModal()
    }

    override func beginSheetModal(for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        layout()
        super.beginSheetModal(for: sheetWindow, completionHandler: handler)
    }
}
