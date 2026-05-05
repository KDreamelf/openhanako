# Hanako (Flutter Edition)

> 个人 AI Agent，带记忆、灵魂、与多窗口桌面工作流。
> 这是 Hanako 项目的 **Flutter 全 Dart 重写版**——前身 Electron + Node.js 版本完整保留在 [`legacy-electron/`](./legacy-electron/) 子目录里供参考。

## 当前状态（2026-04，Phase 0–4 全部完成）

| Phase | 内容 | 状态 |
|-------|------|------|
| 0 | Spike：单窗口 + OpenAI 流式 + sqlite + PerfHUD | ✅ |
| 1 | Drift schema + AI 网关模型目录 + 子体身份密钥协商 | ✅ |
| 2 | Core Managers + Memory + Bridge + Skill 外部进程 + CLI + Server | ✅ |
| 3 | 多窗口（desktop_multi_window）+ 系统托盘 + 全局快捷键 + Onboarding | ✅ |
| 4 | Windows release build + Inno Setup 模板 + Drift 兼容验证 + 文档 | ✅ |

## 三种运行形态（同一份 `lib/core/`）

```
Flutter Desktop (GUI)   ← flutter run  /  build/windows/x64/runner/Release/hanako.exe
Headless Server         ← dart run bin/server.dart      → shelf HTTP + WS
CLI                     ← dart run bin/hanako.dart      → agents / chat / config
```

## 启动

```bash
# 开发
flutter run -d windows

# 生产构建（Windows）
flutter build windows --release
# 产物：build/windows/x64/runner/Release/hanako.exe

# CLI
dart run bin/hanako.dart agents list
dart run bin/hanako.dart agents create --name "Hanako" --yuan hanako
dart run bin/hanako.dart chat --text "你好"

# Headless server
HANA_PORT=4000 dart run bin/server.dart
```

## 核心特性

- **AI 网关模型目录**：子体只选择模型，模型列表来自 `ai.幻宙.cn` 在密钥协商后返回的授权模型列表
- **私钥身份通信**：子体持有私钥，向 AI 网关做 ECDH 短期通道协商，聊天请求不再使用本地供应商/API Key
- **Drift / SQLite 持久化**：与 legacy `better-sqlite3` 同 schema（facts + FTS5），**已通过兼容性测试**——现有用户 `facts.db` 可直接打开
- **Memory 系统完整**：滚动摘要 + 4 块编译（today/week/longterm/facts）+ 元事实拆分 + 标签搜索 + FTS5 全文搜索补充
- **多窗口**：主聊天 / Settings / Editor (re_editor) / Browser (desktop_webview_window)，每窗口独立 Flutter Engine
- **系统集成**：托盘 + 全局快捷键 (Ctrl+Alt+=) + 单实例锁
- **流式渲染**：thinking / text / tool_call 三类事件，`RepaintBoundary` 隔离
- **PerfHUD**：debug/profile 模式实时显示 fps/build/raster
- **PromptToolStreamParser**：工具调用 / thinking 块跨 chunk 增量解析（防 N-BUG-1）
- **Bridge**：Telegram HTTP long polling 完整；Lark/飞书 webhook + AES 加解密 + tenant_access_token 完整
- **Channel**：`.md` 文件读写 + frontmatter + 消息追加 + 退群清理
- **Skill**：**Anthropic Agent Skills 标准格式**——`{name}/SKILL.md` + frontmatter（`name` / `description` / `license` / `allowed-tools`）。SkillManager 只负责发现 + 解析 + 注入 system prompt 列表，不做 "执行"——模型按需用 `read_file` 加载完整 SKILL.md，用 `bash` / `python` 等通用工具执行其中的 scripts。1s debounce watch + per-agent 隔离 + legacy `title` 字段兼容。
- **Onboarding**：5 步流程，每步可跳过（规避 BUG-5）
- **Windows Credential Manager**：直接 FFI 调 win32 API，绕开 flutter_secure_storage 的 ATL 依赖

## 目录结构

```
hanako/
├── lib/
│   ├── main.dart                     # Flutter 入口（主窗口 + 子窗口分支）
│   ├── app/                          # ProviderScope / IPC / 桌面集成
│   ├── core/                         # Engine + 8 个 Manager
│   ├── llm/
│   │   ├── provider.dart             # Message + sealed LlmEvent 协议对象
│   │   ├── streaming/sse_parser.dart # 跨 chunk SSE 解析（防 N-BUG-1）
│   │   └── tool_format/prompt_tool.dart
│   ├── memory/                       # Drift schema + FactStore
│   ├── bridge/                       # Telegram (完整) + Lark (webhook + AES + tenant token)
│   ├── ui/                           # 主窗口 / Settings / Editor (re_editor) / Browser (webview) / Onboarding (5 step)
│   └── shared/                       # HanaHome / YamlIo / Result
├── bin/
│   ├── hanako.dart                   # CLI 入口
│   └── server.dart                   # shelf headless server
├── windows/runner/main.cpp           # Nvidia/AMD 高性能 GPU 导出 + UIThreadPolicy
├── installers/windows.iss            # Inno Setup 模板
├── test/
│   ├── widget_test.dart              # 主题 smoke
│   └── drift_legacy_compat_test.dart # Drift ↔ better-sqlite3 兼容验证
├── flutter-migration-plan/           # 原始迁移规划文档（7 份 + 性能优化复盘）
├── legacy-electron/                  # 原 Electron + Node 版本（参考用，不动）
├── README.md / CHANGELOG.md
└── pubspec.yaml
```

## 数据兼容性

`HANA_HOME` 与 legacy 完全一致：
- Windows：`%APPDATA%\hanako`
- macOS / Linux：`~/.hanako`

**现有用户的 `agents/<id>/memory/facts.db` 可直接被 Flutter 版打开**——已通过 `test/drift_legacy_compat_test.dart` 验证：
1. 用 raw sqlite3 按 legacy `fact-store.js` 完整 schema 创建 db；
2. 写入若干带 JSON tags 的 facts；
3. 用 Drift 打开同一文件；
4. 读取 / FTS 搜索 / 新增写入全部成功。

## 性能默认配置

参考 [`flutter-migration-plan/性能优化复盘-20260207.md`](./flutter-migration-plan/性能优化复盘-20260207.md)：

- **Windows runner** (`windows/runner/main.cpp`)：导出 `NvOptimusEnablement=1` + `AmdPowerXpressRequestHighPerformance=1` 偏好高性能 GPU；`UIThreadPolicy::RunOnSeparateThread` 显式锁定线程策略
- **PerfHUD**：内置 fps/build/raster 三联监测，debug+profile 自动显示
- **`RepaintBoundary`** 隔离每条流式消息，避免新消息重绘整个列表

## 已知限制

| 项 | 现状 | 计划 |
|---|------|------|
| `dart compile exe` (CLI/server) | dart 3.10 build hooks 限制，临时用 `dart run` | dart SDK 升级 + 等 build hooks 稳定 |
| `desktop_webview_window` Linux | 自动降级到外部浏览器（url_launcher） | 评估 WebKit GTK |
| 已保存身份解锁 UI | 密钥库与 PIN 解锁能力已在 identity 层，主界面尚缺独立解锁页 | Phase 5 接入“我的”页面 |
| macOS / Linux 打包 | 配置就绪，需对应平台机器构建 | CI 上配 |
| Onboarding 视觉 | 5 步功能完整，UI 简约 | Phase 5 加 Lottie 动画 |

## 旧 Electron 版

完整保留在 [`legacy-electron/`](./legacy-electron/) 中，**不会动**。可以随时进入参考 / 跑测试：

```bash
cd legacy-electron
npm install
npm start
```

## 测试

```bash
flutter analyze    # 0 errors，仅 lint info
flutter test       # 包含 Drift 兼容测试
```

## 文档

- [`flutter-migration-plan/`](./flutter-migration-plan/) — 完整迁移方案（7 份 markdown + pubspec 模板 + 性能优化复盘）
- [`CHANGELOG.md`](./CHANGELOG.md) — 详细变更记录
- [`legacy-electron/README.md`](./legacy-electron/README.md) — 原 Electron 版项目说明

## License

Apache-2.0（见 [`legacy-electron/LICENSE`](./legacy-electron/LICENSE)）
