# Camoufox 浏览器集成设计

> 设计日期：2026-05-19  
> 状态：草案  
> 相关代码：`lib/core/browser_manager.dart`、`installers/windows.iss`、`native/windows_ops_sidecar/`

---

## 1. 架构分层

```
┌─────────────────────────────────────────────────────┐
│  安装器 (Inno Setup)                                 │
│  内置 Python/uv → venv → camoufox 安装 → 解压二进制    │
│  产物：{app}\browser\venv + Camoufox 二进制 + bridge   │
└───────────────┬─────────────────────────────────────┘
                │ 安装时一次性完成
┌───────────────▼─────────────────────────────────────┐
│  Hanako browser bridge (Python 进程)                 │
│  启动 Camoufox/Playwright → 暴露 JSONL stdin/stdout    │
│  由客户端 BrowserManager 按需启停                      │
└───────────────┬─────────────────────────────────────┘
                │ JSONL over stdio
┌───────────────▼─────────────────────────────────────┐
│  BrowserManager (Dart)                               │
│  JSONL 命令 → Python Playwright 页面控制              │
│  暴露给 Agent 工具：browser / web_search              │
└─────────────────────────────────────────────────────┘
```

客户端代码不涉及 Python/uv/pip 操作——安装器全权负责环境搭建。Dart 也不直接实现
Playwright 私有协议，而是通过项目内置的 `hanako_browser_bridge.py` 调用 Python
Playwright/Camoufox API。

---

## 2. 安装器改动 (Inno Setup)

### 2.1 内置文件

安装包需要打入（`installers/bundled/` 目录）：

| 文件 | 来源 | 大小 |
|------|------|------|
| `python-3.12-embed-amd64.zip` | python.org embeddable package | ~15 MB |
| `uv.exe` | astral.sh/uv releases | ~30 MB |
| `camoufox-browser-win64.zip` | 构建机提前 fetch 后压缩 | ~300 MB |
| `hanako_browser_bridge.py` | 项目安装器目录 | <1 MB |

### 2.2 安装逻辑（Pascal Script）

```
[Code] 伪逻辑：

function PrepareBrowserEnvironment():
    venvDir = {app}\browser\venv

    // 1. 解压内置 Python embeddable，避免污染系统 Python
    ExtractBundled('python-3.12-embed-amd64.zip', '{app}\browser\python')
    python = '{app}\browser\python\python.exe'

    // 2. 复制内置 uv
    CopyBundled('uv.exe', '{app}\browser\uv.exe')
    uv = '{app}\browser\uv.exe'

    // 3. 创建 venv + 安装 camoufox Python 包
    Exec(uv, 'venv ' + venvDir + ' --python ' + python)
    Exec(uv, 'pip install --python ' + venvDir + '\Scripts\python.exe camoufox[geoip]')

    // 4. 解压内置 Camoufox 浏览器二进制，不在用户机器上走官方 CDN
    ExtractBundled('camoufox-browser-win64.zip', '{app}\browser\camoufox-data')
    executable = FindBrowserExecutable('{app}\browser\camoufox-data')

    // 5. 写入配置文件
    WriteConfigJson('{app}\browser\config.json', {
        'venvPython': venvDir + '\Scripts\python.exe',
        'bridgeScript': '{app}\browser\hanako_browser_bridge.py',
        'browserDataDir': '{app}\browser\camoufox-data',
        'browserExecutable': executable,
        'headless': true,
        'excludeDefaultAddons': true,
    })
```

### 2.3 卸载时清理

`[UninstallDelete]` 加 `{app}\browser` 目录。

---

## 3. 客户端侧 (Dart + Rust sidecar)

### 3.1 BrowserManager 重写

BrowserManager 管理 Python bridge 子进程。没有安装 Camoufox 时，`navigate`/`snapshot`
保留静态 HTTP 兜底；`web_search` 和交互类动作必须走真实 Camoufox。

```dart
class BrowserManager {
  // 读 {app}/browser/config.json 获取 venvPython + bridgeScript
  // 启动 Python bridge：python.exe hanako_browser_bridge.py config.json
  // 通过 stdin/stdout JSONL 发送浏览器命令
  
  Future<void> start()       // 启动 bridge + Camoufox
  Future<void> stop()        // 关闭 bridge + Camoufox
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
    await browserManager.start();  // 幂等，且必须是真实 Camoufox
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

现有 browser 工具的 action 列表大部分是 stub。重写后真实浏览器模式下所有交互 action
通过 Python bridge 实际执行：
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
4. 安装器递归查找 `camoufox.exe` 或 `firefox.exe`，写入 `browserExecutable`
5. bridge 通过 `executable_path` 和版本信息启动 Camoufox，不依赖默认用户缓存

---

## 5. 进程生命周期

```
客户端启动
  │
  ├─ BrowserManager 初始化（读 config.json，不启动进程）
  │
  ├─ Agent 首次调用 browser/web_search 工具
  │   └─ browserManager.start()
  │       ├─ 启动 Hanako browser bridge 子进程
  │       │   python.exe hanako_browser_bridge.py config.json
  │       ├─ bridge 调用 Camoufox(headless=true, executable_path=...)
  │       └─ Dart 通过 JSONL 发送命令
  │
  ├─ Agent 后续调用 → 复用已有 bridge 进程
  │
  ├─ 空闲超时（如 10 分钟无操作）→ browserManager.stop()
  │   ├─ bridge 关闭 Playwright/Camoufox
  │   └─ 杀 bridge 子进程
  │
  └─ 客户端退出 → browserManager.stop()
```

---

## 6. 安全考虑

- Camoufox 不暴露网络 API；Dart 与 bridge 只通过本机子进程 stdio 通信
- bridge 进程以当前用户权限运行
- 默认排除 Camoufox 的完整 `DefaultAddons` 集合，避免首次启动访问外部插件站点；若当前 Camoufox 版本无法暴露默认插件排除 API，bridge 会失败闭环而不是静默联网下载

---

## 7. 实施步骤

```
阶段 A：安装器
  → 修改 windows.iss：内置 Python embeddable + uv + Camoufox 二进制
  → [Code] 段实现 Python/uv 检测 + venv 创建 + camoufox 安装
  → 写入 {app}\browser\config.json

阶段 B：BrowserManager 重写
  → 读 config.json 获取路径
  → 启停 Hanako browser bridge 子进程
  → JSONL 命令 + Python Playwright/Camoufox API

阶段 C：工具接入
  → browser 工具所有 action 接通
  → web_search 工具实现（Bing DOM 提取）

阶段 D：测试 + 上线
  → 端到端测试：安装 → 启动浏览器 → 搜索 → 截图
  → 安装包构建流水线加 Camoufox 资源
```
