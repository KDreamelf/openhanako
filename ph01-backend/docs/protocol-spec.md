# PH01 非对称身份与通信协议契约

**版本**：v1.5  
**日期**：2026-05-05  
**状态**：实施中  
**约束**：本文档由子体侧定义，业务后台网关（auth-gateway）/ AI 网关（ai-gateway）/ 主脑（master-server）等所有对端必须遵循。

---

## 0. 核心原则

PH01 不使用传统 `token` / `session` 作为用户登录态。

- **长期身份 = 用户持有合法私钥**。
- **公钥是公开身份材料**，可出现在用户资料、P2P 评价链、签名验证材料和公钥查询接口中。
- 服务端保存 `user_id -> public_key` 绑定关系，并用公钥验签确认请求者持有对应私钥。
- 私钥不过期；只要客户端持有未撤销私钥，就拥有该身份。
- 短期对称密钥只属于通信层，用于加密 LLM 请求等传输内容，不是登录凭据。

因此，系统安全不依赖“公钥保密”，只依赖私钥、助记词、故事/关键词等恢复材料不泄露。

---

## 1. 名词

| 术语 | 含义 |
|---|---|
| **子体** | 用户电脑上的客户端（hanako-flutter） |
| **auth-gateway** | 用户、公钥、恢复候选、SignedRequest 验签、用户管理后台 |
| **ai-gateway** | 正式 AI 网关，指 `ph01-ai-gateway` 魔改 New API。负责短期通信通道协商、加密转发、模型映射和套餐限流 |
| **长期身份私钥** | 用户永久身份凭据，只保存在客户端 |
| **短期通信通道 / channel** | 由 ECDH 派生的短期 AES-GCM 通信密钥，有空闲过期时间，不是登录态 |
| **主脑 / master-server** | 集群中央节点，负责经验审核 / Veto Block 等；不在本契约范围内 |

---

## 2. 密钥与签名格式

### 2.1 算法

- **签名算法**：ECDSA over **secp256k1**
- **密钥协商**：ECDH over **secp256k1** + HKDF-SHA256 派生 AES-256
- **摘要**：SHA-256
- **对称加密**：AES-256-GCM，nonce 12 字节随机

### 2.2 密钥序列化

| 字段 | 长度 | 编码 |
|---|---:|---|
| 私钥 | 32 字节 | 大端，仅本地保存 |
| 公钥 | 65 字节 | 非压缩：`0x04 ‖ X(32) ‖ Y(32)` |
| 公钥 hex | 130 字符 | 小写 hex，不带 `0x` |
| 公钥哈希 | 32 字节 | `SHA-256(公钥 65 字节)` |
| 公钥哈希 hex | 64 字符 | 小写 hex，不带 `0x` |

### 2.3 签名格式

| 字段 | 长度 | 编码 |
|---|---:|---|
| 签名 | 64 字节 | 固定长度 `r ‖ s`，大端，不用 DER |
| 签名 hex | 128 字符 | 小写 hex |
| 待签名摘要 | 32 字节 | `SHA-256(消息)` |

### 2.4 助记词派生

- 助记词 = 12 个中文名词，字典见 `hanako-flutter/lib/identity/word_dict.dart`
- 派生：`PBKDF2-HMAC-SHA512(mnemonic_str, "mnemonic", 2048, 64)` → 64 字节 seed
- 私钥 = `seed[0:32]`
- 不做 BIP-32 HD 派生

---

## 3. 用户与公钥模型

### 3.1 用户实体

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | uint64 / uuid | 主键 |
| `username` | string(32) | 唯一，用户标识 |
| `nickname` | string(64) | 昵称 |
| `email` | string(254) | 注册时必须验证，用于第二阶段 RFA / 2FA |
| `tier` | enum | `free` / `pro` / `enterprise` |
| `disabled` | bool | 禁用标志 |
| `created_at` | timestamp | 创建时间 |

### 3.2 公钥实体

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | uint64 | 主键 |
| `user_id` | uint64 | 外键 |
| `pubkey_hex` | string(130) | 65 字节非压缩公钥 hex |
| `pubkey_hash` | string(64) | SHA-256(公钥) hex |
| `created_at` | timestamp | 创建时间 |
| `revoked_at` | timestamp? | 撤销时间，nil 表示有效 |

轮换语义：

- 用户可拥有多个公钥。
- 旧公钥不删除，只标记 `revoked_at`。
- 验签只接受未撤销公钥。

---

## 4. SignedRequest

所有需要长期身份证明的请求使用同一个外层包装：

```json
{
  "payload": "{...原始请求 JSON 字符串...}",
  "pubkey": "04abcd...",
  "signature": "deadbeef...",
  "timestamp": 1777632000,
  "nonce": "8字节hex"
}
```

待签名内容：

```text
payload + "\n" + pubkey + "\n" + timestamp + "\n" + nonce
```

服务端验签流程：

1. 检查 `timestamp` 在允许窗口内。
2. 检查 `nonce` 未在窗口内重复。
3. 用 `pubkey` 验证 `signature`。
4. 计算 `pubkey_hash`。
5. 检查该公钥已注册、未撤销、用户未禁用。
6. 将 `user_id` / `tier` 作为本次请求上下文。

---

## 5. 注册与身份确认

### 5.0 用户名可用性预检

**GET `/api/v1/auth/username_available?username=alice`**

公开接口，不要求签名。用于子体首次引导判断用户名后续流程：

- `available=true`：进入新身份注册。
- `available=false`：用户名已存在，进入既有账号恢复登录。

响应：

```json
{
  "username": "alice",
  "available": true
}
```

### 5.1 注册邮箱验证

**POST `/api/v1/auth/register_email/start`**

公开接口，不要求签名。用户名预检可用后，子体先提交用户名和邮箱，请求认证中心发送注册验证码。

请求：

```json
{
  "username": "alice",
  "email": "alice@example.com"
}
```

响应：

```json
{
  "challenge_id": "email-challenge-id",
  "delivery": "a***e@example.com",
  "expires_in": 600,
  "cooldown_seconds": 60
}
```

同一邮箱注册验证码发送成功后，服务端强制 60 秒冷却。冷却期内再次请求返回：

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 42
```

```json
{
  "error": "rate_limit_exceeded",
  "message": "rate_limit_exceeded",
  "retry_after": 42
}
```

### 5.2 注册

**POST `/api/v1/auth/register`**

请求是 `SignedRequest`，payload：

```json
{
  "username": "alice",
  "nickname": "Alice",
  "email": "alice@example.com",
  "email_challenge_id": "email-challenge-id",
  "email_code": "123456",
  "pubkey_hex": "04abcd..."
}
```

服务端：

1. 验证签名，确认客户端持有该公钥对应私钥。
2. 检查 `payload.pubkey_hex == outer.pubkey`。
3. 校验注册邮箱验证码，确认邮箱属于本次注册。
4. 创建用户与第一把公钥。
5. 返回身份摘要。

响应：

```json
{
  "user_id": 12345,
  "username": "alice",
  "tier": "free",
  "pubkey_hash": "abc123..."
}
```

服务端不签发 JWT、access token 或长期 session。

### 5.3 身份确认

**POST `/api/v1/auth/login`**

这里的 `login` 不是换取 token，而是一次“我持有该用户私钥”的签名确认。payload：

```json
{ "username": "alice" }
```

服务端：

1. 验证 SignedRequest。
2. 根据请求公钥查用户。
3. 确认公钥属于 `username` 且未撤销。
4. 返回身份摘要。

响应同注册响应。

---

## 6. 恢复流程

恢复的目标不是换取 token，而是在新设备上重新得到用户长期身份私钥。

### 6.1 第一阶段：快速恢复

- LLM 只输出两层矩阵：`K=2`。
- 客户端本地枚举 `D=12`，即完整覆盖 `2^12 = 4096` 个组合。
- 本地先做 BIP-39 checksum 过滤。
- checksum 通过后派生私钥、公钥与公钥哈希。
- 公钥 / 公钥哈希可作为公开验证材料使用。
- 若候选私钥对应到该用户有效公钥，则恢复成功并持久化私钥。

### 6.2 恢复候选查询

**POST `/api/v1/auth/recovery_candidates`**

请求体不签名，因为客户端此时可能还没有恢复出私钥：

```json
{ "username": "alice" }
```

响应：

```json
{
  "username": "alice",
  "pubkey_hashes": ["abc123...", "def456..."],
  "server_signature": ""
}
```

安全边界：

- 公钥和公钥哈希不是秘密。
- 此接口仍必须限频，因为它能帮助已经拿到故事/关键词的攻击者做目标确认。
- 失败多次后进入 RFA / 2FA，再开放 K=3/K=4 的深度恢复。

### 6.3 第二阶段：深度恢复

触发条件：

- K=2 全量恢复失败。
- 用户通过 RFA / 2FA。当前默认机制是绑定邮箱验证码。

**POST `/api/v1/auth/recovery_rfa/start`**

请求：

```json
{ "username": "alice" }
```

响应：

```json
{
  "challenge_id": "base64url...",
  "delivery": "a***e@example.com",
  "expires_in": 600,
  "cooldown_seconds": 60
}
```

同一邮箱恢复验证码发送成功后，服务端同样强制 60 秒冷却；冷却期内返回 `429 rate_limit_exceeded`，响应体带 `retry_after`，响应头带 `Retry-After`。

**POST `/api/v1/auth/recovery_rfa/verify`**

请求：

```json
{
  "challenge_id": "base64url...",
  "code": "123456"
}
```

响应：

```json
{
  "recovery_grant": "base64url...",
  "expires_in": 1800,
  "max_candidates_per_column": 4
}
```

`recovery_grant` 只表示“该用户通过了邮箱二验，可以进入更宽矩阵的深度恢复”。它不是登录态，不能用于调用 LLM 或业务 API。

通过后，客户端可请求更宽矩阵：

- K=3 或 K=4。
- Windows 端优先使用 GPU 恢复后端。
- 仍然以恢复长期私钥为目标，不发放 token。

---

## 7. 公钥合法性查询

公钥是公开身份材料。认证中心提供批量绑定查询，用于 AI 网关、P2P 评价链校验等场景快速判断一组 `user_id + pubkey_hash` 是否全部属于 PH01 当前有效身份集合。

**POST `/api/v1/auth/verify_pubkeys`**

请求：

```json
{
  "items": [
    { "user_id": 12345, "pubkey_hash": "abc123..." },
    { "user_id": 67890, "pubkey_hash": "def456..." }
  ]
}
```

语义：

- 只接受未撤销公钥。
- 用户被禁用时视为未命中。
- 单次最多 1000 项。
- 全部命中只返回 `ok: true`。
- 未命中时只返回未命中项。

全部有效：

```json
{ "ok": true }
```

存在未命中：

```json
{
  "ok": false,
  "missing": [
    { "user_id": 67890, "pubkey_hash": "def456..." }
  ]
}
```

### 7.1 AI 网关登录挑战验签

AI 网关登录码 / 协议登录不再提交用户名，也不再把登录响应包成 SignedRequest。客户端响应只包含用户 ID、明文 nonce 和对 challenge 的签名。

客户端返回给 AI 网关：

```json
{
  "user_id": 12345,
  "nonce": "random-nonce",
  "signature": "deadbeef..."
}
```

AI 网关用 `nonce` 作为 Redis key，O(1) 取回 pending challenge。nonce 已包含在 challenge JSON 内，外层 nonce 只用于定位，不参与保密。

AI 网关调用认证中心内部接口：

```json
{
  "user_id": 12345,
  "challenge": "base64url(json)",
  "signature_hex": "deadbeef..."
}
```

语义：

- `user_id` 不是秘密，只用于定位认证中心用户。
- `challenge` 是 AI 网关生成并展示给客户端的 base64url(JSON) 原文。
- `signature_hex` 是客户端私钥对 `challenge` 原文的 ECDSA-SHA256 签名。
- 认证中心按 `user_id` 查未撤销公钥，并用任一有效公钥验证签名。
- 验签成功返回 `user_id`、`username`、`tier`、`pubkey_hash`。
- 用户不存在、被禁用、无有效公钥或签名不匹配时返回 `valid: false`。

---

## 8. 短期通信通道（子体 ↔ ai-gateway）

子体调 LLM 时先建立短期通信通道。通道只保存 AES-GCM 密钥和用户上下文，不代表长期登录态。

### 8.1 握手

**POST `/api/v1/channel/handshake`**

请求是 `SignedRequest`，payload：

```json
{
  "ephemeral_pubkey": "04abcd..."
}
```

流程：

1. 子体生成临时 ECDH 密钥对。
2. 子体用长期身份私钥签名握手 payload。
3. ai-gateway 调 auth-gateway 验签。
4. ai-gateway 生成服务端临时 ECDH 密钥对。
5. 双方派生同一个 AES-256 key。
6. ai-gateway 将短期通道保存到 Redis，空闲 TTL 默认 10 分钟。

响应：

```json
{
  "channel_id": "...",
  "ephemeral_pubkey": "04abcd...",
  "idle_expires_in": 600,
  "allowed_models": ["mock-gpt"]
}
```

### 8.2 加密消息包装

```json
{
  "channel_id": "...",
  "nonce": "12字节hex",
  "ciphertext": "AES-256-GCM密文hex",
  "tag": "16字节tag hex"
}
```

服务端用 `channel_id` 找到短期 AES key。`channel_id` 只是通信通道索引，不是身份 token；通道过期后客户端静默重新握手。

### 8.3 LLM 调用

**POST `/api/v1/llm/chat`**

加密前 plaintext：

```json
{
  "model": "mock-gpt",
  "messages": [{"role": "user", "content": "..."}],
  "stream": true
}
```

服务端：

1. 取出通道 AES key。
2. 解密请求。
3. 校验模型白名单与限流。
4. 转发上游 LLM。
5. 把响应用同一通道密钥加密返回。
6. 每次成功使用后刷新通道空闲 TTL。

---

## 9. 错误码

| 错误码 | HTTP | 说明 |
|---|---:|---|
| `invalid_signature` | 401 | 签名验证失败 |
| `timestamp_expired` | 401 | 时间戳超出窗口 |
| `nonce_replayed` | 401 | nonce 重放 |
| `pubkey_not_found` | 401 | 公钥未注册或已撤销 |
| `user_disabled` | 403 | 用户被禁用 |
| `user_not_found` | 404 | 用户名不存在 |
| `username_taken` | 409 | 用户名已占用 |
| `model_not_allowed` | 403 | 套餐不支持该模型 |
| `rate_limit_exceeded` | 429 | 超出限流 |
| `channel_expired` | 401 | 短期通信通道过期，需重新握手 |
| `invalid_channel` | 401 | `channel_id` 不存在 |
| `rfa_not_available` | 503 | 恢复二验服务未配置或 Redis 不可用 |
| `email_not_configured` | 503 | 邮件发送配置缺失或无效 |
| `email_not_bound` | 400 | 用户未绑定恢复邮箱 |
| `email_verification_required` | 400 | 注册邮箱挑战或验证码缺失 / 不匹配 |
| `rfa_challenge_not_found` | 404 | 验证挑战不存在或已失效 |
| `rfa_code_invalid` | 401 | 验证码错误 |
| `rfa_code_expired` | 400 | 验证码过期 |
| `decryption_failed` | 400 | 对称解密失败 |
| `invalid_payload` | 400 | payload JSON 解析失败 |
| `internal_error` | 500 | 服务端内部错误 |

---

## 10. 文件位置

| 模块 | 路径 |
|---|---|
| 子体侧身份实现 | `hanako-flutter/lib/identity/` |
| 子体后端客户端 | `hanako-flutter/lib/identity/hanako_backend_client.dart` |
| 子体 ECDH | `hanako-flutter/lib/identity/ecdh.dart` |
| auth-gateway | `ph01-backend/cmd/auth-gateway/` |
| ai-gateway | `ph01-ai-gateway/` |
| 旧 Go 版 ai-gateway 原型 | `ph01-backend/cmd/legacy-ai-gateway/`，不参与当前生产部署 |
| 共享密码学库 | `ph01-backend/internal/crypto/` |
| 协议数据结构 | `ph01-backend/pkg/api/proto.go` |

---

## 11. 版本演进

- **v1.0 (2026-04-27)**：secp256k1 + ECDH + AES-256-GCM 初版。
- **v1.1 (2026-05-01)**：移除 JWT 登录态；明确私钥即长期身份；将短期 `session` 语义改为通信 `channel`。
- **v1.2 (2026-05-01)**：接入邮箱 RFA；验证码通过后发放短期 `recovery_grant`，只授权 K=3/K=4 深度恢复。
- **v1.3 (2026-05-01)**：新增批量 `user_id + pubkey_hash` 合法性查询，供 AI 网关和 P2P 校验使用。
- **v1.4 (2026-05-04)**：AI 网关登录码 / 协议登录响应简化为 `user_id + nonce + signature(challenge)`。
- **v1.5 (2026-05-05)**：注册流程新增邮箱验证码；`/auth/register` 必须携带邮箱、挑战 ID 与验证码。
