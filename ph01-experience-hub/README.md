# ph01-experience-hub · PH01 经验管理端

`ph01-experience-hub` 是部署在大容量服务器上的经验网络管理服务。它保存经验包、维护索引，并向主脑侧 CLI 客户端提供 C/S API。

同一进程还承载经验网络治理能力：主脑发现评价链异常时，可以请求管理端签发否决块。线上只持有 Root 公钥签发的主控证书与主控私钥；Root 私钥离线冷保存，不进部署环境。

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

所有 `/api/v1/*` 接口都需要：

```http
Authorization: Bearer <admin_token>
```

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/healthz` | 健康检查 |
| `POST` | `/api/v1/experiences?status=inbox` | 上传 `.hxp` |
| `GET` | `/api/v1/experiences` | 列表，可按 `status` / `keyword` / `q` 过滤 |
| `GET` | `/api/v1/search?q=text&status=network&limit=50` | 搜索 `content/` 下文本文件，返回路径、行号和片段 |
| `GET` | `/api/v1/experiences/{id}` | 查看索引详情 |
| `GET` | `/api/v1/experiences/{id}/file` | 读取默认原始记录入口 |
| `GET` | `/api/v1/experiences/{id}/file?path=content/raw/conversation.md` | 读取包内 Markdown 文件 |
| `GET` | `/api/v1/experiences/{id}/package` | 下载原始 `.hxp` |
| `POST` | `/api/v1/experiences/{id}/review` | 更新审核状态 |
| `GET` | `/api/v1/vfs/index` | 输出主脑可读 Markdown 虚拟索引 |
| `GET` | `/api/v1/governance/root/certificate` | 公开 Root 公钥证书 |
| `GET` | `/api/v1/governance/master/certificate` | 公开主控证书 |
| `POST` | `/api/v1/governance/veto_blocks/sign` | 主脑风控决策后签发否决块 |

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
