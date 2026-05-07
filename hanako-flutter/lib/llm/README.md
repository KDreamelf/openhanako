# lib/llm/

本目录只保留子体 UI 与会话层需要的 LLM 协议对象：

- `provider.dart`：`Message` 与 `LlmEvent`
- `streaming/`：通用流式解析工具
- `tool_format/`：工具调用文本格式解析

子体端不再配置供应商、API Key、OAuth 或 Codex 登录。实际模型列表与聊天请求全部走 AI 网关：

```text
子体私钥 → ECDH 短期通道 → ai.xn--lbtx0e.cn → 网关动态分组/订阅/模型转发
```

模型选择只展示 AI 网关在密钥协商后返回的授权模型列表。
