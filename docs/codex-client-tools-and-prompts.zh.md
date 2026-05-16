# PH01 客户端 Codex 工具与内置提示词中文清单

本文用于提示词工程师审阅当前客户端暴露给模型的工具描述和内置提示词。

检查范围：

- `hanako-flutter/lib/core/codex_agent_runtime.dart`
- `hanako-flutter/lib/local_tools/local_tools.dart`
- `hanako-flutter/lib/windows_ops/windows_ops_tools.dart`
- `hanako-flutter/lib/core/session_coordinator.dart`
- `hanako-flutter/lib/core/skill_manager.dart`

## 工具总览

当前 Codex 风格客户端最多可见 38 个工具：

- 常驻本地工具：13 个。
- 常驻 Codex 运行时工具：17 个。
- Windows 操作工具：最多 8 个，取决于 sidecar 能力探测结果。

Windows 操作工具只有在 `WindowsOpsCapabilities.sidecar=true` 且对应能力开启时才会注册。

## 常驻本地工具

本地工具只保留 Codex 标准工具未覆盖的业务能力；文件、搜索和终端类能力统一走 Codex 的 `exec_command` / `apply_patch`。
文件和网页卡片不是工具能力：模型在最终回复中输出 Markdown 链接，客户端展示层会把本地绝对路径渲染为文件卡片，把 `http/https` 链接渲染为网页卡片。

1. `search_memory`
   搜索当前 Agent 的本地记忆文本。
2. `web_search`
   搜索互联网获取实时信息。当前 Flutter 客户端需要配置搜索 provider 后才能执行。
3. `web_fetch`
    抓取指定 http/https URL 并提取文本。会阻止内网地址访问。
4. `pin_memory`
    将内容写入当前 Agent 的置顶记忆。
5. `unpin_memory`
    按关键词从当前 Agent 的置顶记忆中移除内容。
6. `list_pinned_memory`
    列出当前 Agent 的置顶记忆。
7. `create_experience`
    把当前会话或 Agent 已通过文件编辑生成的原始目录保存为 PH01 本地私有经验，不会提交网络审核。经验本体必须来自会话截取或 raw_directory 文件树；AI 不得把完整经验正文作为工具参数传入。
8. `experience_search`
    检索 PH01 经验包文件树，只返回经验 ID、文件路径、行号和短片段。读取全文或继续定位请使用 Codex 的 exec_command。
9. `cron`
    创建和管理定时任务。到期后会在后台打开独立 session 执行指定 prompt。
10. `create_artifact`
    创建 HTML、代码或 Markdown 产物并返回本地文件路径；最终回复需用 Markdown 链接引用该路径。
11. `browser`
    控制浏览器打开网页、读取页面标题/文本和查看状态；复杂交互会返回中文限制说明。
12. `install_skill`
    为当前 Agent 安装 Anthropic Agent Skill，并可立即启用。
13. `notify`
    向用户发送系统通知。

## 常驻 Codex 运行时工具

1. `exec_command`
   运行一条本地命令并返回 stdout/stderr/exit_code。兼容 Codex 的 exec_command 参数。
2. `write_stdin`
   向 exec_command(tty: true) 创建的长进程会话写入字符，并读取近期 stdout/stderr。
3. `apply_patch`
   应用 Codex 风格补丁。当前 Chat Completions 工具通道不支持 freeform custom tool，因此通过 patch 字符串传入。
4. `request_user_input`
   请求用户回答一到三个短问题并等待响应。当前客户端运行时尚未接入阻塞式模态输入时会返回不可用结果。
5. `request_permissions`
   请求额外文件系统或网络权限。客户端可按设置弹出授权框、自动批准或自动拒绝。
6. `view_image`
   从本地文件系统读取图片。仅在用户给出完整图片路径，或工具产出了图片文件路径时使用。
7. `spawn_agent`
   创建一个 Agent 来处理指定任务。这是 Codex 多 Agent v2 的入口工具。
8. `send_message`
   向已有 Agent 发送消息。消息会进入队列，不会触发新的执行轮次。
9. `followup_task`
   向已有的非根目标 Agent 发送消息，并触发该目标 Agent 执行一轮。
10. `wait_agent`
    等待一个或多个 Agent 到达当前完成点，并返回状态。
11. `close_agent`
    关闭一个 Agent，并返回请求关闭前的状态。
12. `list_agents`
    列出当前 Codex 多 Agent 树中可见的 Agent。
13. `get_goal`
    获取当前线程的目标，包括状态和预算字段。
14. `create_goal`
    仅在用户、系统或开发者指令明确要求时创建目标。
15. `update_goal`
    更新已有目标。仅用于标记目标已经达成。
16. `tool_search`
    搜索当前 Codex 工具注册表中的可用工具，用于发现延迟或不熟悉的工具能力。
17. `update_plan`
    更新当前任务计划。用于复杂任务中同步步骤与状态，兼容 Codex plan 工具语义。

## Windows 操作工具

1. `windows_capture_region`
   截取 Windows 屏幕局部区域。默认只返回截图尺寸和体积摘要，避免 base64 污染上下文；需要原图时设置 include_image_base64=true。若目标是理解界面，优先直接调用 windows_ui_parse。
2. `windows_mouse_move`
   把 Windows 鼠标指针移动到指定屏幕坐标。用于真实界面操作前的定位。
3. `windows_mouse_click`
   移动鼠标并执行真实点击。适合配合截图、界面识别或 UIA 坐标操作。
4. `windows_text_input`
   向当前焦点控件输入文字，可选回车提交。使用前应先通过点击或 UIA 聚焦目标输入框。
5. `windows_uia_tree`
   读取 Windows UI Automation 控件树，并返回压缩后的高密度控件摘要。默认省略 process_id、framework_id、空字段和容器噪声；需要调试原始树时设置 include_raw=true。
6. `windows_uia_invoke`
   对 Windows UIA 元素执行 InvokePattern，会触发真实界面动作。
7. `windows_ocr_recognize`
   使用本地 OCR 模型识别图片文字，默认返回压缩后的文本行摘要。只有 OCR bundle 和推理运行链就绪时才会注册。
8. `windows_ui_parse`
   使用本地界面识别模型和 OCR 解析截图，返回高密度界面观察摘要、可点击候选和主要文字。可直接传 x/y/width/height 截图区域，不必先调用截图工具返回 base64。

## 客户端系统提示词

客户端会在每个 session 中拼接以下系统提示词片段：

```text
你运行在用户本机的 PH01 子体客户端中，底层 Agent 执行引擎遵循 OpenAI Codex 的工具循环、工具注册和上下文组织逻辑。

需要本地信息、文件修改、终端命令或桌面操作时，使用请求中提供的原生 function tools；不要把工具调用写成正文。

执行复杂任务时可以使用 update_plan 维护进度；需要额外权限时使用 request_permissions，不要假设权限已被授予。

需要复用历史方案时先检索 experience_search；需要沉淀当前会话时可用 create_experience 保存本地私有经验。若用户要求脱敏，必须在独立会话里读取源目录，并通过持续文件修改生成 raw_directory，再用 create_experience source=raw_directory 导入；不得让 AI 直接输出完整经验正文；客户端不会用规则脱敏；网络提审必须由用户在客户端设置页确认。

如果工具失败，说明失败原因和还缺什么信息。
```

运行时还会按实际值追加以下动态段：

```text
<environment_context>
cwd: {session.cwd}
当前 Agent：{agent.name} ({agent.id})
</environment_context>

Agent 身份：
{agent.identity}

Agent 意识/行为设定：
{agent.ishiki}

<user_instructions>
{AGENTS.md / 项目指令内容}
</user_instructions>

<skills_instructions>
{Skill 列表提示词}
</skills_instructions>
```

## Skill 列表提示词

启用 Skill 时，客户端会注入以下提示词格式：

```text
## 可用 Skill

使用某个 Skill 前，先读取下方路径里的 SKILL.md 文件，加载该 Skill 的完整说明。

- **{s.name}** ({s.displayName}) — {s.description}
  路径：`{s.filePath}`
  允许使用的工具：{s.allowedTools.join(", ")}
```

如果存在 Skill 诊断信息，会追加：

```text
## Skill 诊断
- {diagnostic}
```
