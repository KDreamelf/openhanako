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

客户端脱敏采用路径驱动的独立 Agent 任务：用户在界面里选择源经验、填写脱敏要求，子体只把源目录路径和输出暂存目录交给 Agent。Agent 按正常工具流程分块读取源文件、持续修改暂存目录里的文件，逐项处理附件和工具记录，最终形成新的 `metadata.json`、`raw/conversation.md`、`raw/events.md`、`tool-calls/`、`attachments/` 文件树，再导入成本地私有经验副本。客户端不做规则脱敏，也不把整份经验一次性塞入模型上下文或要求模型输出完整脱敏稿。

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
- `title`、`brief`、`keywords` 属于索引路标，可以由 Agent 辅助编写；它们不能作为经验本体或替代 `raw/` 下的机械转录。
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

第二阶段新增 `review-materials.json`，用于表达管理端审核通过后签发的网络流转材料。它可以由管理端包下载接口直接附加到 `.hxp`，也可以由原作者单独取回后附加到本地包：

```text
exp_xxx.hxp
├── package.zip
├── publisher.json
├── ratings.dat
└── review-materials.json
```

`review-materials.json` 最小字段：

```json
{
  "schema_version": "ph01.experience.review_materials.v1",
  "root_key_id": "ph01-exp-root-20260504",
  "signature_algorithm": "secp256k1_ecdsa_sha256_rs64",
  "signature_payload_sha256": "sha256-of-signature-payload",
  "manager_review_signature": "64-byte-rs-hex",
  "signature_payload": {
    "schema_version": "ph01.experience.review_payload.v1",
    "experience_id": "exp_xxx",
    "package_hash_algorithm": "sha256",
    "package_hash": "package.zip-sha256",
    "publisher_pubkey": "publisher-public-key-hex",
    "review_status": "network",
    "review_mode": "manual_review",
    "reviewed_at": "2026-05-09T00:00:00Z",
    "certificate_id": "ph01-exp-master-20260504",
    "signer_role": "experience_review_master",
    "signature_algorithm": "secp256k1_ecdsa_sha256_rs64"
  },
  "manager_certificate": {}
}
```

客户端导入 network 经验时必须同时验证：

- 内置 Root 公钥验证主控工作证书。
- 主控工作证书验证 `manager_review_signature`。
- 审核 payload 中的经验 ID、发布者公钥、`package.zip` hash 与本地包一致。
- `publisher.json` 发布者签名与 `package.zip` hash 一致。

---

### 6.1 P2P / DHT 传输层补充

第二阶段的包请求与节点发现只负责“找到谁能发包”，不负责把包判定为可信。可信性仍然只来自签名链与 hash 校验。

DHT 传输层采用独立 `experience-dht` 部署版。经验管理端不内置 DHT 运行时，也不承担打洞 socket 或 relay 字节搬运；它只维护公共 DHT 列表、注册、注销、健康检查和管理端兜底下载。源码和部署资产分开：`experience-dht/deployment-package/` 是可扩散部署包，内置部署脚本、Dockerfile、Compose 配置、可选极简 `config.yml` 和预编译二进制放置目录；开发机侧构建脚本负责编译并生成可发放压缩包，也可发布不含源码的 Docker Hub 镜像 `dreamelf6174/experience-dht`。Docker 部署只要求 `EXPERIENCE_DHT_INIT_PASSWORD` 一次性绑定密码、端口映射和持久化 `/data/experience-dht` volume；状态路径由程序和容器映射内部约定，不作为配置字段暴露；节点 ID 首次启动自动生成并写入 DHT 状态文件；公网访问 URL、UDP 候选地址、relay 策略、管理端地址和公开状态都由绑定客户端配置面板签名同步。DHT 默认是私有节点，公开/私有状态不作为部署配置项存在，而是由绑定客户端用账号公钥签名切换，并持久化到 DHT 运行状态文件；客户端绑定 DHT 时应把默认经验管理端地址写入 DHT 作为 bootstrap 地址，私有 DHT 可据此拉取公共 DHT 列表并与公共 DHT 进行短 TTL discovery federation，但不会自动公开注册。公共 DHT 注册/注销不依赖管理端 admin token；用户 DHT 的注册/注销请求必须携带 `owner_peer_id` 对应公钥的签名证明。需要重新绑定时，通过部署包 reset 脚本删除 DHT 状态后重建。

客户端通过 DHT 发送 presence 时，使用 PH01 签名请求包裹业务 payload：

```json
{
  "payload": "{\"peer_id\":\"peer_...\",\"endpoints\":[...],\"package_hashes\":[\"sha256:...\"]}",
  "pubkey": "04...",
  "signature": "64-byte-rs-hex",
  "timestamp": 1778323200,
  "nonce": "random"
}
```

`payload` 最小字段：

```json
{
  "peer_id": "peer_...",
  "owner_peer_id": "owner_...",
  "endpoints": [],
  "package_hashes": ["sha256:..."],
  "ttl_seconds": 300
}
```

P2P 包请求最小字段：

```json
{
  "schema_version": "ph01.experience.package_request.v1",
  "request_id": "req_...",
  "experience_id": "exp_...",
  "package_hash": "sha256:...",
  "requester_peer_id": "peer_...",
  "requester_public_key": "04...",
  "requester_addrs": [],
  "preferred_transports": ["ipv6_direct", "ipv4_hole_punch", "dht_relay", "manager_seed"],
  "dht_node_id": "dht_01",
  "nonce": "random",
  "timestamp": "2026-05-09T09:00:00Z",
  "requester_signature": "64-byte-rs-hex"
}
```

P2P 包供给响应最小字段：

```json
{
  "schema_version": "ph01.experience.package_offer.v1",
  "request_id": "req_...",
  "experience_id": "exp_...",
  "package_hash": "sha256:...",
  "provider_peer_id": "peer_...",
  "provider_addrs": [],
  "available_transports": ["ipv6_direct", "ipv4_hole_punch", "dht_relay"],
  "review_materials": {},
  "publisher": {},
  "nonce": "random",
  "timestamp": "2026-05-09T09:00:00Z",
  "provider_signature": "64-byte-rs-hex"
}
```

DHT relay 会话创建使用 PH01 签名请求包裹以下业务 payload：

```json
{
  "schema_version": "ph01.experience.relay_session_request.v1",
  "request_id": "req_...",
  "experience_id": "exp_...",
  "package_hash": "sha256:...",
  "requester_peer_id": "peer_...",
  "requester_owner_peer_id": "owner_...",
  "provider_peer_id": "peer_...",
  "provider_owner_peer_id": "owner_...",
  "ttl_seconds": 300,
  "max_bytes": 67108864
}
```

IPv4 打洞协调会话创建使用 PH01 签名请求包裹以下业务 payload：

```json
{
  "schema_version": "ph01.experience.hole_punch_request.v1",
  "request_id": "req_...",
  "experience_id": "exp_...",
  "package_hash": "sha256:...",
  "requester_peer_id": "peer_...",
  "requester_owner_peer_id": "owner_...",
  "requester_addrs": [],
  "provider_peer_id": "peer_...",
  "provider_owner_peer_id": "owner_...",
  "provider_addrs": [],
  "ttl_seconds": 300
}
```

打洞协调状态上报 payload：

```json
{
  "peer_id": "peer_...",
  "role": "requester|provider",
  "result": "attempting|succeeded|failed",
  "observed_endpoint": {
    "network": "udp",
    "host": "203.0.113.10",
    "port": 50000
  },
  "local_endpoints": []
}
```

relay 端点：

```http
POST /api/v1/package-requests
GET /api/v1/package-requests?package_hash=sha256:...
POST /api/v1/package-requests/{request_id}/offers
GET /api/v1/package-requests/{request_id}/offers
POST /api/v1/hole-punch/sessions
POST /api/v1/hole-punch/sessions/{session_id}/reports
GET /api/v1/hole-punch/sessions/{session_id}
POST /api/v1/relay/sessions
PUT /api/v1/relay/sessions/{session_id}/package
GET /api/v1/relay/sessions/{session_id}/package
```

说明：

- `requester_public_key` 不能省略，它是请求签名的身份锚点。
- `review_materials` 是网络导入时必须携带的材料，不是 DHT 的信任来源。
- `provider_addrs`、`requester_addrs`、`available_transports` 只表达连接和路由能力。
- DHT package request / offer 端点只作为短 TTL 需求和供给路由表，不搬运 `.hxp` 字节。
- 供给方发布 offer 或上传 relay 字节前，必须先验证本地 `.hxp` 缓存和审核材料。
- `ExperienceDhtProviderRecord` 只是一层可连接候选，不等于可信经验包。
- DHT 打洞协调只交换候选地址、观测公网地址和尝试结果，不直接完成 UDP socket 穿透。
- DHT relay 只按会话搬运 `.hxp` 字节，不修改包内容，不跳过接收端签名链和 hash 校验。

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
- 后续接入签名、评价链和公共 DHT 列表维护

它不负责：

- 把经验整理成教程
- 自动提炼 Skill
- 把原始过程压缩成结论
- 替代子体侧脱敏确认
- 内置运行 DHT、打洞 socket 或 relay 字节搬运

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
- 子体侧脱敏 UI 与导出格式
