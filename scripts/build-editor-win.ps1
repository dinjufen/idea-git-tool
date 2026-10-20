# 从 vendored 源码编译 Windows 端编辑器组件 WinUIEdit（C++ / WinRT 组件）。
#
# 产物：apps/windows/Vendor/WinUIEdit/_buildWinUI3/x64/<配置>/WinUIEditor/bin/WinUIEditor/
#   WinUIEditor.dll、WinUIEditor.winmd、WinUIEditor.pri
# 需要 Visual Studio 2022 或更新版本（“使用 C++ 的桌面开发”工作负载）。
#
# 用法：scripts/build-editor-win.ps1 [Release|Debug]（默认 Release；编辑器组件一般不需要调试版）
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Config = 'Release'
)
$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Vendor = Join-Path $Root 'apps/windows/Vendor/WinUIEdit'
$Project = Join-Path $Vendor 'WinUIEditor/WinUIEditor.vcxproj'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$MSBuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild/**/Bin/MSBuild.exe' | Select-Object -First 1
if (-not $MSBuild) { throw '未找到 MSBuild，请安装 Visual Studio（使用 C++ 的桌面开发）' }

# 上游工程固定为 v143 工具集与 Windows SDK 10.0.22621；这里改用本机已安装的最新版本，不修改 vendored 工程。
$vcRoot = Split-Path (Split-Path (Split-Path $MSBuild))
$Toolset = Get-ChildItem (Join-Path $vcRoot 'Microsoft/VC/*/Platforms/x64/PlatformToolsets') -Directory |
    Where-Object Name -Match '^v\d+$' | Sort-Object Name | Select-Object -Last 1 -ExpandProperty Name
$SdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/Include'
$Sdk = Get-ChildItem $SdkRoot -Directory | Where-Object Name -Match '^10\.' | Sort-Object { [version]$_.Name } | Select-Object -Last 1 -ExpandProperty Name
if (-not $Sdk) { throw '未找到 Windows 10/11 SDK，请在 Visual Studio Installer 中安装' }

# SolutionDir 决定 packages/ 与 _buildWinUI3/ 的位置（vcxproj 中按 ..\packages 引用）。
$common = @($Project, "-p:SolutionDir=$Vendor\", "-p:PlatformToolset=$Toolset", "-p:WindowsTargetPlatformVersion=$Sdk", '-nologo', '-v:m')

Write-Host '==> 还原 NuGet 包'
& $MSBuild @common -t:restore -p:RestorePackagesConfig=true
if ($LASTEXITCODE -ne 0) { throw "还原失败（退出码 $LASTEXITCODE）" }

Write-Host "==> 编译 WinUIEditor ($Config, x64)"
& $MSBuild @common -m "-p:Configuration=$Config" -p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw "编译失败（退出码 $LASTEXITCODE）" }

Write-Host "==> 完成：$Vendor\_buildWinUI3\x64\$Config\WinUIEditor\bin\WinUIEditor"
