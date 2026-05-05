# 来源

- 原始文件: `C:\Users\dream\.codex\sessions\2026\04\30\rollout-2026-04-30T16-21-56-019ddd7a-f627-7910-b362-f15c72324089.jsonl`
- 摘录行号: 1276-1730
- 生成方式: 从原始 JSONL 机械抽取，不做摘要、不做改写
- 摘录对象: `event_msg.user_message`、`event_msg.agent_message`、`response_item.function_call`、`response_item.function_call_output`、`response_item.custom_tool_call`、`response_item.custom_tool_call_output`、`response_item.web_search_call`、`event_msg.exec_command_end`、`event_msg.patch_apply_end`、`event_msg.web_search_end`、`event_msg.error`
- 落盘格式: 虚拟微信单行文本，使用 `.md` 文件承载
- 格式规则: `[时间] 发送者: 内容`；每条记录一行；多行内容转义为字面 `\n`；不保留实时状态字段
- 发送者字段: 未脱敏时写用户名；脱敏时写 `用户`；本样本默认不脱敏，用户发送者写 `天使`
- 工具事件: `tool-calls/line-<原始行号>-<事件类型>.md` 按原始行号保存同一条机械摘录，便于单独查证
