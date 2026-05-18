# 飞书（Lark）长连接事件订阅协议事实

> 调研日期：2026-05-18  
> 来源：飞书开放平台公开文档（开发文档/服务端 API）+ `larksuite/oapi-sdk-go` v3_main 分支
> ws/ 目录源码（client.go、const.go、model.go、pbbp2.pb.go）。
>
> 本文档目的：给 Dart 端实现 `LarkWsClient` 提供可执行的事实清单。**不**作为
> 飞书官方规范引用——飞书并未公开协议白皮书，所有细节均从公开 Go SDK 反推。

---

## 1. 连接生命周期

### 1.1 Bootstrap：HTTP 拿连接 URL

```
POST {domain}/callback/ws/endpoint
domain 默认 = https://open.feishu.cn  （Lark 国际版 host 另算）

Body (JSON):
{
  "AppID": "cli_xxxxx",
  "AppSecret": "...",
  "ClientAssertion": "...?"   // 可选：客户端断言（SDK 内部生成）
}

Response (JSON):
{
  "StatusCode": 0,
  "Msg": "success",
  "Endpoint": {
    "Url": "wss://...?ticket=<one-time>",   // 一次性 token 已嵌入 URL
    "ClientConfig": {
      "PingInterval":       <seconds>,      // 服务端下发，不要硬编码
      "ReconnectInterval":  <seconds>,
      "ReconnectCount":     <int>,
      "ReconnectNonceTimes":<int>
    }
  }
}
```

错误码（见 §5）。`StatusCode != 0` 必须看 `Msg` 拒绝连接，不要进入 dial 阶段。

### 1.2 WebSocket Dial

直接 `WebSocket.connect(Endpoint.Url)`。**不需要 Authorization header**——
鉴权在 bootstrap 步骤完成，URL 已经携带一次性 ticket。

握手响应：HTTP `101 Switching Protocols`。任何其它状态码视为失败，按
ReconnectInterval 退避后重试，重试上限 ReconnectCount。

### 1.3 心跳

按 `ClientConfig.PingInterval`（**服务端下发**，不要硬编码）周期性发送
`FrameType=Control, message_type="ping"` 的 Frame；服务端回 `pong`。
未收到 pong 视为链路死亡，触发重连。

### 1.4 断线 / 重连 / Token 过期

- 网络断 / 服务端主动断 → 按 `ReconnectInterval` 起退避，最多 `ReconnectCount` 次。
- ticket 过期 → bootstrap 重新拿 Endpoint，再 dial。
- 多次失败 → 上报错误，由上层决定继续等待还是关闭。

---

## 2. 帧格式（pbbp2 — 自定义 protobuf）

飞书 WS 走 binary frame，payload 是自定义 protobuf（"pbbp2"）。
原始 `.proto` 文件**未公开**，需要从 `larksuite/oapi-sdk-go/ws/pbbp2.pb.go`
反推（或在 Dart 端手写 wire codec）。

### 2.1 顶层 Frame

```protobuf
message Frame {
  uint32       FrameType = 1;   // 0 = Control, 1 = Data
  repeated     Header headers = 2;
  bytes        Payload = 3;
}

message Header {
  string key   = 1;
  string value = 2;
}
```

### 2.2 Header 键约定

| key                    | 含义 |
|------------------------|------|
| `type`                 | "event" / "card" / "ping" / "pong" |
| `message_id`           | 逻辑消息 ID（分片重组按这个聚合） |
| `sum`                  | 分片总数（默认 1） |
| `seq`                  | 当前分片序号（0-based） |
| `trace_id` / `link_id` | 链路追踪 |
| `biz_processing_time`  | 服务端建议处理时长（毫秒） |

### 2.3 Data 帧 Payload

Payload 是 UTF-8 JSON（飞书事件订阅的标准事件 envelope），结构例：

```jsonc
{
  "schema": "2.0",
  "header": {
    "event_id":   "...",
    "event_type": "im.message.receive_v1",
    "create_time":"...",
    "token":      "...",
    "app_id":     "cli_xxxxx",
    "tenant_key": "..."
  },
  "event": { /* event_type 决定结构 */ }
}
```

### 2.4 分片重组

大消息按 `message_id` 切多帧，各帧 `sum`/`seq` 标记位置。客户端缓存
分片到 `Map<message_id, List<bytes>>`，齐了拼接 payload，把组装好的
事件 dispatch 给上层。乱序到达也能 reassemble。

### 2.5 Control 帧

`FrameType=0` 的 Frame 用作 ping/pong 等控制信号。`type` header 区分。

### 2.6 上行 Response（可选）

某些事件要求客户端在 3 秒内 ack。Payload 用：

```protobuf
message Response {
  int32                     StatusCode = 1;
  map<string, string>       Headers    = 2;
  bytes                     Data       = 3;
}
```

业务正常处理 = `StatusCode: 0`。处理超时（>3s）= 服务端可能重发或断连。

---

## 3. 事件订阅模型

**隐式订阅**：连接建立后，飞书按该 App 在开放平台 Developer Console
里勾选的事件订阅列表自动推送。客户端代码只 **register handler**，
不主动 subscribe。

要订阅 `im.message.receive_v1`：在开放平台后台勾选 "im / 接收消息 v1.0"
权限和事件订阅，应用发布后即生效。

---

## 4. 处理约束

每条事件**必须 3 秒内处理完**（含业务逻辑）。否则：
- 服务端可能重发同一事件（去重靠 `event_id`）
- 累计超时可能导致服务端断连

实现建议：handler 接到事件**立即返回 ack**，重活儿丢给后台异步。

---

## 5. 错误码

来自 `larksuite/oapi-sdk-go/ws/const.go`：

| 码 | 含义 | 处理 |
|---|---|---|
| 0 | 成功 | 继续 |
| 1 | 系统繁忙 | 退避后重试 |
| 403 | 禁止访问 | 检查 AppID / AppSecret / 应用权限 |
| 514 | 认证失败 | 重新 bootstrap 拿新 ticket |
| 1000040343 | 内部错误 | 退避重试 |
| 1000040350 | 连接数超限 | 同一 App 同时连接过多，等待或断开旧连接 |

---

## 6. 鉴权对比（vs webhook 模式）

| | Webhook | 长连接 |
|---|---|---|
| 加密 | 可选 AES-256-CBC（encrypt_key） | 不需要 |
| 签名 | sha256(timestamp + nonce + encrypt_key + body) | 不需要 |
| 鉴权时机 | 每次回调请求都验签 | 仅 bootstrap 一次 |
| 公网入口 | 必需 | 不需要 |
| 适用 | Server 部署 / 已有公网域名 | GUI 客户端 / 内网部署 |

GUI 桌面客户端**只能走长连接**——没有公网入口接 webhook。
Server 模式（`bin/server.dart`）保留 webhook 兼容已部署用户和国际 Lark
（Lark international 不暴露 WS）。

---

## 7. Dart 端实施草图

### 7.1 文件层级

```
lib/bridge/
  lark_bridge.dart                # 现状：保留 send + webhook 接收路径
  lark_ws_client.dart             # 新增：bootstrap + dial + 心跳 + 重连 + 分片
  lark_ws_protocol.dart           # 新增：pbbp2 Frame/Header/Response 编解码
```

### 7.2 依赖

| 包 | 版本 | 用途 |
|---|---|---|
| `package:dio` | 已有 | bootstrap POST |
| `package:web_socket_channel` | 已有 | WS Dial |
| `package:protobuf` | **新增** | Frame 编解码（或自己写 wire codec，见 §7.3） |

### 7.3 protobuf 取舍

**方案 A：用 protoc + .proto**
1. 反推一份 `pbbp2.proto`（参考 oapi-sdk-go 的 .pb.go）
2. 仓库加 `tools/proto/pbbp2.proto`
3. CI 加 `protoc --dart_out=...` 步骤

**方案 B：手写 wire codec（推荐）**
- pbbp2.Frame 字段只有 3 个：FrameType (uint32, tag 1)、Headers (repeated Header, tag 2)、Payload (bytes, tag 3)
- Header 是 (key:string, value:string)
- 手写 50-100 行 Dart 的 varint + length-delimited 编解码即可
- 不在仓库引入 protoc 工具链

倾向 **方案 B**。

### 7.4 接入点

`bridge_source_manager.dart` 的 `case 'feishu'` 分支：

```dart
case 'feishu':
case 'lark':
  final adapter = LarkBridge(
    appId: config.credentials['appId'] ?? '',
    appSecret: config.credentials['appSecret'] ?? '',
    verificationToken: config.credentials['verificationToken'],
    encryptKey: config.credentials['encryptKey'],
    // 新增：默认走 WS。fallback webhook 由 bin/server.dart 处理
    receiveMode: LarkReceiveMode.websocket,
  );
  await bridgeSessionManager.register(adapter);
  await adapter.start();   // 内部启动 LarkWsClient
```

`LarkBridge.messages` 流由 `LarkWsClient` 写入。`bin/server.dart` 仍然把
webhook 路由挂到 shelf router（不影响）。

### 7.5 配置点

| 配置 | 默认 | 来源 |
|---|---|---|
| `pingInterval` | 服务端 ClientConfig 下发 | bootstrap response |
| `reconnectInterval` | 服务端 ClientConfig 下发 | bootstrap response |
| `reconnectCount` | 服务端 ClientConfig 下发 | bootstrap response |
| `domain` | `https://open.feishu.cn` | 硬编码常量（Lark international 用户走 webhook，不走 WS） |
| `receiveMode` | `websocket` | 设置项可改成 `webhook` 兜底 |

### 7.6 测试

- 单元：手写 wire codec 的 round-trip（构造 Frame → 编码 → 解码 → 对比）
- 集成：mock bootstrap server + 模拟 ws server 发 Data 帧 → 验证 `LarkBridge.messages` 收到正确 `IncomingMessage`
- 分片：发 3 个 frame 同 message_id 不同 seq → 验证组装

---

## 8. 不解决的问题（留 backlog）

- **Lark international 不支持 WS**：仅国内飞书。海外用户必须 webhook + Server 模式部署。
- **3 秒 ack 约束**：客户端处理 LLM 流式回复需要更长。`LarkWsClient` 应该
  立刻 ack（StatusCode 0），把消息丢到后台队列再触发 `BridgeSessionManager.executeExternalMessage`。
- **`pbbp2.proto` 没有正式公开**：手写 codec 是事实推断，飞书改协议时
  我们的 codec 可能需要跟随更新。把关键字段名（type/message_id/sum/seq）
  和 tag 号集中放在 `lark_ws_protocol.dart` 顶部常量里，方便迭代。

---

## 9. 参考来源

- `larksuite/oapi-sdk-go` v3_main 分支 `ws/` 目录（client.go / const.go / model.go / pbbp2.pb.go）
- 飞书开放平台《使用长连接接收回调》文档
- 飞书开放平台 SDK 文档（Java / Go / Python / Node.js 多语言实现，行为一致）
