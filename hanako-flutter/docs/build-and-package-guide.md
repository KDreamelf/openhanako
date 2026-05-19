# 安装包构建手册

> 最后更新：2026-05-19  
> 适用版本：v0.0.3+

本文档覆盖从源码到安装包的完整构建流程。没有 CI/CD，**所有步骤手动执行**。打包前逐项检查，缺一不可。

---

## 0. 前置环境

| 工具 | 最低版本 | 用途 |
|------|---------|------|
| Flutter | 3.x stable | 客户端构建 |
| Rust (MSVC) | 1.78+ | windows_ops_sidecar 构建 |
| Inno Setup | 6.0+ | 安装包打包 |
| PowerShell | 5.1+ | 脚本执行 |
| Python | 3.10+ | Camoufox 资源准备（构建机用） |
| uv | 0.4+ | Camoufox 资源准备（构建机用） |
| Go | 1.22+ | experience-dht 构建（如需同步发布） |

---

## 1. 构建客户端

```powershell
cd hanako-flutter

# 清理旧产物
flutter clean

# 获取依赖
flutter pub get

# 静态检查（必须 0 error）
flutter analyze --no-pub
# 如果有 error 停止，不继续打包

# 运行测试（必须全部通过）
flutter test
# 如果有 fail 停止，不继续打包

# release 构建
flutter build windows --release
```

产物位置：`build/windows/x64/runner/Release/`

---

## 2. 构建 Windows Ops Sidecar

```powershell
cd native/windows_ops_sidecar

cargo build --release
```

产物：`target/release/hanako_windows_ops_sidecar.exe`

复制到 Flutter release 目录：

```powershell
$src = "target\release\hanako_windows_ops_sidecar.exe"
$dst = "..\..\build\windows\x64\runner\Release\native\windows_ops\"
New-Item -ItemType Directory -Force -Path $dst
Copy-Item $src $dst
```

---

## 3. 准备模型资源

模型文件不在 git 中，需要从团队共享存储获取。

```
build/windows/x64/runner/Release/models/
├── windows_ops/
│   ├── ui_parser/
│   │   ├── ui_parser.manifest.json
│   │   └── weights/icon_detect/
│   │       ├── model.onnx
│   │       ├── model.yaml
│   │       ├── train_args.yaml
│   │       └── LICENSE
│   └── ocr/
│       ├── ocr.manifest.json
│       ├── text-detection.rten
│       └── text-recognition.rten
```

**检查清单**：
- [ ] `model.onnx` 存在且 > 1MB
- [ ] `text-detection.rten` 存在且 > 1MB
- [ ] `text-recognition.rten` 存在且 > 1MB

---

## 4. 准备 Camoufox 浏览器资源

**这是最容易漏掉的一步。** 三个文件必须放到 `installers/bundled/` 目录。

### 4.1 Python Embeddable

从 python.org 下载 Windows embeddable package（**不是安装器**）：

```powershell
# 下载 Python 3.12 embeddable (amd64)
$pythonUrl = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip"
$dest = "installers\bundled\python-3.12-embed-amd64.zip"
New-Item -ItemType Directory -Force -Path "installers\bundled"
Invoke-WebRequest -Uri $pythonUrl -OutFile $dest
```

**验证**：文件约 15MB，zip 内含 `python.exe` + `python312.zip` + `python3.dll` 等。

### 4.2 uv

从 GitHub Releases 下载 Windows 二进制：

```powershell
# 下载 uv（构建时确认最新版本号）
$uvUrl = "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip"
Invoke-WebRequest -Uri $uvUrl -OutFile "$env:TEMP\uv.zip"
Expand-Archive -Force "$env:TEMP\uv.zip" -DestinationPath "$env:TEMP\uv-extracted"
Copy-Item "$env:TEMP\uv-extracted\uv.exe" "installers\bundled\uv.exe"
```

**验证**：`uv.exe` 约 30MB，可直接运行 `.\installers\bundled\uv.exe --version`。

### 4.3 Camoufox 浏览器二进制

**绝对不能从 Camoufox 官方 CDN 下载——会被墙。** 使用构建机提前下载并存入团队存储。

在构建机上（需要能访问外网的环境，或使用代理）：

```powershell
# 创建临时 venv
uv venv camoufox-prep --python 3.12
camoufox-prep\Scripts\activate

# 安装 camoufox
uv pip install camoufox

# 执行 fetch（下载浏览器二进制）
python -m camoufox.pkgman install

# 找到下载的浏览器目录
python -c "import camoufox; print(camoufox.get_path('camoufox'))"
# 输出类似：C:\...\site-packages\camoufox\data\camoufox-...

# 打包成 zip
$dataDir = python -c "import camoufox; print(camoufox.get_path('camoufox'))"
Compress-Archive -Path "$dataDir\*" -DestinationPath "camoufox-browser-win64.zip"

# 复制到 installers/bundled/
Copy-Item "camoufox-browser-win64.zip" "hanako-flutter\installers\bundled\"

# 清理
deactivate
Remove-Item -Recurse camoufox-prep
```

**验证**：
- `camoufox-browser-win64.zip` 约 **300MB**
- zip 内含 `camoufox.exe`（或 `firefox.exe`）+ `omni.ja` + `xul.dll` 等 Firefox 核心文件

### 4.4 最终检查

```powershell
ls installers\bundled\

# 必须看到：
#   python-3.12-embed-amd64.zip    (~15 MB)
#   uv.exe                         (~30 MB)
#   camoufox-browser-win64.zip     (~300 MB)
```

**缺任何一个文件，Inno Setup 编译会失败。**

---

## 5. 编译安装包

```powershell
cd hanako-flutter

# 确认 Inno Setup 在 PATH 中
iscc.exe --version

# 编译
iscc.exe installers\windows.iss
```

产物：`build/installers/phantasm_01_Setup-v0.0.3.exe`

**预期大小**：约 **400-500 MB**（客户端 ~50MB + sidecar ~5MB + 模型 ~30MB + Camoufox ~300MB + Python/uv ~45MB，LZMA 压缩后）。

---

## 6. 安装测试

在干净 Windows 环境（最好是虚拟机）上测试：

### 6.1 安装

- [ ] 运行安装包，完成安装
- [ ] 安装过程中能看到"正在配置浏览器环境..."状态
- [ ] 安装完成，桌面出现快捷方式

### 6.2 基本功能

- [ ] 启动客户端，能看到主界面
- [ ] 创建/解锁身份成功
- [ ] 选择模型，发送消息，收到回复
- [ ] 工具调用正常（read_file、exec_command 等）

### 6.3 浏览器功能

- [ ] `{安装目录}\browser\config.json` 存在
- [ ] `{安装目录}\browser\venv\Scripts\python.exe` 存在
- [ ] `{安装目录}\browser\camoufox-data\` 内有 Firefox 文件

Agent 测试：
- [ ] 让 Agent 调用 `web_search` 工具搜索一个关键词
- [ ] 返回结果包含 title/url/snippet
- [ ] 让 Agent 调用 `browser` 工具打开一个网页
- [ ] `snapshot` 能返回页面文本

### 6.4 经验网络

- [ ] 设置中能看到经验相关选项
- [ ] `publish_demand` 工具可调用（即使无远端节点，不应崩溃）

### 6.5 卸载

- [ ] 卸载后 `{安装目录}` 被清理
- [ ] 用户数据（`%APPDATA%\hanako`）保留

---

## 7. 发布

1. 安装包重命名为最终发布名（如需要）
2. 上传到团队网盘/分发渠道
3. 更新 CHANGELOG.md
4. git tag 打版本标签

```powershell
git tag -a v0.0.3 -m "v0.0.3: context compaction + P2P experience network + Camoufox browser"
```

---

## 8. 常见问题

### Q: Inno Setup 编译报 "Source file not found"
A: `installers/bundled/` 下缺文件。回到第 4 节准备资源。

### Q: 安装后 Camoufox 不工作
A: 检查 `config.json` 中 `venvPython` 路径是否正确。手动执行：
```powershell
& "{安装目录}\browser\venv\Scripts\python.exe" -m camoufox_connector --port 9222
```
看是否有报错。

### Q: pip install 超时
A: 安装器使用阿里云镜像 (`mirrors.aliyun.com`)。如果用户环境网络异常，检查是否有代理拦截。

### Q: 用户电脑有 Python 但版本太低
A: 安装器的 `FindPythonInPath` 只检查 Python 是否存在，未严格检查版本。如果遇到兼容问题，可以改为总是使用内置 Python（修改安装器逻辑跳过检测）。

### Q: 安装包太大
A: 主要是 Camoufox 浏览器二进制 (~300MB)。可以考虑：
- 安装包不内置 Camoufox，改为首次使用时从团队 CDN 下载
- 但这需要客户端代码支持下载逻辑，违反"安装器搞定一切"原则
- 当前选择安装包内置，优先保证离线可用
