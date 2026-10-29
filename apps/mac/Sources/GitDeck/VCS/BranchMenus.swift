import AppKit
import GitDeckCore

/// 分支操作菜单，项目与 IDEA 的分支子菜单一致；分支弹窗与 Git 日志左侧的分支面板共用。
@MainActor
enum BranchMenus {
    /// `beforeAction`：执行操作前调用（例如关闭弹窗）。
    static func menu(for branch: BranchRef, model: ProjectModel, operations ops: GitOperations,
                     beforeAction: (@MainActor () -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let name = branch.name
        let current = model.currentBranchTitle
        let isCurrent = branch.isCurrent

        func add(_ title: String, enabled: Bool = true, _ action: (@MainActor () -> Void)?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let action, enabled {
                let handler = MenuAction {
                    beforeAction?()
                    action()
                }
                item.target = handler
                item.action = #selector(MenuAction.invoke)
                item.representedObject = handler
            } else {
                item.isEnabled = false
                if action == nil { item.toolTip = tr("common.notImplemented") }
            }
            menu.addItem(item)
        }

        if branch.kind == .local {
            add(tr("branches.menu.checkout"), enabled: !isCurrent) { ops.checkout(.local(name)) }
        } else {
            add(tr("branches.menu.checkout")) { ops.checkout(.remote(name)) }
        }
        add(tr("branches.menu.newFrom", name)) { ops.newBranch(from: name) }
        add(tr("branches.menu.checkoutAndRebase", current), enabled: branch.kind == .local && !isCurrent) {
            ops.checkoutAndRebase(name)
        }
        menu.addItem(.separator())
        add(tr("branches.menu.compare", current), enabled: !isCurrent) { ops.compareWithCurrent(name) }
        add(tr("branches.menu.showDiff")) { ops.showDiffWithWorkingTree(name) }
        add(tr("branches.menu.aiReview", current, name), enabled: !isCurrent && ops.aiReview != nil) {
            ops.aiReview?.reviewBranch(against: name, in: ops.model)
        }
        menu.addItem(.separator())
        add(tr("branches.menu.rebaseOnto", current, name), enabled: !isCurrent) { ops.rebase(onto: name) }
        add(tr("branches.menu.mergeInto", name, current), enabled: !isCurrent) { ops.merge(name) }
        menu.addItem(.separator())
        if branch.kind == .local {
            add(tr("branches.menu.update"), enabled: branch.upstream != nil) { ops.updateBranch(name) }
            // 与 IDEA 一致，任何本地分支都可以推送。
            add(tr("branches.menu.push")) { ops.push(branch: name) }
            menu.addItem(.separator())
            add(tr("branches.menu.rename")) { ops.rename(name) }
            add(tr("branches.menu.delete"), enabled: !isCurrent) { ops.delete(name) }
        } else {
            add(tr("branches.menu.pull", name, current)) { ops.merge(name) }
            add(tr("branches.menu.delete")) { ops.deleteRemoteBranch(name) }
        }
        return menu
    }
}
