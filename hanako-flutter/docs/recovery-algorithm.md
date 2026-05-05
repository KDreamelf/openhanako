# Hanako 子体身份恢复算法

**版本**：v4  
**日期**：2026-05-01  
**状态**：实施中  
**与对端约定**：长期身份由私钥证明；恢复流程的目标是重新得到私钥，不是换取 token。

---

## 1. 安全模型

- 公钥和公钥哈希是公开身份材料，不作为秘密保护。
- 私钥、助记词、故事/关键词是敏感恢复材料。
- 用户恢复成功后，客户端持久化私钥；后续请求直接用私钥签名或进行 ECDH 通信协商。
- 服务端不签发 JWT / access token / 长期 session。
- 短期对称密钥只属于通信层，空闲过期后静默重新握手。

---

## 2. 两阶段恢复

### 2.1 第一阶段：快速恢复

第一阶段默认只让 LLM 每列输出两个候选：

- `K = 2`
- `D = 12`
- 全空间：`2^12 = 4096`
- 本地计算目标：30 秒内完成

流程：

1. 用户输入故事或关键词。
2. LLM 输出 `12 × 2` 候选矩阵。
3. 客户端本地枚举完整矩阵。
4. 每个组合先做 BIP-39 checksum。
5. checksum 通过后才做 PBKDF2、secp256k1 公钥派生、公钥哈希。
6. 若候选公钥哈希命中该用户的有效公钥哈希集合，恢复成功。
7. 客户端将恢复出的私钥写入本地 keystore。

第一阶段不限制汉明距离，因为 K=2 的全空间足够小。

### 2.2 第二阶段：深度恢复

第一阶段失败后进入 RFA / 2FA。当前默认机制是邮箱验证码。验证通过后再开放更宽矩阵：

- `K = 3` 或 `K = 4`
- Windows 桌面优先使用 GPU 恢复后端
- 仍然只恢复私钥，不引入 token/session 登录态
- 服务端返回的 `recovery_grant` 只授权深度恢复，不是登录态

---

## 3. 矩阵协议

LLM 必须输出严格 JSON：

```json
{
  "columns": [
    [12, 84],
    [451, 77],
    [15, 200]
  ]
}
```

约束：

| 字段 | 约束 |
|---|---|
| `columns` | 外层固定 12 行 |
| `columns[i]` | 第一阶段固定 2 个 ID |
| `columns[i][r]` | 字典 ID，范围 `[0, 2047]` |
| 排序 | rank-0 最相似，rank-1 次相似 |

RFA 后的深度恢复可以用 `StoryParser(candidatesPerColumn: 3)` 或 `4` 生成更宽矩阵。

---

## 4. 汉明距离枚举

定义：

```text
d(S, M) = #{ i : S_i != M[i][0] }
```

枚举顺序：

```text
for d = 0..D_max:
  for each subset C of columns with |C| = d:
    for each rank vector R in {1..K-1}^d:
      build candidate ids
      attempt(candidate)
```

K=2 时，`D=12` 即完整覆盖所有 `4096` 个组合。

---

## 5. 单次 attempt

```text
1. 12 个 ID -> BIP-39 checksum
2. checksum 失败：快速丢弃
3. checksum 通过：PBKDF2-HMAC-SHA512(mnemonic, "mnemonic", 2048, 64)
4. seed[0:32] -> secp256k1 私钥
5. 私钥 * G -> 65 字节非压缩公钥
6. SHA-256(公钥) -> 公钥哈希
7. hash 命中目标集合 -> 恢复成功
```

checksum 约 `15/16` 快速失败，所以第一阶段实际进入 PBKDF2 的组合约 `4096 / 16 = 256`。

---

## 6. GPU 基准

Windows + GTX 1660 SUPER 实测：

| 指标 | 结果 |
|---|---:|
| GPU PBKDF2-HMAC-SHA512-2048 | 约 `32,692/s` |
| checksum 折算矩阵枚举 | 约 `523,066 组合/s` |
| 60 秒折算枚举量 | 约 `31,457,280 组合` |
| native CPU secp256k1 公钥派生 | 约 `44,474/s` |

全矩阵估算：

| K | 全空间 | 估算耗时 |
|---|---:|---:|
| 2 | `4,096` | 小于 1 秒 |
| 3 | `531,441` | 约 1 秒 |
| 4 | `16,777,216` | 约 32 秒 |
| 5 | `244,140,625` | 约 7.8 分钟 |

基准工具：

- `benchmarks/gpu_recovery_bench/gpu_recovery_bench.py`
- `benchmarks/gpu_recovery_bench/results/gtx1660super-60s-reuse-kernel.json`

---

## 7. 服务端协作

第一阶段需要服务端提供该用户名下的有效公钥哈希集合：

```http
POST /api/v1/auth/recovery_candidates
```

请求：

```json
{ "username": "alice" }
```

响应：

```json
{
  "username": "alice",
  "pubkey_hashes": ["sha256_hex_64"],
  "server_signature": ""
}
```

此接口不要求签名，因为用户此时可能还没恢复出私钥。它必须限频、审计、失败冷却。

第二阶段邮箱 RFA：

```http
POST /api/v1/auth/recovery_rfa/start
```

请求：

```json
{ "username": "alice" }
```

响应：

```json
{
  "challenge_id": "base64url",
  "delivery": "a***e@example.com",
  "expires_in": 600
}
```

```http
POST /api/v1/auth/recovery_rfa/verify
```

请求：

```json
{
  "challenge_id": "base64url",
  "code": "123456"
}
```

响应：

```json
{
  "recovery_grant": "base64url",
  "expires_in": 1800,
  "max_candidates_per_column": 4
}
```

客户端拿到 `max_candidates_per_column` 后，再用 `StoryParser(candidatesPerColumn: 3/4)` 进入深度恢复。

---

## 8. 文件位置

| 模块 | 路径 |
|---|---|
| 密钥对 | `lib/identity/keypair.dart` |
| 助记词派生 | `lib/identity/mnemonic.dart` |
| 故事解析 | `lib/identity/story_parser.dart` |
| 矩阵搜索 | `lib/identity/recovery.dart` |
| 业务封装 | `lib/identity/identity_repository.dart` |
| GPU benchmark | `../benchmarks/gpu_recovery_bench/` |
