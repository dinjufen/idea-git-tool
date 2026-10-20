# 生成 Windows 安装程序（见 docs/DECISIONS.md 第 15 项）：自包含发布 + Inno Setup，按用户安装到
# %LOCALAPPDATA%\Programs\GitDeck，无需管理员权限。
#
# 产物（均在 /build 下，已加入 .gitignore）：
#   build/windows/publish/        自包含发布目录（主程序 + askpass + 核心库）
#   build/windows/GitDeck-<版本>-x64-setup.exe   安装程序
#
# 用法：scripts/package-win.ps1 [-Config Release|Debug] [-SkipCore]
#   -Config Debug  生成调试版安装程序（数据目录为 GitDeck.debug，可在开发机上试装而不影响正式版）
#   -SkipCore      跳过 Rust 核心的构建（已用 build-core-win.ps1 构建过同一配置时）
#
# 需要 Inno Setup 6（ISCC.exe）：默认在 %LOCALAPPDATA%\Programs\Inno Setup 6 或 Program Files 下查找，
# 也可以用环境变量 ISCC 指定。
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Config = 'Release',
    [switch]$SkipCore
)
$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Apps = Join-Path $Root 'apps/windows'
$Out = Join-Path $Root 'build/windows'
$Publish = Join-Path $Out 'publish'
$AskPassPublish = Join-Path $Out 'askpass'

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe 失败（退出码 $LASTEXITCODE）" }
}

# 版本号与 mac 端一致，取自 Cargo.toml。
$Version = (Select-String -Path (Join-Path $Root 'Cargo.toml') -Pattern '^version\s*=\s*"(.+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
Write-Host "==> GitDeck $Version ($Config)"

$Iscc = if ($env:ISCC) { $env:ISCC } else {
    @(
        (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Iscc) { throw '找不到 Inno Setup 6 的 ISCC.exe（可用环境变量 ISCC 指定）' }

if (-not $SkipCore) {
    Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'build-core-win.ps1'), $Config.ToLowerInvariant())
}

foreach ($dir in @($Publish, $AskPassPublish)) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}

Write-Host '==> dotnet publish GitDeck'
Invoke-Checked dotnet @('publish', (Join-Path $Apps 'GitDeck/GitDeck.csproj'), '-c', $Config, '-r', 'win-x64',
    '--self-contained', 'true', "-p:Platform=x64", "-p:Version=$Version", '-o', $Publish)

# 非打包的 WinUI 应用发布时不会带上编译后的 XAML（*.xbf）与资源索引（GitDeck.pri），从构建目录补上。
$BuildDir = Join-Path $Apps "GitDeck/bin/x64/$Config/net10.0-windows10.0.19041.0/win-x64"
Get-ChildItem $BuildDir -Recurse -File -Include '*.xbf', '*.pri' | ForEach-Object {
    $target = Join-Path $Publish ([IO.Path]::GetRelativePath($BuildDir, $_.FullName))
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item $_.FullName $target -Force
}

# askpass 是 WinForms 程序：同样自包含发布，再合并到主程序目录（两者使用同一版本的 .NET 运行时）。
Write-Host '==> dotnet publish GitDeck.AskPass'
Invoke-Checked dotnet @('publish', (Join-Path $Apps 'GitDeck.AskPass/GitDeck.AskPass.csproj'), '-c', $Config, '-r', 'win-x64',
    '--self-contained', 'true', "-p:Version=$Version", '-o', $AskPassPublish)
Get-ChildItem $AskPassPublish -Recurse -File | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($AskPassPublish, $_.FullName)
    $target = Join-Path $Publish $relative
    # 运行时文件两者相同、保留主程序的一份；askpass 自身的文件（含 runtimeconfig）以自包含发布的为准。
    if (-not (Test-Path $target) -or $_.Name -like 'GitDeck.AskPass.*') {
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $_.FullName $target
    }
}
foreach ($required in @('GitDeck.exe', 'GitDeck.AskPass.exe', 'gitdeck_core.dll', 'GitDeck.pri', 'App.xbf')) {
    if (-not (Test-Path (Join-Path $Publish $required))) { throw "发布目录缺少 $required" }
}
# 调试符号不随安装包分发。
Get-ChildItem $Publish -Recurse -Filter *.pdb | Remove-Item -Force

Write-Host '==> Inno Setup'
$Iss = Join-Path $Apps 'Installer/GitDeck.iss'
$defines = @("/DAppVersion=$Version", "/DSourceDir=$Publish", "/DOutputDir=$Out", "/DRepoRoot=$Root")
if ($Config -eq 'Debug') { $defines += '/DDebugBuild' }
Invoke-Checked $Iscc (@('/Q') + $defines + @($Iss))
Get-ChildItem $Out -Filter 'GitDeck-*-setup.exe' | ForEach-Object { Write-Host "    $($_.FullName)" }
