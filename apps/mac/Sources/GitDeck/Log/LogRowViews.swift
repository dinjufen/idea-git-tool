import AppKit
import GitDeckCore

/// 提交图配色，按核心返回的颜色序号循环取用。
enum GraphPalette {
    static let colors: [NSColor] = [
        0x3574F0, 0x5FB865, 0xE55765, 0xD6AE58, 0x955AE0,
        0x2E9E9E, 0xE07D3C, 0xC94F9C, 0x6C8EBF, 0x8FAD50,
    ].map { NSColor(hex: $0) }

    static func color(_ index: UInt32) -> NSColor {
        colors[Int(index) % colors.count]
    }
}

/// Log 表格 Subject 列：提交图 + 引用标签 + 标题，一次绘制完成以保证大列表滚动流畅。
final class LogSubjectCellView: NSView {
    static let laneWidth: CGFloat = 14
    private static let nodeRadius: CGFloat = 3.5

    var commit: LogCommit? {
        didSet { needsDisplay = true }
    }

    /// 是否为当前 HEAD 所在提交（标题加粗，与 IDEA 一致）。
    var isHead = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let commit else { return }
        let graph = commit.graph
        let h = bounds.height
        let x: (UInt32) -> CGFloat = { CGFloat($0) * Self.laneWidth + Self.laneWidth / 2 + 4 }

        // 提交图线段。
        for edge in graph.edges {
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            switch edge.part {
            case .full:
                path.move(to: NSPoint(x: x(edge.fromLane), y: 0))
                path.line(to: NSPoint(x: x(edge.toLane), y: h))
            case .top:
                path.move(to: NSPoint(x: x(edge.fromLane), y: 0))
                path.line(to: NSPoint(x: x(edge.toLane), y: h / 2))
            case .bottom:
                path.move(to: NSPoint(x: x(edge.fromLane), y: h / 2))
                path.line(to: NSPoint(x: x(edge.toLane), y: h))
            }
            GraphPalette.color(edge.color).setStroke()
            path.stroke()
        }
        let center = NSPoint(x: x(graph.lane), y: h / 2)
        let r = Self.nodeRadius
        let node = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        GraphPalette.color(graph.color).setFill()
        node.fill()

        // 引用标签与标题。
        var cursor = CGFloat(graph.width) * Self.laneWidth + 12
        for label in commit.refs {
            cursor = drawRefLabel(label, at: cursor, rowHeight: h) + 4
        }
        let font = isHead ? NSFont.systemFont(ofSize: 13, weight: .semibold) : Theme.uiFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.text,
            .paragraphStyle: Self.truncating,
        ]
        let size = commit.subject.size(withAttributes: attrs)
        let rect = NSRect(x: cursor + 2, y: (h - size.height) / 2, width: max(0, bounds.width - cursor - 4), height: size.height)
        commit.subject.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// 绘制一个圆角引用标签，返回其右边缘 x 坐标。
    private func drawRefLabel(_ label: RefLabel, at x: CGFloat, rowHeight h: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: label.isCurrent ? .semibold : .regular),
            .foregroundColor: Theme.text,
        ]
        let size = label.name.size(withAttributes: attrs)
        let rect = NSRect(x: x, y: (h - 16) / 2, width: size.width + 12, height: 16)
        RefStyle.background(for: label.kind).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        label.name.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2), withAttributes: attrs)
        return rect.maxX
    }
}

/// 引用标签底色：本地分支、远程分支、标签、HEAD 区分显示。
enum RefStyle {
    static func background(for kind: RefKind) -> NSColor {
        switch kind {
        case .head: Theme.dynamic(light: 0xFFE8B3, dark: 0x5C4A1E)
        case .localBranch: Theme.dynamic(light: 0xD9F2DB, dark: 0x294A2E)
        case .remoteBranch: Theme.dynamic(light: 0xE8E0F7, dark: 0x3F3554)
        case .tag: Theme.dynamic(light: 0xFFF1CC, dark: 0x4D4224)
        }
    }
}

/// IDEA 的“美化”日期格式：今天 / 昨天显示相对日期，其余显示日期与时间。
enum LogDateFormatter {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let long: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func short(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return tr("log.date.today", time.string(from: date)) }
        if calendar.isDateInYesterday(date) { return tr("log.date.yesterday", time.string(from: date)) }
        return full.string(from: date)
    }

    static func detailed(_ timestamp: Int64) -> String {
        long.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
