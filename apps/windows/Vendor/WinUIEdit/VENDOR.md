# WinUIEdit（vendored）

Windows 端编辑器组件（见 docs/DECISIONS.md 第 14 项）。

- 上游：https://github.com/BreeceW/WinUIEdit
- 版本：提交 `d9f60dbca65c2af54ced590d873d9438de32ce77`（2026-07-03，NuGet 0.0.5-prerelease）
- 许可：WinUIEdit 见 `LICENSE`；Scintilla 见 `scintilla/License.txt`；Lexilla 见 `lexilla/License.txt`（均为宽松许可，保留版权声明即可）

只保留编译 WinUI 3 版本所需的部分：`WinUIEditor/`、`scintilla/`（include、src、winui）、`lexilla/`（include、lexlib、lexers、src）
和构建用的 props 文件；示例工程、UWP 相关文件、测试与文档未复制。

相对上游的改动：

1. `UseWinUI3.txt` 设为 `true`（只编译 WinUI 3 版本）。
2. `WinUIEditor/packages.config` 中 C++/WinRT 的版本改为 `2.0.240405.15`，与 `WinUIEditor.vcxproj` 中引用的版本一致
   （上游最近一次提交只回退了 vcxproj 中的版本）。

编译：`scripts/build-editor-win.ps1`（产物在 `_buildWinUI3/`，NuGet 包在 `packages/`，均不提交）。
