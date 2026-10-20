# mac 端剩余事项

> 更新日期：2026-10-19 · 对应提交 `ae3edde` 之后

一期、二期、三期（AI 评审）的规划功能在 mac 端已全部实现，并补齐了多仓库项目（窗口标签页 + 多根项目）、设置窗口、界面语言切换和应用图标。本文记录尚未完成或尚未验证的部分。

## 1. 发布准备

| 事项 | 说明 |
|------|------|
| 代码签名与公证 | 需要 Apple Developer ID（证书、Team ID、notarytool 凭据），首次发布前与用户确认。目前 `scripts/build-mac-app.sh` 只做 ad-hoc 签名 |
| 正式名称与 Bundle ID | `product.env` 中的 `GitDeck` / `com.example.gitdeck` 仍是占位 |
| DMG 安装包 | 尚未制作（背景图、Applications 快捷方式、签名后再公证 DMG） |
| Release 构建警告 | `scripts/build-mac-app.sh release` 时出现重复的 `dsymutil` 警告，不影响运行，需查明来源并消除 |
| 图标变体 | 只有 1024 PNG 生成的 `AppIcon.icns`；macOS 26 的深色 / 着色图标需用 Icon Composer 制作 `.icon` |
| 自动更新 | 未规划（如需要，可选 Sparkle，MIT 许可） |

## 2. 许可证合规（需与用户确认）

- **UniFFI 是 MPL-2.0 许可**（`uniffi`、`uniffi_core`、`uniffi_macros` 等 0.32.2），与第 9 项决策“只用宽松许可”的字面要求冲突。`deny.toml` 的白名单中没有 MPL-2.0，但项目从未实际运行过 `cargo deny check`，所以一直没有发现。
  - MPL-2.0 是按文件生效的弱 copyleft：不修改其源文件时，可以静态链接进闭源商用程序，只需在发布物中附上许可证并说明其源码获取方式。
  - 需要用户决定：接受 MPL-2.0（把它加入 `deny.toml` 白名单并在关于页列出），还是改为手写 C ABI 层（工作量大）。
- 发布前需要生成第三方许可证清单（Rust 依赖 + vendored CodeEditTextView），放进“关于”窗口或安装包。
- CI 中尚未接入 `cargo deny check licenses`。

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
- mac 界面层没有自动化 UI 测试；Rust 核心有 164 个集成测试。

## 5. 可选的打磨

- 界面字体设置（IDEA 的 外观 > 使用自定义字体）：Windows 端已在 设置 > 通用 中实现，mac 端尚未实现（方案待用户确认）。

- 细节 UI 打磨（动画、空状态插图、键盘导航的完整性、VoiceOver 标签）。
- 用户试用后反馈的问题。

## 6. 后续分期

- 四期 Windows 端：2026-10-19 开工，交接说明见 [WINDOWS-HANDOFF.md](WINDOWS-HANDOFF.md)。
- 五期（可选）GitHub / GitLab PR 集成：未开始。
