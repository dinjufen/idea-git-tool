import AppKit
import GitDeckCore

/// 多仓库项目的 Branches 弹窗：顶部选择仓库（带标识色与当前分支）并可开启同步分支控制，
/// 下方是所选仓库的分支列表（与单仓库时的 Branches 弹窗相同）。
final class RepositoryBranchesPopover: NSViewController {
    weak var popover: NSPopover? {
        didSet { child?.popover = popover }
    }

    private let workspace: Workspace
    private let operationsFor: (ProjectModel) -> GitOperations
    private let onCommit: @MainActor () -> Void
    private let repoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let syncCheckbox = NSButton(checkboxWithTitle: tr("workspace.sync"), target: nil, action: nil)
    private let container = NSView()
    private var child: BranchesPopover?

    init(workspace: Workspace, selected: ProjectModel, operationsFor: @escaping (ProjectModel) -> GitOperations, onCommit: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.operationsFor = operationsFor
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
        selectedIndex = workspace.models.firstIndex { $0 === selected } ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var selectedIndex = 0

    override func loadView() {
        let root = ColoredView(Theme.toolWindowBackground)
        root.frame = NSRect(x: 0, y: 0, width: 380, height: 520)

        for model in workspace.models {
            let item = NSMenuItem(title: "\(workspace.displayName(of: model))  —  \(model.currentBranchTitle)", action: nil, keyEquivalent: "")
            item.image = Self.chip(workspace.color(for: model))
            repoPopup.menu?.addItem(item)
        }
        repoPopup.selectItem(at: selectedIndex)
        repoPopup.target = self
        repoPopup.action = #selector(repositoryChanged)
        repoPopup.controlSize = .small
        syncCheckbox.state = SyncBranchControl.isEnabled ? .on : .off
        syncCheckbox.controlSize = .small
        syncCheckbox.font = Theme.smallFont
        syncCheckbox.toolTip = tr("workspace.sync.tooltip")
        syncCheckbox.target = self
        syncCheckbox.action = #selector(syncChanged)

        let header = NSStackView(views: [repoPopup, NSView(), syncCheckbox])
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        let divider = SeparatorLine(.horizontal)
        container.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, divider, container] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: divider.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        showRepository()
    }

    /// 仓库标识色的小方块（菜单项图标）。
    static func chip(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
            return true
        }
    }

    private func showRepository() {
        child?.view.removeFromSuperview()
        child?.removeFromParent()
        let model = workspace.models[selectedIndex]
        let controller = BranchesPopover(model: model, operations: operationsFor(model), onCommit: onCommit)
        controller.popover = popover
        addChild(controller)
        container.addSubview(controller.view)
        controller.view.pinEdges(to: container)
        child = controller
    }

    @objc private func repositoryChanged() {
        selectedIndex = max(0, repoPopup.indexOfSelectedItem)
        showRepository()
    }

    @objc private func syncChanged() {
        SyncBranchControl.isEnabled = syncCheckbox.state == .on
    }
}
