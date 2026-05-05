# 04 · BUG 甄别与重写策略

> 重写不是修复 BUG 的银弹，但**已知 BUG 不应该被重新引入**。本章列出每个观察到的疑似异常，并明确：
> - 🟢 **真功能** —— 保留
> - 🔴 **已知 BUG** —— 重写时主动规避
> - 🟡 **历史 workaround** —— 评估后选择丢弃或简化
>
> 另外 4.13 节列出 Dart 重写**专属的新风险**，避免迁移过程引入新一批 BUG。

## 4.1 OAuth 相关（最近 3 个 commit 集中修）

### 🔴 BUG-1：`api_provider` 字段在 OAuth logout 后残留
- **现状**：`config.yaml` 持有 `api_provider: openai-codex`，OAuth 登出只清了 token 文件；下次启动 Pi SDK 看到 provider 名又走 OAuth 路径，找不到 token → "Failed to extract accountId from token"
- **commit**：`d3f0544` / `66d2164` / `3083e69`
- **Dart 重写策略**：
  ```dart
  class ProviderUnregistrar {
    final HanaDatabase _db;
    final ConfigCoordinator _config;
    final SecureStorage _secure;

    Future<void> unregister(String providerName) async {
      await _db.transaction(() async {
        await _purgeFromAuthFile(providerName);       // 1. 删 token 文件
        await _purgeFromProvidersYaml(providerName);  // 2. 改 providers.yaml
        await _purgeFromConfigYaml(providerName);     // 3. 清 config.yaml 引用
        await _invalidateInMemoryCache(providerName); // 4. 清内存缓存
      });
    }
  }
  ```
  Drift transaction 包住所有清理，**原子性**——要么全成功要么全回滚。
- **不带过去**：原代码的「启动期清理」是补丁式修复，新版本应该让 logout 操作本身就完整，启动期不需要 fallback

### 🔴 BUG-2：getAllProviders 把 OAuth token 回填到 api_key 字段
- **现状**：清理逻辑曾写 `if (!api_key) purge`，但内部 `getAllProviders` 把 token 当 api_key 返回，导致清理永远不触发
- **commit**：`66d2164`
- **Dart 重写策略**：
  ```dart
  // ✅ Dart 端 sealed class
  sealed class ProviderCredential {
    const ProviderCredential();
  }
  class ApiKeyCredential extends ProviderCredential {
    final String apiKey;
    const ApiKeyCredential(this.apiKey);
  }
  class OAuthCredential extends ProviderCredential {
    final String accessToken;
    final String? refreshToken;
    final DateTime? expiresAt;
    final String? accountId;       // 解决 BUG-1 的根因字段
    const OAuthCredential({
      required this.accessToken,
      this.refreshToken,
      this.expiresAt,
      this.accountId,
    });
  }
  ```
  Dart 的 `switch` exhaustive 检查保证 ApiKey 与 OAuth **永不混用**。
- **不带过去**：JS 弱类型让这个 bug 容易出现，Dart 强类型 + 严格模式天然避免

## 4.2 Windows 平台兼容（多个 commit 反复修）

### 🟢 功能：bash 候选过滤 WSL launcher
- **commit**：`732b6c2`
- **判定**：保留——Windows 上 WSL 跨文件系统访问 `/mnt/c/...` 极慢，主动避开是正确选择
- **Dart 重写策略**：
  ```dart
  Future<String?> findBash() async {
    final result = await Process.run('where', ['bash']);
    final candidates = (result.stdout as String).split('\n')
      .map((s) => s.trim())
      .where((p) => p.isNotEmpty)
      .where((p) => !p.toLowerCase().contains(r'system32\bash.exe'))  // 滤掉 WSL launcher
      .toList();
    return candidates.firstOrNull;
  }
  ```

### 🟢 功能：bash spawn 失败时降级到 cmd.exe
- **commit**：`da7583f`
- **判定**：保留——是合法降级
- **Dart 重写策略**：实现 `ShellRunner` 抽象，按 platform 选择最佳 shell

### 🔴 BUG-3：fork 后 PATH 不完整（macOS GUI 应用）
- **commit**：`da7583f`
- **现状**：Electron fork 不继承登录 shell 环境变量
- **Dart 重写策略**：
  ```dart
  Future<String> ensureCompletePath() async {
    if (!Platform.isMacOS) return Platform.environment['PATH'] ?? '';
    // GUI 应用启动的 PATH 不含 /usr/local/bin 等，从登录 shell 拿
    final r = await Process.run('/bin/zsh', ['-l', '-c', 'echo \$PATH']);
    return (r.stdout as String).trim();
  }
  ```
  注：Skill 子进程启动时把这个补全的 PATH 传进去，确保 `git` / `node` / 等命令能找到。

## 4.3 频道与 Bridge

### 🔴 BUG-4：频道发送异常静默失败
- **commit**：`acd4766`
- **Dart 重写策略**：sealed class `BridgeResult` 强制处理错误分支
  ```dart
  sealed class BridgeResult {}
  class BridgeSuccess extends BridgeResult { final String messageId; }
  class BridgeError extends BridgeResult {
    final String reason;
    final String? remoteCode;
  }
  ```
  调用方 `switch` 必须穷尽所有分支，**无法吞错**。

## 4.4 模型回退（Fallback Chain）

### 🟡 待评估：模型不可用时的链式回退
- **判定**：是产品功能（用户期望模型挂掉时自动切下一个）
- **Dart 重写策略**：保留功能，但 fallback 决策**必须显式给用户提示**——`FallbackBanner` widget，每次回退弹 toast 或顶部 banner
  ```dart
  class FallbackBanner extends ConsumerWidget {
    @override
    Widget build(BuildContext context, WidgetRef ref) {
      final fallback = ref.watch(modelFallbackEventProvider);
      if (fallback == null) return const SizedBox.shrink();
      return MaterialBanner(
        content: Text('模型 ${fallback.from} 不可用，已切换到 ${fallback.to}'),
        actions: [
          TextButton(
            onPressed: () => ref.read(modelManagerProvider).pinModel(fallback.from),
            child: const Text('坚持使用'),
          ),
          TextButton(
            onPressed: () => ref.read(modelFallbackEventProvider.notifier).dismiss(),
            child: const Text('知道了'),
          ),
        ],
      );
    }
  }
  ```

## 4.5 Onboarding

### 🔴 BUG-5：Onboarding 缺少跳过按钮
- **commit**：`9ca1600`
- **Dart 重写策略**：Onboarding 路由从设计阶段就要求「每一步都可跳过」+「右上角永远有跳过按钮」

## 4.6 Codex 认证文件兼容

### 🟡 历史 workaround：Codex auth 文件格式兼容
- **commit**：`7c5c28c` / `lib/llm/codex-responses-patch.js`
- **判定**：是真实需求（用户从 OpenAI 官方工具导出），但 patch 文件本身是补丁
- **Dart 重写策略**：直接合并进 `CodexOAuthProvider` 的解析路径，**不保留 "patch" 这个概念**
- **风险点**：Pi SDK 内部对 Codex token 的处理可能有未文档化细节，需要把 patch 逻辑 + Pi SDK 内部逻辑一起重写并对齐

## 4.7 Markdown 渲染

### 🟢 功能：图片占位符
- **commit**：`e764388`
- **判定**：是 markdown-it 的合理行为，看起来像 BUG 实际是设计

## 4.8 Splash / 启动体验

### 🟡 Splash 窗口
- **判定**：Electron 现状是独立 BrowserWindow，**重写时改为主窗口的启动屏 Route**——少一个窗口少一份内存
- **Dart 重写策略**：
  ```yaml
  flutter_native_splash: ^2.4.0
  ```
  - `flutter_native_splash` 给冷启动一个静态画面（启动期 0-500ms）
  - Flutter 启动后切到 Lottie 动画 Route（500ms - Engine ready）
  - Engine ready 后切到主聊天 Route

## 4.9 Server 启动失败处理

### 🟡 Electron 现状：30s 超时硬等
- **现状**：`desktop/main.cjs` 给 server fork 30s 超时，超时直接报错退出
- **Dart 重写策略**：**Option A 下根本没有 server 子进程**，Engine 初始化在主进程内同步执行。失败时给三个选项：
  - 「重试」（再 init 一次）
  - 「重置配置」（备份当前 config.yaml 并写入默认值）
  - 「联系支持」（导出诊断日志压缩包）

## 4.10 Better-sqlite3 native rebuild

### 🟢 整条编译链路消失
- **现状**：`postinstall` 跑 `electron-rebuild -f -w better-sqlite3`，每次依赖变更都要重编译 native
- **Dart 端**：drift + sqlite3 (Dart) **纯 Dart**。Windows 用 `sqlite3_flutter_libs` 自带 dll，macOS/Linux 系统自带或自带 dylib
- **影响**：CI 时间从「每次 install 5+ min」降到「pub get 30s」

## 4.11 「不带过去」综合清单（Option A）

| # | 项 | 替代方案 |
|---|----|---------|
| 1 | OAuth logout 启动期 fallback 清理 | logout 本身事务性，Drift transaction 包住 |
| 2 | api_key 字段混存 OAuth token | sealed class `ProviderCredential` |
| 3 | Skill Viewer / DevTools 独立窗口 | Modal / Flutter Inspector |
| 4 | Splash 独立窗口 | 主窗口启动 Route |
| 5 | Codex Responses Patch 单独 patch 文件 | 合并进 `CodexOAuthProvider` |
| 6 | 频道异常静默 | sealed class `BridgeResult` + 错误事件 |
| 7 | better-sqlite3 native rebuild + electron-rebuild | drift 纯 Dart |
| 8 | Server 启动失败默默退出 | 重试 + 用户可操作错误 |
| 9 | 模型 fallback 静默切换 | `FallbackBanner` widget 显式提示 |
| 10 | preload.cjs 的 contextBridge 沙箱模型 | Dart 函数直接调用，无沙箱边界 |
| 11 | IPC handler 散落 main.cjs 各处 | `lib/app/ipc_registry.dart` 集中注册 |
| 12 | Server fork 后 PATH 注入 workaround | 不需要 fork；自身需要 PATH 时主动 zsh -l 拿 |

## 4.12 「确认保留」综合清单

| # | 项 | 重要性 | 实现要点 |
|---|----|--------|---------|
| 1 | Plan Mode（read-only 工具集） | 核心 | UI toggle + 工具白名单 enum |
| 2 | Memory 高斯衰减 + Fact Store | 核心 | Drift + 后台 isolate ticker |
| 3 | Desk 系统（时间线、Cron 自动化） | 核心 | UI 重写 + cron 包 |
| 4 | Bridge（Telegram / WeCom / 飞书） | 重要 | teledart + dio |
| 5 | Skill 系统（GitHub 同步 + 本地安装） | 重要 | 外部进程模型 |
| 6 | 多 Agent / 频道协作 | 重要 | ChannelManager Dart 化 |
| 7 | 流式输出（thinking + text_delta + toolcall） | 核心交互 | StreamingMessageWidget |
| 8 | Session 分支（branching） | 重要 | UI 用 Tree widget 展示 |
| 9 | YAML 热更新配置 | 维护友好 | yaml_edit + FileSystemEvent |
| 10 | 模型 fallback chain | 用户体验 | 必须显式提示（见 4.4） |
| 11 | i18n（zh-CN / en） | 用户体验 | intl + .arb |
| 12 | 多主题（warm-paper / dark） | 用户体验 | ThemeData 重写 |
| 13 | CLI 模式 | 工具属性 | `bin/hanako.dart` |
| 14 | Headless server 模式 | 工具属性 | `bin/server.dart` shelf |

## 4.13 Dart 重写专属新风险（迁移过程要主动防范）

迁移过程可能引入的**新 BUG 类**：

### 🔥 N-BUG-1：SSE 解析器跨 chunk 边界处理
- **风险**：dio 流式响应是按 TCP chunk 给的，可能在 SSE event 中间切断；naive 实现会丢字段
- **防范**：用 `LineBuffer` 跨 chunk 累积，遇到 `\n\n`（event 分隔）才 emit
- **测试**：单测构造极端 chunk（每字节一个）验证

### 🔥 N-BUG-2：Pi SDK 行为隐式约定未对齐
- **风险**：Pi SDK 内部对 Anthropic thinking 块 / 工具调用 args 拼接的逻辑可能有未文档化细节，Dart 端漏实现导致流式渲染错位
- **防范**：搭一个对照测试——录制 10 个 Electron 端真实对话的原始 SSE 流，回放给 Dart 解析器，结果与 Electron 端 UI 渲染对齐
- **测试**：snapshot 测试

### 🔥 N-BUG-3：Drift schema 与 better-sqlite3 schema 漂移
- **风险**：Drift 的列定义与原 schema 一字之差，旧 db 打不开
- **防范**：写 `tools/dump_legacy_schema.js` 从 Electron 端导出当前 schema 完整 SQL，Dart 端 Drift schema 用相同字段顺序、类型、默认值
- **测试**：拷贝一份现有用户的 facts.db 到测试目录，跑 Drift 打开 + 查询，验证结果一致

### 🔥 N-BUG-4：Skill 外部进程协议不稳定
- **风险**：stdin/stdout 协议可能因为换行符（CRLF vs LF）、buffer flush 时机、stderr 误解析导致跨平台行为不一致
- **防范**：协议固定 LF（`Process.start` 配 `runInShell: false`）；skill 输出强制单行 JSON + 结束标志
- **测试**：跨平台 integration test

### 🔥 N-BUG-5：OAuth 凭据存储跨平台差异
- **风险**：`flutter_secure_storage` 在 Linux 上用 libsecret，需要用户系统装 gnome-keyring 或 kwallet
- **防范**：检测失败后降级到加密文件（基于设备指纹派生 key）
- **测试**：headless Linux（CI）验证降级路径

### 🔥 N-BUG-6：Drift 写入并发冲突
- **风险**：UI 线程 + ticker 后台 isolate 同时写 Drift，可能锁等待
- **防范**：用 Drift 的 `MultiExecutor` 或单一 isolate 处理写入；读用 background isolate
- **测试**：压测高频写入

### 🔥 N-BUG-7：YAML 写回丢注释
- **风险**：原始 `yaml_writer` 序列化会丢失注释和顺序，热更新后用户的注释消失
- **防范**：用 `yaml_edit` 包做"原文修改"而非完全重写
- **测试**：保留 1 份带注释的 sample config，verify 写回不丢

### 🔥 N-BUG-8：跨 isolate 数据传递性能
- **风险**：Dart isolate 间传递大对象（消息列表）会复制；流式渲染如果跨 isolate 会卡顿
- **防范**：streaming 在 main isolate；只把重计算（高斯衰减、向量检索）放后台 isolate
- **测试**：性能基准（每秒 50 条 text_delta 流畅渲染）

### 🔥 N-BUG-9：desktop_multi_window 子窗口插件未注册
- **风险**：子窗口 main 函数缺 `DartPluginRegistrant.ensureInitialized()`，部分插件 method channel 失效
- **防范**：每个 SubWindowApp 启动第一行就调
- **测试**：smoke test 启动每个子窗口确认插件可用

### 🔥 N-BUG-10：Codex device-code 轮询竞态
- **风险**：用户授权后轮询响应可能晚于 expires_in，导致显示「超时」实际已成功
- **防范**：轮询间隔严格按服务端 `interval` 字段；超时后再额外宽限 30s
- **测试**：mock OAuth server 模拟边缘时序

### 🔥 N-BUG-11：业务调用阻塞主窗口 IPC
- **风险**：子窗口通过 `business.invoke` 触发耗时业务（如全量同步）会阻塞主窗口 method handler
- **防范**：长任务在 main isolate 内 `compute()` / `Isolate.run()` 异步执行；IPC handler 立即返回 task id，进度通过事件流推送
- **测试**：UI 卡顿监控

### 🔥 N-BUG-12：CLI / Server 模式下没有 Flutter binding
- **风险**：`lib/core/` 里如果误用了 Flutter API（如 `WidgetsBinding`），CLI/Server 模式直接崩
- **防范**：`lib/core/` 严禁 import `package:flutter/*`；只用 `dart:*` 与纯 Dart 包；CI 加 lint 规则
- **测试**：`dart compile exe bin/hanako.dart` 通过即可证明无 Flutter 依赖

## 4.14 重写规则总结

1. **强类型先行**：Dart 端用 `sealed class` / `freezed` / `enum` 表达状态机，避免 JS 弱类型导致的字段混淆
2. **显式失败**：所有可失败操作返回 `Result<S, E>` 或 `sealed class`，绝不静默吞错
3. **事务性写入**：涉及多个文件的状态变更（如 OAuth logout）必须包装成 Drift transaction，要么全成功要么全回滚
4. **可测试性**：UI 组件保持纯函数，状态变更经 Riverpod；副作用（HTTP / FS）经 Repository 抽象方便 mock
5. **不要复制 BUG**：每次实现一个原 Electron 功能时，先看 git log 该模块最近 5 个 commit 是否有修复，把修复合入新实现
6. **lib/core/ 零 Flutter 依赖**：保证 CLI / Server 模式可以脱离 UI 运行
