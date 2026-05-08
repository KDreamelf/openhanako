# PH01 认证中心对接

本文记录 `ph01-ai-gateway` 与认证中心的边界、登录流、mTLS、IP 归属地、PH01 密钥规则。

## 职责划分

- 认证中心：注册、登录、签名校验、公钥合法性查询、用户身份管理
- AI 网关：订阅、支付、AI 网关转发、PH01 密钥配置承载、root 公共密钥承载注册/登录期故事生成与还原配置
- 网关本地：保留 New API 既有用户/Token/订阅数据模型
- 用户名：认证中心用户名是唯一用户名，AI 网关侧直接使用同名用户名，不再生成 `ph01_<id>` 影子用户名

## 环境变量

| 变量 | 说明 |
|---|---|
| `PH01_AUTH_BASE_URL` | 认证中心根地址 |
| `PH01_AUTH_BASE` | 兼容别名 |
| `PH01_AUTH_INTERNAL_TOKEN` | 认证中心内部鉴权头 |
| `PH01_AUTH_CA_CERT` | 认证中心 CA 证书路径 |
| `PH01_AUTH_CLIENT_CERT` | 网关客户端证书路径 |
| `PH01_AUTH_CLIENT_KEY` | 网关客户端私钥路径 |
| `PH01_AUTH_SERVER_NAME` | mTLS SNI |
| `PH01_GATEWAY_PUBLIC_BASE_URL` | 网关对外根地址 |
| `PH01_TRUST_PROXY_HEADERS` | 是否信任 `X-Forwarded-For` / `X-Real-IP` |
| `PH01_GEOIP_API_URL` | 线上 IP 归属地接口，支持 `{ip}` 占位符 |
| `PH01_GEOIP_API_TIMEOUT_MS` | 线上归属地接口超时，默认 800ms |
| `PH01_GEOIP_CACHE_TTL_HOURS` | 归属地长效缓存时长，默认 168 小时 |
| `PH01_GEOIP_DB_PATH` | 本地归属地数据库（mmdb）路径，作为兜底 |

## 登录挑战

登录不再只用随机 nonce，而是 challenge 对象，JSON 后再做 base64url 编码。

### 对象结构

```json
{
  "version": 1,
  "purpose": "ph01_ai_gateway_login",
  "nonce": "random-nonce",
  "challenge_id": "random-nonce",
  "ip": "1.2.3.4",
  "ip_location": "CN / Beijing",
  "ua": "Mozilla/5.0 ...",
  "issued_at": 1777632000,
  "expires_at": 1777632300
}
```

### 返回值

`GET /api/ph01/auth/challenge`

返回：

```json
{
  "challenge": "base64url(json)",
  "challenge_id": "random-nonce",
  "nonce": "random-nonce",
  "expires_at": 1777632300,
  "detail": {
    "...": "..."
  },
  "protocol_url": "ph01://login?challenge=...&callback=...nonce=..."
}
```

`challenge_id` 是兼容字段，值与 `nonce` 相同。网关存储 pending challenge 时直接使用 `nonce` 作为 Redis key。

### 两种登录方式

1. 登录码方式
   - 网页显示 challenge
   - 用户在子体客户端“我的”页输入 challenge
   - 客户端弹授权窗，展示 IP、归属地、UA
   - 用户确认后，客户端把带 `user_id` 的签名 JSON 复制到剪贴板
   - 网页粘贴后完成登录

2. 协议方式
   - 网页打开 `ph01://login?...`
   - 子体客户端接收 challenge
   - 客户端弹授权窗，展示 IP、归属地、UA
   - 用户确认后，客户端向 callback 回传带 `user_id` 的签名 JSON
   - 网关轮询 challenge 状态，完成自动登录

### 登录请求

`POST /api/ph01/auth/login`

登录码粘贴和协议回调都使用同一份 JSON。`user_id` 是认证中心用户 ID 明文，用于让网页端不再要求用户输入用户名；`signature` 是客户端私钥对原始 `challenge` 字符串的签名。

请求体：

```json
{
  "user_id": 123,
  "nonce": "random-nonce",
  "signature": "64-byte-rs-hex"
}
```

签名内容就是网页展示或协议收到的 `base64url(json)` challenge 原文，不再包一层 SignedRequest。

网关校验：

- 顶层 `user_id` 必须大于 0
- 明文 `nonce` 必须存在，用于 O(1) 定位 Redis 中的 pending challenge
- `signature` 必须存在
- 网页登录码路径：challenge 由请求体 `nonce` 定位
- 协议登录路径：challenge 由请求体 `nonce` 定位；callback URL 同时携带 `nonce` 作为兜底
- 认证中心验签后返回的 `user_id` 必须等于请求体 `user_id`

认证中心负责校验：

- 按 `user_id` 查未撤销公钥
- 用该用户任一有效公钥验证 `signature(challenge)`
- 用户公钥归属
- 用户状态

子体客户端生成登录码时直接复制上述 JSON；协议登录时把上述 JSON POST 到 `ph01://login` 中携带的 callback。

## 公钥合法性查询

认证中心提供批量查询：

`POST /api/v1/auth/verify_pubkeys`

请求：

```json
{
  "items": [
    { "user_id": 123, "pubkey_hash": "abc..." }
  ]
}
```

命中全部返回：

```json
{ "ok": true }
```

未命中项会在 `missing` 中返回。

网关代理接口：

`POST /api/ph01/auth/pubkeys/verify`

## 用户同步

认证中心注册普通用户成功后调用 AI 网关内部接口：

`POST /api/ph01/internal/users/sync`

请求必须携带 `Authorization: Bearer <PH01_AUTH_INTERNAL_TOKEN>`。请求体：

```json
{
  "ph01_user_id": 123,
  "username": "alice",
  "nickname": "Alice",
  "email": "alice@example.com",
  "tier": "free",
  "pubkey_hash": "..."
}
```

同步规则：

- `username` 直接使用认证中心用户名
- `ph01_user_id` 作为稳定绑定键，避免同名外部来源混淆
- 若网关本地已存在同名用户，则绑定该用户
- 若不存在同名用户，则创建同名网关用户并生成 `PH01 Default Key`
- `root` 属于预置账号，不走注册同步生成；登录时绑定网关 root 用户
- `root` 绑定后还会生成 `PH01 Public Key`，用于注册/登录期故事生成与还原的公共流程

## 子体 AI 通道

AI 网关直接承载子体协议路由：

- `POST /api/v1/channel/handshake`
- `GET /api/v1/models?channel_id=...`
- `POST /api/v1/llm/chat`

握手规则：

- 子体提交 `SignedRequest`，payload 中包含临时 ECDH 公钥
- AI 网关调用认证中心 `verify_signature` 校验长期身份
- 网关生成服务端临时 ECDH 密钥，并把短期通道写入 Redis；Redis 不可用时退回进程内存储
- `PH01 Default Key` 只作为配置承载点读取分组、模型限制和额度，不对外作为 API credential 使用
- 返回的 `allowed_models` 来自该承载点的有效分组与模型限制

聊天规则：

- 子体请求体必须使用握手派生的 AES-256-GCM 加密
- 网关解密后复用 New API 现有 relay 分发、计费、模型限制和渠道选择
- 上游响应再用同一个短期通道密钥加密返回

## IP 归属地

当前实现按以下顺序处理：

1. 先查长效缓存
2. 再查线上归属地接口
3. 最后查本地 mmdb 数据库兜底

- 私网 / 回环地址：直接标记为 `local/private`
- Redis 可用时：归属地缓存写入 Redis；Redis 不可用时退回进程内缓存
- 公网地址：优先走线上接口，成功后写入长效缓存
- 线上接口不可用或未配置时：回退到本地数据库

可选公开方案：

- [MaxMind GeoLite2](https://www.maxmind.com/en/geolite2/signup)
- [DB-IP Lite](https://db-ip.com/db/lite.php)
- [ip-api.com](https://ip-api.com/)

生产环境建议让线上接口返回结果后进入本地长效缓存，同时保留 mmdb 兜底，避免单点依赖。

## mTLS

认证中心与网关之间使用 mTLS。

- 网关启动时读取 CA、客户端证书、客户端私钥
- 认证中心对服务端证书做校验
- 开发环境用脚本生成一组 CA + 双端证书

## PH01 密钥规则

- 取消“创建密钥”按钮
- 普通 PH01 用户保留 `PH01 Default Key`
- root 用户保留 `PH01 Default Key` 与 `PH01 Public Key`
- PH01 系统密钥不能删、不能改名、不能禁用、不能取明文
- `PH01 Default Key` 与 `PH01 Public Key` 都不作为 API 访问凭证
- PH01 系统密钥是配置承载点，可以绑定分组、额度、模型限制等配置
- `PH01 Public Key` 承载注册/登录期故事生成与还原所需的配置

## 子体模型与通信

子体客户端固定连接：

- 认证中心：`https://auth.幻宙.cn`
- AI 网关：`https://ai.幻宙.cn`

子体不配置供应商，不保存上游 API Key，也不走 Codex/OAuth 登录。用户可选模型由 AI 网关动态决定：

1. 子体用长期私钥签名，向 AI 网关发起 ECDH 短期通道协商。
2. AI 网关通过认证中心校验签名和用户身份。
3. AI 网关根据网关本地用户的默认密钥分组，计算该用户可用模型列表。
4. 子体只展示该授权模型列表。
5. 后续聊天请求通过短期通道加密发送。

当前子体调用约定：

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/v1/channel/handshake` | 私钥签名 + ECDH 握手，返回 `channel_id`、服务端临时公钥、空闲过期时间、授权模型 |
| `GET` | `/api/v1/models?channel_id=...` | 读取当前短期通道的授权模型列表 |
| `POST` | `/api/v1/llm/chat` | 使用通道对称密钥加密后的聊天请求 |
| `GET` | `/api/v1/public/story/models` | 匿名读取 root `PH01 Public Key` 配置承载的公开故事模型列表，受公开故事 IP 限流保护 |
| `POST` | `/api/v1/public/story/models` | 已登录子体用 PH01 加密信封读取公开故事模型列表，跳过匿名 IP 限流 |
| `POST` | `/api/v1/public/story/chat` | 注册/登录恢复期故事生成与故事解析；匿名请求用明文 OpenAI chat body，已登录请求可用 PH01 加密信封；服务端禁止 stream/tools |

默认密钥只用于管理端绑定分组、额度、模型限制与订阅权益等配置承载，不作为子体请求凭证下发或使用。root 的公共密钥只用于承载注册/登录期故事生成与还原配置，同样不能作为 API key 使用或展示。

公开故事接口的模型调用始终使用 root 的 `PH01 Public Key` 配置承载。PH01 加密信封只用于已登录子体的传输保密和匿名限流绕过，不会改用当前用户密钥或余额。

## root 用户

- 认证中心用户名为 `root` 的用户，映射到网关 root 用户
- root 仍走授权登录
- root 登录后会生成 `PH01 Default Key` 与 `PH01 Public Key`
- 旧部署若已经只有默认密钥，AI 网关启动时会自动回填缺失的 `PH01 Public Key`
