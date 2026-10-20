# 构建 Rust 核心并为 Windows 端生成 C# 绑定。
#
# 产物（均已加入 .gitignore）：
#   apps/windows/GitDeck.Core/Generated/gitdeck_core.cs   uniffi-bindgen-cs 生成的 C# API
#   apps/windows/GitDeck.Core/Native/win-x64/gitdeck_core.dll   核心动态库
#
# 用法：scripts/build-core-win.ps1 [debug|release]（默认 debug）
param(
    [ValidateSet('debug', 'release')]
    [string]$Config = 'debug'
)
$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Target = 'x86_64-pc-windows-msvc'   # 目前只提供 x64（见 docs/DECISIONS.md 第 13 项）
$CoreProject = Join-Path $Root 'apps/windows/GitDeck.Core'
$Tools = Join-Path $Root 'build/tools'

# uniffi-bindgen-cs 必须与 Cargo.toml 中的 UniFFI 版本对应（见 docs/DECISIONS.md 第 12 项）。
$BindgenTag = 'v0.11.1+v0.31.0'
$Bindgen = Join-Path $Tools 'bin/uniffi-bindgen-cs.exe'

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe 失败（退出码 $LASTEXITCODE）" }
}

$installed = if (Test-Path $Bindgen) { (& $Bindgen --version) -join '' } else { '' }
if ($installed -notlike "*$($BindgenTag.TrimStart('v'))*") {
    Write-Host "==> 安装 uniffi-bindgen-cs $BindgenTag"
    Invoke-Checked cargo @('install', '--git', 'https://github.com/NordSecurity/uniffi-bindgen-cs',
        '--tag', $BindgenTag, 'uniffi-bindgen-cs', '--root', $Tools, '--locked', '--force')
}

Write-Host "==> cargo build ($Config, $Target)"
$cargoArgs = @('build', '--manifest-path', (Join-Path $Root 'Cargo.toml'), '--target', $Target, '-p', 'gitdeck-core')
if ($Config -eq 'release') { $cargoArgs += '--release' }
Invoke-Checked cargo $cargoArgs
$Dll = Join-Path $Root "target/$Target/$Config/gitdeck_core.dll"

Write-Host '==> 生成 C# 绑定'
$Generated = Join-Path $CoreProject 'Generated'
if (Test-Path $Generated) { Remove-Item -Recurse -Force $Generated }
New-Item -ItemType Directory -Force $Generated | Out-Null
Invoke-Checked $Bindgen @('--library', $Dll, '--no-format',
    '--config', (Join-Path $Root 'core/gitdeck-core/uniffi.toml'), '--out-dir', $Generated)

$Native = Join-Path $CoreProject 'Native/win-x64'
New-Item -ItemType Directory -Force $Native | Out-Null
Copy-Item $Dll $Native -Force
$Pdb = [IO.Path]::ChangeExtension($Dll, '.pdb')
if (Test-Path $Pdb) { Copy-Item $Pdb $Native -Force }

Write-Host "==> 完成：$CoreProject"
