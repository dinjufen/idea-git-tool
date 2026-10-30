import AppKit
import CodeEditTextView
import GitDeckCore

/// 行内提交信息（与 VSCode / GitLens 的 current line blame 一致，与 Windows 端相同）：光标所在行的行尾以淡色显示
/// 该行最近一次提交，不改动文本；鼠标悬停在这段文字上时弹出提交详情，鼠标在弹窗内时保持显示，移出后关闭。
@MainActor
final class InlineBlameController: NSObject {
    /// 行尾与提交信息之间的空隙（字符数）。
    private static let gap = "    "
    /// 可见宽度小于此值时不显示行内文字（放不下有意义的内容）。
    private static let minimumWidth: CGFloat = 40

    /// git blame 结果（与 Annotate 注释列共用）。
    var blame: BlameResult? {
        didSet { update(force: true) }
    }

    /// 编辑后的行号映射：当前行 → blame 时的行；`nil` 元素表示新增或修改的行。为 `nil` 时按行号一一对应。
    var lineMap: [Int?]? {
        didSet { update(force: true) }
    }

    /// 当前用户的提交邮箱：作者为本人的提交显示为“你”。
    var userEmail: String? {
        didSet { update(force: true) }
    }

    /// 读取提交的完整信息（弹窗中显示完整的提交说明）。
    var commitDetails: ((String) async -> CommitDetails?)?

    /// 在 Git 日志中定位提交（弹窗中的“在 Git 日志中显示”）。
    var onShowCommit: ((String) -> Void)?

    private weak var textView: TextView?
    private weak var scrollView: NSScrollView?
    private let label = InlineBlameLabel()
    private var line = -1
    private var popover: NSPopover?
    private var popoverLine = -1
    private var pointerInPopover = false
    private var pointerOnLabel = false
    private var showTimer: Timer?
    private var hideTimer: Timer?

    init(textView: TextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init()
        label.isHidden = true
        textView.addSubview(label)
        label.onHover = { [weak self] inside in self?.labelHovered(inside) }
    }

    // MARK: - 行内文字

    /// 光标所在行的提交；行在 blame 之后被修改过（或是新增的行）时返回 nil。`known` 为 false 表示没有 blame 结果。
    private func commit(atLine current: Int) -> (commit: BlameCommit?, known: Bool) {
        guard let blame else { return (nil, false) }
        let mapped: Int?
        if let lineMap {
            mapped = lineMap.indices.contains(current) ? lineMap[current] : nil
        } else {
            mapped = current
        }
        guard let index = mapped, blame.lines.indices.contains(index) else { return (nil, true) }
        let commitIndex = Int(blame.lines[index])
        return (blame.commits.indices.contains(commitIndex) ? blame.commits[commitIndex] : nil, true)
    }

    private var caretLine: Int? {
        guard let textView, let location = textView.selectionManager.textSelections.first?.range.location,
              let position = textView.layoutManager.textLineForOffset(location) else { return nil }
        return position.index
    }

    /// 刷新行内提交信息：只显示在光标所在行（`force` 为 false 时光标仍在同一行则不重写）。
    func update(force: Bool) {
        let newLine = EditorSettings.inlineBlame && blame != nil ? (caretLine ?? -1) : -1
        if !force, newLine == line { return }
        if newLine != line { closePopover() }
        line = newLine
        guard newLine >= 0, let text = text(forLine: newLine), let frame = labelFrame(forLine: newLine, text: text) else {
            label.isHidden = true
            line = -1
            return
        }
        label.font = EditorSettings.font
        label.textColor = Self.textColor
        label.stringValue = text.display
        label.toolTip = nil
        label.frame = frame
        label.isHidden = false
    }

    private static var textColor: NSColor {
        Theme.dynamic(light: 0x080808, dark: 0xBCBEC4).withAlphaComponent(0.4)
    }

    /// 行内文字：“作者, 相对时间 • 提交标题”；超出可见宽度时截断标题。
    private func text(forLine current: Int) -> (display: String, full: String)? {
        let (commit, known) = commit(atLine: current)
        guard known else { return nil }
        guard let commit, !commit.isUncommitted else {
            let text = "\(tr("blame.inline.you")) • \(tr("blame.inline.uncommitted"))"
            return (text, text)
        }
        let prefix = "\(authorLabel(commit)), \(Self.relativeDate(commit.authorTime)) • "
        return (prefix + commit.summary, prefix + commit.summary)
    }

    private func authorLabel(_ commit: BlameCommit) -> String {
        if let email = userEmail, !email.isEmpty, email.caseInsensitiveCompare(commit.authorEmail) == .orderedSame {
            return tr("blame.inline.you")
        }
        return commit.authorName
    }

    /// 行尾（不含换行符）之后、空出几个字符的位置；宽度截到可见区域右边缘（至少保留一部分标题）。
    private func labelFrame(forLine current: Int, text: (display: String, full: String)) -> NSRect? {
        guard let textView, let position = textView.layoutManager.lineStorage.getLine(atIndex: current) else { return nil }
        let string = textView.string as NSString
        var end = position.range.location + position.range.length
        while end > position.range.location, end <= string.length,
              let scalar = UnicodeScalar(string.character(at: end - 1)), CharacterSet.newlines.contains(scalar) {
            end -= 1
        }
        guard let rect = textView.layoutManager.rectForOffset(end) else { return nil }
        let font = EditorSettings.font
        let gapWidth = (Self.gap as NSString).size(withAttributes: [.font: font]).width
        let width = (text.display as NSString).size(withAttributes: [.font: font]).width + 4
        let x = rect.minX + gapWidth
        // 可见区域右边缘：减去竖向滚动条（叠加样式的滚动条也会盖住文字），避免末尾的 … 被挡住。
        var visibleRight = x + width
        if let scrollView {
            let scroller = scrollView.hasVerticalScroller && !(scrollView.verticalScroller?.isHidden ?? true)
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollView.scrollerStyle)
                : 0
            visibleRight = scrollView.documentVisibleRect.maxX - scroller
        }
        // 按可见宽度截断（末尾显示 …）；行尾已经接近右边缘、放不下几个字时不显示。
        let available = visibleRight - x - 8
        guard available >= Self.minimumWidth else { return nil }
        return NSRect(x: x, y: position.yPos, width: min(width, available), height: position.height)
    }

    /// 相对时间（“3 天前”），与 Windows 端相同的粒度。
    static func relativeDate(_ timestamp: Int64) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let now = Date()
        let seconds = now.timeIntervalSince(then)
        let calendar = Calendar.current
        if seconds < 60 { return tr("blame.date.now") }
        if seconds < 120 { return tr("blame.date.minute") }
        if seconds < 3600 { return tr("blame.date.minutes", "\(Int(seconds / 60))") }
        if seconds < 7200 { return tr("blame.date.hour") }
        if calendar.isDate(then, inSameDayAs: now) { return tr("blame.date.hours", "\(Int(seconds / 3600))") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: then), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return tr("blame.date.yesterday") }
        if days < 30 { return tr("blame.date.days", "\(days)") }
        let months = calendar.dateComponents([.month], from: then, to: now).month ?? 0
        if months < 12 { return months <= 1 ? tr("blame.date.month") : tr("blame.date.months", "\(months)") }
        let years = months / 12
        return years <= 1 ? tr("blame.date.year") : tr("blame.date.years", "\(years)")
    }

    /// 字号、行距或编辑区宽度变化后重新排版：等文本视图完成布局后再计算位置与截断宽度。
    func relayout() {
        DispatchQueue.main.async { [weak self] in self?.update(force: true) }
    }

    // MARK: - 悬停弹窗

    private func labelHovered(_ inside: Bool) {
        pointerOnLabel = inside
        if inside {
            hideTimer?.invalidate()
            guard popover?.isShown != true else { return }
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPopover() }
            }
        } else {
            showTimer?.invalidate()
            scheduleClose()
        }
    }

    private func scheduleClose() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pointerInPopover, !self.pointerOnLabel else { return }
                self.closePopover()
            }
        }
    }

    func closePopover() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        pointerInPopover = false
        popoverLine = -1
        popover?.close()
        popover = nil
    }

    private func showPopover() {
        guard line >= 0, !label.isHidden, label.window != nil else { return }
        let current = line
        let commit = commit(atLine: current).commit
        let content = InlineBlamePopoverView(commit: commit) { [weak self] hash in
            self?.closePopover()
            self?.onShowCommit?(hash)
        } onCopy: { [weak self] hash in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hash, forType: .string)
            self?.closePopover()
        }
        content.onHover = { [weak self] inside in
            guard let self else { return }
            self.pointerInPopover = inside
            if inside { self.hideTimer?.invalidate() } else { self.scheduleClose() }
        }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        // 紧贴该行，系统按可用空间放在下方或上方，鼠标可以直接移进弹窗。
        popover.show(relativeTo: label.bounds, of: label, preferredEdge: .maxY)
        self.popover = popover
        popoverLine = current

        if let commit, !commit.isUncommitted, let commitDetails {
            let hash = commit.hash
            Task { [weak self, weak content] in
                guard let details = await commitDetails(hash), let self, let content, self.popoverLine == current else { return }
                content.setMessage(details.message.trimmingCharacters(in: .whitespacesAndNewlines))
                self.popover?.contentSize = content.fittingSize
            }
        }
    }
}

/// 行尾的淡色文字：鼠标进出时通知控制器。
private final class InlineBlameLabel: NSTextField {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // 点击穿透到编辑器（放置光标等）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 弹窗内容：作者与邮箱、相对时间与完整时间、提交说明（过长时滚动），以及修订号与操作（在 Git 日志中显示、复制修订号）。
private final class InlineBlamePopoverView: NSView {
    private static let maxMessageHeight: CGFloat = 360
    private static let width: CGFloat = 460

    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private let messageView = NSTextView()
    private var messageHeight: NSLayoutConstraint?
    private let onShowInLog: (String) -> Void
    private let onCopy: (String) -> Void
    private var commitHash = ""

    init(commit: BlameCommit?, onShowInLog: @escaping (String) -> Void, onCopy: @escaping (String) -> Void) {
        self.onShowInLog = onShowInLog
        self.onCopy = onCopy
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.width),
        ])

        guard let commit, !commit.isUncommitted else {
            stack.addArrangedSubview(NSTextField.label(tr("blame.inline.you"), font: Theme.font(ofSize: 13, weight: .semibold)))
            let detail = NSTextField(wrappingLabelWithString: tr("blame.inline.uncommitted.detail"))
            detail.textColor = Theme.secondaryText
            stack.addArrangedSubview(detail)
            return
        }
        commitHash = commit.hash

        let author = NSMutableAttributedString(string: commit.authorName, attributes: [.font: Theme.font(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text])
        if !commit.authorEmail.isEmpty {
            author.append(NSAttributedString(string: "  <\(commit.authorEmail)>", attributes: [.font: Theme.uiFont, .foregroundColor: Theme.text]))
        }
        let authorLabel = NSTextField(labelWithAttributedString: author)
        authorLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(authorLabel)
        let date = NSTextField.label("\(InlineBlameController.relativeDate(commit.authorTime))  (\(LogDateFormatter.detailed(commit.authorTime)))",
                                     color: Theme.secondaryText)
        stack.addArrangedSubview(date)

        // 先显示 blame 中的标题，读取到完整提交说明后替换；说明过长时在固定高度内滚动。
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.drawsBackground = false
        messageView.font = Theme.uiFont
        messageView.textColor = Theme.text
        messageView.textContainerInset = .zero
        messageView.textContainer?.lineFragmentPadding = 0
        messageView.textContainer?.widthTracksTextView = true
        messageView.isVerticallyResizable = true
        messageView.string = commit.summary
        let scroll = NSScrollView()
        scroll.documentView = messageView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let height = scroll.heightAnchor.constraint(equalToConstant: 20)
        messageHeight = height
        NSLayoutConstraint.activate([height, scroll.widthAnchor.constraint(equalToConstant: Self.width - 28)])
        messageView.frame = NSRect(x: 0, y: 0, width: Self.width - 28, height: 20)
        // 不随父视图自动拉宽：宽度由上面的 frame 固定，文字在其中换行。
        messageView.autoresizingMask = []
        stack.addArrangedSubview(scroll)
        stack.setCustomSpacing(8, after: scroll)

        let separator = SeparatorLine(.horizontal)
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let hashLabel = NSTextField.label(String(commit.hash.prefix(8)), font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: Theme.secondaryText)
        let show = Self.link(tr("blame.inline.showInLog"), target: self, action: #selector(showInLog))
        let copy = Self.link(tr("blame.inline.copyHash"), target: self, action: #selector(copyHash))
        let footer = NSStackView(views: [hashLabel, show, copy])
        footer.spacing = 12
        stack.addArrangedSubview(footer)
        updateMessageHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func link(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.linkColor, .font: Theme.smallFont])
        return button
    }

    func setMessage(_ message: String) {
        messageView.string = message
        updateMessageHeight()
    }

    private func updateMessageHeight() {
        guard let container = messageView.textContainer, let layout = messageView.layoutManager else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        messageHeight?.constant = min(max(used, 16), Self.maxMessageHeight)
    }

    @objc private func showInLog() { onShowInLog(commitHash) }
    @objc private func copyHash() { onCopy(commitHash) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
