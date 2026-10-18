import AppKit

/// 编辑器顶部的查找栏（IDEA / VSCode 的 ⌘F）：输入即搜索，Return 下一个，⇧Return 上一个，Esc 关闭。
/// 替换模式（⌘R）多一行替换输入框与 Replace / Replace All 按钮。
final class FindBar: ColoredView, NSSearchFieldDelegate {
    var onQueryChange: ((String, Bool) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?

    private let field = NSSearchField()
    private let matchCase = NSButton(checkboxWithTitle: tr("find.matchCase"), target: nil, action: nil)
    private let countLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)
    private let replaceField = NSTextField()
    private let replaceRow = NSStackView()
    private var heightConstraint: NSLayoutConstraint!

    /// 显示替换行。
    var isReplaceMode = false {
        didSet {
            replaceRow.isHidden = !isReplaceMode
            heightConstraint.constant = isReplaceMode ? 64 : 34
        }
    }

    init() {
        super.init(Theme.toolWindowBackground)
        translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = tr("find.placeholder")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        matchCase.controlSize = .small
        matchCase.font = Theme.smallFont
        matchCase.target = self
        matchCase.action = #selector(queryChanged)

        func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> IconButton {
            let b = IconButton(symbol: symbol, tooltip: tooltip, size: 22, pointSize: 11)
            b.target = self
            b.action = action
            return b
        }
        let stack = NSStackView(views: [
            field, countLabel,
            button("chevron.up", tr("find.previous"), #selector(previous)),
            button("chevron.down", tr("find.next"), #selector(next)),
            matchCase, NSView(),
            button("xmark", tr("find.close"), #selector(close)),
        ])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        replaceField.placeholderString = tr("find.replace.placeholder")
        replaceField.delegate = self
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        let replaceButton = NSButton(title: tr("find.replace"), target: self, action: #selector(replace))
        let replaceAllButton = NSButton(title: tr("find.replaceAll"), target: self, action: #selector(replaceAll))
        for b in [replaceButton, replaceAllButton] {
            b.bezelStyle = .push
            b.controlSize = .small
        }
        replaceRow.setViews([replaceField, replaceButton, replaceAllButton], in: .leading)
        replaceRow.spacing = 6
        replaceRow.isHidden = true
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replaceRow)

        let bottom = SeparatorLine(.horizontal)
        addSubview(bottom)
        heightConstraint = heightAnchor.constraint(equalToConstant: 34).withPriority(.init(999))
        NSLayoutConstraint.activate([
            heightConstraint,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: topAnchor, constant: 17),
            field.widthAnchor.constraint(equalToConstant: 260),
            replaceRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            replaceRow.centerYAnchor.constraint(equalTo: topAnchor, constant: 47),
            replaceField.widthAnchor.constraint(equalTo: field.widthAnchor),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    var query: String { field.stringValue }
    var isCaseSensitive: Bool { matchCase.state == .on }

    func focus(with initial: String?) {
        if let initial, !initial.isEmpty, !initial.contains("\n") {
            field.stringValue = initial
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        queryChanged()
    }

    func setResult(text: String) {
        countLabel.stringValue = text
        countLabel.textColor = Theme.secondaryText
    }

    func setResult(current: Int?, total: Int) {
        if query.isEmpty {
            countLabel.stringValue = ""
        } else if total == 0 {
            countLabel.stringValue = tr("find.noMatches")
        } else {
            countLabel.stringValue = tr("find.count", "\((current ?? 0) + 1)", "\(total)")
        }
        countLabel.textColor = !query.isEmpty && total == 0 ? Theme.FileStatus.conflict : Theme.secondaryText
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) !== replaceField { queryChanged() }
    }

    func focusReplace() {
        window?.makeFirstResponder(replaceField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)) where control === replaceField:
            replace()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            NSEvent.modifierFlags.contains(.shift) ? previous() : next()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc private func queryChanged() { onQueryChange?(query, isCaseSensitive) }
    @objc private func next() { onNext?() }
    @objc private func previous() { onPrevious?() }
    @objc private func close() { onClose?() }
    @objc private func replace() { onReplace?(replaceField.stringValue) }
    @objc private func replaceAll() { onReplaceAll?(replaceField.stringValue) }
}
