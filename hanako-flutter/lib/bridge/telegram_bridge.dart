import 'dart:async';

import 'package:dio/dio.dart';

import 'bridge_adapter.dart';

/// Telegram bot client（HTTP long polling）。
///
/// 不依赖 teledart，直接对 Telegram Bot API 走 HTTP；保留扩展点以后可接 webhook。
class TelegramBridge implements BridgeAdapter {
  TelegramBridge({required this.token, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.telegram.org/bot$token',
              receiveTimeout: const Duration(seconds: 60),
            ));

  final String token;
  final Dio _dio;

  final _controller = StreamController<IncomingMessage>.broadcast();
  bool _running = false;
  int _offset = 0;

  @override
  String get platform => 'telegram';

  @override
  Stream<IncomingMessage> get messages => _controller.stream;

  /// 启动 long polling（每 30s 拉一次）。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_pollLoop());
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        final resp = await _dio.get(
          '/getUpdates',
          queryParameters: {
            'offset': _offset,
            'timeout': 25,
          },
        );
        final j = resp.data as Map<String, dynamic>;
        if (j['ok'] != true) {
          await Future<void>.delayed(const Duration(seconds: 5));
          continue;
        }
        final updates = (j['result'] as List?)?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];
        for (final upd in updates) {
          final updateId = upd['update_id'] as int? ?? 0;
          if (updateId >= _offset) _offset = updateId + 1;
          final msg = upd['message'] as Map<String, dynamic>?;
          if (msg == null) continue;
          final text = msg['text'] as String? ?? '';
          final from = msg['from'] as Map<String, dynamic>?;
          final chat = msg['chat'] as Map<String, dynamic>?;
          if (text.isEmpty) continue;
          if (_controller.isClosed) return;
          _controller.add(IncomingMessage(
            userId: '${from?['id']}',
            userName: from?['username'] as String?,
            chatId: '${chat?['id']}',
            text: text,
            ts: DateTime.fromMillisecondsSinceEpoch(
              ((msg['date'] as int? ?? 0) * 1000),
              isUtc: true,
            ),
            raw: msg,
          ));
        }
      } on DioException catch (_) {
        await Future<void>.delayed(const Duration(seconds: 5));
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  @override
  Future<BridgeResult> send(OutgoingMessage msg) async {
    try {
      final resp = await _dio.post(
        '/sendMessage',
        data: {
          'chat_id': msg.chatId,
          'text': msg.text,
          ...?msg.extra,
        },
      );
      final j = resp.data as Map<String, dynamic>;
      if (j['ok'] != true) {
        return BridgeError(j['description'] as String? ?? 'sendMessage failed');
      }
      final result = j['result'] as Map<String, dynamic>?;
      return BridgeSuccess('${result?['message_id'] ?? ''}');
    } on DioException catch (e) {
      return BridgeError(e.message ?? 'network error',
          remoteCode: e.response?.statusCode?.toString());
    }
  }

  @override
  Future<void> dispose() async {
    _running = false;
    if (!_controller.isClosed) await _controller.close();
  }
}

void unawaited(Future<void> _) {}
