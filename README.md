# GitDeck（代号）

对齐 JetBrains IDEA Git 功能的跨平台原生 Git 客户端。架构与产品决策见 [docs/DECISIONS.md](docs/DECISIONS.md)。

## 目录结构

```
core/gitdeck-core/     Rust 共享核心：git CLI 调用与解析（UniFFI 导出给 Swift / C#）
core/uniffi-bindgen/   绑定生成工具
apps/mac/              macOS 客户端（Swift + AppKit，SwiftPM 包）
scripts/               构建脚本
product.env            产品名与 Bundle ID（发布前统一替换）
deny.toml              依赖许可证白名单（cargo-deny）
```

## 环境要求（macOS 开发）

- Apple Silicon Mac，macOS 15+
- Xcode（脚本默认使用 `/Applications/Xcode-beta.app`，可通过 `DEVELOPER_DIR` 覆盖）
- Rust stable（`rustup`），目标 `aarch64-apple-darwin`
- Git 2.30+

## 构建与运行

```bash
scripts/build-mac-app.sh
```

```bash
open build/debug/GitDeck.app
```

发布构建：`scripts/build-mac-app.sh release`。

## 测试

```bash
cargo test --workspace
```

## 开发约定

- 所有 git 操作在 Rust 核心中实现，UI 层只负责展示与交互。
- 界面文案全部放在 `apps/mac/Sources/GitDeck/Resources/Localizable.xcstrings`（en / zh-Hans），中文术语对齐 IDEA 官方中文语言包。
- 只引入 MIT / Apache-2.0 / BSD 等宽松许可的依赖。
