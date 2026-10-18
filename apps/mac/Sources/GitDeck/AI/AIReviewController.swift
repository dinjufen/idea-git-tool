import AppKit
import GitDeckCore

/// 一个项目的 AI 评审：启动与取消评审、接收核心的进度事件、首次使用确认、提交前检查与生成提交信息。
/// AI Review 工具窗口与编辑器标记都观察它。
@MainActor
final class AIReviewController {
    enum Phase: Equatable {
        case idle, running, finished, failed, cancelled
    }

    struct Activity {
        let symbol: String
        let text: String
    }

    enum Readiness {
        case ready(AiProviderConfig, String)
        /// 提交前检查时用户选择跳过评审。
        case skip
        case cancelled
    }

    let model: ProjectModel
    weak var window: NSWindow?
    /// 显示 AI Review 工具窗口。
    var onReveal: (() -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var title = ""
    private(set) var files: [String] = []
    private(set) var excluded: [String] = []
    private(set) var truncated = false
    private(set) var activities: [Activity] = []
    /// 当前一轮模型输出的正文（Agent 的说明文字）。
    private(set) var narration = ""
    private(set) var result: ReviewResult?
    private(set) var errorText: String?
    private(set) var usage: (input: UInt64, output: UInt64) = (0, 0)
    private(set) var turn: UInt32 = 0
    private(set) var modelName = ""
    /// 已应用建议的发现（按 `result.findings` 下标）。
    private(set) var applied: Set<Int> = []

    private var scope: ReviewScope?
    private var task: AiTask?
    private var generation = 0
    private var completion: ((ReviewResult?) -> Void)?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    init(model: ProjectModel) {
        self.model = model
    }

    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for handler in observers.values { handler() }
    }

    var isRunning: Bool { phase == .running }
    var canRerun: Bool { scope != nil && !isRunning }

    /// 评审的是工作区（本地改动，或与当前 HEAD 相同且没有本地改动的修订）：发现可以在编辑器中标记、直接应用建议。
    func isWorkingTreeResult(for path: String) -> Bool {
        guard let result else { return false }
        guard let revision = result.revision else { return true }
        let head = model.status.branch.oid ?? ""
        let matchesHead = revision == "HEAD" || (!head.isEmpty && head.hasPrefix(revision)) || (!revision.isEmpty && revision.hasPrefix(head))
        return matchesHead && !model.status.changes.contains { $0.path == path }
    }

    /// 工作区文件上的发现（下标与发现），用于编辑器标记。
    func workingTreeFindings(for path: String) -> [(index: Int, finding: ReviewFinding)] {
        guard let result, isWorkingTreeResult(for: path) else { return [] }
        return result.findings.enumerated().filter { $0.element.file == path }.map { ($0.offset, $0.element) }
    }

    // MARK: - 准备：配置与授权

    /// 检查是否已配置模型服务，并在本项目首次发送代码前请用户确认。
    func prepare(allowSkip: Bool = false) -> Readiness {
        guard let (config, apiKey) = AISettings.current() else {
            let alert = NSAlert()
            alert.messageText = tr("ai.notConfigured.title")
            alert.informativeText = tr("ai.notConfigured.message")
            alert.addButton(withTitle: tr("ai.notConfigured.open"))
            if allowSkip { alert.addButton(withTitle: tr("ai.precommit.commitAnyway")) }
            alert.addButton(withTitle: tr("common.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                SettingsWindowController.shared.show(.ai)
                return .cancelled
            case .alertSecondButtonReturn where allowSkip:
                return .skip
            default:
                return .cancelled
            }
        }
        let project = model.rootURL.path
        if !AISettings.hasConsent(project: project, config: config) {
            let alert = NSAlert()
            alert.messageText = tr("ai.consent.title", AISettings.host(config.baseUrl))
            alert.informativeText = tr("ai.consent.message", model.projectName, AISettings.host(config.baseUrl))
            alert.addButton(withTitle: tr("ai.consent.allow"))
            alert.addButton(withTitle: tr("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
            AISettings.grantConsent(project: project, config: config)
        }
        return .ready(config, apiKey)
    }

    // MARK: - 评审

    func reviewLocalChanges(paths: [String]) {
        let count = paths.isEmpty ? model.status.changes.count : paths.count
        start(scope: .localChanges(paths: paths), title: tr("ai.scope.local", "\(count)"))
    }

    func reviewCommits(_ hashes: [String], subject: String?) {
        let title = hashes.count == 1
            ? tr("ai.scope.commit", String(hashes[0].prefix(8)), subject ?? "")
            : tr("ai.scope.commits", "\(hashes.count)")
        start(scope: .commits(hashes: hashes), title: title)
    }

    func reviewBranch(against base: String) {
        let head = model.status.branch.head ?? "HEAD"
        start(scope: .branchCompare(base: base, head: "HEAD"), title: tr("ai.scope.branch", head, base))
    }

    func rerun() {
        guard let scope, !isRunning else { return }
        start(scope: scope, title: title)
    }

    /// 开始评审；`completion` 在结束时调用（失败或取消时参数为 `nil`）。
    func start(scope: ReviewScope, title: String, allowSkip: Bool = false, completion: ((ReviewResult?) -> Void)? = nil) {
        guard !isRunning else {
            onReveal?()
            return
        }
        let (config, apiKey): (AiProviderConfig, String)
        switch prepare(allowSkip: allowSkip) {
        case let .ready(c, k): (config, apiKey) = (c, k)
        case .skip:
            completion?(ReviewResult(summary: "", findings: [], revision: nil, turns: 0, inputTokens: 0, outputTokens: 0, incomplete: true))
            return
        case .cancelled:
            completion?(nil)
            return
        }
        generation += 1
        let current = generation
        self.scope = scope
        self.title = title
        self.completion = completion
        phase = .running
        files = []
        excluded = []
        truncated = false
        activities = []
        narration = ""
        result = nil
        errorText = nil
        usage = (0, 0)
        turn = 0
        applied = []
        modelName = config.model
        onReveal?()
        notify()

        let options = ReviewOptions(
            language: AISettings.language.promptName,
            sensitivePatterns: AISettings.sensitivePatterns,
            maxTurns: 0,
            tokenBudget: 0
        )
        // 回调来自核心的后台线程：按顺序转到主线程处理，丢弃旧评审的事件。
        let listener = ReviewListenerBridge { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, generation: current) }
            }
        }
        task = model.repository.startAiReview(config: config, apiKey: apiKey, scope: scope, options: options, listener: listener)
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        // 不等待后台线程结束：立即显示已取消，之后到达的事件被丢弃。
        generation += 1
        phase = .cancelled
        task = nil
        finish(nil)
    }

    func clear() {
        guard !isRunning else { return }
        phase = .idle
        scope = nil
        result = nil
        activities = []
        narration = ""
        errorText = nil
        notify()
    }

    func markApplied(_ index: Int) {
        applied.insert(index)
        notify()
    }

    private func handle(_ event: ReviewEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case let .started(files, excluded, truncated):
            self.files = files
            self.excluded = excluded
            self.truncated = truncated
            activities.append(Activity(symbol: "doc.text.magnifyingglass", text: tr("ai.activity.files", "\(files.count)")))
            if !excluded.isEmpty {
                activities.append(Activity(symbol: "lock", text: tr("ai.activity.excluded", excluded.joined(separator: ", "))))
            }
            if truncated {
                activities.append(Activity(symbol: "scissors", text: tr("ai.activity.truncated")))
            }
        case let .thinking(turn):
            self.turn = turn
            flushNarration()
        case let .text(text):
            narration += text
        case let .toolCall(name, detail):
            // 模型在调用工具前写的说明排在工具调用之前。
            flushNarration()
            activities.append(Activity(symbol: Self.symbol(forTool: name), text: "\(Self.title(forTool: name))  \(detail)"))
        case let .usage(input, output):
            usage = (input, output)
        case let .finished(result):
            self.result = result
            phase = .finished
            task = nil
            finish(result)
        case let .failed(error):
            task = nil
            if case .AiCancelled = error {
                phase = .cancelled
            } else {
                phase = .failed
                errorText = errorMessage(error)
            }
            finish(nil)
        }
        notify()
    }

    private func flushNarration() {
        let text = narration.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { activities.append(Activity(symbol: "text.bubble", text: text)) }
        narration = ""
    }

    private func finish(_ result: ReviewResult?) {
        let completion = self.completion
        self.completion = nil
        if let result {
            let problems = result.findings.count
            model.post(problems == 0 ? tr("ai.done.none") : tr("ai.done.some", "\(problems)"))
        } else if phase == .failed {
            model.post(tr("ai.failed"), isError: true)
        }
        notify()
        completion?(result)
    }

    static func symbol(forTool name: String) -> String {
        switch name {
        case "read_file": "doc.text"
        case "list_directory": "folder"
        case "search_code": "magnifyingglass"
        case "git_log": "clock.arrow.circlepath"
        case "git_blame": "person.text.rectangle"
        default: "wrench"
        }
    }

    static func title(forTool name: String) -> String {
        switch name {
        case "read_file": tr("ai.tool.readFile")
        case "list_directory": tr("ai.tool.listDirectory")
        case "search_code": tr("ai.tool.search")
        case "git_log": tr("ai.tool.log")
        case "git_blame": tr("ai.tool.blame")
        default: name
        }
    }

    // MARK: - 提交前检查

    /// 提交前评审选中的改动；返回是否继续提交。发现错误或警告时询问用户。
    func reviewBeforeCommit(paths: [String]) async -> Bool {
        let result: ReviewResult? = await withCheckedContinuation { continuation in
            start(scope: .localChanges(paths: paths), title: tr("ai.scope.local", "\(paths.count)"), allowSkip: true) { result in
                continuation.resume(returning: result)
            }
        }
        guard let result else {
            // 失败或取消：失败时询问是否仍然提交。
            guard phase == .failed else { return false }
            let alert = NSAlert()
            alert.messageText = tr("ai.precommit.failed")
            alert.informativeText = errorText ?? ""
            alert.addButton(withTitle: tr("ai.precommit.commitAnyway"))
            alert.addButton(withTitle: tr("common.cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        let problems = result.findings.filter { $0.severity != .suggestion }.count
        guard problems > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = tr("ai.precommit.problems", "\(problems)")
        alert.informativeText = tr("ai.precommit.problems.message")
        alert.addButton(withTitle: tr("ai.precommit.review"))
        alert.addButton(withTitle: tr("ai.precommit.commitAnyway"))
        alert.addButton(withTitle: tr("common.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            onReveal?()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - 生成提交信息

    private var messageTask: AiTask?

    var isGeneratingMessage: Bool { messageTask != nil }

    /// 根据选中文件生成提交信息；取消或失败时返回 `nil`（失败会提示）。
    func generateCommitMessage(paths: [String]) async -> String? {
        if let messageTask {
            messageTask.cancel()
            self.messageTask = nil
            return nil
        }
        guard case let .ready(config, apiKey) = prepare() else { return nil }
        let task = AiTask()
        messageTask = task
        let repository = model.repository
        let language = AISettings.language.promptName
        let patterns = AISettings.sensitivePatterns
        let result = await Task.detached {
            Result {
                try repository.generateCommitMessage(
                    config: config, apiKey: apiKey, paths: paths, language: language,
                    sensitivePatterns: patterns, task: task
                )
            }
        }.value
        guard messageTask === task else { return nil }
        messageTask = nil
        switch result {
        case let .success(message):
            return message
        case let .failure(error):
            if case CoreError.AiCancelled = error { return nil }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("ai.message.failed")
            alert.informativeText = errorMessage(error)
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return nil
        }
    }
}

/// 把核心的回调接口转成闭包。
final class ReviewListenerBridge: ReviewListener, @unchecked Sendable {
    private let handler: @Sendable (ReviewEvent) -> Void

    init(_ handler: @escaping @Sendable (ReviewEvent) -> Void) {
        self.handler = handler
    }

    func onEvent(event: ReviewEvent) { handler(event) }
}
