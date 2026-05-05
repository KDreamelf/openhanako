# 登录系统讨论经验样本

这个目录保存一份按“虚拟微信”格式组织的原始机械摘录样本。

目录结构：

```text
exp_login_identity_discussion/
├── README.md
├── metadata.md
├── raw/
│   └── conversation.md
├── tool-calls/
│   └── line-<原始行号>-<事件类型>.md
└── source/
    └── source.md
```

样本本体是 `raw/conversation.md`。

`tool-calls/` 按原始 JSONL 行号保存工具调用、工具输出、补丁事件和系统错误的机械摘录。

`source/source.md` 只记录原始来源和摘录范围，用于查证。
