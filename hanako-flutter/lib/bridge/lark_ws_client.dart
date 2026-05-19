import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'bridge_adapter.dart';
import 'lark_ws_protocol.dart';

/// 飞书长连接客户端。
///
/// 生命周期：bootstrap → dial → 心跳 + 分片重组 → 断线重连。
/// 来源：docs/feishu-ws-protocol.md（从 larksuite/oapi-sdk-go ws/ 反推）。
class LarkWsClient {
  LarkWsClient({
    required this.appId,
    required this.appSecret,
    this.domain = 'https://open.feishu.cn',
    Dio? dio,
  }) : _dio = dio ?? Dio();

  final String appId;
  final String appSecret;
  final String domain;
  final Dio _dio;

  WebSocket? _ws;
  Timer? _pingTimer;
  bool _running = false;
  int _reconnectAttempts = 0;

  int _pingInterval = 30;
  int _reconnectInterval = 5;
  int _reconnectCount = 10;

  final _controller = StreamController<IncomingMessage>.broadcast();
  final Map<String, List<_Fragment>> _fragments = {};

  Stream<IncomingMessage> get messages => _controller.stream;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _connectLoop();
  }

  Future<void> stop() async {
    _running = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    await _ws?.close();
    _ws = null;
    await _controller.close();
  }

  Future<void> _connectLoop() async {
    while (_running) {
      try {
        final endpoint = await _bootstrap();
        if (endpoint == null) {
          await _backoff();
          continue;
        }
        await _dial(endpoint);
        _reconnectAttempts = 0;
        await _listen();
      } catch (_) {}
      if (!_running) break;
      _reconnectAttempts++;
      if (_reconnectAttempts > _reconnectCount) {
        _reconnectAttempts = 0;
      }
      await _backoff();
    }
  }

  Future<_BootstrapEndpoint?> _bootstrap() async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$domain/callback/ws/endpoint',
        data: {'AppID': appId, 'AppSecret': appSecret},
      );
      final body = resp.data;
      if (body == null) return null;
      final statusCode = body['StatusCode'] as int? ?? -1;
      if (statusCode != 0) return null;

      final ep = body['Endpoint'] as Map<String, dynamic>?;
      if (ep == null) return null;
      final url = ep['Url'] as String?;
      if (url == null || url.isEmpty) return null;

      final config = ep['ClientConfig'] as Map<String, dynamic>? ?? {};
      _pingInterval = (config['PingInterval'] as num?)?.toInt() ?? 30;
      _reconnectInterval = (config['ReconnectInterval'] as num?)?.toInt() ?? 5;
      _reconnectCount = (config['ReconnectCount'] as num?)?.toInt() ?? 10;

      return _BootstrapEndpoint(url: url);
    } catch (_) {
      return null;
    }
  }

  Future<void> _dial(_BootstrapEndpoint endpoint) async {
    _ws = await WebSocket.connect(endpoint.url)
        .timeout(const Duration(seconds: 15));
    _startPing();
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(Duration(seconds: _pingInterval), (_) {
      try {
        _ws?.add(LarkFrame.ping().encode());
      } catch (_) {}
    });
  }

  Future<void> _listen() async {
    final ws = _ws;
    if (ws == null) return;
    await for (final data in ws) {
      if (data is! List<int>) continue;
      final frame = LarkFrame.decode(Uint8List.fromList(data));
      if (frame == null) continue;
      _handleFrame(frame);
    }
  }

  void _handleFrame(LarkFrame frame) {
    if (frame.isPing) {
      try {
        _ws?.add(LarkFrame.pong().encode());
      } catch (_) {}
      return;
    }
    if (frame.isPong || frame.isControl) return;

    // Data 帧：分片重组
    final messageId = frame.messageId;
    final sum = frame.sum;
    final seq = frame.seq;

    if (sum <= 1) {
      _dispatchPayload(frame.payload);
      _ack(frame);
      return;
    }

    final fragments = _fragments.putIfAbsent(messageId, () => []);
    fragments.add(_Fragment(seq: seq, payload: frame.payload));

    if (fragments.length >= sum) {
      fragments.sort((a, b) => a.seq.compareTo(b.seq));
      final assembled = BytesBuilder();
      for (final f in fragments) {
        assembled.add(f.payload);
      }
      _fragments.remove(messageId);
      _dispatchPayload(assembled.toBytes());
    }
    _ack(frame);
  }

  void _dispatchPayload(List<int> payload) {
    try {
      final json = jsonDecode(utf8.decode(payload, allowMalformed: true));
      if (json is! Map<String, dynamic>) return;

      final header = json['header'] as Map<String, dynamic>?;
      final eventType = header?['event_type'] as String?;
      if (eventType != 'im.message.receive_v1') return;

      final event = json['event'] as Map<String, dynamic>?;
      if (event == null) return;
      final message = event['message'] as Map<String, dynamic>?;
      final sender = event['sender'] as Map<String, dynamic>?;
      if (message == null || sender == null) return;
      if (message['message_type'] != 'text') return;

      final contentStr = message['content'] as String? ?? '{}';
      String text;
      try {
        text = (jsonDecode(contentStr) as Map)['text']?.toString() ?? '';
      } catch (_) {
        text = contentStr;
      }
      if (text.trim().isEmpty) return;

      _controller.add(IncomingMessage(
        userId: sender['sender_id']?['open_id']?.toString() ?? '',
        userName: sender['sender_id']?['user_id']?.toString(),
        chatId: message['chat_id']?.toString() ?? '',
        text: text,
        ts: DateTime.now(),
        raw: json,
      ));
    } catch (_) {}
  }

  void _ack(LarkFrame frame) {
    try {
      final response = LarkResponse(statusCode: 0);
      final ackFrame = LarkFrame(
        frameType: 0,
        headers: {
          'type': 'response',
          if (frame.messageId.isNotEmpty) 'message_id': frame.messageId,
        },
        payload: response.encode(),
      );
      _ws?.add(ackFrame.encode());
    } catch (_) {}
  }

  Future<void> _backoff() async {
    if (!_running) return;
    final seconds = _reconnectInterval * (_reconnectAttempts + 1);
    await Future<void>.delayed(Duration(seconds: seconds.clamp(1, 60)));
  }
}

class _BootstrapEndpoint {
  const _BootstrapEndpoint({required this.url});
  final String url;
}

class _Fragment {
  const _Fragment({required this.seq, required this.payload});
  final int seq;
  final List<int> payload;
}
