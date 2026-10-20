# GitDeck（代号）

对齐 JetBrains IDEA Git 功能的跨平台原生 Git 客户端。架构与产品决策见 [docs/DECISIONS.md](docs/DECISIONS.md)；mac 端剩余事项见 [docs/MAC-REMAINING.md](docs/MAC-REMAINING.md)；Windows 端开发交接见 [docs/WINDOWS-HANDOFF.md](docs/WINDOWS-HANDOFF.md)。

## 目录结构

```
core/gitdeck-core/     Rust 共享核心：git CLI 调用与解析（UniFFI 导出给 Swift / C#）
apps/windows/          Windows 客户端（C# + WinUI 3，开发中）
core/uniffi-bindgen/   绑定生成工具
apps/mac/              macOS 客户端（Swift + AppKit，SwiftPM 包）
apps/mac/Vendor/       第三方源码的 vendored 副本（各自保留 LICENSE，改动说明见其 Package.swift）
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

## 环境要求（Windows 开发）

- Windows 10 1809+ x64
- Rust stable（MSVC 工具链）、Git for Windows 2.30+、.NET 10 SDK
- Visual Studio 2022 或更新版本（“使用 C++ 的桌面开发”与“.NET 桌面开发”）

## 构建与运行（Windows）

```powershell
scripts/build-core-win.ps1
dotnet build apps/windows/GitDeck.sln
dotnet run --project apps/windows/GitDeck.CoreSmoke -- <仓库路径>
```

`build-core-win.ps1` 编译核心并用 `uniffi-bindgen-cs` 生成 C# 绑定（首次运行会把它安装到 `build/tools`）。

## 测试

```bash
cargo test --workspace
```

## 开发约定

- 所有 git 操作在 Rust 核心中实现，UI 层只负责展示与交互。
- 界面文案全部放在 `apps/mac/Sources/GitDeck/Resources/Localizable.xcstrings`（en / zh-Hans），中文术语对齐 IDEA 官方中文语言包。
- 只引入 MIT / Apache-2.0 / BSD 等宽松许可的依赖。
