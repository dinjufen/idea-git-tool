; GitDeck 的 Windows 安装程序（Inno Setup 6，见 docs/DECISIONS.md 第 15 项）。
; 由 scripts/package-win.ps1 调用，传入 AppVersion（完整版本号）、AppNumericVersion（数字部分）、SourceDir（自包含发布目录）、OutputDir、RepoRoot；
; 定义 DebugBuild 时生成调试版（独立的 AppId 与安装目录，可与正式版同时安装）。
;
; 按用户安装到 %LOCALAPPDATA%\Programs\GitDeck，无需管理员权限。卸载只删除程序文件，
; 不删除 %LOCALAPPDATA%\GitDeck 中的设置与 Windows 凭据管理器中保存的密钥。

#ifndef AppVersion
  #error AppVersion 未定义（请通过 scripts/package-win.ps1 构建）
#endif

#define AppName "GitDeck"

#ifdef DebugBuild
  #define AppIdGuid "4599079E-2896-4DD7-9E67-E49D0D2B7EB1"
  #define DisplayName AppName + " (Debug)"
  #define InstallFolder AppName + ".debug"
  #define SetupSuffix "-debug"
#else
  #define AppIdGuid "30BE83CE-ED85-4934-B475-72879C4CBD8B"
  #define DisplayName AppName
  #define InstallFolder AppName
  #define SetupSuffix ""
#endif

[Setup]
AppId={{{#AppIdGuid}}
AppName={#DisplayName}
AppVersion={#AppVersion}
AppVerName={#DisplayName} {#AppVersion}
VersionInfoVersion={#AppNumericVersion}
UninstallDisplayName={#DisplayName}
UninstallDisplayIcon={app}\GitDeck.exe
DefaultDirName={localappdata}\Programs\{#InstallFolder}
DisableProgramGroupPage=yes
DefaultGroupName={#DisplayName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
SetupIconFile={#RepoRoot}\apps\windows\GitDeck\Assets\GitDeck.ico
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=GitDeck-{#AppVersion}-x64{#SetupSuffix}-setup
; 升级时关闭正在运行的 GitDeck（Restart Manager），安装完成后不自动重启旧进程。
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#DisplayName}"; Filename: "{app}\GitDeck.exe"
Name: "{autodesktop}\{#DisplayName}"; Filename: "{app}\GitDeck.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\GitDeck.exe"; Description: "{cm:LaunchProgram,{#DisplayName}}"; Flags: nowait postinstall skipifsilent
