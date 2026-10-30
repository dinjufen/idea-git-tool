import AppKit

/// 设置 > 编辑器：字体、字号与行距（与 “视图” 菜单中的字体设置一致）。
final class EditorSettingsPane: NSViewController {
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let spacingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview = NSTextField.label("")
    private let inlineBlame = NSButton(checkboxWithTitle: tr("settings.editor.inlineBlame"), target: nil, action: nil)
    /// 等宽字体族；第一项（`nil`）为系统等宽字体。
    private var families: [String?] = []
    private var observer: NSObjectProtocol?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.editor")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        view = NSView()
        let manager = NSFontManager.shared
        let monospaced = manager.availableFontFamilies.filter { family in
            manager.availableMembers(ofFontFamily: family)?.first.flatMap { member in
                (member[0] as? String).flatMap { NSFont(name: $0, size: 12)?.isFixedPitch }
            } ?? false
        }
        families = [nil] + monospaced
        fontPopup.addItems(withTitles: [tr("settings.editor.systemFont")] + monospaced)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)

        sizeStepper.minValue = Double(EditorSettings.sizeRange.lowerBound)
        sizeStepper.maxValue = Double(EditorSettings.sizeRange.upperBound)
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped)
        sizeField.target = self
        sizeField.action = #selector(sizeEdited)
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let sizeRow = NSStackView(views: [sizeField, sizeStepper])
        sizeRow.spacing = 4

        spacingPopup.addItems(withTitles: EditorSettings.lineSpacingOptions.map { String(format: "%.1f", $0) })
        spacingPopup.target = self
        spacingPopup.action = #selector(spacingChanged)

        inlineBlame.target = self
        inlineBlame.action = #selector(inlineBlameChanged)
        preview.stringValue = "fn main() { println!(\"GitDeck 0123456789\"); }"
        SettingsForm.install([
            [SettingsForm.label("settings.editor.font"), fontPopup],
            [SettingsForm.label("settings.editor.size"), sizeRow],
            [SettingsForm.label("settings.editor.lineSpacing"), spacingPopup],
            [SettingsForm.label("settings.editor.preview"), preview],
            [NSGridCell.emptyContentView, inlineBlame],
        ], in: view)
        SettingsForm.fitPreferredSize(self)
        // 通过菜单（⌘+ / ⌘-）修改字体时同步显示。
        observer = NotificationCenter.default.addObserver(forName: EditorSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        load()
    }

    private func load() {
        fontPopup.selectItem(at: families.firstIndex(of: EditorSettings.fontFamily.flatMap { NSFont(name: $0, size: 12)?.familyName }) ?? 0)
        sizeField.integerValue = Int(EditorSettings.fontSize)
        sizeStepper.integerValue = Int(EditorSettings.fontSize)
        spacingPopup.selectItem(at: EditorSettings.lineSpacingOptions.firstIndex(of: EditorSettings.lineSpacing) ?? 1)
        preview.font = EditorSettings.font
        inlineBlame.state = EditorSettings.inlineBlame ? .on : .off
    }

    @objc private func inlineBlameChanged() {
        EditorSettings.inlineBlame = inlineBlame.state == .on
    }

    @objc private func fontChanged() {
        let family = families[max(0, fontPopup.indexOfSelectedItem)]
        let size = EditorSettings.fontSize
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            EditorSettings.apply(font)
        } else {
            EditorSettings.reset()
            EditorSettings.fontSize = size
        }
    }

    @objc private func sizeStepped() { EditorSettings.fontSize = CGFloat(sizeStepper.integerValue) }
    @objc private func sizeEdited() { EditorSettings.fontSize = CGFloat(max(1, sizeField.integerValue)) }

    @objc private func spacingChanged() {
        EditorSettings.lineSpacing = EditorSettings.lineSpacingOptions[max(0, spacingPopup.indexOfSelectedItem)]
    }
}
