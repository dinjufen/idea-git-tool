import AppKit
import GitDeckCore

/// Git 工具窗口的 Console 标签：显示本项目执行过的 git 命令、退出码、耗时与错误输出。
final class ConsoleView: NSView {
    private let root: String
    private let textView = NSTextView()
    private let showBackground = NSButton(checkboxWithTitle: tr("console.showBackground"), target: nil, action: nil)
    private var lastId: UInt64 = 0
    /// 已拉取的记录（含隐藏的后台命令），切换显示选项时据此重绘。
    private var entries: [ConsoleEntry] = []
    private var timer: Timer?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(root: String) {
        self.root = root
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        let clear = IconButton(symbol: "trash", tooltip: tr("console.clear"), size: 24, pointSize: 12)
        clear.target = self
        clear.action = #selector(clearAll)
        showBackground.controlSize = .small
        showBackground.font = Theme.smallFont
        showBackground.target = self
        showBackground.action = #selector(render)
        let toolbar = NSStackView(views: [clear, showBackground, NSView()])
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.editorBackground
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolbar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 标签可见时每秒拉取一次新记录，隐藏时停止。
    override var isHidden: Bool {
        didSet { isHidden ? stopPolling() : startPolling() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopPolling() } else if !isHidden { startPolling() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let new = consoleEntries(afterId: lastId)
        guard let last = new.last else { return }
        lastId = last.id
        // 进程内所有仓库共用一个记录，只显示本项目的。
        let mine = new.filter { $0.cwd == root }
        guard !mine.isEmpty else { return }
        entries.append(contentsOf: mine)
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
        append(mine)
    }

    @objc private func render() {
        textView.textStorage?.setAttributedString(NSAttributedString())
        append(entries)
    }

    private func append(_ list: [ConsoleEntry]) {
        let includeBackground = showBackground.state == .on
        let text = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for entry in list where includeBackground || !entry.background || entry.exitCode != 0 {
            let time = Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.timeMs) / 1000))
            text.append(NSAttributedString(string: "\(time)  ", attributes: [.font: mono, .foregroundColor: Theme.secondaryText]))
            let failed = entry.exitCode != 0
            text.append(NSAttributedString(string: entry.command, attributes: [
                .font: mono,
                .foregroundColor: failed ? Theme.FileStatus.conflict : (entry.background ? Theme.secondaryText : Theme.text),
            ]))
            let meta = failed ? "  (exit \(entry.exitCode), \(entry.durationMs) ms)" : "  (\(entry.durationMs) ms)"
            text.append(NSAttributedString(string: meta + "\n", attributes: [.font: mono, .foregroundColor: Theme.secondaryText]))
            if !entry.output.isEmpty {
                let indented = entry.output.split(separator: "\n", omittingEmptySubsequences: false).map { "          " + $0 }.joined(separator: "\n")
                text.append(NSAttributedString(string: indented + "\n", attributes: [.font: mono, .foregroundColor: Theme.secondaryText]))
            }
        }
        guard text.length > 0, let storage = textView.textStorage else { return }
        let atBottom = (textView.enclosingScrollView?.verticalScroller?.floatValue ?? 1) > 0.98
        storage.append(text)
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func clearAll() {
        entries.removeAll()
        textView.textStorage?.setAttributedString(NSAttributedString())
    }
}
