# 经验网络 DHT 可信、PoW 与信誉设计记录

本文记录 2026-05-14 关于 DHT 节点 PoW、用户 PoW、小红花、花环、用户信誉和节点信誉的设计口径。后续实现不得把这些机制混成单一信誉字段，也不得因为“防作弊”误伤真实高贡献用户。

## 核心分层

经验网络可信与信誉分为三层：

```text
用户 PoW：证明用户账号具备真人/真实设备成本
DHT 节点 PoW：证明公开 DHT 节点身份创建具备成本
服务证明：证明 DHT 节点真实帮助用户完成网络工作
```

- 用户 PoW 用于 AI 网关权益策略和小红花权重，不影响正常注册登录。
- DHT 节点 PoW 用于公开 DHT 节点准入和握手初验，防女巫攻击和日食攻击。
- 小红花/花环用于证明节点确实服务过真实用户，并可进一步沉淀为用户信誉。

## 用户 PoW

用户 PoW 不影响正常注册、登录和普通 API。

客户端在查询认证中心用户状态或公钥有效性时，如果发现当前用户没有 PoW 状态，则在按钮区显示：

```text
验证你是真人（无感验证）
```

点击后弹出模态框，说明：

- 本地会执行一次内存用量证明计算。
- 该计算用于提高批量刷号和黑产套利成本。
- 不上传用户隐私数据。
- 完成后使用当前用户私钥签名提交。

流程：

1. 客户端向认证中心请求 PoW challenge。
2. 认证中心把 challenge 和参数写入缓存。
3. 客户端本地执行内存用量证明。
4. 可采用串行多轮，后一轮依赖前一轮结果；在不降低存储难度的前提下降低单轮计算难度，确保速度合理。
5. 客户端对 PoW 结果、challenge ID、公钥哈希和用途签名。
6. 认证中心快速验证。
7. 验证通过后，认证中心只更新用户 PoW 状态，不长期保存具体 PoW 解值。

建议 challenge 输入包含：

```text
pubkey_hash
server_nonce
purpose
difficulty
round_count
issued_at
expires_at
previous_round_result
```

认证中心只记录状态：

```text
pubkey_hash
pow_verified
pow_algorithm
pow_score
pow_verified_at
```

## AI 网关同步

AI 网关不应在登录路径中阻塞用户注册登录，但应接入 PoW 状态用于权益策略。

同步方式：

- AI 网关后台定时请求认证中心用户状态增量接口。
- 认证中心记录上一次请求位置，或使用单调 cursor/change_seq 返回增量。
- 增量包含新增 PoW、用户状态变化、密钥轮换、封禁等信息。
- 用户完成 PoW 后如果 AI 网关未及时刷新，可以通过重新登录触发强制用户状态拉取。

AI 网关策略只影响：

- 用户组自动分配。
- 订阅套餐自动赠送。

root 管理员配置应能分别控制：

- PoW 控制用户组自动分配：启用/关闭。
- PoW 控制订阅套餐自动赠送：启用/关闭。
- 两者都启用、只启用一个、都不启用。

无 PoW 用户仍可登录和使用正常 API，但可以不给自动赠送、不给普通默认组，或进入受限组。具体策略由运营配置决定。

## DHT 节点长期 PoW

DHT 节点长期 PoW 用于公开 DHT 节点身份准入。

目的：

- 提高批量生成 DHT 节点身份的成本。
- 防女巫攻击。
- 降低日食攻击成功概率。
- 让其他节点在握手时可本地验证节点具备创建成本。

节点 PoW 输入包括：

```text
node_id
node_public_key
owner_pubkey_hash
algorithm
difficulty
round_count
```

节点证书建议包含：

```text
node_id
node_public_key
owner_pubkey_hash
algorithm
difficulty
round_count
solution
created_at
owner_signature
node_signature
```

约束：

- 节点 PoW 可设计为不过期。
- 证书必须记录算法、难度、版本和创建时间，方便未来公共网络提高最低准入难度。
- 私有 DHT 不强制受公共准入策略限制。
- 公开注册到经验管理端时，管理端应验证节点 PoW。
- 节点握手时，客户端或其他 DHT 节点应能本地验证节点 PoW 证书。

## 小红花

小红花不是算力 PoW，而是用户对 DHT 节点实际服务的签名收据。

当 DHT 帮助客户端完成网络连通、流转、打洞协助、relay 或 provider 查询等实际工作后，客户端可以用用户私钥给该 DHT 节点签发小红花。

建议字段：

```text
flower_id
node_id
node_pubkey_hash
owner_pubkey_hash
client_pubkey_hash
service_type
service_digest
resource_digest
started_at
finished_at
client_nonce
node_nonce
client_signature
```

说明：

- `node_id` 证明这朵小红花是给具体节点的。
- `owner_pubkey_hash` 让后续用户信誉可以从真实服务事实中沉淀出来。
- `client_pubkey_hash` 用于向认证中心验证发花用户是否有效、是否完成 PoW。
- `service_digest` / `resource_digest` 只记录摘要，不应暴露不必要的资源明文。
- 时间戳和服务摘要由用户私钥签名，不允许后续篡改。

## 握手包体

DHT 握手时，节点可以携带：

```text
最多 10 个花环证书
最多 100 个散花小红花
DHT 节点 PoW 证书
节点握手签名
```

验证规则：

- 节点 PoW 证书先验。
- 花环证书由本地根公钥/管理端工作证书链验签。
- 散花小红花最多 100 个。
- 对散花中的用户公钥或公钥哈希，客户端可批量请求认证中心验证用户有效性和 PoW 状态。
- 已聚合成花环的内容不需要每次请求认证中心。

## 花环与大花环

花环和大花环使用完全相同的数据结构。

大花环不是新类型，本质只是：

```text
读取多个花环或散花
更新累计数值
重新由管理端签名
```

花环字段建议包含：

```text
wreath_id
node_id
node_pubkey_hash
owner_pubkey_hash
service_count
unique_user_count
pow_user_count
weighted_score
first_service_at
last_service_at
source_count
issued_at
issuer_key_id
signature
```

原则：

- 小花环、大花环、继续聚合后的更大花环都使用同一结构。
- 差别只在数值和签名。
- 由于派生链固定且签名可信，客户端无需知道完整前置链。
- 具体原始小红花应由管理端备份，后续用户信誉计算可以回到原始数据。

## 关于重放

本机制不把“花环重复展示”视为攻击。

允许：

- 同一花环在不同握手中反复展示。
- 节点重复上传已有散花。
- 管理端在幂等处理后返回已有聚合结果。

原因：

- 小红花的时间戳、服务摘要和节点 ID 已由用户私钥签名，不能篡改。
- 花环由管理端签名，数值不可被节点单方修改。
- 散花进入花盘/幻日时，本身会经过用户、公钥、PoW、资源摘要等详细验证。
- 原始小红花有备份，用户信誉可以回到原始数据计算。

因此协议层不单独设计“禁止重放”机制。需要保证的是：

- 聚合任务幂等。
- 原始小红花可审计。
- 花环证书可验签。
- 客户端对同一握手包内重复项可做普通去重。

## 用户信誉与节点信誉

小红花绑定节点 ID 是合理的，因为它证明的是具体 DHT 节点完成过工作。

但小红花的价值不能只沉淀在节点 ID 上。否则节点迁移或服务器失效会惩罚真实贡献者。

后续信誉应分为：

```text
用户信誉：属于用户公钥
节点信誉：属于具体 DHT 节点 ID
节点有效信誉：节点信誉 + 用户信誉背书/倍率 + 节点 PoW + 近期服务表现
```

用户信誉的具体计算方式暂不定案，后续继续细化。当前必须保留的方向是：

- 用户信誉可以由原始小红花备份推导。
- 也可以基于去中心化的原始小红花背书体系推导。
- 花环聚合时不强行把用户信誉塞进节点花环。
- 用户信誉可以为用户新建或迁移的 DHT 节点提供背书。
- 节点实际是否继续获得收益，仍取决于它是否继续服务网络。

## 高信誉用户多节点原则

不得把高信誉用户运行多个 DHT 节点视为默认风险。

如果用户本身是服务器、IDC、IPC 或边缘资源行业从业者，手头有大量闲置服务器，愿意运行多个 DHT 或未来边缘节点，这是应鼓励的网络贡献行为。

高信誉用户可以通过信誉获得更高初始权重或倍率，类似高征信用户可以拿到更低成本的信用资源。

原则：

- 不限制高信誉用户开多个 DHT。
- 不限制高信誉用户用个人信誉给节点背书。
- 真实服务产生的信誉不设硬上限。
- 节点不干活就没有新收益，并会在排序、权重或近期活跃度中自然衰减。
- 高信誉用户滥用自己的信誉，本质是在消费和浪费自己的信誉资产。

需要防范的是：

- 没有真实服务却伪造服务历史。
- 未完成用户 PoW 的大量账号刷小红花。

这些问题应分别由节点 PoW、用户 PoW、服务证明签名和聚合验证处理，而不是通过限制真实高贡献用户扩容来处理。

## 节点迁移

节点迁移时，旧节点的小红花仍然证明旧节点实际服务过网络。

如果旧服务器失效，节点 ID 绑定的小红花不应强行迁移为新节点的历史服务量；但用户信誉应保留其长期贡献价值，并可给新节点背书。

如果旧节点仍可签名，可以考虑后续增加：

```text
旧节点签名
用户签名
新节点签名
```

用于表达更强的迁移连续性。该机制不是当前 MVP 必需项。

## 认证中心公开公钥状态接口

认证中心可以开放公钥状态查询接口，供客户端或 DHT 握手时验证散花。

批量请求：

```http
POST /api/v1/auth/pubkeys/status
```

返回：

```json
{
  "items": [
    {
      "pubkey_hash": "hex",
      "valid": true,
      "pow_verified": true,
      "pow_score": 1,
      "disabled": false
    }
  ]
}
```

该接口只返回公钥有效性和 PoW 状态，不返回隐私信息。接口应限流，但不应要求复杂鉴权，否则会破坏 DHT 握手验证体验。

## 管理端周期拉取最新评价链

经验网络管理端负责按周期从 P2P 网络拉取经验包的最新评价链。它不是把所有校验和 IO 都集中在管理端完成，而是把“寻找更长评价链”的工作投放到公共 DHT 网络中，让网络节点和持有资源的客户端共同完成传播、比较和收敛。

管理端维护经验包存量，并据此动态计算默认拉取限频：

```text
经验包少：单包更新周期短，例如约 3 天流转一次
经验包多：单包更新周期拉长，例如 7 天、30 天或更久
全局限频：每分钟只允许发起一个或少量拉取需求
```

流程：

1. 管理端按调度器选择一个待更新经验包。
2. 管理端向已注册的公共 DHT 节点发送“经验需求”。
3. 需求通过经验包 ID、包 Hash 或评价链摘要定位目标包。
4. DHT 节点在本地和已知提供者中查找该经验包。
5. 找到本地资源后，不立即只回传管理端，而是继续把需求留言传播给附近或相关节点。
6. 节点比较本地评价链和接收到的评价链。
7. 如果接收到更长链，则更新本地结果并继续传播。
8. 如果本地链更长，则携带本地长链继续传播。
9. 如果没有更长链，传播在该分支结束。
10. 管理端最终收回当前网络中收敛出的最长评价链，并内部存档。

评价链比较原则：

```text
同一经验包内，链更长者优先
链必须能通过签名、Hash 和结构校验
节点只传播已验证或可验证的链摘要和必要材料
重复需求和重复链应幂等去重
```

这个机制的目的：

- 让管理端获得 P2P 网络中的最新评价链。
- 把长度比较和传播压力分摊到 DHT 网络。
- 避免管理端为每个经验包做高频全量 IO。
- 让用户经验包的信誉自然汇入管理端存档。
- 随经验包总量增长，自动降低单包刷新频率。

管理端只负责周期调度、限频、需求发起、最终收敛结果归档。DHT 网络负责传播需求、寻找资源、比较链长度和回传更优结果。

## 客户端自然语言经验需求

客户端也应支持通过 P2P 网络发布自然语言经验需求，例如：

```text
我想要一个能处理某类窗口自动化任务的经验
我想找一个适合某款软件安装配置的经验
我需要一个能解释某类报错并自动修复的经验
```

这与“按固定包 ID/Hash 拉取评价链”不同。自然语言需求首先需要在网络中寻找公开、可传播的经验包，然后再进入包拉取流程。

目标流程：

1. 客户端输入自然语言需求。
2. 客户端把需求封装成签名的 `experience_demand` 请求。
3. 请求发送到已连接 DHT，DHT 继续在公共网络传播。
4. 持有公开经验索引或本地公开包的节点进行文本匹配。
5. 匹配结果以 offer 形式沿原传播路径反向返回，包含经验 ID、包 Hash、标题、摘要、关键词、完整评价链和可用传输方式。
6. 客户端选择最合适的 offer。
7. 客户端按反向传播路径拉取经验包；中途传播节点可以缓存该经验包和评价链。
8. 拉取后校验 publisher、review materials、ratings 链和包 Hash。
9. 验证通过后进入本地经验缓存或本地经验库。

客户端缓存边界：

- 客户端不能、也不应该全量同步经验包列表。
- 客户端只缓存自己创建/留存的经验包、用户主动拉取成功的网络包，以及需求传播或回传路径中经手的包。
- “经手”是指需求、offer 或包体沿传播路径经过该节点；中途节点可以缓存该包和完整评价链，用于后续做种和提升热度。
- 经验管理端兜底只能按 `request_id`、自然语言 query、经验 ID/Hash 等具体需求返回候选或包体，不能给客户端下发全量包列表。
- Agent 可以查看和解压本地已缓存的经验包，但不能假设全网经验包都已在本地。

回传路径约束：

- offer 和后续包体不默认要求提供者与请求客户端直连。
- 回传应沿着需求传播时形成的中途路径反向返回。
- 每一跳都记录 `request_id`、上一跳和下一跳，形成短期路径状态。
- 路径状态必须有 TTL，避免长期占用内存。
- 回传路径中的中继节点可以缓存经验包、完整评价链和必要索引。
- 缓存后的中继节点后续也可以作为该经验的供给方，增加网络做种资源。
- 如果直连可用，可以作为优化路径，但不能作为唯一回传路径。

这个约束是为了防止“死种”：只有最初提供者持有资源，一旦它不可达，需求虽然被发现但无法稳定拉取。反向路径缓存能把发现过程同时变成扩散过程。

建议请求结构：

```text
schema_version
request_id
natural_language_query
query_language
query_keywords
requester_peer_id
requester_pubkey_hash
preferred_transports
ttl_seconds
hop_limit
created_at
signature
```

建议响应结构：

```text
request_id
experience_id
package_hash
title
brief
keywords
matched_reason
review_chain
review_chain_digest
review_chain_length
review_chain_ref
provider_peer_id
provider_addrs
available_transports
return_path
provider_signature
```

offer 必须携带完整评价链。只带摘要不够，因为客户端需要在本地完成：

- 判断经验包质量。
- 对多个 offer 做选择。
- 校验评价链签名、长度和结构。
- 校验包 Hash、publisher 和审核材料。

如果完整评价链体积过大，可以采用分片或按需补拉，但 offer 本身必须能指向一组完整、可验证、不可篡改的评价链材料。

当前代码检查结论：

- 已有 `ExperiencePackageRequest`，但它要求明确的 `experience_id` 和 `package_hash`。
- 已有 DHT `/api/v1/package-requests`、`/api/v1/providers`、`/api/v1/relay/sessions` 等底层接口。
- 已有客户端 `publishPackageRequest`、`fetchProviders`、`fetchPackageOffers`、`downloadRelayPackage` 等低层封装。
- 已新增自然语言 `experience_demand` 请求类型和 `demand_offer` 响应类型。
- DHT 已新增 `/api/v1/experience-demands`、`/api/v1/experience-demands/{request_id}/offers` 及 federation 只读端点。
- DHT demand 记录会保存短 TTL、hop limit、回传路径元数据，offer 写入时必须携带 `review_chain`。
- DHT offer 查询支持 `include_review_chain=false`，返回 `review_chain_ref` 并通过 `/api/v1/review-chains/{digest}` 按需补拉完整评价链。
- DHT 已新增 `/api/v1/cache/packages/{package_hash}`，用于回传路径中的中途节点缓存 `.hxp` 包体。
- Relay 上传成功会同步写入 DHT 包缓存，避免 relay 会话过期后马上变成死种。
- 客户端已新增需求发布、offer 收集、供给方本地匹配和导入编排。导入时优先查 DHT 回传路径缓存，再使用 relay 会话，最后走管理端 seed 兜底。
- 客户端供给方发布 demand offer 前，会把本地已审核 `.hxp` 上传到 return path 中的 DHT 缓存节点。

因此，当前系统已经具备自然语言需求、反向路径缓存、评价链按需补拉和管理端评价链刷新调度的内测闭环。

## 当前内测落地范围

本轮先实现已经确定的架构，不实现用户自身信誉计算。

已落地：

- 认证中心公钥表增加用户 PoW 状态字段：`pow_verified`、`pow_algorithm`、`pow_score`、`pow_verified_at`。
- 认证中心新增用户 PoW 接口：`POST /api/v1/auth/pow/challenge`、`POST /api/v1/auth/pow/verify`。
- 认证中心新增状态接口：`POST /api/v1/auth/pubkeys/status`、`GET /api/v1/auth/user_state/changes`。
- AI 网关的 PH01 身份表同步并保存 PoW 状态；登录和内部用户同步都会刷新该状态。
- 客户端后端封装增加用户 PoW 发起、计算、提交方法。
- 经验管理端 DHT 注册结构增加 `node_pow`，管理端可验证 DHT 节点长期 PoW。
- DHT 节点本地绑定后生成并持久化 `node_pow`，公开注册时随节点描述上报。
- 经验管理端增加小红花提交、花环聚合、节点信任包查询接口。
- DHT 节点增加本地小红花提交、聚合和信任包查询接口。
- DHT 节点增加自然语言经验需求和 demand offer 的短 TTL 路由、联邦查询、回传路径元数据。
- DHT 节点增加自然语言需求写入限流：同一签名身份每分钟最多发布 30 个需求、120 个 demand offer，超限返回 `429 rate_limited` 和 `Retry-After`。
- 客户端增加自然语言需求发布、offer 收集、最佳 offer 选择、relay/管理端兜底导入工作流。
- 客户端供给方工作流可以轮询 DHT demand，用本地已审核 private/network 经验匹配并发布带完整评价链的 demand offer。
- 经验管理端增加评价链导出、按存量生成刷新计划、候选最长评价链归档接口。
- 经验管理端增加评价链刷新后台调度器，可定时向健康公共 DHT 发送 signed demand，拉取 compact offer，按需补拉评价链并归档更长候选链。
- DHT 节点增加包体缓存接口 `/api/v1/cache/packages/{package_hash}`，relay 上传会同步进入缓存。
- DHT 节点增加评价链按需补拉接口 `/api/v1/review-chains/{digest}`，compact offer 可用 `review_chain_ref` 指向完整材料。
- 客户端增加回传路径缓存上传/下载：供给方沿 return path 反向上传包体，请求方优先从 return path 缓存拉取。

当前接口：

```http
POST /api/v1/auth/pow/challenge
POST /api/v1/auth/pow/verify
POST /api/v1/auth/pubkeys/status
GET  /api/v1/auth/user_state/changes?since=unix_seconds&limit=1000

POST /api/v1/dht/flowers
POST /api/v1/dht/wreaths/aggregate
GET  /api/v1/dht/trust/{node_id}

POST /api/v1/trust/flowers
POST /api/v1/trust/wreaths/aggregate
GET  /api/v1/trust/bundle

POST /api/v1/experience-demands
GET  /api/v1/experience-demands?q=keyword&limit=100
POST /api/v1/experience-demands/{request_id}/offers
GET  /api/v1/experience-demands/{request_id}/offers
GET  /api/v1/federation/experience-demands
GET  /api/v1/federation/experience-demands/{request_id}/offers
PUT  /api/v1/cache/packages/{package_hash}
GET  /api/v1/cache/packages/{package_hash}
GET  /api/v1/review-chains/{digest}

GET  /api/v1/experiences/{experience_id}/review-chain
GET  /api/v1/dht/review-chain/plan?limit=1
POST /api/v1/dht/review-chain/candidates
```

仍未落地，原因是架构还未定案：

- 用户信誉字段和计算公式。
- 用户信誉对节点有效信誉的加权方式。
- 节点迁移时个人信誉如何给新节点背书。

## 后续待定

- 用户信誉的具体计算公式。
- 原始小红花如何作为去中心化信誉背书。
- 用户信誉与节点有效信誉之间的倍率关系。
- 高信誉用户多节点的收益模型。
- 花盘/幻日的最终命名和证书字段。

## 后续处理任务

以下内容当前仍不落地，等待团队继续定案或真实环境联调：

- 公开经验索引同步：客户端本地公开经验、DHT 缓存经验、管理端归档经验之间需要统一索引字段。
- 用户信誉架构：暂不落地，等团队确定中心化字段、去中心化背书、节点信誉加权和迁移规则后再实现。
- 真实公网 DHT/管理端/客户端端到端压测和运营参数校准。
