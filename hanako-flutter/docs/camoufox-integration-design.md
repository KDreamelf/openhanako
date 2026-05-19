# Camoufox 浏览器集成设计

> 设计日期：2026-05-19  
> 状态：草案  
> 相关代码：`lib/core/browser_manager.dart`、`installers/windows.iss`、`native/windows_ops_sidecar/`

---

## 1. 架构分层

```
┌─────────────────────────────────────────────────────┐
│  安装器 (Inno Setup)                                 │
│  检测 Python/uv → 内置兜底 → venv → camoufox 安装     │
│  产物：{app}\browser\venv + Camoufox 二进制           │
└───────────────┬─────────────────────────────────────┘
                │ 安装时一次性完成
┌───────────────▼─────────────────────────────────────┐
│  camoufox-connector (Python 进程)                    │
│  启动 Camoufox 浏览器 → 暴露 WebSocket 端点            │
│  由客户端 BrowserManager 按需启停                      │
└───────────────┬─────────────────────────────────────┘
                │ ws://localhost:{port}
┌───────────────▼─────────────────────────────────────┐
│  BrowserManager (Dart)                               │
│  Playwright Firefox WS 协议 → 页面控制                │
│  暴露给 Agent 工具：browser / web_search              │
└─────────────────────────────────────────────────────┘
```

客户端代码不涉及 Python/uv/pip 操作——安装器全权负责环境搭建。

---

## 2. 安装器改动 (Inno Setup)

### 2.1 内置文件

安装包需要打入（`installers/bundled/` 目录）：

| 文件 | 来源 | 大小 |
|------|------|------|
| `python-3.12-embed-amd64.zip` | python.org embeddable package | ~15 MB |
| `uv.exe` | astral.sh/uv releases | ~30 MB |

### 2.2 安装逻辑（Pascal Script）

```
[Code] 伪逻辑：

function PrepareBeowserEnvironment():
    venvDir = {app}\browser\venv
    
    // 1. 检测系统 Python
    systemPython = FindPythonInPath(minVersion='3.10')
    if systemPython != '':
        python = systemPython
    else:
        // 解压内置 Python embeddable
        ExtractBundled('python-3.12-embed-amd64.zip', '{app}\browser\python')
        python = '{app}\browser\python\python.exe'
    
    // 2. 检测系统 uv
    systemUv = FindInPath('uv.exe')
    if systemUv != '':
        uv = systemUv
    else:
        CopyBundled('uv.exe', '{app}\browser\uv.exe')
        uv = '{app}\browser\uv.exe'
    
    // 3. 创建 venv + 安装 camoufox
    Exec(uv, 'venv ' + venvDir + ' --python ' + python)
    Exec(uv, 'pip install --python ' + venvDir + '\Scripts\python.exe camoufox[geoip] camoufox-connector')
    
    // 4. 下载 Camoufox 浏览器二进制
    //    注意：不能从官方地址下载（墙）。
    //    方案 A：安装包内置 camoufox 二进制（+300MB，安装包大但离线可用）
    //    方案 B：从我们自己的 CDN/网盘镜像拉（安装包小但需要网络）
    //    当前选择：安装包内置（离线可用优先）
    Exec(venvDir + '\Scripts\python.exe', '-m camoufox.pkgman install')
    // 或直接解压内置的浏览器包到 venv 的 camoufox 数据目录
    
    // 5. 写入配置文件
    WriteConfigJson('{app}\browser\config.json', {
        'venvPython': venvDir + '\Scripts\python.exe',
        'connectorModule': 'camoufox_connector',
        'browserDataDir': venvDir + '\Lib\site-packages\camoufox\data',
        'defaultPort': 9222,
    })
```

### 2.3 卸载时清理

`[UninstallDelete]` 加 `{app}\browser` 目录。

---

## 3. 客户端侧 (Dart + Rust sidecar)

### 3.1 BrowserManager 重写

当前 BrowserManager 是 HTTP 静态抓取的占位实现。重写为：

```dart
class BrowserManager {
  // 读 {app}/browser/config.json 获取 venvPython 路径
  // 启动 camoufox-connector 进程（python -m camoufox_connector --port {port}）
  // 连接 WebSocket ws://localhost:{port}
  // 通过 Playwright Firefox 协议发送命令
  
  Future<void> start()       // 启动 connector + 等待 WS 就绪
  Future<void> stop()        // 关闭 WS + 杀 connector 进程
  bool get isRunning
  
  Future<void> navigate(String url)
  Future<String> snapshot()  // 页面 DOM 文本
  Future<String> evaluate(String expression)
  Future<void> click(String selector)
  Future<void> type(String selector, String text)
  Future<Uint8List> screenshot()
  Future<String> pageTitle()
  Future<String> pageUrl()
}
```

### 3.2 web_search 工具实现

```dart
// 替换当前的 _notConfigured 占位
LocalToolNames.webSearch => await _webSearch(arguments, browserManager)

static Future<Map<String, dynamic>> _webSearch(args, browserManager) {
    final query = _requiredString(args, 'query');
    await browserManager.start();  // 幂等
    await browserManager.navigate('https://www.bing.com/search?q=${Uri.encodeComponent(query)}');
    final results = await browserManager.evaluate('''
        // 提取搜索结果 DOM
        Array.from(document.querySelectorAll('.b_algo')).map(el => ({
            title: el.querySelector('h2')?.textContent || '',
            url: el.querySelector('a')?.href || '',
            snippet: el.querySelector('.b_caption p')?.textContent || '',
        }))
    ''');
    return {'ok': true, 'query': query, 'results': results};
}
```

### 3.3 browser 工具增强

现有 browser 工具的 action 列表大部分是 stub。重写后所有 action 通过 WS 协议实际执行：
- `start` → browserManager.start()
- `stop` → browserManager.stop()
- `navigate` → browserManager.navigate(url)
- `snapshot` → browserManager.snapshot()
- `screenshot` → browserManager.screenshot()
- `click` / `type` / `scroll` / `key` → 对应 Playwright 操作
- `evaluate` → browserManager.evaluate(expression)
- `wait` → 等待选择器出现或页面加载

---

## 4. Camoufox 二进制分发策略

### 4.1 决策：安装包内置

| 方案 | 优点 | 缺点 |
|------|------|------|
| 安装包内置 | 离线可用、不怕墙 | 安装包 +300MB |
| 自有 CDN 下载 | 安装包小 | 依赖网络、CDN 成本 |
| 首次启动下载 | 安装包最小 | 用户体验差、代码语义混乱 |

选择**安装包内置**。原因：
1. 不能从官方地址下载（墙）
2. 安装包内一次搞定，代码不碰安装逻辑
3. 用户体验：装完即用

### 4.2 内置方式

Camoufox 二进制本质是一个定制 Firefox 目录。`camoufox fetch` 下载的是一个 zip/tar 包。

安装包做法：
1. 构建时提前下载 Camoufox 二进制包
2. 放入 `installers/bundled/camoufox-browser-win64.zip`
3. 安装时解压到 `{app}\browser\camoufox-data\`
4. 配置 camoufox 库指向这个路径（环境变量 `CAMOUFOX_DATA_DIR`）

---

## 5. 进程生命周期

```
客户端启动
  │
  ├─ BrowserManager 初始化（读 config.json，不启动进程）
  │
  ├─ Agent 首次调用 browser/web_search 工具
  │   └─ browserManager.start()
  │       ├─ 启动 camoufox-connector 子进程
  │       │   python.exe -m camoufox_connector --port 9222 --headless virtual
  │       ├─ 等待 WS 端口就绪（轮询 health check）
  │       └─ 建立 WebSocket 连接
  │
  ├─ Agent 后续调用 → 复用已有 WS 连接
  │
  ├─ 空闲超时（如 10 分钟无操作）→ browserManager.stop()
  │   ├─ 关闭 WS 连接
  │   └─ 杀 connector 子进程
  │
  └─ 客户端退出 → browserManager.stop()
```

---

## 6. 安全考虑

- Camoufox 只监听 localhost，不暴露到网络
- WS 端口随机选择可用端口（避免端口冲突）
- connector 进程以当前用户权限运行
- 浏览器 profile 存在 `{app}\browser\profiles\` 下，卸载时清理

---

## 7. 实施步骤

```
阶段 A：安装器
  → 修改 windows.iss：内置 Python embeddable + uv + Camoufox 二进制
  → [Code] 段实现 Python/uv 检测 + venv 创建 + camoufox 安装
  → 写入 {app}\browser\config.json

阶段 B：BrowserManager 重写
  → 读 config.json 获取路径
  → 启停 camoufox-connector 子进程
  → WebSocket 连接 + Playwright Firefox 协议客户端

阶段 C：工具接入
  → browser 工具所有 action 接通
  → web_search 工具实现（Bing DOM 提取）
  → WindowsOpsCapabilities 加 browser 能力探测

阶段 D：测试 + 上线
  → 端到端测试：安装 → 启动浏览器 → 搜索 → 截图
  → 安装包构建流水线加 Camoufox 资源
```
