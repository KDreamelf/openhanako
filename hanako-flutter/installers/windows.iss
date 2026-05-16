; Inno Setup 安装包脚本（Windows）
; 用法：
;   1. 装 Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
;   2. 先 `flutter build windows --release`
;   3. 在 Inno Setup Compiler 里编译此 .iss，或命令行：
;      iscc.exe installers/windows.iss
;   OCR/端侧模型资源必须已由安装包预置；核心文件缺失时编译应失败。
; 产物：build/installers/phantasm_01_Setup-{version}.exe

#define MyAppName "幻宙01"
#define MyAppVersion "v0.0.2"
#define MyAppPublisher "湖北幻宙智能科技有限公司"
#define MyAppURL "https://xn--lbtx0e.cn"
#define MyAppDirName "phantasm_01"
#define MyAppExeName "phantasm_01.exe"
#define WindowsOpsSidecarExeName "hanako_windows_ops_sidecar.exe"
#define MyAppId "{{5E9B29C7-5F28-4B49-A8CE-2CBE6501F001}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppDirName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installers
OutputBaseFilename=phantasm_01_Setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
VersionInfoCompany={#MyAppPublisher}
VersionInfoCopyright=Copyright (C) 2026 {#MyAppPublisher}. All rights reserved.
VersionInfoDescription={#MyAppName} 安装程序
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion=0.0.2.0
VersionInfoVersion=0.0.2.0
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
ChangesAssociations=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupicon"; Description: "开机自启动（所有用户）"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; release 产物完整目录复制
Source: "..\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs
Source: "..\build\windows\x64\runner\Release\native\windows_ops\{#WindowsOpsSidecarExeName}"; DestDir: "{app}\native\windows_ops"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\ui_parser.manifest.json"; DestDir: "{app}\models\windows_ops\ui_parser"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\model.onnx"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\model.yaml"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\train_args.yaml"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\LICENSE"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ocr\ocr.manifest.json"; DestDir: "{app}\models\windows_ops\ocr"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ocr\text-detection.rten"; DestDir: "{app}\models\windows_ops\ocr"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ocr\text-recognition.rten"; DestDir: "{app}\models\windows_ops\ocr"; Flags: ignoreversion

[Registry]
Root: HKCR; Subkey: "ph01"; ValueType: string; ValueData: "URL:PH01 Login Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "ph01"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCR; Subkey: "ph01\DefaultIcon"; ValueType: string; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCR; Subkey: "ph01\shell\open\command"; ValueType: string; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{commonstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 不删 HANA_HOME（用户数据），仅清理 app 内安装文件
Type: filesandordirs; Name: "{app}"
