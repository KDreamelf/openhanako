# Memory 系统设计（CC 风格）

> 调研日期：2026-05-18  
> 决策来源：PH01 产品方向对齐，参考 Claude Code (`claude-code-main`) `src/memdir/` 与 `src/services/extractMemories/`。

---

## 1. 背景：为什么不是现在这套

Hanako 仓库里同时存在**两套 memory 实现**：

| 路径 | 文件 | 风格 |
|---|---|---|
| **Claude Code 风格** | `lib/memory/claude_memory.dart` + 一组 `*_memory` 工具 | 离散 `.md` + `MEMORY.md` 索引 |
| **滚动摘要风格** | `lib/memory/memory_compile.dart` / `memory_ticker.dart` / `session_summary.dart` / `deep_memory.dart` | 时间窗口压缩（today/week/longterm/facts → memory.md） |

两套共用 `agent/memory/` 目录，**两套都没接通**：

- **CC 风格**：`buildMemoryPrompt` 读 `MEMORY.md` 注入 system prompt 已实现；但 AI 没有写 memory 的工具调用路径（实际上 CC 也不用专用工具，用通用 Write/Edit；但 Hanako 之前没把这层指令完整 wire 上）
- **滚动摘要风格**：`MemoryTicker.start()` **从未被实例化**，`AgentRuntimeLoop` 不调 `notifyTurn`、session 结束不调 `notifySessionEnd`；即便走 UI 手动按钮跑完编译，输出 `memory.md`（小写）跟 `_buildSystemPrompt` 读的 `MEMORY.md`（大写）**文件名大小写不匹配**——任何人手动点过编译按钮的对话都白点了

源头：两套各搬一半凑成的拼装，文件名空间冲突，从产品发布起就没生效。

## 2. 产品方向：走 CC 风格

CC 路子（任务型事实 memory）：
- 一条记忆 = 一个独立可寻址的事实，落成单独 `.md` 文件
- AI 在对话中**主动判断**"该记什么"并写入；不是后台周期编译
- `MEMORY.md` 是机器/AI 维护的**索引文件**，每行一个 `[Title](file.md) — hook`
- system prompt 永远只塞 `MEMORY.md` 索引（截到 200 行/25KB）；具体 `.md` 内容靠 grep / Read 按需拉
- 四种 type：`user` / `feedback` / `project` / `reference`（语义分类，不是时间分类）

滚动摘要路子（陪伴 bot 摘要管道）适合"AI 还记得我们昨天聊过什么"的陪伴产品形态。PH01 是任务型 + 工具调用平台，事实型 memory 更贴合。

## 3. 设计要点

### 3.1 目录结构

```
{agent}/memory/
  MEMORY.md           # 索引，AI 维护，每行 [Title](file.md) — hook
  <topic>.md          # 单条 memory，YAML frontmatter + 正文
  team/               # 团队 scope（暂不启用）
    MEMORY.md
    <topic>.md
```

### 3.2 单条 memory 的 frontmatter

```markdown
---
name: 记忆名（短、可读）
description: 一句话描述，决定 recall 时是否被选中
type: user | feedback | project | reference
---

正文内容
```

### 3.3 四种 type 含义（来自 CC `memoryTypes.ts`）

| type | 描述 | 何时写 |
|---|---|---|
| `user` | 用户的角色、目标、偏好、知识背景 | 学到关于用户的新事实 |
| `feedback` | 用户对工作方式的指导，纠正或确认 | "不要这样"、"对，就这样" |
| `project` | 工作的背景、动机、限制 | 学到 who 在做 what、why、by when |
| `reference` | 指向外部系统的指针（Linear/Slack/Dashboard） | 学到资源位置 |

明确**不该存的**：代码模式（grep 能拿）、git 历史（git log 能拿）、调试 fix 复盘（提交信息能拿）。

### 3.4 system prompt 注入策略

每轮 system prompt 包含：

1. **memory 指令段**（`buildMemoryLines` 的产物）：解释 4 种 type、how to save、when to access、`MEMORY.md` 是索引等
2. **MEMORY.md 内容**（如果存在；截到 200 行/25KB）
3. **相关 memory 段**（findRelevantMemories 选的 ≤5 条，详见 §3.6）

### 3.5 write 路径

**不用专用工具**——模型用现有的 `apply_patch` 工具直接写 `.md`，再 `apply_patch` 改 `MEMORY.md` 索引。

system prompt 告诉模型：
- memory 目录的绝对路径
- 两步保存语义（写 .md + 改索引）
- frontmatter 格式

### 3.6 recall 路径（豪华版）

两层：

1. **每轮**：`findRelevantMemories` 用**记忆模型**（小模型，可配）从 `agent/memory/*.md`（排除 `MEMORY.md`）列出所有 frontmatter 的 description，让小模型按当前用户 query 语义选 ≤5 条最相关，注入当前 turn 的 context。带 `alreadySurfaced` 去重（同会话不重复推同一条）。
2. **MEMORY.md 索引**：系统提示词里始终有，模型自己也可以 grep 翻

### 3.7 extract 路径（豪华版）

turn 结束后启动 background agent（用**记忆模型**）扫近端对话内容，按 4 种 type 抽取候选 memory 写入 `.md`。逻辑：

- `hasMemoryWritesSince`：如果 main agent 本轮自己写了 memory，extract agent 跳过那段（避免重复）
- 用 description 帮助避免重复写已有 .md
- 写入需要更新 MEMORY.md 索引

### 3.8 "记忆模型" 配置项

`preferences.memory.model` 字段，可选值取自 `modelManager.availableModels`。如果未设，fallback 到主对话模型。

- `findRelevantMemories` 每轮的语义筛选用这个模型
- `extractMemories` 的 background agent 用这个模型

Settings → "记忆" 分组：
- 总开关：是否启用 memory
- 模型选择：下拉，从可用模型选
- recall 上限：选 ≤5/10/15 条
- extract 触发：每轮 / 每 N 轮 / 仅 session 结束

## 4. 实施步骤

### 阶段 1：砍滚动摘要管道
- 删 `memory_compile.dart` / `memory_ticker.dart` / `session_summary.dart` / `deep_memory.dart`
- 清理 `engine.dart` / `session_coordinator.dart` / `memory_page.dart` 的引用
- 删相关测试（`memory_parity_test.dart` 等）
- 把 `session_summary._scrubPii` 挪到 `lib/shared/pii_scrubber.dart`（给经验脱敏路径保留）

### 阶段 2：跑通 read 链路
- 检查 `_buildSystemPrompt` 正确注入 `buildMemoryPrompt` 结果
- 对照 CC `memoryTypes.ts` 的 SECTION 补齐 Hanako 这边缺失的指令段
- 验证空文件提示文案与 CC 一致
- 验证 `MEMORY.md` 截断逻辑（200 行/25KB）

### 阶段 3：跑通 write 链路
- 确认 `apply_patch` 暴露给模型
- system prompt 中给出 memory 目录的绝对路径
- end-to-end 测：模型能写 `.md` + 改索引

### 阶段 4：豪华版 + 配置

- 4a：`findRelevantMemories` Dart 实现（参考 CC 同名 .ts）
- 4b：`extractMemories` Dart 实现（参考 CC 同名 .ts）
- 4c：设置项「记忆模型」
- 4d：PII regex 挪通用（已并入阶段 1）

## 5. 风险与边界

| 风险 | 影响 | 缓解 |
|---|---|---|
| 旧用户磁盘上残留 `today.md` / `week.md` 等 | 无功能影响（新链路不读它们），但占磁盘 | 不做主动清理；下次用户清空 hanako 目录自然消失 |
| AI 写 memory 时把敏感信息写进去 | 落盘后明文 | CC 路子靠 AI 主动选择写什么；额外保险靠 `pii_scrubber` 在 write 路径上做兜底（可选） |
| `findRelevantMemories` 每轮额外 LLM 调用 | 成本 / 延迟 | 用记忆模型（小模型）；recall 上限 5 条；alreadySurfaced 去重 |
| `extractMemories` 漏抽 / 误抽 | memory 质量 | extract agent 的 prompt 给清晰的 4 种 type 定义；hasMemoryWritesSince 跳过 main agent 已写段 |
| MEMORY.md 索引腐烂（描述与 .md 真实内容不一致） | recall 不准 | CC 在 buildMemoryLines 中专门给"保持索引描述准确"的指令；不额外做工程化校验 |

## 6. 不打算做的

- **不做** 全量 memory 注入 system prompt：CC 永远只塞索引 + 相关 ≤5 条；防止上下文爆炸
- **不做** 记忆的 SQLite 索引：CC 用文件系统 + grep 已经够，不引入 db
- **不做** memory 编辑的 UI：CC 用 `/memory` slash 命令调出文本编辑器；Hanako 已有 `memory_page.dart` 走文件浏览，足够
- **不做** team memory：暂时单 agent / 单用户场景，team scope 留空目录

## 7. 参考

- `claude-code-main/src/memdir/memdir.ts` —— `buildMemoryLines` / `loadMemoryPrompt` / `truncateEntrypointContent`
- `claude-code-main/src/memdir/memoryTypes.ts` —— 四种 type 的 SECTION 模板
- `claude-code-main/src/memdir/findRelevantMemories.ts` —— recall 筛选实现
- `claude-code-main/src/services/extractMemories/extractMemories.ts` —— background 抽取
- `claude-code-main/src/memdir/memoryAge.ts` —— 陈旧度提示
- `hanako-flutter/lib/memory/claude_memory.dart` —— 当前 Dart port（已实现 read 部分）
