import AppKit

/// 编辑器顶部的查找栏（IDEA / VSCode 的 ⌘F）：输入即搜索，Return 下一个，⇧Return 上一个，Esc 关闭。
final class FindBar: ColoredView, NSSearchFieldDelegate {
    var onQueryChange: ((String, Bool) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let matchCase = NSButton(checkboxWithTitle: tr("find.matchCase"), target: nil, action: nil)
    private let countLabel = NSTextField.label("", font: Theme.smallFont, color: Theme.secondaryText)

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
        let bottom = SeparatorLine(.horizontal)
        addSubview(bottom)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34).withPriority(.init(999)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 260),
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

    func controlTextDidChange(_ obj: Notification) { queryChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
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
}
