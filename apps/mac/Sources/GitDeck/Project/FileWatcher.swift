import CoreServices
import Foundation

/// 监听项目目录的文件变化（FSEvents），合并短时间内的多次变化后回调。
///
/// 对应 IDEA 的 VFS 刷新：外部修改文件、命令行执行 git 后自动刷新状态，无需切回窗口。
/// `.git` 中与状态无关的变化（对象库、reflog、锁文件、GitDeck 自己的数据）被忽略。
@MainActor
final class FileWatcher {
    private let root: String
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var flushTask: Task<Void, Never>?

    /// 合并变化的时间窗口。
    private static let latency: CFTimeInterval = 0.3

    init(root: URL, onChange: @escaping ([String]) -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath().path
        self.onChange = onChange
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.received(Array(list.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        flushTask?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        let relevant = paths.filter(isRelevant)
        guard !relevant.isEmpty else { return }
        pending.formUnion(relevant)
        guard flushTask == nil else { return }
        // 构建等大量写文件时，每 0.5 秒最多回调一次。
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            let changed = Array(self.pending)
            self.pending = []
            self.flushTask = nil
            self.onChange(changed)
        }
    }

    private func isRelevant(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return true }
        let inner = String(path[range.upperBound...])
        if inner.hasSuffix(".lock") { return false }
        for ignored in ["objects/", "logs/", "gitdeck/", "worktrees/", "modules/"] where inner.hasPrefix(ignored) {
            return false
        }
        return true
    }
}
