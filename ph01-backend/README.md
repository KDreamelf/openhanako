# ph01-backend · PH01 认证中心

这是子体（`hanako-flutter`）配套的认证中心 / 授权中心。生产部署只构建并运行一个服务：

| 服务 | 默认端口 | 职责 |
|---|---:|---|
| `auth-center` | 8080 / 8443 | 用户、唯一用户名、公钥、邮箱验证码、恢复二验、SignedRequest 验签、用户管理后台、AI 网关账号同步 |

源码入口仍叫 `cmd/auth-gateway`，生产镜像入口叫 `auth-center`。这两个名字指向同一个认证中心服务。

## 与 AI 网关的边界

正式 AI 网关是 `../ph01-ai-gateway/`，它是魔改 New API，自己带后端与前端，生产镜像由 `ph01-deploy/production/build-images.sh` 从 `ph01-ai-gateway/Dockerfile` 构建。

本目录内的 `cmd/legacy-ai-gateway` 是早期 Go 版 AI 网关原型，已被 `ph01-ai-gateway` 替代，不参与当前生产部署，也不应再被理解为正式 AI 网关。它暂时保留作协议演进参考，后续可以删除或迁移到历史目录。

当前生产三端是：

| 目录 | 生产服务 | 说明 |
|---|---|---|
| `ph01-backend/` | `ph01-auth-center` | 认证中心 / 授权中心 |
| `ph01-ai-gateway/` | `ph01-ai-gateway` | 魔改 New API，正式 AI 网关 |
| `ph01-experience-hub/` | `ph01-experience-network-manager` | 经验网络管控端 |

## 关键约束

- 生产数据源使用 PostgreSQL。
- Redis 用于 nonce 防重放、注册邮箱验证码、恢复二验与限频。
- 用户名在认证中心唯一；AI 网关侧直接使用认证中心用户名。
- 用户长期身份由客户端私钥证明；服务端不签发 JWT / access token / 长期 session。
- `config.hcl` 是认证中心配置事实来源；SMTP 管理页保存时直接回写该文件。
- SQLite 只保留给单元测试使用。

## 固定端点

子体客户端默认直连：

- `https://auth.幻宙.cn` -> 认证中心
- `https://ai.幻宙.cn` -> 正式 AI 网关（`ph01-ai-gateway`）

认证中心内部需要知道 AI 网关同步接口：

- 生产 Docker 内网：`http://ph01-ai-gateway:3000`
- 本地联调：按实际 New API 端口配置

## 配置

本地开发先复制示例配置：

```bash
cd ph01-backend
cp config.hcl.example config.hcl
```

`config.hcl` 至少要填：

```hcl
database "auth" {
  driver = "postgres"
  dsn    = "host=localhost port=5432 user=hanako password=CHANGE_ME dbname=hanako_auth sslmode=disable"
}

redis "auth" {
  url = "redis://localhost:6379/0"
}

smtp "recovery" {
  enabled  = true
  host     = "smtp.example.com"
  port     = 587
  username = "noreply@example.com"
  password = "CHANGE_ME_SMTP_PASSWORD"
  from     = "PH01 <noreply@example.com>"
  tls_mode = "require_starttls"
}

ai_gateway_sync "default" {
  enabled        = true
  base_url       = "http://localhost:3000"
  internal_token = "CHANGE_ME_PH01_INTERNAL_SYNC_TOKEN"
  timeout_ms     = 5000
}

server "auth_gateway" {
  listen       = ":8080"
  admin_token  = "CHANGE_ME_ADMIN_TOKEN_FOR_AUTH_GATEWAY"
  public_base_url = "https://auth.xn--lbtx0e.cn"
  cors_origins = ["*"]
}
```

正式部署使用 `ph01-deploy/production/config/auth-center.hcl` 预置文件，并在部署脚本首次运行时落到 `data/production/config/auth-center.hcl`。`public_base_url` 是管理端协议登录回调的公网根地址，可用环境变量 `PH01_AUTH_PUBLIC_BASE_URL` 临时覆盖。

## 启动

Linux / macOS：

```bash
cd ph01-backend
./scripts/start-all.sh --rebuild
```

Windows PowerShell：

```powershell
cd ph01-backend
.\scripts\start-all.ps1 -Rebuild
```

如果 `config.hcl` 不存在，脚本会从 `config.hcl.example` 生成一份并停止；填完真实配置后再启动。

管理后台：

- `http://localhost:8080/`
- `http://localhost:8080/admin-ui/auth.html`

## 本地 Docker 依赖

本地依赖用 Docker Compose 拉起：

```bash
cd ph01-backend
docker-compose -f docker-compose.local.yml up
```

包含：

- PostgreSQL 16：`localhost:15432`
- Redis 7：`localhost:16379`
- Mock OpenAI-compatible 上游：`localhost:18080/v1`

本地 `config.local.hcl` 不提交仓库，建议按 `config.hcl.example` 生成后改成：

- `database "auth"`：`host=localhost port=15432 ... dbname=hanako_auth`
- `redis "auth"`：`redis://localhost:16379/0`
- `smtp "recovery"`：注册邮箱验证码与恢复二验共用；只支持 `require_starttls` + 587 或 `tls` + 465，不支持明文 SMTP
- `ai_gateway_sync "default"`：指向本地运行的 `ph01-ai-gateway`

## 构建与测试

```bash
go build ./cmd/auth-gateway
go test ./...
```

## API 概览

`auth-center`：

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/v1/auth/username_available?username=...` | 公开用户名预检；可用则注册，已存在则进入恢复登录 |
| `POST` | `/api/v1/auth/register_email/start` | 注册前邮箱验证码；用户名可用后调用 |
| `POST` | `/api/v1/auth/register` | 注册新用户（SignedRequest，必须带邮箱验证码） |
| `POST` | `/api/v1/auth/login` | 身份确认（SignedRequest，不签发 token） |
| `POST` | `/api/v1/auth/rotate_pubkey_email/start` | 密钥轮换前邮箱验证码；必须由当前有效私钥签名 |
| `POST` | `/api/v1/auth/rotate_pubkey` | 密钥轮换；必须同时通过旧私钥签名和邮箱验证码 |
| `POST` | `/api/v1/auth/recovery_candidates` | 拉取某用户名的未撤销公钥哈希集合 |
| `POST` | `/api/v1/auth/recovery_rfa/start` | 第二阶段恢复：发送邮箱验证码 |
| `POST` | `/api/v1/auth/recovery_rfa/verify` | 第二阶段恢复：验证码换取短期 recovery grant |
| `POST` | `/api/v1/auth/verify_signature` | 内部验签接口，供 AI 网关调用；可带 `user_id` 约束公钥归属 |
| `POST` | `/api/v1/auth/verify_challenge_signature` | 内部验签接口，按 `user_id` 验证 `signature(challenge)` |
| `POST` | `/api/v1/auth/verify_pubkeys` | 批量校验 `user_id + pubkey_hash` 绑定关系 |
| `POST` | `/api/v1/auth/verify_pubkeys_at` | 按签名时间戳批量校验历史公钥绑定关系 |
| `GET` | `/admin/session/challenge` | 管理端 PH01 登录挑战码；用于网页登录码和 `ph01://login` |
| `GET` | `/admin/session/challenge/:id/status` | 管理端协议登录轮询；完成后返回后台 session |
| `POST` | `/admin/session/login_code` | 管理端网页登录码登录；仅 `root/admin` 角色可用 |
| `POST` | `/admin/session/protocol/complete` | 子体协议登录回调；仅 `root/admin` 角色可用 |
| `POST` | `/admin/session/login` | 管理端旧 SignedRequest 登录；仅 `root/admin` 角色可用 |
| `GET` | `/admin/session/self` | 管理端当前会话 |
| `GET` | `/admin/users` | 管理：用户列表 |
| `PATCH` | `/admin/users/:id` | 管理：修改 tier / disabled / email / role |
| `POST` | `/admin/users/:id/pubkeys/:pubkey_id/revoke` | 管理：撤销公钥 |
| `GET/PATCH` | `/admin/config/smtp` | 管理：注册与恢复邮箱 SMTP 配置 |
| `POST` | `/admin/config/smtp/test` | 管理：发送 SMTP 测试邮件 |
| `GET` | `/admin/logs` | 管理：审计日志 |

SMTP 配置不写数据库配置表，`config.hcl` 是唯一事实来源；管理端保存 SMTP 时会直接回写 `config.hcl`。

## 项目结构

```text
ph01-backend/
├── cmd/
│   ├── auth-gateway/        # 生产认证中心入口
│   └── legacy-ai-gateway/   # 遗留 Go 原型，不参与生产部署
├── internal/
│   ├── auth/
│   ├── config/
│   ├── crypto/
│   ├── db/
│   ├── redisx/
│   ├── syncai/
│   ├── system/
│   └── user/
├── pkg/api/
├── web/admin/
├── docs/protocol-spec.md
└── config.hcl.example
```

## 安全待办

- CORS 在生产环境收紧到明确域名。
- PostgreSQL 与 Redis 必须有备份和访问控制。
- 恢复候选响应的 root 签名仍待接入独立 Root 权限服务。
