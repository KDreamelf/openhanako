# QQ Bridge: OneBot v11 协议对接事实

> 调研日期：2026-05-20  
> 来源：`botuniverse/onebot-11` GitHub 仓库原始 Markdown（api/public.md、communication/、event/message.md）
> 已验证：2026-05-20 通过 GitHub REST API 直接读取仓库文件确认，非模型记忆。

---

## 1. 协议规范来源

- **OneBot v11 标准**：https://github.com/botuniverse/onebot-11（669 stars，活跃维护）
- **LLOneBot 实现**：https://github.com/LLOneBot/LuckyLilliaBot（3279 stars，原 LLOneBot/LLOneBot 已重命名）
- 支持协议：OneBot 11 + Satori + Milky

---

## 2. 通信模式选择

OneBot v11 定义四种通信方式：

| 模式 | 方向 | 说明 |
|------|------|------|
| HTTP API | 客户端 → OneBot | 正向 HTTP 调用 API（发消息等） |
| HTTP POST | OneBot → 客户端 | 每次事件一个 POST 请求（单向） |
| 正向 WebSocket | 客户端 → OneBot | 客户端连接 OneBot 的 WS 端口 |
| **反向 WebSocket** | **OneBot → 客户端** | **OneBot 主动连接客户端 WS 端口** |

**QBot2.2 现用**：HTTP API（发送，sendQport:3000）+ HTTP POST（接收，listenQport:3001）。

**PH01 选择**：**正向 HTTP（发送）+ 反向 WebSocket（接收）**。
理由：
- 反向 WS 是持久双向连接，比 HTTP POST 更高效
- 不需要客户端开 HTTP 服务器（当前 QBot2.2 用原始 socket 手写 HTTP 解析，极不可靠）
- LLOneBot 支持反向 WS

---

## 3. 发送 API（正向 HTTP）

来源：https://github.com/botuniverse/onebot-11/blob/master/api/public.md

### 3.1 send_private_msg

```
POST http://localhost:{port}/send_private_msg
Content-Type: application/json

{
  "user_id": 12345678,
  "message": "你好"
}

Response:
{ "status": "ok", "retcode": 0, "data": { "message_id": 123 } }
```

### 3.2 send_group_msg

```
POST http://localhost:{port}/send_group_msg
Content-Type: application/json

{
  "group_id": 87654321,
  "message": "你好"
}

Response:
{ "status": "ok", "retcode": 0, "data": { "message_id": 456 } }
```

### 3.3 统一 send_msg

```
POST http://localhost:{port}/send_msg

{
  "message_type": "private" | "group",
  "user_id": 12345678,       // private 时必填
  "group_id": 87654321,      // group 时必填
  "message": "你好"
}
```

### 3.4 message 格式

支持两种格式：
- **字符串**：纯文本或 CQ 码（`[CQ:image,file=...]`）
- **数组**：消息段数组（推荐）

```json
[
  { "type": "text", "data": { "text": "你好 " } },
  { "type": "image", "data": { "file": "https://example.com/img.png" } }
]
```

---

## 4. 事件接收（反向 WebSocket）

来源：https://github.com/botuniverse/onebot-11/blob/master/communication/ws-reverse.md

LLOneBot 配置反向 WS 后，会主动连接我们的 WS 服务器。连接建立后，事件以 JSON 文本帧推送。

### 4.1 私聊消息事件

来源：https://github.com/botuniverse/onebot-11/blob/master/event/message.md

```json
{
  "time": 1515204254,
  "self_id": 10001000,
  "post_type": "message",
  "message_type": "private",
  "sub_type": "friend",
  "message_id": 12,
  "user_id": 12345678,
  "message": "你好～",
  "raw_message": "你好～",
  "font": 456,
  "sender": {
    "user_id": 12345678,
    "nickname": "小不点",
    "sex": "male",
    "age": 18
  }
}
```

### 4.2 群消息事件

```json
{
  "time": 1515204254,
  "self_id": 10001000,
  "post_type": "message",
  "message_type": "group",
  "sub_type": "normal",
  "message_id": 12,
  "group_id": 87654321,
  "user_id": 12345678,
  "message": "你好～",
  "raw_message": "你好～",
  "font": 456,
  "anonymous": null,
  "sender": {
    "user_id": 12345678,
    "nickname": "小不点",
    "card": "群名片",
    "sex": "male",
    "age": 18,
    "area": "",
    "level": "1",
    "role": "member",
    "title": ""
  }
}
```

### 4.3 其他事件类型

- `post_type: "notice"` — 群成员变动、消息撤回等
- `post_type: "request"` — 加好友/加群请求
- `post_type: "meta_event"` — 生命周期、心跳

心跳事件（`meta_event.heartbeat`）每 5 秒一次，可用于检测连接存活。

---

## 5. Dart 端实施设计

### 5.1 文件层级

```
lib/bridge/
  qq_bridge.dart              # 新增：OneBot v11 客户端
```

### 5.2 架构

```
┌──────────────┐     HTTP POST      ┌───────────────┐
│  QqBridge    │ ──────────────────> │  LLOneBot     │
│  (Dart)      │  send_private_msg   │  (本地 3000)  │
│              │  send_group_msg     │               │
│              │                     │               │
│  WS Server   │ <────────────────── │  反向 WS       │
│  (随机端口)   │  事件推送           │  连接我们      │
└──────────────┘                     └───────────────┘
```

### 5.3 QqBridge 接口

```dart
class QqBridge implements BridgeAdapter {
  QqBridge({
    required this.httpPort,       // LLOneBot 的 HTTP API 端口（默认 3000）
    this.wsHost = '127.0.0.1',
    this.wsPort = 0,              // 反向 WS 监听端口（0 = 随机）
  });

  // BridgeAdapter 接口
  Stream<IncomingMessage> get messages;
  Future<void> start();           // 启动 WS server，等 LLOneBot 连接
  Future<void> stop();
  Future<void> sendText(String target, String text);
  Future<void> sendImage(String target, String imageUrl);
}
```

### 5.4 配置

LLOneBot 需要在设置中配置反向 WS 地址指向我们客户端。用户在 PH01 设置页填写：
- LLOneBot HTTP API 端口（默认 3000）
- 我们的 WS 监听端口（自动分配或手动指定）

### 5.5 与 QBot2.2 的差异

| | QBot2.2 | PH01 |
|---|---|---|
| 发送 | HTTP POST 到 LLOneBot | 同（走 Dio） |
| 接收 | 原始 socket 手写 HTTP 解析 | 反向 WS（HttpServer + WebSocket upgrade） |
| 协议 | OneBot v11 | 同 |
| 语言 | Python | Dart |
| 进程 | 独立 Python 进程 | 客户端内嵌 |

---

## 6. LLOneBot 配置要求

用户需要在 LLOneBot 中配置：
1. HTTP API 端口：默认 3000
2. 反向 WebSocket：添加 `ws://127.0.0.1:{我们的端口}/`
3. 消息格式：数组格式（推荐）

---

## 7. 参考来源汇总

| 文档 | URL |
|------|-----|
| OneBot v11 API | https://github.com/botuniverse/onebot-11/blob/master/api/public.md |
| OneBot v11 消息事件 | https://github.com/botuniverse/onebot-11/blob/master/event/message.md |
| OneBot v11 反向 WS | https://github.com/botuniverse/onebot-11/blob/master/communication/ws-reverse.md |
| OneBot v11 HTTP POST | https://github.com/botuniverse/onebot-11/blob/master/communication/http-post.md |
| LLOneBot | https://github.com/LLOneBot/LuckyLilliaBot |
| QBot2.2 参考实现 | 本仓库 QBot2.2/utils/funcs.py、QBot2.2/utils/aifunction.py |
