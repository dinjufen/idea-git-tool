# 架构与产品决策记录

> 代号：**GitDeck**（占位，发布前统一替换）· Bundle ID 占位：`com.example.gitdeck`
> 记录日期：2026-10-17

## 目标

一个跨平台 Git 客户端：

1. 功能、交互、UI 对齐 JetBrains IDEA 的 Git 相关功能（以 **New UI** 为基准）。
2. 内置类 VSCode 文本编辑器：语法高亮、字体设置、Git 历史、冲突解决。
3. 平台：macOS 15+（仅 arm64）；Windows 10+（x86-64 与 arm64，无 32 位）。
4. 接入 AI 大模型与 Agent，用于代码评审。
5. 现代化 UI 交互（优先级低于功能）。

## 已确定的决策

| # | 议题 | 决定 | 要点 |
|---|------|------|------|
| 1 | 技术栈 | **原生**：macOS 用 Swift，Windows 用 C# + WinUI 3 | 两端 UI 各自原生实现 |
| 2 | 核心逻辑 | **Rust 共享核心**，经 UniFFI 生成 Swift / C# 绑定 | git 调用与解析、提交图布局、diff/三方合并、AI 客户端与 Agent、配置与凭据统一在核心 |
| 3 | 编辑器 | **原生组件 + tree-sitter** | mac：CodeEditSourceEditor；Win：WinUIEdit（Scintilla）；高亮 token 由 Rust 核心中的 tree-sitter 统一计算 |
| 4 | Git 后端 | **系统 git CLI**（与 IDEA 一致），最低 git 2.30 | Windows 优先使用用户安装的 Git for Windows，缺失时回退到安装包内置的 MinGit |
| 5 | 平台顺序 | **mac 先行，Windows 后跟** | Rust 核心从一开始就在 CI 上跑 Windows 测试 |
| 6 | 分期 | 见下文「分期」 | |
| 7 | UI 基准 | **IDEA New UI** | 主工具栏 + VCS 分支组件 + 图标条工具窗口 |
| 8 | 语言 | **简体中文 + 英文** | 跟随系统、可手动切换；中文术语对齐 IDEA 官方中文语言包；mac 用 `.xcstrings`，Win 用 `.resw`，核心返回错误码 + 文案键 |
| 9 | 许可 | **闭源 / 商用** | 只使用 MIT / Apache-2.0 / BSD 等宽松许可依赖，CI 加许可证扫描；禁止 GPL/AGPL（例如 STTextView） |
| 10 | 命名 | 代号 GitDeck | 名称集中配置；名称中不使用 "IDEA" / "JetBrains" 商标 |

### 由以上决策推导出的技术默认

- **mac UI 框架**：以 AppKit 为主（`NSOutlineView` / `NSTableView` 承载变更树、Log 图等大数据量视图），简单对话框和设置页用 SwiftUI。
- **Win UI 框架**：WinUI 3 + Windows App SDK，打包为 MSIX，同时提供 x64 与 arm64 两个包。
- **构建**：Rust 核心编译为静态库（mac：`aarch64-apple-darwin`；Win：`x86_64-pc-windows-msvc` 与 `aarch64-pc-windows-msvc`）。
- **本机环境**：使用 `/Applications/Xcode-beta.app`，构建时通过 `DEVELOPER_DIR` 指定，不改动系统级 `xcode-select`。

## 分期

### 一期：日常工作流闭环（mac）
- 仓库：打开、克隆、初始化
- Project 文件树、编辑器（语法高亮、字体设置、查找替换）
- Commit 工具窗口：变更列表、Changelist、按块/按行部分提交、Amend、提交前检查
- Diff 查看器：并排 / 统一视图
- Git Log：提交图、按分支/作者/日期/路径筛选、提交详情
- Branches 弹窗：检出、新建、删除、重命名、合并、变基、比较
- Fetch、Pull、Update Project、Push 对话框
- 冲突解决：Conflicts 对话框 + 三栏合并
- Annotate（blame）、File History、Stash、Shelve

### 二期：高级操作
- 交互式 Rebase、Cherry-pick、Revert、Reset、Undo Commit
- Tags、Remotes 管理、Worktrees、Submodules
- Patch 创建与应用、Git Console

### 三期：AI 评审（可与二期并行）
- 接入大模型与 Agent，评审本地变更与提交
- 细节（接入哪些厂商、Agent 可用的工具、评审结果的展示方式）在开工前单独讨论

### 四期：Windows 端
- 复用 Rust 核心，实现 WinUI 3 UI 层
- 构建与验证环境待定：由用户提供 Windows 机器（SSH）或使用 GitHub Actions Windows runner

### 五期（可选）：GitHub / GitLab PR 集成
- PR 列表、在客户端内评审、评论、合并

## 待讨论（到对应阶段再定）

- AI 评审的细节（三期开工前）
- Windows 构建与验证环境（四期开工前）
- 代码签名与公证：Apple Developer ID、Windows 代码签名证书（首次打包发布前）
