# Agent Runtime 对齐清单

本文用于对齐当前 Flutter 子体客户端、PH01 AI 网关与原 Hanako TS 版的 Agent 执行模型。

## 对照基线

- 原 TS 入口：`legacy-electron/core/session-coordinator.js`
- 原 Agent loop：`legacy-electron/node_modules/@mariozechner/pi-agent-core/dist/agent-loop.js`
- 原 session 持久化：`legacy-electron/node_modules/@mariozechner/pi-coding-agent/dist/core/session-manager.js`
- 原 provider 转换：`legacy-electron/node_modules/@mariozechner/pi-ai/dist/providers/*`
- 原 prompt tool 包装：`legacy-electron/lib/llm/prompt-tool-provider.js`
- 当前 Flutter：`hanako-flutter/lib/core/session_coordinator.dart`
- 当前网关：`ph01-ai-gateway/relay/markdowntools/markdown_tools.go`

## 必须直接搬运的契约

### 1. Agent loop 状态机

原版不是单轮请求拼接，而是固定状态机：

```text
user prompt
  -> assistant stream
  -> if assistant has toolCall:
       execute every tool call
       append toolResult messages
       continue from toolResult
  -> repeat until no toolCall
```

必须保持：

- 不设置任意“工具轮次上限”。
- 工具执行失败要返回 `toolResult(isError=true)`，继续交给模型处理。
- 上游 LLM/API 错误才中断当前流。
- 用户插话/排队消息可以跳过剩余工具，并给跳过的工具补 `toolResult`。

### 2. 消息模型

原版内部消息不是扁平字符串，而是 block 结构：

- `user.content[]`
- `assistant.content[]`
  - `text`
  - `thinking`
  - `toolCall`
- `toolResult.content[]`

当前 Flutter 的 `Message(role, content)` 只能显示文本，不能作为 runtime 内核模型。需要新增内部 runtime message，UI 再投影为可见文本。

### 3. Session JSONL

原版 session JSONL 是 entry tree：

- 首行 `type=session`
- 后续 entry 带 `id` / `parentId`
- message entry 中保存完整消息对象
- 支持分支、标题、compaction、model/thinking 变更

当前 Flutter 直接写 `{role, content}`，会丢：

- assistant tool calls
- tool results
- thinking blocks
- stopReason/error metadata
- 分支结构

短期可兼容旧格式读取，但新写入应按原版 entry 语义靠拢。

### 4. Provider 边界转换

原版的 provider 层负责把内部消息转换为具体 API：

- OpenAI：assistant `toolCall` -> `tool_calls`，`toolResult` -> role `tool`
- Gemini：assistant `toolCall` -> `functionCall`，`toolResult` -> `functionResponse`
- Thinking / thought signature 只在 provider 边界处理

PH01 架构中该职责属于 AI 网关。客户端仍只发送标准 OpenAI function call；网关负责 Gemini/OpenAI/Claude 等渠道转换。

### 5. Prompt tool / Markdown AST 包装

原 TS 版已有 `prompt-tool-provider.js`，核心契约是：

- 请求前把 native tools 转为 system prompt 工具协议。
- 历史 assistant toolCall 序列化为文本协议。
- 历史 toolResult 序列化为 user 消息。
- 响应文本解析为内部 toolCall。
- 工具协议片段未完整闭合前不能透给 UI。

当前项目改成 Markdown AST 语法，这是产品要求，可以不搬 `<tool_call>` JSON 语法，但必须搬上述边界行为。

## 当前偏差

### Flutter 子体

- `SessionCoordinator.prompt()` 是手写 loop，已经接近原状态机，但仍没有独立 runtime message 层。
- 当前持久化已开始保存 `tool_calls` 和 `tool`，但仍是 OpenAI JSON 形态，不是原版 entry tree。
- `_loadMessages()` 只给 UI 读可见文本，这是对的；但 `_loadRequestMessages()` 才是上下文来源，必须有回归测试保证 toolCall/toolResult survives restart。
- `_appendFailedTurn()` 把 API 错误作为 assistant 文本写入，会进入后续请求上下文。原版会持久化错误，但 provider 转换会跳过 error/aborted assistant。这里需要单独定策略。

### AI 网关

- `ApplyRequest()` 已按“标准 OpenAI function call -> Markdown AST prompt”走。
- `TransformStreamResponse()` 负责“Markdown AST -> OpenAI tool_calls”。
- 已修一处 start marker 跨 chunk 泄露风险，但 parser 应继续按原 prompt-tool provider 的原则补测试：
  - 起始标签多段切开
  - 结束标签多段切开
  - 工具块里有 Markdown heading
  - 不完整工具块 flush 回正文
  - thinking/reasoning 字段内的工具块不执行

### 工具面

- 原版内置基础工具是 `read/bash/edit/write/grep/find/ls`。
- 当前 Flutter 已实现同名工具，并加了 Windows 操作扩展。
- 当前还注册了很多原版 custom tools 的占位实现；这可以保留，但不能让模型误以为已完整可用。占位工具返回的 error 必须作为 `toolResult` 继续给模型。

## 下一轮修复顺序

1. 抽出 Dart 版 `AgentRuntimeLoop`，按 `agent-loop.js` 状态机重写当前 `SessionCoordinator.prompt()`。
2. 新增 `RuntimeMessage` / `RuntimeContentBlock`，UI 使用投影，不再让 OpenAI JSON 直接兼任内部模型。
3. 新增 session entry writer/reader，兼容读取旧 `{role, content}`，新写入原版 entry tree。
4. 给“工具调用后重启仍能继续”补回归测试。
5. 给网关 Markdown AST stream parser 补完整切块测试。
6. 再重新打包客户端，并重新部署网关。

## 需要确认的一点

原版对 LLM/API 级错误的策略是：错误消息可保存在 session 文件中，但再次构造请求时跳过 `stopReason=error/aborted` 的 assistant。当前用户预期是“报错后说继续能接上”。这两者可以兼容：UI 显示错误，runtime 请求上下文回到最后一个有效 assistant/toolResult 状态，再追加用户的“继续”。
