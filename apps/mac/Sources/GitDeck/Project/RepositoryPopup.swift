import AppKit
import GitDeckCore

/// 多仓库项目中工具窗口工具栏上的仓库选择（Stash、Shelf、Worktrees 等按仓库显示的内容）。
/// 只有一个仓库时隐藏。
@MainActor
final class RepositoryPopup: NSPopUpButton {
    private var workspace: Workspace?
    private var observer: UUID?
    private var onChange: ((ProjectModel) -> Void)?
    private(set) var selected: ProjectModel?

    init() {
        super.init(frame: .zero, pullsDown: false)
        bezelStyle = .inline
        controlSize = .small
        font = Theme.smallFont
        target = self
        action = #selector(changed)
        isHidden = true
        setAccessibilityLabel(tr("workspace.repository"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { workspace?.removeObserver(observer) }
    }

    func configure(workspace: Workspace, selected: ProjectModel, onChange: @escaping (ProjectModel) -> Void) {
        self.workspace = workspace
        self.selected = selected
        self.onChange = onChange
        observer = workspace.observe { [weak self] in self?.rebuild() }
        rebuild()
    }

    private func rebuild() {
        guard let workspace else { return }
        isHidden = !workspace.isMultiRoot
        // 选中的仓库被移除时回到主仓库。
        if let selected, !workspace.models.contains(where: { $0 === selected }) {
            self.selected = workspace.primary
            onChange?(workspace.primary)
        }
        let titles = workspace.models.map { workspace.displayName(of: $0) }
        if itemTitles != titles {
            removeAllItems()
            for repository in workspace.models {
                let item = NSMenuItem(title: workspace.displayName(of: repository), action: nil, keyEquivalent: "")
                item.image = RepositoryBranchesPopover.chip(workspace.color(for: repository))
                menu?.addItem(item)
            }
        }
        if let index = workspace.models.firstIndex(where: { $0 === selected }) { selectItem(at: index) }
    }

    @objc private func changed() {
        guard let workspace, workspace.models.indices.contains(indexOfSelectedItem) else { return }
        let repository = workspace.models[indexOfSelectedItem]
        guard repository !== selected else { return }
        selected = repository
        onChange?(repository)
    }
}
