# ph01-experience-hub · PH01 经验管理端

`ph01-experience-hub` 是部署在大容量服务器上的经验网络管理服务。它保存经验包、维护索引，并向主脑侧 CLI 客户端提供 C/S API。

同一进程还承载经验网络治理能力：主脑发现评价链异常时，可以请求管理端签发否决块。线上只持有 Root 公钥签发的主控证书与主控私钥；Root 私钥离线冷保存，不进部署环境。

它不负责单独运行 DHT 节点、打洞 socket 或 relay 搬运；这些职责由独立的 `experience-dht` 服务承担。管理端只负责公共 DHT 列表、节点注册、健康检查和治理入口。

协议草案见：[docs/experience-package-spec.md](../docs/experience-package-spec.md)。

## 当前能力

- 上传 `.hxp` 经验包或原始转储目录
- 校验外层包至少包含 `package.zip` / `publisher.json` / `ratings.dat`
- 解开 `package.zip` 到 `content/`，作为主脑读取原始记录的只读投影
- 文件系统存储：
  - `inbox/`：待主脑审核
  - `network/`：审核通过
  - `rejected/`：审核拒绝
  - `packages/`：原始 `.hxp`
  - `index.json`：轻量索引
- 输出主脑可读的虚拟文件系统 Markdown 索引
- CLI 客户端 `ph01-expctl`

## 主脑检索口径

经验管理端对主脑暴露的是文件系统式资料库，而不是只返回摘要的 RAG 服务。

主脑侧默认流程：

```text
ph01-expctl vfs
  -> 按目录名 / README / metadata 初筛
  -> 按关键词搜索原始文件
  -> read content/raw/conversation.md
  -> 需要时继续读取 tool-calls / attachments
```

`index.json`、数据库或全文索引只用于加速列表和过滤。经验本体仍然是 `package.zip` 解开的 `content/` 文件树。

## 配置

```bash
cd ph01-experience-hub
cp config.example.json config.json
```

```json
{
  "listen": ":8090",
  "storage_root": "./data/experience-hub",
  "admin_token": "CHANGE_ME_EXPERIENCE_HUB_TOKEN",
  "cors_origins": ["*"],
  "max_upload_bytes": 536870912,
  "review": {
    "trust_admin_uploads": false
  },
  "review_chain_scheduler": {
    "enabled": false,
    "interval_seconds": 60,
    "poll_delay_seconds": 2,
    "limit": 1,
    "dht_fanout_limit": 3
  },
  "auth_center": {
    "base_url": "http://localhost:8080",
    "audience": "ph01-experience-hub"
  },
  "governance": {
    "enabled": true,
    "root_certificate_path": "../certs/public/experience-network/root-certificate.json",
    "master_certificate_path": "../certs/public/experience-network/master-certificate.json",
    "master_private_key_hex": "CHANGE_ME_MASTER_PRIVATE_KEY_HEX"
  }
}
```

生产环境建议：

- `storage_root` 指向大容量磁盘或挂载卷。
- `admin_token` 通过环境变量或部署系统注入。
- 上传接口会把非 hub admin token 的 Bearer 转给认证中心 `/admin/session/self`
  验证；普通 SignedRequest 上传会在包级 PoW 通过后，用签名公钥哈希查询认证中心
  `/api/v1/auth/pubkeys/status`。`review.trust_admin_uploads=false` 时认证中心管理员
  上传进入 inbox；`true` 时只有认证中心状态为 `root/admin` 的账号才自动审核入网。
- 上传前客户端先向管理端申请包级 PoW challenge id，管理端通过认证中心
  `/api/v1/auth/pow/delegated/challenge` 创建通用委托 PoW。上传接口要求每个
  经验包携带已完成的 challenge id，并通过
  `/api/v1/auth/pow/delegated/status` 查询状态；管理端不在本进程内计算 PoW，
  该校验发生在可信管理员免审判断之前。
- `review_chain_scheduler.enabled=true` 后，管理端会按当前网络包存量生成评价链刷新需求，
  投递到已注册且健康的公共 DHT，并把更长的评价链归档为候选链；该功能依赖
  `governance.enabled=true`，因为 DHT 写入需要 PH01 签名。
- 反向代理层启用 HTTPS。

## 启动服务端

```bash
go run ./cmd/experience-hub -config config.json
```

构建：

```bash
go build -o bin/experience-hub ./cmd/experience-hub
go build -o bin/ph01-expctl ./cmd/ph01-expctl
```

## CLI

主脑侧配置：

```bash
export PH01_EXP_BASE_URL=http://localhost:8090
export PH01_EXP_TOKEN=CHANGE_ME_EXPERIENCE_HUB_TOKEN
```

常用命令：

```bash
ph01-expctl pack ./raw_dump ./exp_demo.hxp
ph01-expctl upload ./exp_demo.hxp
ph01-expctl upload ./raw_dump
ph01-expctl vfs
ph01-expctl search GPU benchmark
ph01-expctl list -status inbox
ph01-expctl read exp_demo
ph01-expctl read exp_demo content/raw/conversation.md
ph01-expctl review -status approved -reason "通过审核" exp_demo
ph01-expctl fetch exp_demo ./exp_demo.hxp
```

`review -status approved` 会映射为服务端的 `network` 状态。

## HTTP API

除公开治理证书、DHT 服务发现接口、普通用户 SignedRequest 上传外，`/api/v1/*` 接口都需要：

```http
Authorization: Bearer <admin_token>
```

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/healthz` | 健康检查 |
| `POST` | `/api/v1/experiences?status=inbox` | 管理端 Bearer 上传 raw `.hxp` |
| `POST` | `/api/v1/experiences` | SignedRequest 上传 `.hxp`；非管理员进入 `inbox`，配置允许时 `root/admin` 自动入网 |
| `GET` | `/api/v1/experiences` | 列表，可按 `status` / `keyword` / `q` 过滤 |
| `GET` | `/api/v1/search?q=text&status=network&limit=50` | 搜索 `content/` 下文本文件，返回路径、行号和片段 |
| `GET` | `/api/v1/experiences/{id}` | 查看索引详情 |
| `GET` | `/api/v1/experiences/{id}/file` | 读取默认原始记录入口 |
| `GET` | `/api/v1/experiences/{id}/file?path=content/raw/conversation.md` | 读取包内 Markdown 文件 |
| `GET` | `/api/v1/experiences/{id}/package` | 下载 `.hxp`；network 状态会附加 `review-materials.json` |
| `GET` | `/api/v1/experiences/{id}/review-materials` | 审核通过后单独取回签名/证书材料 |
| `POST` | `/api/v1/experiences/{id}/review` | 更新审核状态；配置治理服务后 network 审核会签发审核材料 |
| `GET` | `/api/v1/vfs/index` | 输出主脑可读 Markdown 虚拟索引 |
| `GET` | `/api/v1/governance/root/certificate` | 公开 Root 公钥证书 |
| `GET` | `/api/v1/governance/master/certificate` | 公开主控证书 |
| `POST` | `/api/v1/governance/veto_blocks/sign` | 主脑风控决策后签发否决块 |
| `GET` | `/api/v1/dht/nodes` | 公开 DHT 节点列表，自动隐藏过期或 unhealthy 节点 |
| `POST` | `/api/v1/dht/nodes/register` | 公开 DHT 节点自注册；用户节点需携带 `owner_peer_id` 对应公钥的 `admin_signed_request` |
| `DELETE` | `/api/v1/dht/nodes/{node_id}` | 注销公开 DHT 节点；请求体携带同一 owner 公钥的 SignedRequest |

对 DHT 来说，“公共”是行为状态：节点主动向管理端注册并持续响应健康检查，就会作为公共 DHT 候选展示；关闭公开时应注销节点或停止心跳。协议不使用单独的可见性字段。

DHT 节点描述字段与客户端保持一致：

```json
{
  "schema_version": "ph01.experience.dht_node.v1",
  "node_id": "dht_01",
  "owner_kind": "user",
  "endpoints": [
    {
      "network": "https",
      "host": "dht.example.com",
      "port": 443
    },
    {
      "network": "udp",
      "host": "203.0.113.10",
      "port": 41001
    }
  ],
  "capabilities": {
    "relay": true,
    "hole_punch": true
  },
  "relay_policy": "public",
  "region": "cn-east",
  "load": {
    "relay_active_sessions": 0,
    "relay_capacity": 100
  },
  "health_status": "healthy",
  "last_health_check_at": "2026-05-09T09:55:00Z",
  "expires_at": "2026-05-09T10:00:00Z"
}
```

审核通过的网络包会携带 `review-materials.json`。原作者也可以只请求
`GET /api/v1/experiences/{id}/review-materials`，客户端会重新校验本地
`package.zip` hash；一致时附加材料，不一致时应重新下载完整包。

## DHT 独立部署口径

DHT 不内置到经验管理端，也不要求通过 `ph01-deploy` 才能部署。源码目录和部署包分开：
`experience-dht/deployment-package/` 是可单独扩散的部署包目录，只携带运行资产和预编译二进制，不携带源码。

经验管理端只负责：

- 维护公共 DHT 列表。
- 接收 DHT 自注册和注销。
- 做健康检查和过期隐藏。
- 作为 P2P 不可达时的稳定下载源。

部署 DHT 节点请使用：

```bash
cd ../experience-dht/deployment-package
./deploy.sh init
./deploy.sh up
```

当 `review.trust_admin_uploads=true` 且请求 Bearer 是认证中心 `root/admin`
管理端 session，或 SignedRequest 的签名公钥在认证中心状态中属于 `root/admin`
账号时，`POST /api/v1/experiences` 会自动导入为 `network`，并在
`review/local-review.json` 中记录 `review_mode=trusted_admin_upload`、
`reviewed_by` 和 `reviewed_role`。该路径仍会校验包结构、`package.zip` hash、
发布者签名，并生成 `review-materials.json`。

普通用户可使用 PH01 `SignedRequest` 上传，业务 payload 使用
`ph01.experience.upload.v1`，包含 `package_base64` 与可选 `package_sha256`。
服务端验签后由管理端查询认证中心账号状态；非管理员只导入 `inbox`，不会因为
query 指定 `status=network` 而免审。
同一个 `experience_id` 一旦进入管理端的 `inbox`、`network` 或 `rejected`，
后续重复上传都会被拒绝，返回 HTTP 409 与 `experience_already_submitted`，
并带回现有状态供客户端同步本地提审状态。
客户端申请包级 PoW challenge 时也应携带 `experience_id`。管理端会在调用认证中心
创建委托 PoW 前先检查重复状态；已存在的经验直接返回同样的 409，不会再创建新挑战。

## 原始转储目录示例

```text
raw_dump/
├── metadata.json
├── raw/
│   ├── conversation.md
│   └── events.md
├── tool-calls/
│   └── run.txt
└── attachments/
```

`metadata.json` 只用于索引：

```json
{
  "schema_version": "ph01.experience.raw.v1",
  "experience_id": "exp_demo",
  "title": "示例原始经验转储",
  "brief": "只用于管理端展示和关键词过滤",
  "keywords": ["demo", "experience"],
  "created_at": "2026-05-01T00:00:00Z"
}
```

`ph01-expctl pack` 会生成：

```text
exp_demo.hxp
├── package.zip
├── publisher.json
└── ratings.dat
```

## 测试

```bash
go test ./...
go vet ./...
```

## 后续接入点

- `publisher.json` 完整签名校验。
- `ratings.dat` 权重计算。
- P2P gossip / fetch。
- 后台索引加速，例如 PG / SQLite / 对象存储；不改变主脑侧文件系统式读取入口。
