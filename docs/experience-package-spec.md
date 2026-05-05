# PH01 经验包与经验管理端协议

**版本**：v0.2  
**日期**：2026-05-01  
**状态**：按 MVP v3 修正版  

本文只以 `master-server/docs/幻宙01-MVP需求文档-v3-集群信息平权(2).md` 为最高准则。早期 v0.2 文档和现有代码只能作为历史参考，不能覆盖 v3 对“经验”的定义。

---

## 1. 核心定义

经验不是 Skill，也不是整理后的方法卡片。

经验的本体是：**原始对话记录与 Agent 行为的无损转储片段**。

它应完整保留：

- 用户与子体如何把问题讲清楚
- AI 如何追问、判断、试错
- 工具调用、命令、文件读写、网络请求等行为
- 工具结果、日志、图片、文件等证据
- 结论产生前后的上下文和逻辑变化

允许做的处理只有一类：**脱敏**。

脱敏在客户端完成，由子体和用户确认哪些内容需要隐藏。脱敏后仍应保留原始结构和过程，不能改写成摘要或教程。

---

## 2. 经验与 Skill 的边界

| 类型 | 本质 | 是否整理 | 用途 |
|---|---|---:|---|
| Skill | 提炼后的流程、模板、脚本 | 是 | 直接指导执行 |
| 经验 / 阅历 | 原始认知过程与行为记录 | 否 | 让 AI 追溯当时怎么想、怎么做 |

Skill 可以从经验中提炼出来，但经验不能反过来被压缩成 Skill。

禁止把经验本体做成：

- JSON 标签集合
- 操作步骤卡片
- 结论摘要
- 适用条件模板
- “某问题如何解决”的教程正文

这些都可以作为派生物，但不是经验本体。

---

## 3. 外层经验包

网络传输格式建议使用 `.hxp`，本质是 zip。

外层包结构与 MVP v3 对齐：

```text
exp_xxx.hxp
├── package.zip       # 经验本体：原始聊天/行为转储包
├── publisher.json    # 发布者信息与签名材料
└── ratings.dat       # 评价链，JSON Lines DAG
```

强制要求：

- 必须有 `package.zip`
- 必须有 `publisher.json`
- 必须有 `ratings.dat`

不再强制 `experience.md` / `timeline.md`。如果它们存在，也只能是原始转储的一部分，不能承担“经验正文”的角色。

---

## 4. package.zip

`package.zip` 是经验本体。

它保存客户端导出的原始记录，推荐结构如下：

```text
package.zip
├── metadata.json          # 可选，仅做索引
├── raw/
│   ├── conversation.md    # 虚拟微信单行原始记录
│   └── events.md          # 可选，工具调用/操作记录的单行机械转录
├── tool-calls/            # 工具调用输入输出原文
├── attachments/           # 图片、日志、文件、多模态材料
└── redaction.json         # 可选，脱敏说明，不保存被遮蔽原文
```

说明：

- `conversation.md` 不是总结稿，而是机械转录。
- `conversation.md` 的推荐行格式是 `[时间] 发送者: 内容`；发送者未脱敏时写用户名，脱敏时写 `用户`。
- `events.md` 如果存在，也必须是机械转录，不能改写成摘要。
- 大段命令输出、图片、日志等放入附件目录，再由记录文件用 Markdown 链接引用。
- 不推荐把结构化日志作为经验本体格式；如果原始来源本身是程序日志，应作为来源原件保存在 `source/` 或 `attachments/`，虚拟微信记录仍以 `.md` 单行文本落盘。

---

## 5. metadata.json

`metadata.json` 只用于程序层快速过滤和管理端索引，不是经验本体。

示例：

```json
{
  "schema_version": "ph01.experience.raw.v1",
  "experience_id": "exp_20260501_gpu_recovery",
  "title": "Windows GPU 恢复过程沟通转储",
  "brief": "关于攻击模型、GPU benchmark、两阶段恢复验证的原始沟通过程",
  "keywords": ["windows", "gpu", "recovery", "benchmark"],
  "created_at": "2026-05-01T12:00:00Z"
}
```

约束：

- `brief` 只能服务于检索和展示，不能替代原始记录。
- `keywords` 用于 v3 中的程序层初筛。
- 没有 metadata 时，管理端可以用 `package.zip` hash 生成经验 ID。

---

## 6. 签名链

客户端内置 PH01 Root 公钥。

Root 私钥用于签发二级审核证书；日常审核由二级私钥完成。

```text
PH01 Root Private Key
  -> 签发 Experience Review Certificate
       -> 二级私钥签署通过审核的经验包
```

接收方验证：

```text
内置 Root 公钥
  -> 验证审核证书
  -> 验证主脑审核签名
  -> 验证发布者签名
  -> 验证 package.zip hash
```

目前管理端先保留 `publisher.json`，后续再补完整二级证书与签名字段。

---

## 7. ratings.dat

`ratings.dat` 是追加式 JSON Lines DAG。

它保存：

- 根节点
- 使用者赞踩
- 主脑 Veto Block
- 分叉合并信息

评价链不改变经验本体。即使经验被差评或吊销，原始信息也应保留在缓存或备份中，便于审计和继续传播吊销信息。

---

## 8. 管理端职责

经验管理端部署在大容量服务器上，不和主脑本体混放。

它负责：

- 保存所有上传经验包
- 按 `inbox / network / rejected` 管理状态
- 解开 `package.zip`，提供只读内容投影
- 维护轻量索引
- 向主脑侧 CLI 提供 C/S API
- 保存审核结果
- 后续接入签名、评价链、P2P 同步

它不负责：

- 把经验整理成教程
- 自动提炼 Skill
- 把原始过程压缩成结论
- 替代子体侧脱敏确认

---

## 9. 主脑侧 CLI

CLI 是主脑操作经验管理端的客户端。

常用命令：

```bash
ph01-expctl pack ./raw_dump ./exp_demo.hxp
ph01-expctl upload ./exp_demo.hxp
ph01-expctl list -status inbox
ph01-expctl search "GPU benchmark"
ph01-expctl read exp_demo
ph01-expctl read exp_demo content/raw/conversation.md
ph01-expctl review -status approved -reason "通过审核" exp_demo
ph01-expctl fetch exp_demo ./exp_demo.hxp
```

默认 `read exp_demo` 应读取原始记录入口，而不是整理正文。

---

## 10. 检索方式

MVP 阶段遵循 v3 的文件系统检索思路。

主脑不是普通 Web 用户，也不是只能接收检索结果列表的业务接口。主脑作为 AI Agent，本来就可以阅读目录、查看文件名、搜索文本、打开片段、继续追溯附件。因此经验库的第一检索入口应当是：**文件系统式可读资料库**。

推荐检索路径：

```text
列出经验目录 / 虚拟文件系统索引
  -> 通过目录名、README、metadata 找到候选经验
  -> 用全文搜索匹配 conversation.md / tool-calls / attachments
  -> 读取原始记录片段
  -> 必要时继续读取上下文、附件和工具结果
```

这意味着：

- 目录名应尽量人类可读，例如 `exp_gpu_benchmark_windows/`，便于 `ls` 后直接判断。
- `README.md` 和 `metadata.json` 是路标，不是经验正文。
- `metadata.json` 关键词只做初筛提示，不能承担完整召回责任。
- `conversation.md` 与附件才是主脑判断经验是否相关的依据。
- 管理端可以提供 `find` / `rg` 等价能力，返回文件路径和行号，而不是只返回摘要。

后续可以补辅助能力：

- 评价排序
- 场景匹配
- 更强文本搜索
- 向量检索或 embedding

但这些只能是旁路索引层增强，不能替代原始文件，也不能把主脑限制成只能读数据库召回片段。即使未来引入 PostgreSQL、SQLite、对象存储或向量索引，主脑侧仍应看到稳定的文件系统式视图。

---

## 11. 待定项

- 二级审核证书字段格式
- `publisher.json` 的最终签名字段
- `metadata.json` 的最小必填字段
- 管理端是否需要数据库作为后台加速索引；这不能改变文件系统式主入口
- P2P 节点与管理端是否拆成两个进程
- 子体侧脱敏 UI 与导出格式
