import AppKit
import GitDeckCore

/// 右侧的 AI Review 工具窗口：评审进度（可取消）、总结、按文件分组的发现（严重程度、位置），
/// 选中发现查看说明，双击跳转到源码，可预览并应用修改建议。
final class AIReviewToolWindow: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFinding: ((Int) -> Void)?
    var onApplySuggestion: ((Int) -> Void)?
    var onReviewLocalChanges: (() -> Void)?

    private final class FileNode {
        let path: String
        var findings: [FindingNode] = []
        init(path: String) { self.path = path }
    }

    private final class FindingNode {
        let index: Int
        let finding: ReviewFinding
        init(index: Int, finding: ReviewFinding) {
            self.index = index
            self.finding = finding
        }
    }

    private let controller: AIReviewController
    private let outline = NSOutlineView()
    private let detailView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
    private let statusLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let spinner = NSProgressIndicator()
    private let emptyState = NSStackView()
    private let split = NSSplitView()
    private let detailScroll = NSScrollView()
    private let openButton = NSButton(title: tr("ai.finding.open"), target: nil, action: nil)
    private let applyButton = NSButton(title: tr("ai.finding.apply"), target: nil, action: nil)
    private var rerunButton: IconButton!
    private var stopButton: IconButton!
    private var clearButton: IconButton!
    private var nodes: [FileNode] = []
    private var shownResult: ReviewResult?
    private var observer: UUID?

    init(controller: AIReviewController) {
        self.controller = controller
        super.init(frame: .zero)
        buildLayout()
        observer = controller.observe { [weak self] in self?.update() }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    private func buildLayout() {
        let background = ColoredView(Theme.toolWindowBackground)
        addSubview(background)
        background.pinEdges(to: self)

        func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 24, pointSize: 12)
            b.target = self
            b.action = action
            return b
        }
        rerunButton = button("arrow.clockwise", tr("ai.action.rerun"), #selector(rerun))
        stopButton = button("stop.circle", tr("ai.action.stop"), #selector(stop))
        clearButton = button("trash", tr("ai.action.clear"), #selector(clear))
        let header = ToolWindowHeader(title: tr("toolwindow.aiReview"), actions: [
            button("sparkles", tr("ai.action.reviewLocal"), #selector(reviewLocal)),
            rerunButton, stopButton, clearButton,
            button("gearshape", tr("ai.action.settings"), #selector(openSettings)),
        ])

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [spinner, statusLabel])
        status.spacing = 6
        status.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("finding"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .sourceList
        outline.backgroundColor = Theme.toolWindowBackground
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.setAccessibilityLabel(tr("toolwindow.aiReview"))
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false

        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.drawsBackground = true
        detailView.backgroundColor = Theme.editorBackground
        detailView.textContainerInset = NSSize(width: 10, height: 8)
        detailView.autoresizingMask = [.width]
        detailView.isVerticallyResizable = true
        detailView.isHorizontallyResizable = false
        detailView.minSize = NSSize(width: 0, height: 0)
        detailView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailView.textContainer?.widthTracksTextView = true
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(outlineScroll)
        split.addArrangedSubview(detailScroll)
        split.translatesAutoresizingMaskIntoConstraints = false

        for b in [openButton, applyButton] {
            b.bezelStyle = .push
            b.controlSize = .small
            b.target = self
        }
        openButton.action = #selector(openSelected)
        applyButton.action = #selector(applySelected)
        let buttons = NSStackView(views: [openButton, applyButton, NSView()])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let emptyLabel = NSTextField.label(tr("ai.empty"), color: Theme.secondaryText)
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.preferredMaxLayoutWidth = 260
        let emptyButton = NSButton(title: tr("ai.action.reviewLocal"), target: self, action: #selector(reviewLocal))
        emptyButton.bezelStyle = .push
        emptyState.orientation = .vertical
        emptyState.spacing = 12
        emptyState.setViews([emptyLabel, emptyButton], in: .center)
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, status, split, buttons, emptyState] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            status.heightAnchor.constraint(equalToConstant: 20),
            split.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            buttons.heightAnchor.constraint(equalToConstant: 24),
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
    }

    override func layout() {
        super.layout()
        // 文本宽度跟随可见区域（扣除滚动条），长段落自动换行。
        let width = detailScroll.contentSize.width
        if width > 0, detailView.frame.width != width { detailView.setFrameSize(NSSize(width: width, height: detailView.frame.height)) }
        // 首次布局时把分隔条放在约 55% 处。
        if split.bounds.height > 0, split.subviews.first?.frame.height == 0 || split.subviews.first?.frame.height == split.bounds.height {
            split.setPosition(split.bounds.height * 0.55, ofDividerAt: 0)
        }
    }

    // MARK: - 状态

    private func update() {
        let phase = controller.phase
        let running = phase == .running
        emptyState.isHidden = phase != .idle
        split.isHidden = phase == .idle
        spinner.isHidden = !running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        rerunButton.isEnabled = controller.canRerun
        stopButton.isEnabled = running
        clearButton.isEnabled = !running && phase != .idle

        statusLabel.stringValue = statusText()
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.textColor = phase == .failed ? Theme.FileStatus.conflict : Theme.secondaryText

        if controller.result != shownResult {
            shownResult = controller.result
            rebuildNodes()
        }
        updateDetail()
    }

    private func statusText() -> String {
        let tokens = controller.usage.input + controller.usage.output
        let usage = tokens > 0 ? " · " + tr("ai.status.tokens", Self.format(tokens)) : ""
        switch controller.phase {
        case .idle:
            return ""
        case .running:
            let step = controller.turn > 0 ? " · " + tr("ai.status.turn", "\(controller.turn)") : ""
            return tr("ai.status.running", controller.title) + step + usage
        case .finished:
            let count = controller.result?.findings.count ?? 0
            return controller.title + " · " + (count == 0 ? tr("ai.done.none") : tr("ai.done.some", "\(count)")) + usage
        case .failed:
            return tr("ai.failed") + ": " + (controller.errorText ?? "")
        case .cancelled:
            return controller.title + " · " + tr("ai.status.cancelled")
        }
    }

    private static func format(_ tokens: UInt64) -> String {
        tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
    }

    private func rebuildNodes() {
        nodes = []
        for (index, finding) in (controller.result?.findings ?? []).enumerated() {
            let node: FileNode
            if let existing = nodes.first(where: { $0.path == finding.file }) {
                node = existing
            } else {
                node = FileNode(path: finding.file)
                nodes.append(node)
            }
            node.findings.append(FindingNode(index: index, finding: finding))
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private var selectedFinding: FindingNode? {
        outline.item(atRow: outline.selectedRow) as? FindingNode
    }

    /// 选中某个发现（例如点击编辑器中的标记）。
    func select(findingIndex: Int) {
        for node in nodes {
            guard let item = node.findings.first(where: { $0.index == findingIndex }) else { continue }
            outline.expandItem(node)
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            return
        }
    }

    private func updateDetail() {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: Theme.uiFont, .foregroundColor: Theme.text]
        let secondary: [NSAttributedString.Key: Any] = [.font: Theme.smallFont, .foregroundColor: Theme.secondaryText]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Theme.text]

        if let node = selectedFinding {
            let f = node.finding
            text.append(NSAttributedString(string: f.title + "\n", attributes: bold))
            let location = f.endLine > f.line ? "\(f.file):\(f.line)-\(f.endLine)" : "\(f.file):\(f.line)"
            text.append(NSAttributedString(string: Self.severityTitle(f.severity) + " · " + location + "\n\n", attributes: secondary))
            text.append(NSAttributedString(string: f.explanation + "\n", attributes: body))
            if let suggestion = f.suggestion {
                text.append(NSAttributedString(string: "\n" + tr("ai.finding.suggestion") + "\n", attributes: secondary))
                text.append(NSAttributedString(string: suggestion.replacement, attributes: mono))
            }
            openButton.isEnabled = true
            applyButton.isEnabled = f.suggestion != nil && !controller.applied.contains(node.index)
                && controller.isWorkingTreeResult(for: f.file)
            applyButton.title = controller.applied.contains(node.index) ? tr("ai.finding.applied") : tr("ai.finding.apply")
        } else {
            if let result = controller.result {
                if !result.summary.isEmpty {
                    text.append(NSAttributedString(string: result.summary + "\n\n", attributes: body))
                } else if result.findings.isEmpty, controller.files.isEmpty {
                    text.append(NSAttributedString(string: tr("ai.nothingToReview") + "\n\n", attributes: body))
                }
                if result.incomplete {
                    text.append(NSAttributedString(string: tr("ai.incomplete") + "\n\n", attributes: secondary))
                }
            }
            for activity in controller.activities {
                text.append(NSAttributedString(string: "•  " + activity.text + "\n", attributes: secondary))
            }
            let narration = controller.narration.trimmingCharacters(in: .whitespacesAndNewlines)
            if !narration.isEmpty {
                text.append(NSAttributedString(string: "\n" + narration + "\n", attributes: body))
            }
            if controller.phase == .finished, !controller.modelName.isEmpty {
                text.append(NSAttributedString(string: "\n" + tr("ai.reviewedBy", controller.modelName), attributes: secondary))
            }
            openButton.isEnabled = false
            applyButton.isEnabled = false
            applyButton.title = tr("ai.finding.apply")
        }
        detailView.textStorage?.setAttributedString(text)
        if controller.isRunning, selectedFinding == nil { detailView.scrollToEndOfDocument(nil) }
    }

    static func severityTitle(_ severity: ReviewSeverity) -> String {
        switch severity {
        case .error: tr("ai.severity.error")
        case .warning: tr("ai.severity.warning")
        case .suggestion: tr("ai.severity.suggestion")
        }
    }

    static func severitySymbol(_ severity: ReviewSeverity) -> (String, NSColor) {
        switch severity {
        case .error: ("xmark.octagon.fill", ReviewColors.error)
        case .warning: ("exclamationmark.triangle.fill", ReviewColors.warning)
        case .suggestion: ("lightbulb.fill", ReviewColors.suggestion)
        }
    }

    // MARK: - 动作

    @objc private func reviewLocal() { onReviewLocalChanges?() }
    @objc private func rerun() { controller.rerun() }
    @objc private func stop() { controller.cancel() }
    @objc private func clear() { controller.clear() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func openSelected() {
        guard let node = selectedFinding else {
            // 双击文件行：展开 / 折叠。
            if let item = outline.item(atRow: outline.clickedRow) as? FileNode {
                outline.isItemExpanded(item) ? outline.collapseItem(item) : outline.expandItem(item)
            }
            return
        }
        onOpenFinding?(node.index)
    }

    @objc private func applySelected() {
        guard let node = selectedFinding else { return }
        onApplySuggestion?(node.index)
    }

    // MARK: - NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.findings.count }
        return item == nil ? nodes.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.findings[index] }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FileNode
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label("")
        let detail = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let node = item as? FileNode {
            icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: (node.path as NSString).pathExtension) ?? .plainText)
            label.stringValue = (node.path as NSString).lastPathComponent
            let directory = (node.path as NSString).deletingLastPathComponent
            detail.stringValue = directory.isEmpty ? "\(node.findings.count)" : "\(directory)  \(node.findings.count)"
            cell.toolTip = node.path
        } else if let node = item as? FindingNode {
            let (symbol, color) = Self.severitySymbol(node.finding.severity)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: Self.severityTitle(node.finding.severity))?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            icon.contentTintColor = color
            label.stringValue = node.finding.title
            detail.stringValue = ":\(node.finding.line)"
            if controller.applied.contains(node.index) { label.textColor = Theme.secondaryText }
            cell.toolTip = node.finding.title
        }
        let stack = NSStackView(views: [icon, label, detail])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// 评审发现的严重程度颜色（对应 IDEA 的 Error / Warning / Weak Warning）。
enum ReviewColors {
    static let error = Theme.dynamic(light: 0xDB3B4B, dark: 0xE55765)
    static let warning = Theme.dynamic(light: 0xE08855, dark: 0xF2C55C)
    static let suggestion = Theme.dynamic(light: 0x3574F0, dark: 0x548AF7)
}
