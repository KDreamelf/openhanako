# 上下文撑满 / 总结压缩设计

> 调研日期：2026-05-19  
> 决策来源：参考 `claude-code-main` `src/services/compact/` 完整生态，落地到 Hanako 的简化版。

---

## 1. CC 的完整设计（事实摘要）

### 1.1 阈值体系

CC 把"上下文压力"分四档，全部基于模型实际上下文窗口动态计算：

```
有效窗口 effectiveContextWindow = model.contextWindow - reservedForSummary
   reservedForSummary = min(model.maxOutputTokens, 20_000)
   // 据 CC p99.99 实测：压缩 summary 输出通常 <17K，留 20K 安全

阈值（自上而下递进）：
   AUTOCOMPACT_BUFFER_TOKENS  = 13_000
   WARNING_THRESHOLD_BUFFER   = 20_000
   ERROR_THRESHOLD_BUFFER     = 20_000
   MANUAL_COMPACT_BUFFER      =  3_000

autoCompactThreshold = effectiveWindow - AUTOCOMPACT_BUFFER          # 自动压缩触发
warningThreshold     = autoCompactThreshold - WARNING_THRESHOLD_BUFFER  # UI 警告
errorThreshold       = autoCompactThreshold - ERROR_THRESHOLD_BUFFER    # 严重警告
```

举例：200K 上下文 + 32K 输出预算模型 → 有效窗口 ~180K，autocompact 触发于 167K，warning 触发于 147K（≈ 73%）。

### 1.2 触发机制

| 触发方式 | 条件 | 谁来 |
|---|---|---|
| 自动 | tokenUsage ≥ autoCompactThreshold | 下一轮发起前 |
| 手动 | `/compact` slash 命令 | 用户主动 |
| 部分压缩 (microCompact) | 单一工具输出过大 | API 层自动 |

熔断器：连续 `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3` 次失败就停 —— 防止 `prompt_too_long` 死循环（CC 实测 1279 个 session 出现过 50+ 次连续失败浪费 25 万 API 调用）。

### 1.3 压缩流程（compact.ts）

1. **收集**所有 message（含 user / assistant / tool_use / tool_result / attachment）
2. 调主对话模型（`getMainLoopModel`），用 `getCompactPrompt` 提示词做总结
3. 模型按 **10 节模板**返回：
   - Primary Request and Intent
   - Key Technical Concepts
   - Files and Code Sections（包含完整代码片段 + 改动原因）
   - Errors and fixes（含用户反馈）
   - Problem Solving
   - **All user messages**（完整列出，不能丢）
   - Pending Tasks
   - Current Work（最近一段的精确细节 + 模型最后的位置）
   - Optional Next Step（含**用户最近一次原话的 verbatim 引用**，防止解释漂移）
4. summary 用 `<analysis>` + `<summary>` 双段包裹，`<analysis>` 是模型的草稿，被剥掉不进 context
5. 创建 `CompactBoundaryMessage`（特殊 system message 类型）
6. 后续 `normalizeMessagesForAPI` 按 boundary 把 history 拆前后两段：
   - boundary 之前 → 用 summary 替代
   - boundary 之后 → 原样保留
7. **post-compact 清理**：自动重注入 boundary 之前**仍活跃**的：
   - 用户 plan（`getPlanFilePath`）
   - 最近读过的关键文件（最多 5 个 / 每个 5K token / 总预算 50K）
   - 当前启用的 skills（每个 5K token / 总预算 25K）
   - tool discovery 增量（toolSearch）
   - agent 列表、MCP 指令的变化

### 1.4 关键设计点

- **"No tool" 前导**：压缩调用本身用 `maxTurns: 1` + 强提示"REJECT all tool calls"——模型偶尔会忍不住调工具读文件验证，但本轮被拒后失去文本输出。CC 实测 Sonnet 4.6 上无 preamble 时 2.79% 会失败，加 preamble 后 0.01%。
- **`CompactBoundaryMessage` 持久化**：boundary 写入 session 转录文件；下次启动也按它截断历史。
- **prompt cache 友好**：boundary 之后的消息 prefix 稳定，能命中前缀缓存。

### 1.5 UI 警告

- token 用量超过 warning threshold 时，UI 顶部显示提示条："上下文还剩 X%"
- 超过 error threshold 颜色升级
- 用户可以手动 dismiss（`compactWarningStore`）

---

## 2. Hanako 的现状差距

| 能力 | CC | Hanako 现状 |
|---|---|---|
| 知道模型 context window | 内置每 model 元数据 | **没**——`ModelInfo` 只有 id + name |
| 跟踪当前 token usage | 从 API response.usage 字段 | **没**——chat events 流没解析 usage |
| 上下文窗口 telemetry | 完整 | **没** |
| 压缩边界标记 | `CompactBoundaryMessage` 特殊类型 | **没**——session jsonl 是平铺消息 |
| 压缩调用 | 主对话模型 + 严格 prompt | **没**——前面有删掉的 session_summary，但风格完全不同 |
| post-compact 重注入 | 自动 plan / 文件 / skills | **没**——需要新建路径 |
| UI 警告 | 顶部条 + 颜色升级 + dismiss | **没** |

---

## 3. Hanako 实施方案（5 阶段）

按依赖排序，每阶段独立 commit + 可验证。

### 阶段 1：基础测量（不动行为，只看数据）

**目标**：让客户端知道"当前对话用了多少 token / 该模型上限多少"。  
**不做**：任何压缩动作。

变更：

- `lib/core/model_manager.dart`：`ModelInfo` 新增 `contextWindow` / `maxOutputTokens` 字段（int）
- 一个 model 元数据 JSON（`assets/model_metadata.json` 或硬编码 map），按 model id 注入 context window 与 max output：
  ```jsonc
  {
    "gpt-5.5":           { "contextWindow": 200000, "maxOutputTokens": 32000 },
    "gpt-5.4":           { "contextWindow": 128000, "maxOutputTokens": 16000 },
    "LongCat-Flash-Chat":{ "contextWindow":  64000, "maxOutputTokens":  8000 },
    "LongCat-Flash-Lite":{ "contextWindow":  64000, "maxOutputTokens":  8000 }
  }
  ```
  未列入的 model 给默认值（128K / 8K）。
- `lib/llm/provider.dart`：新增 `TokenUsageDelta` LlmEvent 子类（含 `inputTokens` / `outputTokens` / `cachedTokens`）
- `lib/identity/hanako_backend_client.dart`：`_chatDeltaEvents` 解析 OpenAI 风格 `usage` 字段，yield `TokenUsageDelta`
- `lib/core/agent_runtime.dart`：累加 turn 内的 token usage，写入 RuntimeMessage 元数据（`stopReason` 字段旁加 `tokenUsage`）
- session jsonl 持久化最近 N 轮的 usage（已有字段 reuse）
- `lib/ui/chat_page.dart`：顶部状态栏显示"X / Y tokens (Z%)"

工作量：1 天。无破坏性。

### 阶段 2：阈值 + 警告

**目标**：达到 warning 阈值时 UI 提示用户。  
**不做**：自动压缩。

变更：

- `lib/core/compact_threshold.dart` 新建：
  ```dart
  class CompactThresholds {
    final int effectiveWindow;
    final int autoCompactThreshold;
    final int warningThreshold;
    final int errorThreshold;
  }
  CompactThresholds computeThresholds(ModelInfo model);
  ```
- preferences 加可配置 buffer（默认沿用 CC 的 13K / 20K / 20K）
- `chat_page.dart` 顶部加警告 banner：
  - 超过 warning：amber 条 "上下文使用 73%，剩余约 N 轮，建议压缩"
  - 超过 error：crimson 条 "上下文即将耗尽，下一轮可能失败"
  - 提供"立即压缩"按钮（暂时灰色 disabled——阶段 3 才接通）
  - "本会话不再提示"开关

工作量：半天。

### 阶段 3：手动压缩（核心）

**目标**：用户点"压缩"按钮 / 触发 `/compact`，把对话压缩成 summary 然后继续。

变更：

- `lib/core/agent_runtime.dart`：`RuntimeMessage` 新增 `compactBoundary` role 类型（跟 `system` / `user` / `assistant` / `toolResult` 并列）
- `lib/memory/conversation_compact.dart` 新建（**不**放 `lib/memory/`，因为它跟记忆系统是独立的关注点）— 实际应该是 `lib/core/conversation_compact.dart`：
  - `compactPrompt`：10 节模板，参考 CC 但精简（中文版本）
  - `compactConversation()`：收集 messages → 调主对话模型 → 解析 summary → 写 boundary 到 session
- `lib/core/session_coordinator.dart`：
  - 加 `Future<CompactResult> compactCurrentSession()` 方法
  - `_runRuntimeTurnForSession` 加载 history 时按 boundary 截断（只送 boundary 之后给模型）
- `lib/ui/chat_page.dart`：
  - 阶段 2 的"立即压缩"按钮接通
  - 压缩中状态显示（spinner + "正在压缩对话..."）
  - 压缩完成后插入分隔卡片（视觉提示历史已被压缩）
- runtime_session_store：load 时识别 boundary，提供 `loadMessagesAfterLastBoundary()`

工作量：2-3 天。**重头戏**。

### 阶段 4：自动压缩

**目标**：用户不知不觉触发，避免每次手动。

变更：

- `lib/core/session_coordinator.dart`：
  - `promptBlocks` 前先检查 `tokenUsage >= autoCompactThreshold`，是则 await 一次 compactCurrentSession 再 prompt
  - 加 `_consecutiveCompactFailures` 计数 + `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3` 熔断器
- `lib/ui/chat_page.dart`：自动压缩时 UI 显示"正在自动压缩..."；失败 toast 提示
- preferences 加开关：`autoCompactEnabled`（默认 true）

工作量：半天到 1 天。

### 阶段 5：post-compact 重注入

**目标**：boundary 之后的对话能"接住"压缩前的关键状态——不丢 plan、不丢最近读过的文件。

变更：

- `_runRuntimeTurnForSession` 加载 history 时，检测最近 boundary：
  - 收集 boundary 之前**最后 5 个** `read_file` 调用的文件路径 + 重读它们（每文件 5K token 上限）
  - 收集 boundary 之前**最后 1 个** `update_plan` 的 plan 文本 → 附加为 system reminder
  - 收集当前启用的 skills 列表 → 附加
  - 总预算 50K token（不能比 effectiveWindow 大）
- 写入 boundary 之后的"重注入消息"作为第一条 attachment

工作量：1-2 天。

---

## 4. 总体工作量

| 阶段 | 估计 | 关键收益 |
|---|---|---|
| 1 基础测量 | 1 天 | 看到数据是核心；UI 上知道还能聊多久 |
| 2 阈值警告 | 0.5 天 | 用户能提前感知 |
| 3 手动压缩 | 2-3 天 | 真正的能力——能压缩 + 接续对话 |
| 4 自动压缩 | 0.5-1 天 | 无感体验 |
| 5 post-compact 重注入 | 1-2 天 | 压缩后对话质量不掉 |
| **合计** | **~5-7.5 天** | |

---

## 5. 几个待决策点

1. **压缩用什么模型**？  
   - **A**：主对话模型（CC 的做法）—— 总结质量最好，但烧主模型 token  
   - **B**：记忆辅助模型（`preferences.memory.aux_model`，已实现）—— 复用现有配置  
   - **C**：单独再配一个"压缩模型"  
   
   推荐 **B**——已有配置点，用户能管。

2. **"压缩"是否破坏前端工程师做的会话 UI**？  
   - 压缩边界在 jsonl 里是真实存在的 message → `runtime_session_store._displayMessages` 需要把它转成 UI 上的"分隔卡片"
   - 风险：现有 UI 不识别 boundary message 会显示成 `unknown role` 或 fallback 文字
   - 建议：阶段 3 落地时 streaming_message 加 `RuntimeDisplayCompactBoundaryBlock` 类，专门渲染

3. **压缩前是否给用户预览总结的机会**？  
   - CC 默认不给（无感压缩）  
   - PH01 用户可能会希望先看一眼 —— 但加 preview 会引入"压缩待确认"中间态
   - 推荐：**默认无感**，preferences 里给"压缩前需确认"开关

4. **`/compact` slash 命令需不需要**？  
   - Hanako 现在没有 slash 命令体系（chat_page 输入框只走 user prompt）
   - 替代：UI 顶部"压缩"按钮 + 设置项里的按钮
   - 推荐：**先按钮**，slash 命令做不做看产品方向

5. **boundary 怎么编码到 jsonl**？  
   - 选项 1：复用 `type:message + role:compactBoundary` 增加 `RuntimeMessage.role` 的合法值
   - 选项 2：新增顶层 `type:compact` entry，与 `type:message` 平级
   
   推荐选项 1——所有现有 reader 代码已经按 role 分发，少改一点。

---

## 6. 不做的（明确边界）

- **microCompact（单工具输出过大截断）**：CC 的边角能力，PH01 工具结果一般不会大到爆。先不做。
- **prompt cache break detection**：CC 在压缩时有 cache key 优化。Hanako 走的是飞书/腾讯 gateway 不保证支持 prompt cache。不做。
- **跨 session compact**：CC 也不做。
- **forked agent 模式做压缩**：CC 用 fork 共享 cache。Hanako 用单次主模型调用即可（更简单，cache miss 不致命）。

---

## 7. 参考来源

- `claude-code-main/src/services/compact/` 整个目录（11 个文件）
- 重点：`autoCompact.ts`（阈值、熔断器）/ `compact.ts`（核心流程）/ `prompt.ts`（10 节总结模板）/ `compactWarningHook.ts`（UI 警告）
- `claude-code-main/src/utils/messages.ts:3708+`（`isCompactBoundaryMessage` / `normalizeMessagesForAPI` 处理）
