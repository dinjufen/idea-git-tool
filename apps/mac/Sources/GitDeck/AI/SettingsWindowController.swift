import AppKit
import GitDeckCore

/// 设置窗口（⌘,）。目前包含 AI 评审页：模型服务、API Key（钥匙串）、评审语言与敏感文件规则。
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate, NSTextViewDelegate {
    static let shared = SettingsWindowController()

    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSSecureTextField()
    private let deleteKeyButton = NSButton(title: tr("ai.settings.deleteKey"), target: nil, action: nil)
    private let baseURLField = NSTextField()
    private let modelBox = NSComboBox()
    private let effortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maxTokensField = NSTextField()
    private let toolsCheckbox = NSButton(checkboxWithTitle: tr("ai.settings.tools"), target: nil, action: nil)
    private let testButton = NSButton(title: tr("ai.settings.test"), target: nil, action: nil)
    private let testStatus = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let patternsView = NSTextView()
    private let grid = NSGridView()
    private var effortRow: NSGridRow?
    private var toolsRow: NSGridRow?
    private var testTask: Task<Void, Never>?

    private var provider: AISettings.Provider {
        AISettings.Provider.allCases[max(0, providerPopup.indexOfSelectedItem)]
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = tr("settings.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        load()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 布局

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        let title = NSTextField.label(tr("ai.settings.title"), font: .systemFont(ofSize: 15, weight: .semibold))

        providerPopup.addItems(withTitles: AISettings.Provider.allCases.map(\.title))
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        keyField.placeholderString = tr("ai.settings.key.placeholder")
        keyField.delegate = self
        deleteKeyButton.bezelStyle = .push
        deleteKeyButton.controlSize = .small
        deleteKeyButton.target = self
        deleteKeyButton.action = #selector(deleteKey)
        let keyRow = NSStackView(views: [keyField, deleteKeyButton])
        keyRow.spacing = 6

        baseURLField.delegate = self
        modelBox.delegate = self
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 6
        modelBox.target = self
        modelBox.action = #selector(modelChanged)
        effortPopup.addItems(withTitles: AISettings.efforts)
        effortPopup.target = self
        effortPopup.action = #selector(effortChanged)
        maxTokensField.delegate = self
        maxTokensField.formatter = {
            let f = NumberFormatter()
            f.minimum = 1_024
            f.maximum = 128_000
            f.allowsFloats = false
            return f
        }()
        toolsCheckbox.target = self
        toolsCheckbox.action = #selector(toolsChanged)

        testButton.bezelStyle = .push
        testButton.target = self
        testButton.action = #selector(testConnection)
        testStatus.lineBreakMode = .byTruncatingTail
        let testRow = NSStackView(views: [testButton, testStatus])
        testRow.spacing = 8

        languagePopup.addItems(withTitles: AISettings.Language.allCases.map(\.title))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        patternsView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        patternsView.isRichText = false
        patternsView.isAutomaticQuoteSubstitutionEnabled = false
        patternsView.isAutomaticDashSubstitutionEnabled = false
        patternsView.delegate = self
        patternsView.textContainerInset = NSSize(width: 4, height: 4)
        patternsView.autoresizingMask = [.width]
        let patternsScroll = NSScrollView()
        patternsScroll.documentView = patternsView
        patternsScroll.hasVerticalScroller = true
        patternsScroll.borderType = .bezelBorder
        patternsScroll.translatesAutoresizingMaskIntoConstraints = false
        patternsScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let resetPatterns = NSButton(title: tr("ai.settings.patterns.reset"), target: self, action: #selector(resetPatterns))
        resetPatterns.bezelStyle = .push
        resetPatterns.controlSize = .small
        let patternsHint = NSTextField.label(tr("ai.settings.patterns.hint"), font: Theme.smallFont, color: Theme.secondaryText)
        patternsHint.lineBreakMode = .byWordWrapping
        patternsHint.preferredMaxLayoutWidth = 440
        let patternsColumn = NSStackView(views: [patternsScroll, patternsHint, resetPatterns])
        patternsColumn.orientation = .vertical
        patternsColumn.alignment = .leading
        patternsColumn.spacing = 6
        patternsScroll.widthAnchor.constraint(equalTo: patternsColumn.widthAnchor).isActive = true

        let rulesHint = NSTextField.label(tr("ai.settings.rules.hint"), font: Theme.smallFont, color: Theme.secondaryText)
        rulesHint.lineBreakMode = .byWordWrapping
        rulesHint.preferredMaxLayoutWidth = 440
        let privacyHint = NSTextField.label(tr("ai.settings.privacy.hint"), font: Theme.smallFont, color: Theme.secondaryText)
        privacyHint.lineBreakMode = .byWordWrapping
        privacyHint.preferredMaxLayoutWidth = 440

        func label(_ key: String) -> NSTextField {
            let l = NSTextField.label(tr(key))
            l.alignment = .right
            return l
        }
        let rows: [[NSView]] = [
            [label("ai.settings.provider"), providerPopup],
            [label("ai.settings.key"), keyRow],
            [label("ai.settings.baseURL"), baseURLField],
            [label("ai.settings.model"), modelBox],
            [label("ai.settings.effort"), effortPopup],
            [NSGridCell.emptyContentView, toolsCheckbox],
            [label("ai.settings.maxTokens"), maxTokensField],
            [NSGridCell.emptyContentView, testRow],
            [NSGridCell.emptyContentView, privacyHint],
            [label("ai.settings.language"), languagePopup],
            [label("ai.settings.patterns"), patternsColumn],
            [NSGridCell.emptyContentView, rulesHint],
        ]
        for row in rows { grid.addRow(with: row) }
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 450
        grid.rowAlignment = .firstBaseline
        effortRow = grid.row(at: 4)
        toolsRow = grid.row(at: 5)
        grid.row(at: 8).bottomPadding = 8
        grid.row(at: 10).rowAlignment = .none
        grid.cell(atColumnIndex: 0, rowIndex: 10).yPlacement = .top
        for field in [keyField, baseURLField, maxTokensField] as [NSView] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        modelBox.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let stack = NSStackView(views: [title, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - 数据

    private func load() {
        providerPopup.selectItem(at: AISettings.Provider.allCases.firstIndex(of: AISettings.provider) ?? 0)
        loadProvider()
        languagePopup.selectItem(at: AISettings.Language.allCases.firstIndex(of: AISettings.language) ?? 0)
        patternsView.string = AISettings.sensitivePatterns.joined(separator: "\n")
    }

    private func loadProvider() {
        let provider = self.provider
        keyField.stringValue = ""
        let hasKey = AISettings.apiKey(provider) != nil
        keyField.placeholderString = tr(hasKey ? "ai.settings.key.saved" : "ai.settings.key.placeholder")
        deleteKeyButton.isEnabled = hasKey
        baseURLField.stringValue = AISettings.baseURL(provider)
        baseURLField.placeholderString = defaultAiBaseUrl(kind: provider.kind)
        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: provider.suggestedModels)
        modelBox.stringValue = AISettings.model(provider)
        modelBox.placeholderString = provider == .anthropic ? "claude-opus-5-5" : tr("ai.settings.model.placeholder")
        effortPopup.selectItem(withTitle: AISettings.effort)
        maxTokensField.integerValue = AISettings.maxTokens(provider)
        toolsCheckbox.state = AISettings.supportsTools ? .on : .off
        effortRow?.isHidden = provider != .anthropic
        toolsRow?.isHidden = provider != .openAICompatible
        testStatus.stringValue = ""
    }

    /// 输入框尚未结束编辑时（例如直接点击“测试连接”）也写入设置。
    private func commitFields() {
        let provider = self.provider
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            if AISettings.setAPIKey(provider, key) {
                keyField.stringValue = ""
                keyField.placeholderString = tr("ai.settings.key.saved")
                deleteKeyButton.isEnabled = true
            } else {
                testStatus.stringValue = tr("ai.settings.key.saveFailed")
                testStatus.textColor = Theme.FileStatus.conflict
            }
        }
        if baseURLField.stringValue != AISettings.baseURL(provider) {
            AISettings.setBaseURL(provider, baseURLField.stringValue)
        }
        if modelBox.stringValue != AISettings.model(provider) {
            AISettings.setModel(provider, modelBox.stringValue)
        }
        if maxTokensField.integerValue > 0, maxTokensField.integerValue != AISettings.maxTokens(provider) {
            AISettings.setMaxTokens(provider, maxTokensField.integerValue)
        }
    }

    private func savePatterns() {
        let patterns = patternsView.string
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if patterns != AISettings.sensitivePatterns { AISettings.sensitivePatterns = patterns }
    }

    // MARK: - 动作

    @objc private func providerChanged() {
        AISettings.provider = provider
        loadProvider()
    }

    @objc private func deleteKey() {
        AISettings.setAPIKey(provider, nil)
        loadProvider()
    }

    @objc private func modelChanged() { commitFields() }
    @objc private func effortChanged() { AISettings.effort = effortPopup.titleOfSelectedItem ?? "high" }
    @objc private func toolsChanged() { AISettings.supportsTools = toolsCheckbox.state == .on }

    @objc private func languageChanged() {
        AISettings.language = AISettings.Language.allCases[max(0, languagePopup.indexOfSelectedItem)]
    }

    @objc private func resetPatterns() {
        patternsView.string = defaultSensitivePatterns().joined(separator: "\n")
        savePatterns()
    }

    @objc private func testConnection() {
        commitFields()
        testTask?.cancel()
        let provider = self.provider
        let config = AISettings.config(provider, effort: "low")
        let key = AISettings.apiKey(provider) ?? ""
        guard !config.model.isEmpty else {
            showTestResult(tr("ai.error.noModel"), ok: false)
            return
        }
        testButton.isEnabled = false
        testStatus.textColor = Theme.secondaryText
        testStatus.stringValue = tr("ai.settings.test.running")
        testTask = Task {
            let result = await Task.detached { Result { try testAiConnection(config: config, apiKey: key) } }.value
            self.testButton.isEnabled = true
            switch result {
            case .success:
                self.showTestResult(tr("ai.settings.test.ok", config.model), ok: true)
            case let .failure(error):
                self.showTestResult(errorMessage(error), ok: false)
            }
        }
    }

    private func showTestResult(_ text: String, ok: Bool) {
        testStatus.stringValue = text
        testStatus.toolTip = text
        testStatus.textColor = ok ? LineStatusColors.added : Theme.FileStatus.conflict
    }

    // MARK: - 代理

    func controlTextDidEndEditing(_ obj: Notification) { commitFields() }

    func textDidChange(_ notification: Notification) { savePatterns() }

    func windowWillClose(_ notification: Notification) {
        commitFields()
        savePatterns()
    }
}
