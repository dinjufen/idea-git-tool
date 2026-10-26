# mac 端剩余事项

> 更新日期：2026-10-20

一期、二期、三期（AI 评审）的规划功能在 mac 端已全部实现，并补齐了多仓库项目（窗口标签页 + 多根项目）、设置窗口、界面语言切换、界面字体和应用图标。本文记录尚未完成或尚未验证的部分。

2026-10-20：UniFFI 按第 12 项决策降为 0.31.0 后，Swift 绑定已重新生成，并在应用中验证（状态、Log、多仓库、编辑器标记，以及 AI 评审的流式回调接口）。

## 1. 发布准备

| 事项 | 说明 |
|------|------|
| 代码签名与公证 | 需要 Apple Developer ID（证书、Team ID、notarytool 凭据），首次发布前与用户确认。目前 `scripts/build-mac-app.sh` 只做 ad-hoc 签名 |
| 正式名称与 Bundle ID | `product.env` 中的 `GitDeck` / `com.example.gitdeck` 仍是占位 |
| DMG 安装包 | 尚未制作（背景图、Applications 快捷方式、签名后再公证 DMG） |
| Release 构建警告 | `scripts/build-mac-app.sh release` 时出现重复的 `dsymutil` 警告，不影响运行，需查明来源并消除 |
| 图标变体 | 只有 1024 PNG 生成的 `AppIcon.icns`；macOS 26 的深色 / 着色图标需用 Icon Composer 制作 `.icon` |
| 自动更新 | 未规划（如需要，可选 Sparkle，MIT 许可） |

## 2. 许可证合规

- UniFFI（MPL-2.0）已按 DECISIONS 第 12 项作为例外接受，`deny.toml` 中逐个 crate 放行。
- 发布前需要生成第三方许可证清单（Rust 依赖 + vendored CodeEditTextView），放进“关于”窗口或安装包。
- 尚未把 `cargo deny check licenses` 作为固定检查步骤（暂无 CI，见第 13 项）。

## 3. 尚未在真实环境中验证

| 功能 | 现状 |
|------|------|
| AI 评审 / 生成提交信息 | 只用本地模拟服务（SSE mock）测过；需要用户用真实的 Anthropic / OpenAI 兼容 API Key 跑一遍 |
| 需要认证的远程操作 | 克隆私有仓库、askpass 弹框、多仓库 Update / Push 未在真实远程上验证 |
| Changelist 右键菜单 | 新建 / 编辑 / 删除 / 设为活动 / 移动到 等对话框没有逐个手动点过 |
| 大仓库性能 | 未用大型仓库（十万级提交、上万文件变更）做性能测试 |

## 4. 已知限制

- 提交前的 AI 评审只评审**主仓库**中勾选的文件；多仓库项目中其他仓库的变更不在评审范围内。
- 多仓库 Log 选择“所有仓库”时只画提交圆点和仓库颜色条，不画分支线（各仓库的图无法合并成一张）。
- mac 界面层没有自动化 UI 测试；Rust 核心有 165 个集成测试。
- 编辑器的行内提交信息（光标所在行行尾显示最近一次提交，悬停弹出提交详情，设置 > 编辑器中可关闭）目前只在 Windows 端实现，mac 端尚未跟进。核心为此新增了 `Repository.user_email()`，mac 上需要重新运行 `scripts/build-core-mac.sh`。
- 界面字体不作用于系统菜单栏、窗口标题栏与设置窗口的分页按钮（由系统绘制）；修改字号后，已经打开的对话框不会重新调整窗口大小（新打开的会）。

## 5. 可选的打磨

- 细节 UI 打磨（动画、空状态插图、键盘导航的完整性、VoiceOver 标签）。
- 用户试用后反馈的问题。

## 6. 后续分期

- 四期 Windows 端：已完成（W0–W9，x64），见 DECISIONS 第 12–17 项。
- 五期（可选）GitHub / GitLab PR 集成：未开始。
