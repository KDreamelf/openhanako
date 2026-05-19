; Inno Setup 安装包脚本（Windows）
; 用法：
;   1. 装 Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
;   2. 先 `flutter build windows --release`
;   3. 在 Inno Setup Compiler 里编译此 .iss，或命令行：
;      iscc.exe installers/windows.iss
;   OCR/端侧模型资源必须已由安装包预置；核心文件缺失时编译应失败。
;   Camoufox 资源须提前下载到 installers/bundled/。
; 产物：build/installers/phantasm_01_Setup-{version}.exe

#define MyAppName "幻宙01"
#define MyAppVersion "v0.0.3"
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
VersionInfoProductVersion=0.0.3.0
VersionInfoVersion=0.0.3.0
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
; ---- 客户端主程序 ----
Source: "..\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs

; ---- Windows Ops Sidecar ----
Source: "..\build\windows\x64\runner\Release\native\windows_ops\{#WindowsOpsSidecarExeName}"; DestDir: "{app}\native\windows_ops"; Flags: ignoreversion

; ---- 模型资源 ----
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\ui_parser.manifest.json"; DestDir: "{app}\models\windows_ops\ui_parser"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\model.onnx"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\model.yaml"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\train_args.yaml"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ui_parser\weights\icon_detect\LICENSE"; DestDir: "{app}\models\windows_ops\ui_parser\weights\icon_detect"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ocr\ocr.manifest.json"; DestDir: "{app}\models\windows_ops\ocr"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ocr\text-detection.rten"; DestDir: "{app}\models\windows_ops\ocr"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\models\windows_ops\ocr\text-recognition.rten"; DestDir: "{app}\models\windows_ops\ocr"; Flags: ignoreversion

; ---- Camoufox 浏览器环境（内置兜底） ----
; Python embeddable + uv：仅在系统无合适 Python/uv 时使用
Source: "bundled\python-3.12-embed-amd64.zip"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall
Source: "bundled\uv.exe"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall
; Camoufox 浏览器二进制（提前从镜像下载，不走官方 CDN）
Source: "bundled\camoufox-browser-win64.zip"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall nocompression

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

[Code]
// ============================================================
// Camoufox 浏览器环境自举
//
// 逻辑：
//   1. 检测系统 PATH 中是否有 Python 3.10+ 和 uv
//   2. 没有则解压内置的 Python embeddable + uv
//   3. 用 uv 创建 venv 并安装 camoufox + camoufox-connector
//   4. 解压内置 Camoufox 浏览器二进制到数据目录
//   5. 写入 config.json 供客户端读取
// ============================================================

var
  BrowserPython: String;
  BrowserUv: String;
  BrowserVenvDir: String;
  BrowserDataDir: String;

function FindPythonInPath(): String;
var
  Output: String;
  ResultCode: Integer;
begin
  Result := '';
  if Exec('cmd.exe', '/C python --version 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      if Exec('cmd.exe', '/C where python', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      begin
        if ResultCode = 0 then
          Result := 'python';
      end;
    end;
  end;
end;

function FindUvInPath(): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if Exec('cmd.exe', '/C uv --version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
      Result := 'uv';
  end;
end;

procedure ExtractBundledPython();
var
  PythonDir: String;
  ResultCode: Integer;
begin
  PythonDir := ExpandConstant('{app}\browser\python');
  ForceDirectories(PythonDir);
  // 使用 PowerShell 解压 zip
  Exec('powershell.exe',
    '-NoProfile -Command "Expand-Archive -Force -Path ''' +
    ExpandConstant('{tmp}\python-3.12-embed-amd64.zip') +
    ''' -DestinationPath ''' + PythonDir + '''"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  BrowserPython := PythonDir + '\python.exe';
end;

procedure ExtractBundledCamoufox();
var
  ResultCode: Integer;
begin
  BrowserDataDir := ExpandConstant('{app}\browser\camoufox-data');
  ForceDirectories(BrowserDataDir);
  Exec('powershell.exe',
    '-NoProfile -Command "Expand-Archive -Force -Path ''' +
    ExpandConstant('{tmp}\camoufox-browser-win64.zip') +
    ''' -DestinationPath ''' + BrowserDataDir + '''"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure SetupBrowserVenv();
var
  ResultCode: Integer;
  VenvPython: String;
begin
  BrowserVenvDir := ExpandConstant('{app}\browser\venv');
  VenvPython := BrowserVenvDir + '\Scripts\python.exe';

  // 创建 venv
  Exec(BrowserUv, 'venv "' + BrowserVenvDir + '" --python "' + BrowserPython + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // 安装 camoufox + connector（使用国内镜像加速）
  Exec(BrowserUv, 'pip install --python "' + VenvPython + '" -i https://mirrors.aliyun.com/pypi/simple/ camoufox[geoip] camoufox-connector',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure WriteBrowserConfig();
var
  ConfigPath: String;
  ConfigContent: String;
  VenvPython: String;
begin
  ConfigPath := ExpandConstant('{app}\browser\config.json');
  VenvPython := BrowserVenvDir + '\Scripts\python.exe';
  BrowserDataDir := ExpandConstant('{app}\browser\camoufox-data');
  ConfigContent :=
    '{' + #13#10 +
    '  "venvPython": "' + VenvPython + '",' + #13#10 +
    '  "connectorModule": "camoufox_connector",' + #13#10 +
    '  "browserDataDir": "' + BrowserDataDir + '",' + #13#10 +
    '  "defaultPort": 0,' + #13#10 +
    '  "headless": "virtual"' + #13#10 +
    '}';
  SaveStringToFile(ConfigPath, ConfigContent, False);
end;

procedure PrepareBrowserEnvironment();
var
  SystemPython: String;
  SystemUv: String;
begin
  WizardForm.StatusLabel.Caption := '正在配置浏览器环境...';

  // 1. Python
  SystemPython := FindPythonInPath();
  if SystemPython <> '' then
    BrowserPython := SystemPython
  else
  begin
    WizardForm.StatusLabel.Caption := '正在解压内置 Python...';
    ExtractBundledPython();
  end;

  // 2. uv
  SystemUv := FindUvInPath();
  if SystemUv <> '' then
    BrowserUv := SystemUv
  else
  begin
    BrowserUv := ExpandConstant('{app}\browser\uv.exe');
    FileCopy(ExpandConstant('{tmp}\uv.exe'), BrowserUv, False);
  end;

  // 3. venv + packages
  WizardForm.StatusLabel.Caption := '正在安装 Camoufox 依赖...';
  SetupBrowserVenv();

  // 4. Camoufox 浏览器二进制
  WizardForm.StatusLabel.Caption := '正在解压 Camoufox 浏览器...';
  ExtractBundledCamoufox();

  // 5. 配置文件
  WriteBrowserConfig();

  WizardForm.StatusLabel.Caption := '浏览器环境配置完成。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    PrepareBrowserEnvironment();
  end;
end;
