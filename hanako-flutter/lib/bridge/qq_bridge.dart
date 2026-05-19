import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'bridge_adapter.dart';

/// QQ Bridge — OneBot v11 协议客户端。
///
/// 发送：正向 HTTP API（POST 到 LLOneBot 的 HTTP 端口）。
/// 接收：反向 WebSocket（本地启 WS server，LLOneBot 连接推送事件）。
///
/// 协议来源：https://github.com/botuniverse/onebot-11
class QqBridge implements BridgeAdapter {
  QqBridge({
    required this.httpPort,
    this.wsHost = '127.0.0.1',
    this.wsPort = 0,
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:$httpPort',
    receiveTimeout: const Duration(seconds: 15),
  ));

  final int httpPort;
  final String wsHost;
  final int wsPort;
  final Dio _dio;

  HttpServer? _wsServer;
  WebSocket? _clientWs;
  final _controller = StreamController<IncomingMessage>.broadcast();
  int? _actualWsPort;

  @override
  String get platform => 'qq';

  @override
  Stream<IncomingMessage> get messages => _controller.stream;

  int? get actualWsPort => _actualWsPort;

  Future<void> start() async {
    _wsServer = await HttpServer.bind(wsHost, wsPort);
    _actualWsPort = _wsServer!.port;
    _wsServer!.listen(_handleHttpRequest);
  }

  void _handleHttpRequest(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      _clientWs = ws;
      ws.listen(
        (data) {
          if (data is String) _handleEvent(data);
        },
        onDone: () {
          if (_clientWs == ws) _clientWs = null;
        },
      );
    } else {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('PH01 QQ Bridge WS endpoint')
        ..close();
    }
  }

  void _handleEvent(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return;
      final postType = json['post_type'] as String?;
      if (postType != 'message') return;

      final messageType = json['message_type'] as String?;
      final userId = json['user_id']?.toString() ?? '';
      final rawMessage = json['raw_message']?.toString() ??
          json['message']?.toString() ?? '';
      final sender = json['sender'] as Map?;
      final userName = sender?['nickname']?.toString() ??
          sender?['card']?.toString();

      String chatId;
      if (messageType == 'group') {
        chatId = 'group:${json['group_id']}';
      } else {
        chatId = 'private:$userId';
      }

      if (rawMessage.trim().isEmpty) return;

      _controller.add(IncomingMessage(
        userId: userId,
        userName: userName,
        chatId: chatId,
        text: rawMessage,
        ts: DateTime.fromMillisecondsSinceEpoch(
          ((json['time'] as num?) ?? 0).toInt() * 1000,
        ),
        raw: json,
      ));
    } catch (_) {}
  }

  @override
  Future<BridgeResult> send(OutgoingMessage msg) async {
    final chatId = msg.chatId;
    try {
      if (chatId.startsWith('group:')) {
        final groupId = chatId.substring(6);
        final resp = await _dio.post<Map<String, dynamic>>(
          '/send_group_msg',
          data: {
            'group_id': int.tryParse(groupId) ?? groupId,
            'message': msg.text,
          },
        );
        final data = resp.data;
        final msgId = data?['data']?['message_id']?.toString() ?? '';
        if (data?['status'] == 'ok' || data?['retcode'] == 0) {
          return BridgeSuccess(msgId);
        }
        return BridgeError(
          data?['msg']?.toString() ?? 'unknown error',
          remoteCode: data?['retcode']?.toString(),
        );
      } else {
        final userId = chatId.startsWith('private:')
            ? chatId.substring(8)
            : chatId;
        final resp = await _dio.post<Map<String, dynamic>>(
          '/send_private_msg',
          data: {
            'user_id': int.tryParse(userId) ?? userId,
            'message': msg.text,
          },
        );
        final data = resp.data;
        final msgId = data?['data']?['message_id']?.toString() ?? '';
        if (data?['status'] == 'ok' || data?['retcode'] == 0) {
          return BridgeSuccess(msgId);
        }
        return BridgeError(
          data?['msg']?.toString() ?? 'unknown error',
          remoteCode: data?['retcode']?.toString(),
        );
      }
    } catch (e) {
      return BridgeError(e.toString());
    }
  }

  @override
  Future<void> dispose() async {
    await _clientWs?.close();
    await _wsServer?.close(force: true);
    await _controller.close();
    _clientWs = null;
    _wsServer = null;
  }
}
