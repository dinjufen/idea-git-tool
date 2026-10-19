# Windows 端（四期）开发交接说明

> 编写日期：2026-10-19 · 基于提交 `ae3edde` 之后的 `main`
>
> 读者：在 Windows 机器上接手开发的人或 Claude 会话。本文自成一体；mac 机器上的会话记忆不会同步过来，所以需要知道的约定都写在这里。

## 0. 新会话开场

在 Windows 上 clone 仓库后，可以对新会话这样说：

> 这是 GitDeck 项目的 Windows 端（四期）开发。请先完整阅读 `docs/WINDOWS-HANDOFF.md`、`docs/DECISIONS.md`、`README.md`，然后按交接文档第 5 节先在本机跑通 Rust 核心测试，再按第 6 节逐个和我确认开工前的决策。

## 1. 项目概况

- **目标**：跨平台 Git 客户端，功能、交互、UI 对齐 JetBrains IDEA 的 Git 功能（New UI），内置编辑器，以及 AI 代码评审。完整决策见 [DECISIONS.md](DECISIONS.md)，这份文档是一切实现的依据。
- **架构**：
  - Rust 共享核心 `core/gitdeck-core`：所有 git 操作（调用系统 git CLI）、解析、提交图布局、diff / 三方合并、tree-sitter 语法高亮、AI 评审 Agent。
  - 核心通过 UniFFI 0.32 导出；mac 端用生成的 Swift 绑定。
  - UI 层各平台原生：mac 是 Swift + AppKit（已完成），**Windows 是 C# + WinUI 3（本期任务）**。
- **mac 端现状**：一至三期全部完成，另有多仓库项目、设置、语言切换等。剩余事项见 [MAC-REMAINING.md](MAC-REMAINING.md)。
- **Windows 端现状**：零代码。Rust 核心**从未在 Windows 上编译或运行过测试**（第 5 项决策说要在 CI 上跑 Windows 测试，但仓库里还没有 CI）。

## 2. 协作约定（必须遵守）

1. **用中文沟通**。不清楚或需要讨论的事项**一次只提一个问题**，给出推荐项和取舍，讨论确定后再继续。技术细节层面的默认值可以自行决定，但要说明。
2. 重大决策写入 `docs/DECISIONS.md`。文档里没有覆盖的重大方向，先问用户。
3. **每完成一批功能，先问用户是否提交**；用户说提交并推送后再执行 `git commit` 和 `git push origin main`。提交身份沿用仓库已有提交的作者（见 `git log`）。提交信息用英文，标题概括这一批的内容。
4. **测试隔离**：用户会同时安装、试用正式版。调试和截图验证时只能结束自己启动的调试构建进程，不能结束用户的正式版进程，也不能删除正式版的设置和凭据。
   - Windows 上调试版和正式版应使用不同的应用标识、设置目录和凭据前缀，例如调试版加 `.debug` 后缀，与 mac 端一致。
5. **许可证**：闭源商用，只能引入 MIT / Apache-2.0 / BSD / ISC / Zlib / Unicode 许可的依赖，禁止 GPL / AGPL。MPL-2.0 的情况见第 6 节第 1 项。NuGet 包同样适用。
6. 名称集中在 `product.env`；代码和文案里不出现 “IDEA” / “JetBrains” 商标。

## 3. 仓库结构

```
core/gitdeck-core/        Rust 共享核心
  src/git/runner.rs       git 进程调用（git 可执行文件选择、askpass、环境变量）
  src/repo.rs             Repository 对象（UniFFI Object，绝大多数 API 都是它的方法）
  src/ai/                 AI 评审：HTTP/SSE、Anthropic 与 OpenAI 兼容协议、Agent 工具、敏感文件过滤
  src/*.rs                分支、提交、diff、合并、stash、shelf、changelist、tag、remote、workspace 等
  tests/                  集成测试（用真实 git 搭建临时仓库）
core/uniffi-bindgen/      绑定生成命令行工具（目前只用于 Swift）
apps/mac/                 mac 客户端（Swift + AppKit），Windows UI 的行为参考实现
apps/mac/Sources/GitDeck/Resources/Localizable.xcstrings   全部界面文案（en / zh-Hans，约 780 条）
scripts/                  mac 构建脚本、图标生成脚本
assets/icon/              应用图标源图（1024 PNG）
deny.toml                 依赖许可证白名单
```

### 核心 API 概览

- `Repository`（Object）：打开 / 初始化仓库后的所有操作，包括状态、提交、分支、Log、diff、合并、stash、shelf、changelist、tag、remote、worktree、submodule、console 等。方法都是**阻塞调用**，UI 侧必须在后台线程调用。
- `AiTask`（Object）：AI 任务的取消句柄。
- `ReviewListener`（回调接口，`#[uniffi::export(with_foreign)]`）：AI 评审的流式进度回调。
- 自由函数：
  - git 选择：`git_candidates`、`git_info`、`git_info_at`、`set_git_executable`、`set_askpass_program`。
  - 克隆：`clone_repository`、`clone_directory_name`。
  - diff 与合并：`diff_texts`、`line_changes`、`merge_chunks`、`partial_text`。
  - 高亮：`highlight`、`language_for_path`。
  - AI：`test_ai_connection`、`apply_review_suggestion`、`default_ai_base_url`、`default_sensitive_patterns`、`is_sensitive_path`。
  - 其他：`console_entries`、`clear_console`、`stash_revisions`、`default_changelist_name`、`core_version`。
- 错误统一为 `GitError` 枚举（`src/error.rs`）。UI 根据枚举变体映射本地化文案，mac 端的映射在 `apps/mac/Sources/GitDeck/Common/L10n.swift`。
- UniFFI 不导出 Rust 常量，需要时改为导出函数（如 `default_changelist_name()`）。

## 4. Windows 开发环境

| 工具 | 说明 |
|------|------|
| Windows 10/11 | x64 或 arm64 机器均可；另一种架构靠交叉编译，验证方式待定（见第 6 节） |
| Git for Windows 2.30+ | 核心依赖系统 git；同时提供 Git Credential Manager 与 OpenSSH |
| Rust stable（rustup，MSVC 工具链） | `rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc` |
| Visual Studio 2022（或 Build Tools） | 工作负载：“使用 C++ 的桌面开发”（含 MSVC x64/ARM64 编译器与 Windows SDK）和 “.NET 桌面开发”；WinUI 3 需要 Windows App SDK |
| .NET SDK 8 或更新 | 具体版本开工时确定（建议当前 LTS） |

先确认：

```powershell
git --version
cargo --version
dotnet --info
```

## 5. 第一步：在 Windows 上跑通 Rust 核心

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets
cargo test --workspace
```

在 mac 上这三步全部通过（164 个测试，clippy 0 警告）。Windows 上预计会遇到下面这些问题，修复时**不要破坏 mac 行为**，修完后在 mac 上也要能通过（可让用户在 mac 上跑）：

| 风险点 | 位置 | 说明 |
|--------|------|------|
| 换行符 | 全局 | Git for Windows 安装时通常设置系统级 `core.autocrlf=true`。测试辅助函数 `tests/common/mod.rs` 的 `git()` 会忽略系统配置，但核心的 `GitRunner` 不会，因此测试里通过核心 API 执行的 git 可能产生 CRLF。diff、部分提交（`diff.rs` 的 `partial_text`）、shelf 与 patch 应用都对行尾敏感 |
| `/dev/null` | `tests/common/mod.rs` | `GIT_CONFIG_GLOBAL=/dev/null`，Git for Windows 一般能识别；若不能，改为按平台使用 `NUL` 或一个临时空文件 |
| 文件权限位 | `src/commit.rs:227` | 部分提交时用 `#[cfg(unix)]` 读取可执行位；Windows 上（`core.filemode=false`）应改为沿用索引或 HEAD 中的模式 |
| hook 脚本 | `tests/commit.rs:219` | 提交前 hook 测试用 `#!/bin/sh`，Git for Windows 会用自带的 sh 执行，应该可行，需确认 |
| 路径分隔符 | `workspace.rs`、`ai/filter.rs`、`ai/tools.rs`、`changes.rs`、`shelf.rs` | git 输出的相对路径都用 `/`；凡是把文件系统路径转成字符串再比较、拼接或做前缀判断的地方，在 Windows 上会遇到 `\`。AI 工具的路径穿越 / 符号链接防护尤其要重新验证 |
| 长路径 | 全局 | 超过 260 字符的路径需要 `core.longpaths=true` 和应用清单中的 longPathAware |
| git 查找 | `src/repo.rs:51`、`src/git/runner.rs:329` | 已有 Windows 分支：`C:\Program Files\Git\cmd\git.exe` 等候选路径，以及安装包内置的 `<exe 目录>\mingit\cmd\git.exe`；未实测 |
| 子进程窗口 | `src/git/runner.rs:320` | 已设置 `CREATE_NO_WINDOW`；未实测 |
| TLS | `Cargo.toml` | ureq 使用 `native-tls-no-default` + 平台证书验证，Windows 上走 SChannel；未实测 |

修复完成后，建议加上 GitHub Actions：在 Windows x64 runner 上跑 `cargo test`，并交叉编译 `aarch64-pc-windows-msvc`。这一步和用户确认后再加。

## 6. 开工前需要逐个和用户确认的决策

按顺序一次问一个。每项都给出了建议，最终以用户的决定为准，决定后写入 `docs/DECISIONS.md`。

1. **C# 绑定的生成方式与 MPL-2.0 许可**（最先确认，影响整个架构）
   - 事实：UniFFI 官方不支持 C#。社区方案 `uniffi-bindgen-cs`（NordSecurity）采用 **MPL-2.0** 许可，而且对 UniFFI 版本有严格对应关系，需要先查它是否支持 0.32。
   - 另外，UniFFI 本身也是 MPL-2.0，mac 端已经在用。这与“只用宽松许可”的字面要求冲突，详见 [MAC-REMAINING.md](MAC-REMAINING.md) 第 2 节。
   - 选项：
     - (a) 接受 MPL-2.0（不修改其源文件即可用于闭源商用），使用 `uniffi-bindgen-cs`。如版本不匹配，就调整 UniFFI 版本或等待其更新。
     - (b) 为 Windows 手写一层 C ABI，再在 C# 中用 P/Invoke 调用。数据结构可以用 JSON 传递以降低工作量。
     - (c) 其他方案。
   - 建议：(a)，前提是用户接受 MPL-2.0，并且版本兼容性验证通过。
2. **构建与验证方式**：在这台 Windows 机器上本地开发和验证，另一种 CPU 架构交给 GitHub Actions 编译（无法运行 UI）。还要确定 Claude 如何做 UI 验证，例如加入与 mac 相同的 `-debug.action` / `-debug.snapshot` 启动参数，把窗口渲染成 PNG 后检查。
3. **编辑器组件**：决策第 3 项定为 WinUIEdit（Scintilla）。开工前核实它当前的许可证（WinUIEdit 为 MIT，Scintilla 使用自有的宽松许可）、对 arm64 的支持、维护状态，以及能否自绘 gutter 装饰（变更标记、AI 评审标记、合并装饰）。如不合适，替代方案是基于 `RichEditBox` / Win2D 自建。
4. **打包与 askpass**：
   - 决策中的默认是 MSIX（x64 与 arm64 两个包）。但 MSIX 安装目录中的 exe 不便被 git 直接按路径调用，而 askpass 依赖 git 调用客户端程序。建议同时提供一个很小的控制台程序 `GitDeck.AskPass.exe`，由它弹出输入框（或通过命名管道请求主程序弹框），把结果写到标准输出。
   - HTTPS 认证在 Windows 上通常由 Git Credential Manager 自己弹框处理，askpass 主要用于 SSH 口令和主机指纹确认。
   - MinGit 是 **GPL-2.0**。作为独立程序随安装包分发，属于聚合分发，通常可以接受，但需要附上它的许可证和源码获取方式。这一点需要用户确认，否则就只依赖用户自行安装的 Git for Windows。
5. **.NET 与 Windows App SDK 版本、最低 Windows 版本**（Win10 1809 / 19041 等）：可以给出推荐后让用户确认。

## 7. 建议的目录与工程结构（可在确认第 6 节后调整）

```
apps/windows/
  GitDeck.sln
  GitDeck/                 WinUI 3 应用（C#）
  GitDeck.Core/            生成的 C# 绑定 + 原生库加载（每种架构一份 gitdeck_core.dll）
  GitDeck.AskPass/         askpass 控制台程序（如第 6 节第 4 项采用）
  Strings/en-US/Resources.resw、Strings/zh-Hans/Resources.resw
scripts/build-core-win.ps1    编译核心（x64 / arm64）、生成 C# 绑定、复制 DLL
scripts/build-win-app.ps1     构建与打包
scripts/xcstrings-to-resw.*   由 Localizable.xcstrings 生成 .resw（保持单一文案来源）
```

- Rust 核心在 Windows 上建议以 `cdylib`（`gitdeck_core.dll`）方式供 C# 加载。`Cargo.toml` 中已经声明了 `cdylib`。
- 文案：以 mac 的 `Localizable.xcstrings` 为唯一来源，用脚本转换成 `.resw`，避免两端文案分叉。键名沿用 mac 端，例如 `log.menu.*`、`commit.*`。

## 8. mac 组件 → Windows 对应

| 能力 | mac 实现（参考代码） | Windows 建议 |
|------|----------------------|--------------|
| 主窗口、工具栏、工具窗口条 | `Project/ProjectWindowController.swift`、`MainToolbarView.swift`、`ToolWindowStripe.swift` | WinUI 3 自定义标题栏（IDEA New UI 在 Windows 上把主菜单放进汉堡按钮）+ 左右图标条 |
| 欢迎页、最近项目、克隆 | `Welcome/` | 同结构 |
| 文件树、编辑器、查找替换 | `ToolWindows/ProjectToolWindow.swift`、`Editor/` | TreeView + 编辑器组件（第 6 节第 3 项） |
| 提交窗口、Changelist、部分提交 | `ToolWindows/CommitToolWindow.swift`、`Diff/LineSelectionStore.swift` | TreeView 加复选框 |
| Diff（并排 / 统一） | `Diff/DiffView.swift` | 同一个编辑器组件的两种布局 |
| Log 提交图 | `Log/LogView.swift`、`LogRowViews.swift` | 虚拟化列表 + Win2D 或自绘图形列；图形布局由核心 `graph.rs` 计算 |
| 分支弹窗 | `VCS/BranchesPopover.swift`、`RepositoryBranchesPopover.swift` | Flyout / Popup |
| 冲突与三栏合并 | `Merge/` | 同结构 |
| Stash / Shelf / Worktrees / Console | `ToolWindows/` | 同结构 |
| AI 评审 | `AI/` | 同结构；API Key 存 Windows 凭据管理器（`CredWrite` / `CredRead`，或 `Windows.Security.Credentials.PasswordVault`） |
| 设置窗口 | `Settings/` | 设置页或对话框；数据存 `%LOCALAPPDATA%\GitDeck\`（调试版单独目录） |
| 多仓库项目 | `Project/Workspace.swift`、`WorkspaceBanner.swift`、`RepositoriesDialog.swift` | 同结构 |
| 文件监视 | `Project/FileWatcher.swift`（FSEvents） | `FileSystemWatcher`，需要去抖动，并忽略 `.git` 内部的噪声 |
| askpass | `App/AskPass.swift`、`App/main.swift` | 见第 6 节第 4 项 |
| 语言切换 | `Settings/GeneralSettingsPane.swift`（重启生效） | `ApplicationLanguages.PrimaryLanguageOverride`，重启生效 |
| 主题 | `Common/Theme.swift`、`AppearanceSetting.swift` | WinUI 浅色 / 深色主题资源；颜色值沿用 `Theme.swift` |
| 调试钩子 | `-debug.*` 启动参数（如 `-debug.action`、`-debug.snapshot`，见 `ProjectWindowController.swift`） | 同名命令行参数，用于自动化截图验证 |

**行为细节以 mac 代码为准**，包括菜单项、快捷键、对话框选项和提示文案。mac 端的实现已经按 IDEA 的交互逐项对齐过；Windows 端只在平台惯例不同的地方调整，例如 Ctrl 替代 Cmd、按钮顺序为“确定 / 取消”。

## 9. 建议的分批顺序

每批完成后问用户是否提交、推送。

1. **W0**：核心在 Windows 上测试全过 + C# 绑定打通（一个最小控制台程序，能打开仓库并列出状态）。
2. **W1**：应用骨架，包括欢迎页、打开 / 克隆仓库、主窗口框架（工具栏、工具窗口条、状态栏）、主题、本地化。
3. **W2**：Project 文件树与编辑器（高亮、字体设置、查找替换、变更标记）。
4. **W3**：提交窗口（变更列表、Changelist、部分提交、Amend、提交前检查）与 Diff 查看器。
5. **W4**：Log（提交图、筛选、详情）、分支弹窗与分支操作、Fetch / Pull / Update / Push、askpass。
6. **W5**：冲突解决与三栏合并、Annotate、File History、Stash、Shelve。
7. **W6**：二期功能，包括交互式 Rebase、Cherry-pick、Revert、Reset、Tags、Remotes、Worktrees、Submodules、Patch、Console。
8. **W7**：AI 评审与设置窗口。
9. **W8**：多仓库项目。
10. **W9**：打包（MSIX x64 / arm64）、签名（需要证书，与用户确认）。

## 10. 每批提交前的检查清单

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets
cargo test --workspace
```

- 构建 Windows 应用（x64 与 arm64），C# 侧不能有新增警告。
- 核心改动会影响 mac 端时（例如修改了导出的 API），提醒用户在 mac 上重新运行 `scripts/build-core-mac.sh` 和 `scripts/build-mac-app.sh`，确认 mac 仍可编译。
- 新增文案同时加入 mac 的 `Localizable.xcstrings`（en 与 zh-Hans），再转换成 `.resw`。
