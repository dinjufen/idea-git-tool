import AppKit
import GitDeckCore

/// 设置 > Git：git 可执行文件、Update Project 的默认方式与是否显示对话框（对应 IDEA 的 Settings > Version Control > Git）。
final class GitSettingsPane: NSViewController, NSComboBoxDelegate {
    private let pathBox = NSComboBox()
    private let testButton = NSButton(title: tr("settings.git.test"), target: nil, action: nil)
    private let testResult = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let updatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let showDialog = NSButton(checkboxWithTitle: tr("settings.git.showUpdateDialog"), target: nil, action: nil)
    private var candidatesTask: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.git")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        pathBox.placeholderString = tr("settings.git.autoDetect")
        pathBox.completes = true
        pathBox.delegate = self
        pathBox.target = self
        pathBox.action = #selector(pathChanged)
        pathBox.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let browse = NSButton(title: tr("clone.browse"), target: self, action: #selector(browse))
        for button in [browse, testButton] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        testButton.target = self
        testButton.action = #selector(test)
        let pathRow = NSStackView(views: [pathBox, browse])
        pathRow.spacing = 6
        let testRow = NSStackView(views: [testButton, testResult])
        testRow.spacing = 8
        testResult.lineBreakMode = .byTruncatingMiddle

        updatePopup.addItems(withTitles: [tr("ops.update.merge.title"), tr("ops.update.rebase.title")])
        updatePopup.target = self
        updatePopup.action = #selector(updateMethodChanged)
        showDialog.target = self
        showDialog.action = #selector(showDialogChanged)

        SettingsForm.install([
            [SettingsForm.label("settings.git.path"), pathRow],
            [NSGridCell.emptyContentView, testRow],
            [NSGridCell.emptyContentView, SettingsForm.hint(tr("settings.git.path.hint"))],
            [SettingsForm.label("settings.git.updateMethod"), updatePopup],
            [NSGridCell.emptyContentView, showDialog],
        ], in: view)
        SettingsForm.fitPreferredSize(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        pathBox.stringValue = GitSettings.executablePath ?? ""
        updatePopup.selectItem(at: GitSettings.updateMethod == .rebase ? 1 : 0)
        showDialog.state = GitSettings.showUpdateDialog ? .on : .off
        loadCandidates()
        test()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pathChanged()
    }

    /// 本机常见位置上的 git 作为下拉候选。
    private func loadCandidates() {
        candidatesTask?.cancel()
        candidatesTask = Task {
            let list = await Task.detached { gitCandidates() }.value
            guard !Task.isCancelled else { return }
            pathBox.removeAllItems()
            pathBox.addItems(withObjectValues: list.map(\.path))
        }
    }

    @objc private func pathChanged() {
        let path = pathBox.stringValue.trimmingCharacters(in: .whitespaces)
        if path != (GitSettings.executablePath ?? "") {
            GitSettings.executablePath = path.isEmpty ? nil : path
            test()
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // 选中候选项后 stringValue 在下一轮事件循环才更新。
        DispatchQueue.main.async { self.pathChanged() }
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        let handle: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else { return }
            pathBox.stringValue = url.path
            pathChanged()
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// 检查当前设置（为空时为自动查找到的）git 的版本。
    @objc private func test() {
        let path = pathBox.stringValue.trimmingCharacters(in: .whitespaces)
        testResult.stringValue = tr("settings.git.testing")
        testResult.textColor = Theme.secondaryText
        Task {
            let result = await Task.detached {
                Result { path.isEmpty ? try gitInfo() : try gitInfoAt(path: path) }
            }.value
            switch result {
            case let .success(info):
                testResult.stringValue = tr("settings.git.found", info.version, info.path)
                testResult.textColor = LineStatusColors.added
            case let .failure(error):
                testResult.stringValue = errorMessage(error)
                testResult.textColor = Theme.FileStatus.conflict
            }
            testResult.toolTip = testResult.stringValue
        }
    }

    @objc private func updateMethodChanged() {
        GitSettings.updateMethod = updatePopup.indexOfSelectedItem == 1 ? .rebase : .merge
    }

    @objc private func showDialogChanged() {
        GitSettings.showUpdateDialog = showDialog.state == .on
    }
}
