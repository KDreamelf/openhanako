; Inno Setup 安装包脚本（Windows）
; 用法：
;   1. 装 Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
;   2. 先 `flutter build windows --release`
;   3. 在 Inno Setup Compiler 里编译此 .iss，或命令行：
;      iscc.exe installers/windows.iss
;   OCR/端侧模型资源必须已由安装包预置；核心文件缺失时编译应失败。
; 产物：build/installers/HanakoSetup-{version}.exe

#define MyAppName "Hanako"
#define MyAppVersion "600.42.0"
#define MyAppPublisher "liliMozi"
#define MyAppURL "https://github.com/liliMozi/openhanako"
#define MyAppExeName "hanako.exe"
#define WindowsOpsSidecarExeName "hanako_windows_ops_sidecar.exe"
#define MyAppId "{{B7D5A0F0-1234-4321-9ABC-HANAKO000001}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installers
OutputBaseFilename=HanakoSetup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
ChangesAssociations=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupicon"; Description: "开机自启动"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

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

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 不删 HANA_HOME（用户数据），仅清理 app 内安装文件
Type: filesandordirs; Name: "{app}"
