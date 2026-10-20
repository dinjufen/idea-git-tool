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
| 3 | 编辑器 | **原生组件 + tree-sitter** | mac：CodeEditTextView（见第 11 项）；Win：WinUIEdit（Scintilla）；高亮 token 由 Rust 核心中的 tree-sitter 统一计算 |
| 4 | Git 后端 | **系统 git CLI**（与 IDEA 一致），最低 git 2.30 | Windows 优先使用用户安装的 Git for Windows，缺失时回退到安装包内置的 MinGit |
| 5 | 平台顺序 | **mac 先行，Windows 后跟** | Rust 核心从一开始就在 CI 上跑 Windows 测试 |
| 6 | 分期 | 见下文「分期」 | |
| 7 | UI 基准 | **IDEA New UI** | 主工具栏 + VCS 分支组件 + 图标条工具窗口 |
| 8 | 语言 | **简体中文 + 英文** | 跟随系统、可手动切换；中文术语对齐 IDEA 官方中文语言包；mac 用 `.xcstrings`，Win 用 `.resw`，核心返回错误码 + 文案键 |
| 9 | 许可 | **闭源 / 商用** | 只使用 MIT / Apache-2.0 / BSD 等宽松许可依赖，CI 加许可证扫描；禁止 GPL/AGPL（例如 STTextView） |
| 10 | 命名 | 代号 GitDeck | 名称集中配置；名称中不使用 "IDEA" / "JetBrains" 商标 |
| 11 | mac 编辑器组件 | **CodeEditTextView + 自建**（2026-10-17 细化第 3 项） | 只使用其底层文本视图（排版、输入法、选区、大文件）；行号 gutter、变更标记、高亮（Rust tree-sitter）、Diff/合并装饰全部自建；编辑器、Diff 视图、三栏合并复用同一组件；以 vendored 副本形式放在 `apps/mac/Vendor/CodeEditTextView`（源码未改，仅去掉上游的 SwiftLint 构建插件） |
| 12 | C# 绑定与 MPL-2.0（2026-10-19，四期开工前） | **接受 MPL-2.0，使用 `uniffi-bindgen-cs` 生成 C# 绑定**；UniFFI 由 0.32 降为 **0.31.0**（`uniffi-bindgen-cs` v0.11.x 对应的版本） | UniFFI 与 `uniffi-bindgen-cs` 均为 MPL-2.0：只使用、不修改其源文件，闭源商用可接受，生成的绑定代码不受其约束；这是第 9 项“只用宽松许可”的明确例外（`deny.toml` 中的 MPL-2.0 同理）。今后升级 UniFFI 需等 `uniffi-bindgen-cs` 发布对应版本；降级后 mac 端需重新生成 Swift 绑定并构建验证 |
| 13 | Windows 构建与验证（2026-10-19） | **只在用户的 Windows x64 机器上本地开发与验证；暂不提供 arm64，暂不加 CI** | 修改第 5 项“CI 上跑 Windows 测试”与第 3 条目标中的 Windows arm64：先只发 x64，arm64 以后需要时再加（本机需加装 MSVC ARM64 生成工具）。UI 验证沿用 mac 的 `-debug.action` / `-debug.snapshot` 启动参数渲染 PNG，必要时直接截屏 |
| 14 | Windows 编辑器组件（2026-10-19 细化第 3 项） | **WinUIEdit（Scintilla 的 WinUI 3 移植）+ 自建，源码 vendored 到 `apps/windows/Vendor/WinUIEdit` 自行编译** | 许可与 Scintilla 同类（宽松，保留版权声明）；上游仍为预发布、单人维护，持有源码以便自行修复。高亮用 Rust tree-sitter 的 token 直接写入样式（不用其自带 lexer）；变更 / AI 评审标记用 margin 标记，Diff / 合并装饰用 indicator 与整行背景，Diff 对齐空白行用 annotation。备选方案（已评估未采用）：Monaco + WebView2（非原生、开销大）、WPF + AvalonEdit（需放弃 WinUI 3） |
| 15 | Windows 打包与 askpass（2026-10-19） | **先做非打包、自包含发布 + 普通安装程序（Inno Setup），有代码签名证书后再加 MSIX** | 安装到 `%LOCALAPPDATA%\Programs\GitDeck`，无需管理员权限；无证书时只有 SmartScreen 提示。askpass 用独立控制台程序 `GitDeck.AskPass.exe`：git 按路径调用，它经命名管道请主程序弹框并把结果写回标准输出；HTTPS 认证优先交给 Git Credential Manager。修改“技术默认”中的 MSIX 打包 |
| 16 | Windows 上的 git（2026-10-20，修改第 4 项） | **不内置 MinGit，只使用用户安装的 Git for Windows** | 找不到 git 时欢迎页提示并给出下载链接，设置中可手动指定 git 路径；避免随包分发 GPL-2.0 程序及其合规材料。以后需要时再考虑内置 |
| 17 | Windows 运行环境（2026-10-20） | **.NET 10 LTS + Windows App SDK 2.5.x，最低 Windows 10 1809（build 17763）** | 与 Windows App SDK、WinUIEdit 的最低版本一致；Windows 11 上使用 Mica 背景，Windows 10 自动退回普通背景 |

### 由以上决策推导出的技术默认

- **mac UI 框架**：以 AppKit 为主（`NSOutlineView` / `NSTableView` 承载变更树、Log 图等大数据量视图），简单对话框和设置页用 SwiftUI。
- **Win UI 框架**：WinUI 3 + Windows App SDK；打包方式见第 15 项，架构见第 13 项。
- **构建**：Rust 核心编译为静态库（mac：`aarch64-apple-darwin`；Win：`x86_64-pc-windows-msvc` 与 `aarch64-pc-windows-msvc`）。
- **远程认证**：与 IDEA 内置 askpass 相同的思路——客户端把自身可执行文件设为 `GIT_ASKPASS` / `SSH_ASKPASS`（并设 `SSH_ASKPASS_REQUIRE=force`），被 git 调用时只弹出原生输入框并把输入写回 git，不保存凭据；系统已配置的 credential helper（如 macOS 钥匙串）仍优先生效。
- **Windows 文案**：不另做 `.resw`，Windows 端直接把 mac 的 `Localizable.xcstrings` 作为嵌入资源读取（单一来源）；Windows 上说法不同的条目以 `<键名>.win` 加入同一文件，用 `scripts/l10n-add.py` 添加。语言切换重启生效。
- **Windows 设置与数据**：`%LOCALAPPDATA%\GitDeck\settings.json`（调试版为 `GitDeck.debug`，与正式版隔离）。AI 服务的 API Key 存在 Windows 凭据管理器，目标名为 `GitDeck.ai/<服务>`（调试版为 `GitDeck.debug.ai/<服务>`）。
- **界面字体**（待用户确认方案）：Windows 端已在 设置 > 通用 中实现 “使用自定义字体”（字体 + 字号，默认跟随系统，修改立即生效），作用于界面文字，编辑器字体单独设置；mac 端尚未实现，见 MAC-REMAINING.md。
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

### 三期：AI 评审（2026-10-18 已与用户逐项确认）

| # | 议题 | 决定 |
|---|------|------|
| 1 | 模型厂商 | **Anthropic Messages API + OpenAI 兼容协议**。Claude 默认 `claude-opus-5-5`，可选 `claude-sonnet-5-5`；OpenAI 兼容协议覆盖 OpenAI、DeepSeek、通义千问、Kimi、智谱及本地 Ollama / LM Studio（自定义 Base URL 与模型名）。Gemini 原生 / Azure 以后按需添加 |
| 2 | 评审场景 | **提交前评审本地变更**（提交窗口按钮，可作为提交前检查）、**评审已有提交**（Log 右键）、**分支对比评审**（当前分支相对目标分支）；另加 **AI 生成提交信息**（提交窗口一键生成） |
| 3 | Agent 能力 | **只读 Agent**：读文件、搜索代码、查看历史版本 / log / blame、列目录、读取评审规则；有轮数与 token 上限；不支持工具调用的模型自动降级为单次调用（diff + 改动文件全文） |
| 4 | 结果展示 | 右侧 **AI 评审工具窗口**（按文件分组、严重程度、文件:行号、点击跳转）+ **编辑器内标记** + **实时进度、可取消** + **一键应用修改建议**（先 Diff 预览，用户确认后写入；写入由用户触发，不是 Agent 自行修改） |
| 5 | 隐私与密钥 | API Key 存**系统钥匙串**（macOS 钥匙串 / Windows 凭据管理器）；**每个项目首次使用时确认**发送对象与内容（本地模型免确认）；**默认排除敏感文件**（`.env`、`*.pem`、`*.key`、`id_rsa*`、`secrets/` 等，可自定义），Agent 工具同样不可读取；支持项目级评审规则文件 `.gitdeck/ai-review.md` |

技术默认（实现时细化）：模型调用、Agent 循环、工具执行、敏感文件过滤都放在 Rust 核心，经流式（SSE）接口把进度与结果推给 UI；Claude 请求使用自适应思考与流式输出，评审默认 effort 设为 `high`（Opus 5.5 的默认值是 `medium`，需显式设置）。

### 四期：Windows 端
- 复用 Rust 核心，实现 WinUI 3 UI 层
- 构建与验证环境待定：由用户提供 Windows 机器（SSH）或使用 GitHub Actions Windows runner
- 2026-10-18：用户决定**暂缓 Windows**，先补齐并打磨 mac 端；开工前再确定构建与验证环境
- 2026-10-19：mac 端功能开发基本完成（剩余事项见 [MAC-REMAINING.md](MAC-REMAINING.md)），**开始 Windows 端**，在用户的 Windows 机器上开发；交接说明见 [WINDOWS-HANDOFF.md](WINDOWS-HANDOFF.md)

### 五期（可选）：GitHub / GitLab PR 集成
- PR 列表、在客户端内评审、评论、合并

## 待讨论（到对应阶段再定）

- 代码签名与公证：Apple Developer ID、Windows 代码签名证书（首次打包发布前）
