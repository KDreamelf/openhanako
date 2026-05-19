# 经验网络 P2P 协议设计

> 设计日期：2026-05-19  
> 状态：草案  
> 相关代码：`lib/experience/experience_network.dart`、`experience_store.dart`、`experience_udp.dart`

---

## 1. 概述

经验网络是 PH01 子体客户端之间交换本地经验包（HXP）的去中心化网络。当前实现依赖 DHT 节点做中心化中继（`dhtRelay` / `managerSeed`），P2P 传输框架（`ExperienceUdpHolePuncher`）已编写但从未接入。

本文档描述目标协议：**基于流言传播的需求扩散 + 沿路返回 + 中间节点缓存** 的完整 P2P 方案。

### 1.1 设计目标

- 去中心化：任意节点可发起需求、响应需求、中继回包
- 带宽高效：哈希握手 + 中间缓存避免重复传输
- 安全：私钥签名防伪造、demandId 去重 + maxResponses 防广播风暴
- 渐进兼容：DHT relay 作为 fallback 保留，P2P 是首选路径

---

## 2. 协议角色

| 角色 | 说明 |
|------|------|
| **Requester** | 发起需求的节点（Agent 通过工具调用触发） |
| **Provider** | 本地持有匹配经验包的节点 |
| **Relay** | 转发需求 / 回包的中间节点 |

每个节点同时扮演三种角色。

---

## 2.5 邻居发现与管理

P2P 协议的基础是每个节点维护一张**邻居表**（逻辑连接，不要求长连接）。邻居表决定 DemandPacket 的扩散路径和 ResponsePacket 的回传可达性。

### 2.5.1 邻居表参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| maxNeighbors | 100 | 邻居表上限 |
| probeInterval | 5 min | 定期探测现有邻居 + 尝试新节点 |
| evictThreshold | 连续 3 次探测失败 | 踢出不可达邻居 |

### 2.5.2 发现机制（三层）

```
                        ┌─────────────────────┐
                        │  1. DHT 节点注册表   │  全网可达，announcePresence()
                        │     （粗粒度）        │  返回全网在线节点列表
                        └─────────┬───────────┘
                                  │ 候选集（可能很大）
                        ┌─────────▼───────────┐
                        │  2. IP 归属地初筛     │  公共 IP 库 API 查归属地
                        │     （缩小范围）      │  同城/同省/同国优先
                        └─────────┬───────────┘
                                  │ 缩小后的候选集
                        ┌─────────▼───────────┐
                        │  3. 延迟探测排名      │  UDP/ICMP 探测 RTT
                        │     （精选邻居）      │  取 top-N 进入邻居表
                        └─────────────────────┘
```

**第 1 层：DHT 节点注册表**
- 节点启动后调用 `announcePresence()` 向 DHT 注册自己
- 定期（每 5 分钟）刷新在线状态
- 其他节点通过 DHT 获取全网在线节点列表（候选集）

**第 2 层：IP 归属地初筛**
- 对候选集中的节点查询 IP 归属地（公共 IP 库 API）
- 按地理距离排序：同城 > 同省 > 同国 > 跨国
- 全网节点很多时，这一层把候选集从数千缩到数百
- 已知问题：客户端授权挑战信息中 IP 归属地字段目前缺失，需排查

**第 3 层：延迟探测排名**
- 对初筛后的候选节点发送 UDP 探测包
- 测量 RTT（往返延迟）
- 按延迟排名，取 top-100 进入邻居表

### 2.5.3 邻居增减策略

```
每次 probeInterval 触发时:
    1. 探测现有邻居 → 标记不可达的（连续失败 >= evictThreshold 则踢出）
    2. 从 DHT 拉新候选 → IP 初筛 → 延迟探测
    3. 如果新候选的延迟优于邻居表中最差的节点：
       替换之（新节点进、旧节点出）
    4. 如果邻居表未满：直接加入
```

邻居表不需要真正的长连接——"邻居"是逻辑概念，表示"上次探测时可达且延迟可接受的节点"。发包时逐个尝试，不可达则跳过。

---

## 3. 需求发布与传播

### 3.1 需求包结构

```
DemandPacket {
  demandId:        bytes32        // 需求唯一 ID
  demandHash:      bytes32        // 需求内容的哈希指纹
  requesterPubKey: bytes          // 发起者公钥
  signature:       bytes          // 发起者对 demandHash 的签名
  query:           string         // 自然语言需求描述
  tags:            string[]       // 可选的结构化标签
  maxResponses:    uint8          // 期望回包数量上限（1-255）
  createdAt:       timestamp
  forwardPath:     PathEntry[]    // 正向传播路径记录
}

PathEntry {
  nodeId:    bytes32    // 节点 ID
  pubKey:    bytes      // 节点公钥
  endpoint:  string     // 节点可达端点（IP:port / relay 地址）
  timestamp: timestamp
  signature: bytes      // 节点对 (demandHash, 前一个 PathEntry) 的签名
}
```

### 3.2 传播规则

1. Requester 创建 `DemandPacket`，用私钥签名，`forwardPath` 初始为空
2. 发送给已知邻居节点
3. 收到需求的节点：
   - 验证 `signature`（用 `requesterPubKey`）
   - 检查是否见过该 `demandId`（去重表）
   - 在 `forwardPath` 末尾追加自己的 `PathEntry`
   - 转发给自己的邻居（排除来源节点）
4. 如果节点本地持有匹配资源 → 进入**响应流程**（§4）

### 3.3 防广播风暴

| 机制 | 说明 |
|------|------|
| demandId 去重 | 同一 demand 只处理一次（节点维护近期 demand 指纹集合）；包自身携带节点判断记录，处理过则直接丢弃 |
| maxResponses 熔断 | 节点收到的响应数 ≥ maxResponses 时停止转发该 demand |
| 签名验证 | 无效签名直接丢弃 |

---

## 4. 响应与回包

### 4.1 回包触发

Provider 节点发现本地有匹配包时：

1. 构造 `ResponsePacket`（见 §4.2）
2. 沿 `forwardPath` **逆序**回传——每一跳发给路径中的上一个节点
3. 同时向网络发布**供应留言** `OfferAnnounce`，防止后续重复回包

### 4.2 响应包结构

```
ResponsePacket {
  demandHash:       bytes32      // 对应的需求指纹
  providerPubKey:   bytes        // 提供者公钥
  providerSig:      bytes        // 提供者签名
  packageFingerprints: PackageFingerprint[]  // 提供的包指纹列表
  returnPath:       PathEntry[]  // 回传时逐跳记录（逆向）
}

PackageFingerprint {
  packageHash:  bytes32    // 经验包内容哈希
  sizeBytes:    uint64     // 包大小
  title:        string     // 包简要标题
  reviewChain:  bytes[]    // 评价链摘要（可选）
}
```

### 4.3 哈希握手（传输优化）

Provider 在发送完整包之前，**先只回传 `PackageFingerprint` 列表**。

中间节点收到 `ResponsePacket` 时：

```
for each fingerprint in packageFingerprints:
    if 本地缓存命中(fingerprint.packageHash):
        从本地缓存续传（不再向 Provider 请求该包）
        继续向 Requester 方向传递
    else:
        透传 ResponsePacket 到下一跳
        等待完整包数据到达后缓存
```

效果：
- 越靠近 Requester 的节点越可能命中缓存 → 链路越短
- 每次回包都给沿路节点填充缓存 → 网络整体持有率持续提升

### 4.4 完整包传输

握手后，Requester（或首个未命中缓存的中间节点）向 Provider 发起完整包拉取：

```
PackageTransferRequest {
  demandHash:   bytes32
  packageHash:  bytes32
  requestedBy:  bytes32    // 请求节点 ID
}
```

传输走 UDP 直连（优先 hole punch）或 DHT relay（fallback）。

---

## 5. 供应留言与多包去重

### 5.1 供应留言结构

```
OfferAnnounce {
  demandHash:            bytes32      // 需求指纹
  providedPackageHashes: bytes32[]    // 已提供的包指纹集合
  providerPubKey:        bytes
  providerSig:           bytes
}
```

### 5.2 节点处理逻辑

节点维护每个活跃 demand 的**已响应集合**（demand → set of packageHash）。

```
收到 OfferAnnounce 时:
    已响应集合[demandHash] ∪= providedPackageHashes
    
    if 已响应集合[demandHash].size >= demand.maxResponses:
        标记该 demand 为已满足，停止转发
    else:
        转发 OfferAnnounce 到邻居
```

```
收到新的 ResponsePacket 时:
    for each fingerprint in responsePacket.packageFingerprints:
        if fingerprint.packageHash in 已响应集合[demandHash]:
            丢弃（重复回包）
        else:
            已响应集合[demandHash].add(fingerprint.packageHash)
            正常处理
```

### 5.3 自然终止

Demand 的生命周期由两个条件终止（先到先停）：

1. `maxResponses` 满足 → 节点级停止转发
2. 时间过期 → 节点定期清理 `createdAt` 超过阈值的 demand 去重记录

不需要 TTL。demandId 去重保证每个节点只处理一次同一 demand——传播在网络所有节点都见过后自然终止，搜索半径不会被人为截断。

---

## 6. 缓存、持有与信息平权

### 6.1 转发即持有

回包经过中间节点时，该节点**永久保存**完整包到本地经验库——不做 LRU 驱逐，不视为临时缓存。转发过来的包直接进入该节点的"可调用经验列表"，与节点自身创建的经验具有同等地位。

- **写入时机**：回包经过本节点时，存入本地经验库
- **命中时机**：收到 ResponsePacket 的 fingerprint 本地已有 → 从本地直接续传
- **不驱逐**：只要用户在网络中，持有的包只增不减

### 6.2 包提活

节点发现一个 demand 匹配自己持有的包时，可以**直接作为 Provider 响应**，而不需要原始作者在线。热门经验包会在网络中自然扩散，不依赖单一源节点。

### 6.3 设计意图：信息平权

转发即获取——每个参与网络的节点天然获利。用户只要存在于网络中，就会随着转发行为不断积累来自不同领域的经验包，接触到自己从未主动搜索过的内容。这是协议层面打破信息茧房的手段：没有推荐算法的漏斗，信息的可达性由网络拓扑决定而非中心化筛选。

---

## 7. 安全模型

### 7.1 签名链路

| 环节 | 签名者 | 验证内容 |
|------|--------|----------|
| DemandPacket | Requester | 需求合法、来源可信 |
| PathEntry | 每个 Relay 节点 | 路径真实、不可篡改 |
| ResponsePacket | Provider | 回包来源可信 |
| OfferAnnounce | Provider | 供应留言不可伪造 |
| HXP 包本身 | 包作者 | 包内容完整、未篡改（已有机制） |

### 7.2 威胁与缓解

| 威胁 | 缓解 |
|------|------|
| 伪造需求耗资源 | 签名验证 + demandId 去重 |
| 路径污染（注入假节点） | PathEntry 链式签名，每个节点只能追加自己 |
| 回包劫持 | ResponsePacket 的 providerSig 验证 |
| 缓存投毒 | 包自身的内容哈希验证（HXP 包头签名） |
| Sybil 攻击 | 后续引入声誉机制（评价链）|

---

## 8. 与现有代码的对应关系

### 8.1 已有零件

| 现有代码 | 协议中的角色 | 状态 |
|----------|-------------|------|
| `ExperienceUdpHolePuncher` | 传输层 UDP 直连 | 完整但未接入 |
| `ExperienceDhtHttpClient.publishExperienceDemand()` | 需求发布 API | 已有，需扩展为 P2P gossip |
| `ExperienceDhtHttpClient.fetchExperienceDemandOffers()` | 拉取 offer | 已有，中心化模式 |
| `ExperienceDhtHttpClient.createRelaySession()` | DHT relay fallback | 已有 |
| `ExperienceDhtHttpClient.downloadCachedPackage()` | 缓存包下载 | 已有 |
| `ExperienceStore.importOffer()` | 包导入 | 已有，需扩展 P2P 路径 |
| `ExperienceConnectionPlanner` | 传输策略规划 | 已有 4 种 transport |
| `ExperienceDemand` / `ExperienceDemandOffer` | 需求/响应数据模型 | 已有，需扩展字段 |

### 8.2 需要新建的组件

| 组件 | 职责 |
|------|------|
| `ExperienceP2pOverlay` | 覆盖网络核心：邻居管理、消息收发、去重表 |
| `NeighborTable` | 邻居表：DHT 发现 → IP 归属地初筛 → 延迟探测排名 → 动态增减，维持 ~100 连接 |
| `DemandPropagator` | 需求传播引擎：forwardPath 记录、demandId 去重、maxResponses 熔断 |
| `ResponseRouter` | 回包路由：沿 forwardPath 逆向、哈希握手、缓存命中检测 |
| `PackageCache` | 本地经验持有：按 packageHash 索引、转发即入库 |
| `OfferDeduplicator` | 供应去重：维护 demand → providedHashes 映射 |
| `P2pMessageCodec` | 协议编解码：DemandPacket / ResponsePacket / OfferAnnounce 序列化 |

### 8.3 迁移路径

```
阶段 A：协议层
  → 定义 DemandPacket / ResponsePacket / OfferAnnounce 数据结构
  → 实现 P2pMessageCodec（protobuf 或自定义 wire format）
  → 实现 DemandPropagator（单元测试用 mock 邻居）

阶段 B：覆盖网络
  → ExperienceP2pOverlay：基于现有 DHT 节点做邻居发现
  → 接入 ExperienceUdpHolePuncher 做节点间直连
  → DHT relay 作为无法直连时的 fallback

阶段 C：回包与缓存
  → ResponseRouter + PackageCache
  → 哈希握手流程
  → OfferDeduplicator + maxResponses 熔断

阶段 D：集成
  → ExperienceStore.importOffer() 加 P2P 路径
  → Agent 工具 publish_demand 接入 DemandPropagator
  → 转发包自动入库到本地经验列表
```

---

## 9. 开放问题

| # | 问题 | 当前倾向 |
|---|------|---------|
| 1 | wire format 用 protobuf 还是自定义二进制 | protobuf（已有飞书 WS 的 pbbp2 经验） |
| 2 | 邻居发现 IP 库 API 可用性 | DHT 端和经验管理端已配公共 IP 库，但客户端挑战信息中归属地字段缺失，需排查 |
| 3 | maxResponses 默认值 | 3（Agent 工具调用时可覆盖） |
| 4 | demand 去重记录过期时间 | 24h（过期后允许重新发起同一需求） |
| 5 | 评价链详细格式 | 待定，当前 `ExperienceDemandOffer` 已预留 `reviewChainDigest` 字段 |
| 6 | 邻居表容量 | 100（可配置） |

---

## 10. 代码闭环断裂台账

> 排查日期：2026-05-19  
> 规则：修复后标 ✅ 已修复；修复后经代码验证标 ✅✅ 已检查。

### 10.1 断裂清单

| # | 链路 | 现状 | 断裂点 | 修复方案 | 状态 |
|---|------|------|--------|----------|------|
| B1 | 主动发包：Agent → 发需求 → 网络 | ⚠️ 断 | 无 `publish_demand` Agent 工具；`ExperienceDemandPullWorkflow` 整类零调用 | 在 local_tools.dart 注册 `publish_demand` 工具，接入 DemandPullWorkflow | ✅ 已修复 |
| B2 | 被动响应：收需求 → 匹配 → 回包 | ⚠️ 断 | `answerMatchingExperienceDemands()` 写好但无后台轮询触发 | 后台调度定期调用 fetchDemands + answerMatching | ✅ 已修复 |
| B3 | 包下载：offer → 下载 → 入库 | ✅ 通 | — | — | ✅✅ 已检查 |
| B4 | 邻居发现：announce + 邻居管理 | ❌ 断 | `announcePresence()` 零调用；无邻居表管理逻辑 | 后台调度定期 announce；新建 NeighborTable | ✅ 已修复 |
| B5 | UDP 打洞：hole punch 传输层 | ❌ 断 | `ExperienceUdpHolePuncher` / `createHolePunchSession` / `reportHolePunch` 全部零调用 | 在传输层选择时接入 hole punch 路径 | ✅ 已修复 |
| B6 | 后台调度：定期轮询/探测 | ❌ 空 | CronStore 无经验网络相关 job | 注册 announce / fetchDemands / neighborProbe 三个定期任务 | ✅ 已修复 |

### 10.2 Dead Code 清单

| 类/方法 | 文件 | 说明 | 状态 |
|---------|------|------|------|
| `ExperienceUdpHolePuncher`（整类） | experience_udp.dart | UDP 打洞实现 | ✅ importOffer._tryHolePunchTransfer |
| `ExperienceDemandPullWorkflow`（整类） | experience_store.dart | 需求拉取工作流 | ✅ daemon.publishDemand + publish_demand 工具 |
| `ExperiencePackageSupplyWorkflow`（整类） | experience_store.dart | 包供应工作流 | ✅ daemon._pollAndAnswer |
| `announcePresence()` | experience_network.dart | DHT 在线广播 | ✅ daemon._announce |
| `answerMatchingExperienceDemands()` | experience_store.dart | 需求匹配+回包 | ✅ daemon._pollAndAnswer |
| `createHolePunchSession()` | experience_network.dart | 打洞会话创建 | ✅ importOffer._tryHolePunchTransfer |
| `reportHolePunch()` | experience_network.dart | 打洞结果上报 | ✅ importOffer._tryHolePunchTransfer |
