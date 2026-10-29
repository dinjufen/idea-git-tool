import AppKit

/// 两份文本之间一段对应关系：源文本 `[fromStart, fromStart + fromCount)` 对应目标文本 `[toStart, toStart + toCount)`。
/// 段与段之间的未变化部分逐行一一对应。
struct LineSegment {
    var fromStart: Double
    var fromCount: Double
    var toStart: Double
    var toCount: Double

    var reversed: LineSegment {
        LineSegment(fromStart: toStart, fromCount: toCount, toStart: fromStart, toCount: fromCount)
    }
}

enum LineMapping {
    /// 把源文本中的行号（可带小数）映射到目标文本；`segments` 须按 `fromStart` 排序。
    static func map(_ line: Double, _ segments: [LineSegment]) -> Double {
        var delta = 0.0
        for segment in segments {
            if line < segment.fromStart { break }
            if line < segment.fromStart + segment.fromCount {
                // 变更段内按比例映射。
                return segment.toStart + (line - segment.fromStart) / segment.fromCount * segment.toCount
            }
            delta = (segment.toStart + segment.toCount) - (segment.fromStart + segment.fromCount)
        }
        return line + delta
    }
}

extension CodeEditorView {
    /// 光标所在行（从 0 开始）。
    var caretLine: Int {
        guard let location = textView.selectionManager.textSelections.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(location) else { return 0 }
        return line.index
    }

    /// 视口顶部所在的行（带小数部分）。
    var topVisibleLine: Double {
        let y = scrollView.contentView.bounds.minY
        guard let line = textView.layoutManager.lineStorage.getLine(atPosition: max(0, y)) else { return 0 }
        let fraction = line.height > 0 ? Double((y - line.yPos) / line.height) : 0
        return Double(line.index) + min(max(fraction, 0), 1)
    }

    /// 滚动使指定行（可带小数）位于视口顶部。
    func scroll(toLine line: Double) {
        let storage = textView.layoutManager.lineStorage
        let whole = Int(line.rounded(.down))
        let y: CGFloat
        if let position = storage.getLine(atIndex: whole) {
            y = position.yPos + CGFloat(line - Double(whole)) * position.height
        } else if let last = storage.last {
            y = last.yPos + last.height
        } else {
            y = 0
        }
        scroll(toY: y)
    }

    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 把第 `line` 行滚动到视口上方约三分之一处并把光标放在该行（跳转到差异时使用，与 IDEA 一致）。
    func reveal(line: Int) {
        let storage = textView.layoutManager.lineStorage
        guard let position = storage.getLine(atIndex: line) ?? storage.last else { return }
        scroll(toY: position.yPos - scrollView.contentView.bounds.height / 3)
        textView.selectionManager.setSelectedRange(NSRange(location: position.range.location, length: 0))
    }
}
