import AppKit

// 作为 git / ssh 的 askpass 被调用时，只弹出认证输入框，不启动主界面。
if AskPass.isInvoked {
    exit(AskPass.run(prompt: CommandLine.arguments.dropFirst().joined(separator: " ")))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
