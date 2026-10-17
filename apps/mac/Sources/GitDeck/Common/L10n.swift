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
        case let .CommandFailed(command, _, stderr):
            tr("error.commandFailed", command, stderr)
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
        }
    }
}

func errorMessage(_ error: any Error) -> String {
    (error as? CoreError)?.localizedMessage ?? error.localizedDescription
}
