import Foundation
import GitDeckCore

/// 本地化入口。文案键统一放在 Resources/Localizable.xcstrings（en / zh-Hans）。
enum L10n {
    /// 打包成 .app 后资源包位于 Contents/Resources；`swift run` 时回退到 SwiftPM 的 Bundle.module。
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "GitDeck_GitDeck", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static var productName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "GitDeck"
    }
}

/// 查找本地化文案；`args` 按 `%@` 顺序替换。
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = L10n.bundle.localizedString(forKey: key, value: nil, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

extension CoreError {
    /// 面向用户的错误描述。核心只给出错误码，文案在这里映射。
    var localizedMessage: String {
        switch self {
        case .GitNotFound:
            tr("error.gitNotFound")
        case let .GitTooOld(found, required):
            tr("error.gitTooOld", found, required)
        case let .NotARepository(path):
            tr("error.notARepository", path)
        case let .CommandFailed(_, _, stderr):
            commandFailedMessage(stderr)
        case let .Parse(detail):
            tr("error.parse", detail)
        case let .Io(detail):
            tr("error.io", detail)
        case .EmptyCommitMessage:
            tr("error.emptyCommitMessage")
        case .NothingToCommit:
            tr("error.nothingToCommit")
        case let .InvalidBranchName(name):
            tr("ops.error.invalidName", name)
        case let .LocalChangesWouldBeOverwritten(files):
            tr("ops.error.overwritten", files.joined(separator: "\n"))
        case let .BranchNotFullyMerged(name):
            tr("ops.delete.notMerged.title", name)
        case let .NoUpstream(branch):
            tr("ops.error.noUpstream", branch)
        case .DetachedHead:
            tr("ops.error.detachedHead")
        case let .PushRejected(reason):
            tr("ops.error.pushRejected", reason)
        case let .AuthenticationFailed(detail):
            tr("ops.error.auth", detail)
        case let .InvalidTagName(name):
            tr("ops.error.invalidTagName", name)
        case .RebaseWithMerges:
            tr("ops.error.rebaseWithMerges")
        case let .InvalidRebasePlan(detail):
            tr("ops.error.invalidRebasePlan", detail)
        case let .AiNetwork(detail):
            tr("ai.error.network", detail)
        case let .AiAuthenticationFailed(message):
            tr("ai.error.auth", message)
        case let .AiRequestFailed(status, message):
            switch status {
            case 429: tr("ai.error.rateLimited", message)
            case 529, 503: tr("ai.error.overloaded", message)
            default: tr("ai.error.request", "\(status)", message)
            }
        case let .AiRefused(category):
            tr("ai.error.refused", category ?? "-")
        case let .AiInvalidResponse(detail):
            tr("ai.error.invalidResponse", detail)
        case let .AiCliNotFound(name):
            tr("ai.error.cliNotFound", name)
        case let .AiCliFailed(message):
            tr("ai.error.cliFailed", message)
        case .AiCancelled:
            tr("ai.error.cancelled")
        }
    }
}

func errorMessage(_ error: any Error) -> String {
    (error as? CoreError)?.localizedMessage ?? error.localizedDescription
}

/// 把 Git 命令失败转成面向用户的说明，与 Windows `L10n.CommandFailedMessage` 保持一致。
func commandFailedMessage(_ stderr: String) -> String {
    let detail = gitErrorDetail(stderr)
    if let revision = unknownRevision(in: detail) {
        return tr("error.unknownRevision", revision)
    }
    if looksLikeUnknownRevision(detail) {
        return tr("error.unknownRevisionGeneric")
    }
    return detail.isEmpty ? tr("error.commandFailedGeneric") : detail
}

/// 去掉 Git 日志里的 fatal/error 等严重级别前缀，避免弹窗看起来像程序崩溃。
func gitErrorDetail(_ stderr: String) -> String {
    stderr
        .components(separatedBy: .newlines)
        .map(stripGitSeverityPrefix)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private let gitSeverityPrefixes = [
    "fatal:", "error:", "warning:", "hint:",
    "致命错误：", "错误：", "警告：", "提示：",
]

private func stripGitSeverityPrefix(_ line: String) -> String {
    var line = line.trimmingCharacters(in: .whitespaces)
    var changed = true
    while changed {
        changed = false
        let lower = line.lowercased()
        for prefix in gitSeverityPrefixes {
            let matches = prefix.allSatisfy(\.isASCII) ? lower.hasPrefix(prefix) : line.hasPrefix(prefix)
            if matches {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
    }
    return line
}

private let unknownRevisionRegexes: [NSRegularExpression] = {
    let patterns = [
        #"could not parse object '([^']+)'"#,
        #"invalid object name '([^']+)'"#,
        #"invalid object name ([0-9a-fA-F]+)"#,
        #"bad revision '([^']+)'"#,
        #"bad object '([^']+)'"#,
        #"ambiguous argument '([^']+)'"#,
        #"无法解析对象\s*['「『“]([^'」』”]+)['」』”]"#,
    ]
    return patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
}()

private func unknownRevision(in detail: String) -> String? {
    let range = NSRange(detail.startIndex..., in: detail)
    for regex in unknownRevisionRegexes {
        guard let match = regex.firstMatch(in: detail, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: detail) else { continue }
        let revision = String(detail[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !revision.isEmpty { return revision }
    }
    return nil
}

private let unknownRevisionGenericRegex = try! NSRegularExpression(
    pattern: #"needed a single revision|unknown revision"#,
    options: [.caseInsensitive]
)

private func looksLikeUnknownRevision(_ detail: String) -> Bool {
    let range = NSRange(detail.startIndex..., in: detail)
    return unknownRevisionGenericRegex.firstMatch(in: detail, options: [], range: range) != nil
}
