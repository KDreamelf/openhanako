# Claude Code 记忆系统复刻清单

本文从 `claude-code-main` 提取记忆相关能力，作为 Hanako 客户端复刻目标。

## 1. 记忆分层

- `user`：用户长期画像、职责、偏好、熟悉技术。
- `feedback`：用户对协作方式的正负反馈，必须带原因和适用边界。
- `project`：项目中的目标、事故、截止时间、组织状态。
- `reference`：外部系统入口，例如某个 Linear 项目、仪表盘、Slack 频道。

## 2. 目录结构

- 私有记忆根目录：`<agentDir>/memory/`
- 团队记忆目录：`<agentDir>/memory/team/`
- 入口文件：`MEMORY.md`
- 每条记忆独立为一个 `.md` 文件，`MEMORY.md` 只做索引。

## 3. Prompt 形态

- 系统提示会说明记忆目录已经存在，可直接写入。
- 系统提示会明确四类记忆和“不要保存什么”。
- `MEMORY.md` 超过 200 行会截断，并附带 warning。
- 团队模式下，private/team 两个目录都各有一份 `MEMORY.md`。
- 读取记忆时必须提醒模型：记忆是快照，不是实时状态。

## 4. 扫描与检索

- 只扫描 `.md` 文件，跳过 `MEMORY.md`。
- 读取前 30 行 frontmatter。
- 生成列表时保留：
  - 文件名
  - 路径
  - 修改时间
  - description
  - type
- 检索时先把全部候选文件 manifest 给模型，再让模型选择最多 5 个。
- 检索结果只返回绝对路径和 mtime，不返回整篇内容。
- 客户端本地 `search_memory` 走递归扫描，只返回路径、行号和片段，不做全量同步。
- 系统提示会把本地 `MEMORY.md` 和（若启用）`team/MEMORY.md` 直接注入到会话上下文里。

## 5. 提取流程

- 会话结束后，后台 fork 一个独立 Agent。
- 只看最近一段消息。
- 如果主 Agent 已经写过记忆文件，后台提取要跳过重叠区间。
- 提取 Agent 只允许读写记忆目录，不能碰其他工具。
- 提取结果写成主题文件，再更新 `MEMORY.md` 索引。

## 6. 会话记忆

- 另有一条 session memory 线：
  - `session-memory/config/template.md`
  - `session-memory/config/prompt.md`
- 结构固定为：
  - Session Title
  - Current State
  - Task specification
  - Files and Functions
  - Workflow
  - Errors & Corrections
  - Codebase and System Documentation
  - Learnings
  - Key results
  - Worklog
- session memory 有总 token 上限和单段上限。
- 编译器会把 `today/week/longterm/facts` 四块合并到 `memory.md`。

## 7. 团队记忆同步

- 团队记忆会在会话开始时同步。
- 通过远端服务拉取/推送。
- 需要做 secret 扫描，避免把密钥写进共享记忆。

## 8. 记忆年龄

- 记忆要能显示：
  - today
  - yesterday
  - N days ago
- 读取时应显示过期提醒，提示这是快照，不是实时状态。

## 9. 复刻优先级

1. 先落地：目录结构、扫描、检索、prompt。
2. 再落地：提取 Agent、索引写回、团队同步。
3. 最后补齐：session memory、夜间编译器、UI 管理页。

## 10. 当前客户端落点

- `lib/memory/claude_memory.dart` 负责目录解析、`MEMORY.md` 截断、递归搜索。
- `lib/core/session_coordinator.dart` 在构建 system prompt 时注入记忆目录内容。
- `lib/local_tools/local_tools.dart` 的 `search_memory` 直接读本地记忆树，不同步全量经验包列表。
