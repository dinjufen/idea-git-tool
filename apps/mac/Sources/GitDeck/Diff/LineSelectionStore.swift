import Foundation
import GitDeckCore

/// 部分提交的行选择（IDEA 在 Diff 中勾选要提交的改动块 / 行）：按文件记录不提交的行。
///
/// 记录选择时两侧的内容；提交时若文件已改变，选择失效，由提交流程提示用户重新选择。
@MainActor
final class LineSelectionStore {
    struct Selection: Equatable {
        /// 工作区（新）文本中不提交的行。
        var excludedLines: Set<UInt32> = []
        /// 基准（HEAD）文本中不提交的删除行。
        var excludedBaseLines: Set<UInt32> = []
        /// 选择时的基准与工作区内容。
        let base: String
        let text: String

        var isEmpty: Bool { excludedLines.isEmpty && excludedBaseLines.isEmpty }

        /// 要提交的内容。
        var content: String {
            partialText(base: base, text: text, excludedLines: Array(excludedLines), excludedBaseLines: Array(excludedBaseLines))
        }
    }

    private(set) var selections: [String: Selection] = [:]
    private var observers: [UUID: @MainActor () -> Void] = [:]

    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func selection(for path: String) -> Selection? { selections[path] }

    /// 该文件只提交部分改动。
    func isPartial(_ path: String) -> Bool { selections[path].map { !$0.isEmpty } ?? false }

    func update(_ path: String, _ selection: Selection) {
        selections[path] = selection.isEmpty ? nil : selection
        notify()
    }

    func remove(_ paths: [String]) {
        var changed = false
        for path in paths where selections.removeValue(forKey: path) != nil { changed = true }
        if changed { notify() }
    }

    private func notify() {
        for handler in observers.values { handler() }
    }
}
