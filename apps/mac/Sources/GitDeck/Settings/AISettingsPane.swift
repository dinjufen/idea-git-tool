import AppKit
import GitDeckCore

/// 设置 > AI 评审：模型服务、API Key（钥匙串）、评审语言与敏感文件规则。
final class AISettingsPane: NSViewController, NSComboBoxDelegate, NSTextViewDelegate {
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSSecureTextField()
    private let deleteKeyButton = NSButton(title: tr("ai.settings.deleteKey"), target: nil, action: nil)
    private let baseURLField = NSTextField()
    private let modelBox = NSComboBox()
    private let effortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maxTokensField = NSTextField()
    private let toolsCheckbox = NSButton(checkboxWithTitle: tr("ai.settings.tools"), target: nil, action: nil)
    private let queryModelsButton = NSButton(title: tr("ai.settings.queryModels"), target: nil, action: nil)
    private let testButton = NSButton(title: tr("ai.settings.test"), target: nil, action: nil)
    private let testStatus = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let patternsView = NSTextView()
    private let grid = NSGridView()
    private var effortRow: NSGridRow?
    private var toolsRow: NSGridRow?
    private var testTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?

    private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cliPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cliRefreshButton = NSButton(title: tr("ai.settings.cli.refresh"), target: nil, action: nil)
    private let cliPathField = NSTextField()
    private let cliStatus = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let writeCheckbox = NSButton(checkboxWithTitle: tr("ai.settings.writePermission"), target: nil, action: nil)
    private var httpRows: [NSGridRow] = []
    private var cliRows: [NSGridRow] = []
    private var detectedClis: [DetectedAiCli] = []

    private var provider: AISettings.Provider {
        AISettings.Provider.allCases[max(0, providerPopup.indexOfSelectedItem)]
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = tr("ai.settings.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        buildLayout()
        SettingsForm.fitPreferredSize(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        load()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        commitFields()
        savePatterns()
    }

    // MARK: - 布局

    private func buildLayout() {
        let content = view

        backendPopup.addItems(withTitles: [tr("ai.settings.reviewBackend.http"), tr("ai.settings.reviewBackend.cli")])
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)

        providerPopup.addItems(withTitles: AISettings.Provider.allCases.map(\.title))
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        cliRefreshButton.bezelStyle = .push
        cliRefreshButton.controlSize = .small
        cliRefreshButton.target = self
        cliRefreshButton.action = #selector(refreshClis)
        cliPopup.target = self
        cliPopup.action = #selector(cliChanged)
        cliPathField.placeholderString = tr("ai.settings.cli.path.placeholder")
        cliPathField.delegate = self
        writeCheckbox.target = self
        writeCheckbox.action = #selector(writePermissionChanged)
        cliStatus.lineBreakMode = .byTruncatingTail

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
        queryModelsButton.bezelStyle = .push
        queryModelsButton.controlSize = .regular
        queryModelsButton.target = self
        queryModelsButton.action = #selector(queryModels)
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
        let modelRow = NSStackView(views: [modelBox, queryModelsButton])
        modelRow.spacing = 8
        let cliRow = NSStackView(views: [cliPopup, cliRefreshButton])
        cliRow.spacing = 8
        let writeHint = NSTextField.label(tr("ai.settings.writePermission.hint"), font: Theme.smallFont, color: Theme.secondaryText)
        writeHint.lineBreakMode = .byWordWrapping
        writeHint.preferredMaxLayoutWidth = 440
        let rows: [[NSView]] = [
            [label("ai.settings.reviewBackend"), backendPopup],
            [label("ai.settings.provider"), providerPopup],
            [label("ai.settings.key"), keyRow],
            [label("ai.settings.baseURL"), baseURLField],
            [label("ai.settings.model"), modelRow],
            [label("ai.settings.effort"), effortPopup],
            [NSGridCell.emptyContentView, toolsCheckbox],
            [label("ai.settings.maxTokens"), maxTokensField],
            [NSGridCell.emptyContentView, testRow],
            [NSGridCell.emptyContentView, privacyHint],
            [label("ai.settings.cli"), cliRow],
            [label("ai.settings.cli.path"), cliPathField],
            [NSGridCell.emptyContentView, cliStatus],
            [NSGridCell.emptyContentView, writeCheckbox],
            [NSGridCell.emptyContentView, writeHint],
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
        // 0 backend; 1-9 HTTP; 10-14 CLI; 15 language; 16 patterns; 17 rules
        effortRow = grid.row(at: 5)
        toolsRow = grid.row(at: 6)
        httpRows = (1...9).map { grid.row(at: $0) }
        cliRows = (10...14).map { grid.row(at: $0) }
        grid.row(at: 9).bottomPadding = 8
        grid.row(at: 16).rowAlignment = .none
        grid.cell(atColumnIndex: 0, rowIndex: 16).yPlacement = .top
        for field in [keyField, baseURLField, maxTokensField, cliPathField] as [NSView] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        modelBox.widthAnchor.constraint(equalToConstant: 240).isActive = true

        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - 数据

    private func load() {
        backendPopup.selectItem(at: AISettings.reviewUsesCli ? 1 : 0)
        providerPopup.selectItem(at: AISettings.Provider.allCases.firstIndex(of: AISettings.provider) ?? 0)
        loadProvider()
        loadCliSettings()
        applyBackendVisibility()
        languagePopup.selectItem(at: AISettings.Language.allCases.firstIndex(of: AISettings.language) ?? 0)
        patternsView.string = AISettings.sensitivePatterns.joined(separator: "\n")
    }

    private func loadProvider() {
        let provider = self.provider
        keyField.stringValue = ""
        applyKeyPresence(AISettings.hasStoredKey(provider))
        refreshKeyPresence(provider)
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

    private func applyKeyPresence(_ hasKey: Bool) {
        keyField.placeholderString = tr(hasKey ? "ai.settings.key.saved" : "ai.settings.key.placeholder")
        deleteKeyButton.isEnabled = hasKey
    }

    /// 钥匙串探测可能耗时数秒，放到后台，避免卡住 tab 切换。
    private func refreshKeyPresence(_ provider: AISettings.Provider) {
        presenceTask?.cancel()
        let account = provider.rawValue
        presenceTask = Task.detached { [weak self] in
            let present = Keychain.probeContains(account)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                AISettings.recordStoredKey(provider, present: present)
                guard self.provider == provider else { return }
                self.applyKeyPresence(present)
            }
        }
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
        if cliPathField.stringValue != AISettings.cliExecutable {
            AISettings.cliExecutable = cliPathField.stringValue
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

    @objc private func backendChanged() {
        commitFields()
        AISettings.reviewUsesCli = backendPopup.indexOfSelectedItem == 1
        applyBackendVisibility()
        if AISettings.reviewUsesCli { refreshClis() }
    }

    @objc private func cliChanged() {
        let index = cliPopup.indexOfSelectedItem
        if index >= 0, index < detectedClis.count {
            AISettings.cliId = detectedClis[index].id
            updateCliStatus()
        }
    }

    @objc private func refreshClis() {
        detectedClis = detectAiClis()
        cliPopup.removeAllItems()
        if detectedClis.isEmpty {
            cliPopup.addItem(withTitle: tr("ai.settings.cli.none"))
            cliPopup.isEnabled = false
        } else {
            cliPopup.isEnabled = true
            cliPopup.addItems(withTitles: detectedClis.map { cli in
                if let version = cli.version, !version.isEmpty {
                    return "\(cli.displayName)  (\(version))"
                }
                return cli.displayName
            })
            if let index = detectedClis.firstIndex(where: { $0.id == AISettings.cliId }) {
                cliPopup.selectItem(at: index)
            } else {
                cliPopup.selectItem(at: 0)
                AISettings.cliId = detectedClis[0].id
            }
        }
        updateCliStatus()
    }

    @objc private func writePermissionChanged() {
        AISettings.cliWritePermission = writeCheckbox.state == .on
    }

    private func loadCliSettings() {
        cliPathField.stringValue = AISettings.cliExecutable
        writeCheckbox.state = AISettings.cliWritePermission ? .on : .off
        refreshClis()
    }

    private func applyBackendVisibility() {
        let cli = AISettings.reviewUsesCli
        httpRows.forEach { $0.isHidden = cli }
        cliRows.forEach { $0.isHidden = !cli }
        if !cli {
            effortRow?.isHidden = provider != .anthropic
            toolsRow?.isHidden = provider != .openAICompatible
        }
    }

    private func updateCliStatus() {
        let executable = cliPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let cli = try resolveAiCli(id: AISettings.cliId, executable: executable)
            cliStatus.stringValue = tr("ai.settings.cli.found", cli.displayName, cli.path)
            cliStatus.textColor = LineStatusColors.added
            cliStatus.toolTip = cli.path
        } catch {
            cliStatus.stringValue = errorMessage(error)
            cliStatus.textColor = Theme.FileStatus.conflict
            cliStatus.toolTip = cliStatus.stringValue
        }
    }

    @objc private func languageChanged() {
        AISettings.language = AISettings.Language.allCases[max(0, languagePopup.indexOfSelectedItem)]
    }

    @objc private func resetPatterns() {
        patternsView.string = defaultSensitivePatterns().joined(separator: "\n")
        savePatterns()
    }


    @objc private func queryModels() {
        commitFields()
        let provider = self.provider
        let key = AISettings.apiKey(provider) ?? ""
        let baseURL = AISettings.baseURL(provider)
        guard !key.isEmpty else {
            showTestResult(tr("ai.error.auth", "API Key required"), ok: false)
            return
        }
        queryModelsButton.isEnabled = false
        testStatus.textColor = Theme.secondaryText
        testStatus.stringValue = tr("ai.settings.queryModels.running")
        testTask?.cancel()
        testTask = Task {
            let result = await Task.detached {
                Result { try listAiModels(kind: provider.kind, baseUrl: baseURL, apiKey: key) }
            }.value
            self.queryModelsButton.isEnabled = true
            switch result {
            case .success(let models):
                self.applyQueriedModels(models, provider: provider)
            case let .failure(error):
                self.showTestResult(errorMessage(error), ok: false)
            }
        }
    }

    private func applyQueriedModels(_ models: [AiModelInfo], provider: AISettings.Provider) {
        guard !models.isEmpty else {
            showTestResult(tr("ai.settings.queryModels.empty"), ok: false)
            return
        }
        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: models.map(\.id))
        let current = AISettings.model(provider)
        if models.contains(where: { $0.id == current }) {
            modelBox.stringValue = current
        } else if modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            modelBox.stringValue = models[0].id
            AISettings.setModel(provider, models[0].id)
        }
        let selectedId = modelBox.stringValue
        let info = models.first(where: { $0.id == selectedId }) ?? models[0]
        let suggested = min(info.maxOutputTokens ?? defaultAiMaxTokens(kind: provider.kind), 128_000)
        let currentTokens: UInt32? = maxTokensField.integerValue > 0 ? UInt32(clamping: maxTokensField.integerValue) : nil
        let next = shouldAutofillAiMaxTokens(kind: provider.kind, current: currentTokens, suggested: suggested)
        if Int(next) != maxTokensField.integerValue {
            maxTokensField.integerValue = Int(next)
            AISettings.setMaxTokens(provider, Int(next))
        }
        showTestResult(tr("ai.settings.queryModels.ok", models.count), ok: true)
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
}
