# Changelog

所有重要变更的记录。

## [600.42.2] · 2026-04-27 · 砍 ChannelTriage / Skill 对齐 Anthropic Agent Skills 标准

两处方向纠正——之前的实现不符合行业惯例，重写：

### Skill：改用 Anthropic Agent Skills 标准格式
**问题**：上一版 `lib/skill/skill_runner.dart` 设计了「外部进程 + stdin/stdout JSON」执行协议，
是过度设计——legacy 调研结论"Pi SDK 加载（不是 eval）"被我误读成"需要外部执行机制"。
行业标准（Anthropic Agent Skills）里 SKILL.md 是 **instruction 文件**，模型自己用通用工具
（read_file / bash / python）按需加载与执行其中的 scripts，**SkillManager 不该负责执行**。

**修正**：
- 删除 `lib/skill/skill_runner.dart` 与整个 `lib/skill/` 目录
- 重写 `lib/core/skill_manager.dart` 按 Anthropic spec 的 frontmatter 字段：
  - `name`（skill ID，文件夹名一致）
  - `description`（一句话描述，给模型决定何时调用）
  - `license`（可选）
  - `allowed-tools`（可选，list of tools this skill can use）
- 兼容字段：legacy `title` → `displayName` fallback
- 新增 `SkillManager.formatForPrompt(List<SkillSpec>)`：注入 system prompt 的列表段，
  让模型知道有哪些 skill 可用 + 路径，按 Anthropic 推荐的"懒加载"模式——不一次性把
  全部 SKILL.md 内容塞进 context
- 新增 `readSkillContent(name)` 直接读完整 SKILL.md 的 helper

### ChannelTriage / Hub：完全砍掉
**问题**：legacy 的 ChannelTriage（agent 自动判断要不要回复频道消息）+ Hub 双轮生成
回复机制依赖大量 utility model LLM 调用 + 复杂 prompt 模板，在 Flutter 单 GUI 桌面应用
里没有产品意义。

**修正**：
- 从 `ChannelManager` 删除 `triggerChannelTriage()` 方法（不留骨架）
- 把 channel 在 Flutter 端的定位明确为：「人 ↔ agent」单线对话的存档/记录形态
- 自动 multi-agent triage 由调用方 / 外部 hub 工具自行实现，不再是 hanako 主线特性

### 验证
- `flutter analyze` —— 0 errors
- `flutter test` —— 2/2 passed（含 Drift 兼容）
- `flutter build windows --debug` —— 16.1s 通过

---

## [600.42.1] · 2026-04-27 · 补完 Phase 4 留下的"骨架"清单

按 legacy 实际代码逐项翻译，把上一版"接口骨架/Phase 5 实现"的项做完。

### 校正
- **WeCom（企业微信）从计划中删除** —— 调研发现 legacy 实际只有 Telegram / Feishu / QQ 三个平台的 adapter，原方案文档误列 WeCom
- **flutter_secure_storage Windows ATL 限制** —— 用 `win32` 包直接调 Windows Credential Manager（CredWriteW / CredReadW / CredDeleteW），绕开 ATL；`lib/llm/oauth/windows_credential_storage.dart` 实现，`TokenStorage` 自动平台分发

### Memory 业务层（lib/memory/）— 完整翻译 legacy
- `session_summary.dart` —— 滚动摘要：两节格式（重要事实 / 事情经过）+ Token 预算线性缩放（10 轮封顶 400 字）+ 助手消息截断（300 字）+ PII redaction
- `memory_compile.dart` —— v3 四块独立编译（today / week / longterm / facts）+ MD5 指纹缓存（内容未变不调 LLM）+ assemble 拼 memory.md
- `memory_ticker.dart` —— turn-based 调度器：每 6 轮 / session 结束 / 每日（断点续跑用 `_dailyStepsCompleted`）
- `deep_memory.dart` —— 元事实拆分（LLM JSON 输出）+ 并发限制 3 + 重试 3 次 + 自动 markProcessed
- `memory_search.dart` —— 标签优先 + FTS 补充的混合搜索（< 3 条结果时自动触发 FTS）

### Bridge（lib/bridge/）— 完整翻译 legacy（含 WSClient → Webhook 替代）
- `lark_bridge.dart` —— 完整飞书集成
  - 接收：HTTP webhook（v2 event subscription，`im.message.receive_v1`）
  - 加解密：AES-256-CBC + PKCS7 padding（pointycastle 实现），key = SHA256(encrypt_key) 截 32 字节
  - 签名验证：sha256(timestamp + nonce + encrypt_key + body) hex
  - 发送：`tenant_access_token/internal` + `/open-apis/im/v1/messages`，token 自动缓存（提前 5 分钟过期）
  - URL 验证 challenge 自动响应

- `core/bridge_session_manager.dart` —— 完整 owner / guest 路由
  - sessionKey 解析（`tg_dm_*` / `fs_group_*` 等）
  - bridge-sessions.json 索引持久化
  - 自动订阅 adapter.messages 流
  - 收到外部消息 → 路由 → SessionCoordinator.prompt → adapter.send

### Channel（lib/channels/ + lib/core/）— 完整翻译
- `channel_store.dart` —— `.md` 文件读写
  - frontmatter（id/name/description/members）解析与序列化
  - 消息格式 `### {sender} | YYYY-MM-DD HH:mm:ss` + `---` 分隔
  - 创建 / 列表 / 删除 / 追加消息 / 读取最近 N 条 / agent 退群清理
- `core/channel_manager.dart` —— 包装 store，提供 listChannels / createChannel / deleteChannelByName / appendMessage / readRecent / cleanupAgentFromChannels（triage 留 Hub）

### Skill（lib/core/skill_manager.dart + lib/skill/）— 完整翻译
- SKILL.md frontmatter 解析（name / title→displayName / description）
- 全局 `skills/` + per-agent `learned-skills/` 双源扫描
- per-agent 隔离（learned skill 标 `_agentId`）
- `fs.watch` + 1s debounce 自动 reload + onReloaded 回调
- `getSkillsForAgent` 按 `agent.config.skills.enabled` 过滤 + 缺失诊断
- 执行机制保留 `lib/skill/skill_runner.dart` 外部进程协议

### UI 子窗口完整接入
- `editor_window.dart` —— 接 `re_editor` + `re_highlight`
  - 自动语言识别（dart/js/ts/json/md/py/yaml）
  - 暗色 / 亮色主题（atom-one-dark / atom-one-light）
  - 行号 + chunk indicator
  - Ctrl+S 保存（`Shortcuts` + `Actions`）
  - 修改标记（•）
- `browser_window.dart` —— 接 `desktop_webview_window`
  - `WebviewWindow.isWebviewAvailable()` 平台检测
  - 可用：`WebviewWindow.create` 打开内嵌窗（亮暗主题跟随）
  - 不可用（如 Linux WebKit）：降级到外部浏览器（url_launcher）
  - 地址栏可编辑

### Onboarding 5 步流程（对齐 legacy onboarding.html）
- Step 0：欢迎
- Step 1：助手名称 / yuan 模板 / 用户称呼
- Step 2：API 供应商（9 个 preset：OpenAI / Anthropic / DashScope / VolcEngine / MiniMax / DeepSeek / Moonshot / Ollama / 自定义）
- Step 3：模型 ID + API Key（Ollama 不需要）
- Step 4：确认配置 → 创建 agent + 写 config.yaml + 写 providers.yaml
- 每步右上角永远显示「跳过」（规避 BUG-5）

### Server 路由扩展（bin/server.dart）
新增对齐 legacy 的全套路由：
- `POST /api/agents`（创建）+ `DELETE /api/agents/<id>`（删除，自动清理频道成员）
- `PUT /api/agents/primary`（设为主 agent）
- `GET/PUT /api/agents/<id>/config`（read 时自动 redact api_key/secret/token）
- `GET/PUT /api/agents/<id>/identity` + `/ishiki`
- `GET/POST/DELETE /api/avatar/<role>`（base64 data URL 上传）
- `GET /api/diary/list` + `POST /api/diary/write`
- `GET /api/desk/activities` + `GET/POST /api/desk/cron`（add/remove/toggle/update）
- `GET/POST /api/desk/jian`（工作空间笔记）
- `GET/POST/DELETE /api/channels` + `GET/POST /api/channels/<id>/messages`
- `GET /api/skills`（按 active agent 的 enabled 过滤）
- `POST /api/bridge/lark/webhook`（按 preferences.bridge.feishu 配置自动构造 LarkBridge + register）
- `GET /api/bridge/status`
- `GET /api/providers` + `DELETE /api/providers/<id>`（事务清理）

### LLM utility
- `lib/llm/utility.dart` —— `callProviderText(provider, model, userContent, systemPrompt, temperature, maxTokens, timeout)` 通用同步 LLM 调用，给 memory compile / summary / triage 等场景用

### Windows 原生集成
- `lib/llm/oauth/windows_credential_storage.dart` —— 直接 FFI 调 Win32 Credential Manager
- `lib/llm/oauth/token_storage.dart` —— 平台自动分发：Windows 走 Credential Manager，其他平台走 `~/.hanako/oauth/{provider}.json`（POSIX 强制 chmod 600）

### 验证
- `flutter analyze` —— 0 errors（仅 lint info 与 1 个 deprecated 提示）
- `flutter test` —— 2/2 passed（widget smoke + Drift legacy 兼容）
- `flutter build windows --debug` —— 13.7s 增量通过

### 仍未完成（明确告知）
- ChannelTriage / Hub 自动判断回复（依赖 utility model 多轮 LLM 调用）—— Phase 5
- macOS Keychain / Linux libsecret backend（当前文件后备工作正常，非必需）—— Phase 5
- 对照 legacy 真实 SSE 录像的 snapshot 测试（需要真实 API key 录制）—— 用户实测后补
- 所有 lint info 修整（用 `?` null-aware 替代 `if (x != null) k: x` 等）—— 不影响功能

---

## [600.42.0] · 2026-04-26 · Flutter 全 Dart 重写

### 项目结构
- 原 Electron + Node.js 版本搬到 `legacy-electron/`（保留 git rename 历史，不删不改）
- 根目录变成 Flutter Desktop 项目骨架
- 三种运行形态共用 `lib/core/`：GUI / CLI / Server

### Phase 0 · Spike
- Flutter Desktop 项目骨架（windows/macos/linux 三平台）
- 单窗口 + Riverpod + dio + OpenAI 流式 spike
- PerfHUD 内置（fps/build/raster，FramePhase.vsyncStart）
- Windows runner 性能优化默认配置：
  - `NvOptimusEnablement` + `AmdPowerXpressRequestHighPerformance` 导出符号偏好高性能 GPU
  - `UIThreadPolicy::RunOnSeparateThread` 显式锁定线程策略
  - CMake `/utf-8` 编译选项（中文注释不再 C4819）
- Drift / sqlite3 跨平台 smoke test

### Phase 1 · 数据 + LLM
- **Drift schema** (`lib/memory/database.dart`)：与 legacy `better-sqlite3` 一致——单表 `facts` + FTS5 虚表 `facts_fts`，`user_version=1`
- **FactStore** (`lib/memory/fact_store.dart`)：add / addBatch / searchByTags / searchFullText / count / delete
- **LLM Provider 抽象** (`lib/llm/provider.dart`)：sealed `LlmEvent` 强制 exhaustive 处理
- **6 个 provider**：
  - `OpenAIProvider` — 标准 chat/completions
  - `AnthropicProvider` — Messages API + thinking 块
  - `DashScopeProvider` / `VolcEngineProvider` / `MiniMaxProvider` — extends `OpenAICompatibleProvider`
  - `CodexOAuthProvider` — OAuth + accountId 提取（直接合并原 codex-responses-patch.js 逻辑）
- **OAuth 三种 flow**：
  - `DeviceCodeFlow` — Codex / MiniMax 等
  - `AuthCodeFlow` — Anthropic / 通用 OAuth 2.0 + PKCE，本地 loopback HTTP server 接 callback
  - 直接 API key
- **TokenStorage**：Phase 1 文件后备（`~/.hanako/oauth/{provider}.json`），未来切 secure storage
- **`ProviderUnregistrar`**（事务清理，规避 BUG-1）：一次清 token / providers.yaml / agent config.yaml / models.json
- **`ProviderCredential` sealed class**（规避 BUG-2）：`ApiKeyCredential` 与 `OAuthCredential` 强制分离
- **PromptToolStreamParser**：跨 chunk 增量解析 `<tool_call>{json}</tool_call>` + `<think>...</think>`（防 N-BUG-1）

### Phase 2 · 业务核心 + Bridge + Skill + CLI/Server
- `HanaEngine` Facade，持有 8 个 Manager
- `AgentManager`：CRUD + 30s 缓存 + 按 preferences.primaryAgent 自动选取
- `SessionCoordinator`：createSession / switchSession / 流式 prompt / listSessions / 标题保存（jsonl 历史 + session-meta.json）
- `ConfigCoordinator`：YAML 读写 + FileSystemEvent 热更新（debounce 200ms）+ 共享模型配置
- `ModelManager`：凭据三层查找（providers.yaml → agent config → OAuth token）+ 启动期 OAuth 残留清理
- `PreferencesManager`：preferences.json 任意 key 读写
- `ChannelManager` / `BridgeSessionManager` / `SkillManager`：接口骨架
- `TelegramBridge`：HTTP long polling 完整实现（getUpdates + sendMessage）
- `SkillRunner`：外部进程协议（stdin/stdout JSON，LF 强制 + 超时控制）
- `YamlIo`：基于 `yaml_edit` 保留注释（防 N-BUG-7）
- **CLI** (`bin/hanako.dart`)：`agents list/create` / `chat --text` / `config` / `version`
- **Headless Server** (`bin/server.dart`)：shelf + shelf_router + shelf_web_socket，覆盖 legacy 主要路由：
  - `/api/health`, `/api/agents`, `/api/agents/switch`
  - `/api/sessions`, `/api/sessions/create`
  - `/api/preferences` (GET/PUT)
  - `/api/chat` (WebSocket，流式 message_update / message_end)

### Phase 3 · UI + 多窗口 + 桌面集成
- `desktop_multi_window` 接入：4 个独立窗口（Main / Settings / Editor / Browser）
- `WindowFactory`：`openSettings` / `openEditor` / `openBrowser`
- `IpcRegistry`：主窗口注册 IPC handler，子窗口通过 `business.invoke` 调用业务（`agents.list/create/switch/delete` / `preferences.read/write` / `sessions.list` / `config.read/update` / `model.unregister`）
- `SubWindowEngineClient`：子窗口 IPC 客户端封装
- 主窗口 `ChatPage` 接入 `HanaEngine.sessionCoordinator.prompt`，无 agent 时显示 `OnboardingPage`，仍保留 OpenAI key fallback
- `SessionDrawer`：侧边 session 列表（按 modified DESC）
- `OnboardingPage`：首次启动引导（含跳过按钮，规避 BUG-5）
- `SettingsWindow` 子窗口：列出 agents + 创建 / 切换 / 删除
- `EditorWindow` / `BrowserWindow`：骨架（Phase 3.5 接 re_editor / desktop_webview_window）
- 主题：`HanakoThemes.warmPaper()` + `dark()` + 系统跟随
- 桌面集成：`tray_manager` 系统托盘 + `hotkey_manager` Ctrl+Alt+= 全局快捷键 + `windows_single_instance` 单实例锁
- 主窗口默认配置：1280×800，最小 900×600，居中，普通标题栏

### Phase 4 · 打包 + 兼容验证 + 文档
- Windows release build 通过（84.8s，约 30MB）
- Inno Setup 安装包脚本模板（`installers/windows.iss`）
- macOS / Linux 打包配置就绪（需要对应平台机器构建）
- Drift schema 兼容验证测试（`test/drift_legacy_compat_test.dart`）：用 raw sqlite3 创建 better-sqlite3 等价 schema，再用 Drift 打开 + 写读
- 完整 README + CHANGELOG

### 不带过去的 BUG（来自 legacy）
- ✅ BUG-1：OAuth logout 后 `api_provider` 残留 → `ProviderUnregistrar` 事务清理
- ✅ BUG-2：`api_key` 字段混存 OAuth token → sealed `ProviderCredential`
- ✅ BUG-3：fork 后 PATH 不完整 → 直接 `Platform.environment` + 无子进程
- ✅ BUG-4：频道异常静默失败 → sealed `BridgeResult`
- ✅ BUG-5：Onboarding 缺跳过按钮 → 右上角永远显示「跳过」
- ✅ Better-sqlite3 native rebuild → 整条 electron-rebuild 链路消失
- ✅ Skill Viewer / DevTools 独立窗口 → Modal / Flutter Inspector 替代
- ✅ Splash 独立窗口 → 主窗口启动 Route
- ✅ Codex Responses Patch 单独 patch 文件 → 合并进 `CodexOAuthProvider`

### 性能基线（Windows debug build）
- 编译：增量 ~10s，全量 ~85s（release）
- 启动：~1-2s（含 engine 初始化）
- 主窗口空载内存：~80MB（debug）
- PerfHUD 显示 fps + p5 + p95 + build/raster ms

### 已知限制
- `flutter_secure_storage` Windows 实现需要 ATL（VS C++/MFC 组件），暂用文件后备
- dart compile exe (CLI/server) 受 dart 3.10 build hooks 限制，临时用 `dart run`
- Skill JS 通过 `node skill.js` 兼容，未提供自动迁移工具
- WeCom / Lark Bridge 仅接口骨架，Telegram 完整实现
- macOS notarize / Linux AppImage 打包待对应平台机器
