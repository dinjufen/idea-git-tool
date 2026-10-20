import AppKit

/// askpass 模式：git / ssh 需要凭据时以 `GIT_ASKPASS` / `SSH_ASKPASS` 调用本程序，
/// 参数为提示语。弹出原生输入框，把用户输入写到标准输出后退出（对应 IDEA 内置的 askpass）。
///
/// 输入内容只交给发起请求的 git 进程，本程序不保存；凭据是否记住由 git 的 credential helper 决定。
@MainActor
enum AskPass {
    /// 当前进程是否作为 askpass 被调用（标记变量由核心在启动 git 时注入）。
    static var isInvoked: Bool {
        ProcessInfo.processInfo.environment["GITDECK_ASKPASS"] == "1"
    }

    /// 返回进程退出码：0 表示已输出用户输入，1 表示用户取消。
    static func run(prompt: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()

        let alert = AppAlert()
        alert.messageText = tr("askpass.title")
        alert.informativeText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)

        // ssh 首次连接确认主机指纹：只需回答 yes / no。
        if isConfirmation(prompt) {
            alert.addButton(withTitle: tr("askpass.yes"))
            alert.addButton(withTitle: tr("askpass.no"))
            let answer = alert.runModal() == .alertFirstButtonReturn ? "yes" : "no"
            write(answer)
            return 0
        }

        let field: NSTextField = isSecret(prompt) ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = isSecret(prompt) ? tr("askpass.password") : tr("askpass.username")
        alert.accessoryView = field
        alert.addButton(withTitle: tr("askpass.ok"))
        alert.addButton(withTitle: tr("common.cancel"))
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
        write(field.stringValue)
        return 0
    }

    private static func isSecret(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["password", "passphrase", "token", "pin"].contains { lower.contains($0) }
    }

    private static func isConfirmation(_ prompt: String) -> Bool {
        prompt.contains("(yes/no")
    }

    private static func write(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }
}
