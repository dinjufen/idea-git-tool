# GitDeck (codename)

English | [简体中文](README.zh-CN.md)

A cross-platform native Git client modeled on the Git tooling in JetBrains IDEA. Interaction and layout follow the IDEA New UI, it includes an editor with syntax highlighting, and it can review code with AI. The macOS app is Swift + AppKit, the Windows app is C# + WinUI 3, and all git operations live in a shared Rust core.

![Git Log and the Commit tool window](docs/screenshots/log.png)

## Download

**Windows x64**: download `GitDeck-<version>-x64-setup.exe` from [Releases](https://github.com/dinjufen/idea-git-tool/releases/latest) and run it. It installs per user to `%LOCALAPPDATA%\Programs\GitDeck` and needs no admin rights.

- Requires Windows 10 1809+ and [Git for Windows](https://git-scm.com/download/win) 2.30+. GitDeck does not bundle git; if it can't find one, the welcome screen says so, and you can set the path in Settings.
- The installer is not code-signed yet. If SmartScreen warns, choose "Run anyway".
- Uninstalling removes only the program files. Settings (`%LOCALAPPDATA%\GitDeck`) and API keys in Credential Manager are kept.

**macOS** (Apple Silicon, macOS 15+): no installer yet; build from source as described below.

## Features

| Area | What's included |
|------|-----------------|
| Repositories | Open, clone, init; multi-repository projects (window tabs and multi-root projects) |
| Commit | Commit tool window, changelists, partial commits by hunk or line, amend, pre-commit checks |
| Browse | Side-by-side and unified diff, Git Log graph (filter by branch, author, date, path), commit details, Annotate (blame), file history |
| Branches and sync | Branches popup (checkout, new, delete, rename, merge, rebase, compare), fetch, pull, Update Project, push |
| Conflicts | Conflicts dialog and three-way merge (apply non-conflicting changes, accept per hunk, undo) |
| Advanced | Interactive rebase, cherry-pick, revert, reset, undo commit, stash, shelve, tags, remotes, worktrees, submodules, patches, Git console |
| Editor | tree-sitter syntax highlighting, find and replace, change markers; UI font and editor font are set separately |
| AI | Review local changes, existing commits or branch differences, and generate commit messages; Anthropic and OpenAI-compatible APIs (including local Ollama / LM Studio), read-only agent, sensitive files excluded by default |
| Other | English and Simplified Chinese UI (Chinese terms follow IDEA's official language pack), light and dark themes |

## Screenshots

The screenshots below are from the Windows app with the Chinese UI.

**Side-by-side diff**: review local changes from the Commit tool window and choose which hunks to commit.

![Side-by-side diff](docs/screenshots/diff.png)

**Three-way merge**: changes from each side on the left and right, the merge result in the middle.

![Three-way merge](docs/screenshots/merge.png)

**Annotate**: the gutter shows the commit and author that last changed each line.

![Annotate](docs/screenshots/annotate.png)

**Dark theme**

![Dark theme](docs/screenshots/dark.png)

## Repository layout

```
core/gitdeck-core/     Shared Rust core: git CLI calls and parsing, AI review (exported to Swift / C# via UniFFI)
core/uniffi-bindgen/   Binding generator
apps/mac/              macOS client (Swift + AppKit, SwiftPM package)
apps/mac/Vendor/       Vendored third-party sources (each keeps its LICENSE; changes noted in its Package.swift)
apps/windows/          Windows client (C# + WinUI 3) and installer script
apps/windows/Vendor/   Vendored source of the Windows editor component, WinUIEdit
scripts/               Build and packaging scripts
docs/                  Decision log, handoff notes and screenshots
product.env            Product name and bundle ID (to be replaced before release)
deny.toml              Dependency license allowlist (cargo-deny)
```

Architecture and product decisions are in [docs/DECISIONS.md](docs/DECISIONS.md), remaining macOS work in [docs/MAC-REMAINING.md](docs/MAC-REMAINING.md), and Windows development notes in [docs/WINDOWS-HANDOFF.md](docs/WINDOWS-HANDOFF.md). These documents are in Chinese.

## Building from source (macOS)

Requirements: Apple Silicon Mac with macOS 15+; Xcode (the scripts use `/Applications/Xcode-beta.app` by default, override with `DEVELOPER_DIR`); Rust stable with the `aarch64-apple-darwin` target; Git 2.30+.

```bash
scripts/build-mac-app.sh
```

```bash
open build/debug/GitDeck.app
```

Release build: `scripts/build-mac-app.sh release`.

## Building from source (Windows)

Requirements: Windows 10 1809+ x64; Rust stable (MSVC toolchain), Git for Windows 2.30+, .NET 10 SDK; Visual Studio 2022 or later with the "Desktop development with C++" and ".NET desktop development" workloads.

```powershell
scripts/build-core-win.ps1
dotnet build apps/windows/GitDeck.sln
```

`build-core-win.ps1` builds the core and generates C# bindings with `uniffi-bindgen-cs` (installed into `build/tools` on first run).

To build the installer (requires Inno Setup 6):

```powershell
scripts/package-win.ps1
```

The output is `build/windows/GitDeck-<version>-x64-setup.exe`. `-Config Debug` builds a debug installer that can be installed alongside the release build.

## Tests

```bash
cargo test --workspace
```

## Conventions

- All git operations are implemented in the Rust core; the UI layers only present and interact.
- All UI strings live in `apps/mac/Sources/GitDeck/Resources/Localizable.xcstrings` (en / zh-Hans), which the Windows app reads directly. Chinese terms follow IDEA's official Chinese language pack.
- Only permissively licensed dependencies (MIT / Apache-2.0 / BSD). The MPL-2.0 exception for UniFFI is decision 12 in the decision log.
