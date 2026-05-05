# Flutter 重构方案（实施文档）

> 本目录独立于现有 `openhanako` 代码，未触碰任何项目文件。
> 任何时候都可以查阅。
>
> **执行决策：Option A · 全 Dart 重写。**

## 目录

| # | 文件 | 用途 |
|---|------|------|
| 0 | [README.md](./README.md) | 索引 + 总览 |
| 1 | [01-架构与可行性评估.md](./01-架构与可行性评估.md) | 单 Dart App 架构 + 可行性 |
| 2 | [02-多窗口实现方案.md](./02-多窗口实现方案.md) | 插件选型 + 窗口映射 + IPC |
| 3 | [03-模块迁移清单.md](./03-模块迁移清单.md) | 每个 npm 依赖的 Dart 等价 + 业务模块设计 |
| 4 | [04-BUG甄别与重写策略.md](./04-BUG甄别与重写策略.md) | BUG 不带过去 + Dart 重写专属新风险 |
| 5 | [05-分阶段路线图与风险.md](./05-分阶段路线图与风险.md) | Phase 0–4 + 风险登记册 |
| - | [pubspec.yaml.template](./pubspec.yaml.template) | 完整依赖清单（含后端模块） |

## 核心结论

✅ **架构**：Flutter Desktop **纯 Dart 单进程**——业务核心、LLM 适配、SQLite 存储、IM Bridge、CLI/Server 模式全部 Dart 化。无 Node.js 运行时、无 Electron BrowserWindow。

✅ **多窗口插件**：选 **`desktop_multi_window`**（详见 [02 章节](./02-多窗口实现方案.md)）。

✅ **窗口收敛**：8 → 4 个独立窗口 + Modal/Route。

✅ **三形态共用同一份 lib/**：
- `flutter run` / 平台二进制 → GUI 模式
- `dart compile exe bin/hanako.dart` → CLI 模式（替代 `index.js`）
- `dart compile exe bin/server.dart` → Headless server 模式（替代 `server/boot.cjs`）

## 项目目录骨架（Dart 端）

```
hanako/
├── lib/
│   ├── main.dart                   # Flutter 入口
│   ├── app/                        # App 启动、Window 工厂、IPC registry
│   ├── core/                       # Engine + 各 Manager（替代 core/*）
│   ├── llm/                        # Provider 适配（替代 Pi SDK + lib/llm/）
│   ├── memory/                     # 记忆系统（Drift + 高斯衰减）
│   ├── bridge/                     # Telegram / WeCom / 飞书
│   ├── skill/                      # Skill 注册 + 外部进程执行
│   ├── ui/                         # Flutter UI / 主题 / i18n
│   ├── server/                     # 可选 Dart shelf headless server
│   └── shared/                     # Result / Logging / Platform 工具
├── bin/
│   ├── hanako.dart                 # CLI 入口
│   └── server.dart                 # Server 模式入口
├── test/                           # 单测 + widget 测试
├── integration_test/               # 端到端 + OAuth 流程
├── windows/  macos/  linux/        # Flutter 平台脚手架
└── pubspec.yaml
```

## 三个最大的执行难点

1. **Pi SDK 完全替代** —— 6 个 LLM provider + 工具调用 + thinking 块 + 三种 OAuth flow 全要 Dart 重写。OpenAI 兼容层让国内 5 家用同一套实现，主要工作量集中在 Anthropic SSE 解析与 Codex device-code OAuth。
2. **better-sqlite3 → Drift** —— schema 完全保留，提供 Drift migration 让现有用户的 `~/.hanako/agents/*/memory/facts.db` 直接可读，不破坏存量数据。
3. **Skill 沙箱模型变更** —— Dart 不能 eval 任意脚本，建议改为「外部进程 + stdin/stdout 协议」。这是 breaking change，迁移期可通过 `node` 命令兼容现有 JS skill。

## 一句话给"一晚上"的实事求是

Spike 一晚上可行（最小可跑路径：单窗口 + OpenAI 流式 + 一条 session）。但要达到「能替代当前 Electron 版本」的稳定度，**OAuth 三套 flow 调试 + Pi SDK 行为逐字段对齐 + 跨平台测试**通常吃掉总工时 40%+，建议把这部分缓冲算进去。详见 [05 章节](./05-分阶段路线图与风险.md)。

## BUG 不带过去（精简版）

| # | 项 | Dart 端替代 |
|---|----|------------|
| 1 | OAuth logout 启动期 fallback 清理 | logout 方法用 Drift transaction 包住，无需启动期补救 |
| 2 | api_key 字段混存 OAuth token | sealed class `ProviderCredential` 区分 ApiKey / OAuth |
| 3 | 频道异常静默 | sealed class `Result<S, E>` 显式返回 |
| 4 | Splash / Skill Viewer / DevTools 独立窗口 | Modal / Flutter Inspector |
| 5 | Codex Responses Patch 单独 patch 文件 | 合并进 `CodexOAuthProvider` 主路径 |
| 6 | better-sqlite3 native rebuild + electron-rebuild | Drift 纯 Dart，整条编译链路消失 |
| 7 | 模型 fallback 静默切换 | `FallbackBanner` widget 显式提示用户 |
| 8 | preload.cjs / contextBridge 沙箱模型 | Dart 函数直接调用，无沙箱边界 |

详见 [04 章节](./04-BUG甄别与重写策略.md)。

## 现状数据（对比基线）

| 指标 | Electron 现状 | Flutter (Option A) 预期 |
|------|--------------|------------------------|
| 总代码量 | ~35K LOC | ~28-32K LOC（Dart 更紧凑） |
| 进程数 | 3+（main / server / renderer） | **1** |
| 安装包体积 | ~150 MB | **~60 MB** |
| 主窗口空载内存 | ~250 MB | **~80 MB** |
| 冷启动时间 | 3-5 s | **1-2 s** |
| UI 帧率 | 受 Chromium 限制 | Skia 直接渲染，60+ FPS |
| 跨平台一致性 | 极高 | 高 |
