import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart' as pc;

import 'bridge_adapter.dart';

/// 飞书 / Lark Bridge。
///
/// **接收**：HTTP webhook（v2 event subscription，对齐 legacy adapter 的事件名
/// `im.message.receive_v1`）。在 GUI 端跑时通常用不到接收（无公网入口），
/// 接收主要在 Server 模式（`bin/server.dart`）下使用——`registerWebhookRoute`
/// 把路由挂到 shelf router。
/// 加解密：可选 AES-256-CBC（pkcs7 padding），key = SHA256(encrypt_key) 截 32 字节。
/// 签名：sha256(timestamp + nonce + encrypt_key + body) hex。
///
/// **发送**：
///   1. POST `https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal`
///      body `{app_id, app_secret}` → `{tenant_access_token, expire}`
///   2. POST `/open-apis/im/v1/messages?receive_id_type=chat_id`
///      headers Authorization: Bearer {tenant_access_token}
///      body `{receive_id, msg_type: "text", content: '{"text":"..."}'}`
///
/// 接收 / 发送解耦：[messages] 流由 webhook 路由 push；上层根据 `chatId` 调 [send]。
class LarkBridge implements BridgeAdapter {
  LarkBridge({
    required this.appId,
    required this.appSecret,
    this.verificationToken,
    this.encryptKey,
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(receiveTimeout: const Duration(seconds: 30)));

  final String appId;
  final String appSecret;
  final String? verificationToken;
  final String? encryptKey;
  final Dio _dio;

  static const _baseUrl = 'https://open.feishu.cn';

  String? _cachedToken;
  DateTime? _tokenExpiresAt;

  final _controller = StreamController<IncomingMessage>.broadcast();

  @override
  String get platform => 'feishu';

  @override
  Stream<IncomingMessage> get messages => _controller.stream;

  /// 由 server 路由调用。raw 是 HTTP request body 字符串，headers 来自 HTTP 头。
  /// 返回值是要给飞书的 HTTP 响应 body（challenge 验证时返回 `{challenge: ...}`）。
  Future<Map<String, dynamic>> handleWebhook({
    required String rawBody,
    Map<String, String> headers = const {},
  }) async {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(rawBody) as Map<String, dynamic>;
    } catch (_) {
      return {'code': 1, 'msg': 'invalid json'};
    }

    // 加密事件：{encrypt: "..."}
    if (data['encrypt'] is String && encryptKey != null) {
      try {
        final decrypted = _aesDecrypt(data['encrypt'] as String, encryptKey!);
        data = jsonDecode(decrypted) as Map<String, dynamic>;
      } catch (e) {
        return {'code': 2, 'msg': 'decrypt failed: $e'};
      }
    }

    // URL 验证
    if (data['type'] == 'url_verification' && data['challenge'] is String) {
      return {'challenge': data['challenge']};
    }

    // verification_token 校验（可选）
    if (verificationToken != null) {
      final token = (data['header'] as Map?)?['token'] ??
          (data['token'] as String?);
      if (token != verificationToken) {
        return {'code': 3, 'msg': 'token mismatch'};
      }
    }

    // 事件分发：v2 event 在 data['event']，v1 直接在 data['event']
    final event = (data['event'] as Map?)?.cast<String, dynamic>() ?? data;
    final eventType = (data['header'] as Map?)?['event_type'] ?? data['type'];

    if (eventType == 'im.message.receive_v1') {
      _onMessageEvent(event);
    }

    return {'code': 0, 'msg': 'ok'};
  }

  void _onMessageEvent(Map<String, dynamic> event) {
    final message = (event['message'] as Map?)?.cast<String, dynamic>();
    final sender = (event['sender'] as Map?)?.cast<String, dynamic>();
    if (message == null || sender == null) return;
    if (message['message_type'] != 'text') return;

    final senderType = (sender['sender_type'] as String?) ?? '';
    if (senderType == 'bot' || senderType == 'app') return;

    final chatId = message['chat_id'] as String? ?? '';
    final senderIdMap = (sender['sender_id'] as Map?)?.cast<String, dynamic>();
    final openId = senderIdMap?['open_id'] as String? ?? 'unknown';
    final userId = senderIdMap?['user_id'] as String? ?? openId;

    var text = '';
    try {
      final contentStr = message['content'] as String? ?? '{}';
      final content = jsonDecode(contentStr) as Map<String, dynamic>;
      text = (content['text'] as String? ?? '').trim();
    } catch (_) {}
    if (text.isEmpty) return;

    final ts = DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(message['create_time'] as String? ?? '0') ?? 0,
    );

    if (_controller.isClosed) return;
    _controller.add(IncomingMessage(
      userId: userId,
      chatId: chatId,
      text: text,
      ts: ts,
      raw: event,
    ));
    // sessionKey 由上层根据 chat_type 判断 group / dm 拼：fs_dm_{openId} / fs_group_{chatId}
  }

  @override
  Future<BridgeResult> send(OutgoingMessage msg) async {
    try {
      final token = await _getTenantToken();
      final resp = await _dio.post(
        '$_baseUrl/open-apis/im/v1/messages',
        queryParameters: {'receive_id_type': 'chat_id'},
        data: {
          'receive_id': msg.chatId,
          'msg_type': 'text',
          'content': jsonEncode({'text': msg.text}),
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          validateStatus: (_) => true,
        ),
      );
      final data = resp.data as Map<String, dynamic>?;
      if (data == null) return const BridgeError('empty response');
      if (data['code'] != 0) {
        return BridgeError(
          data['msg'] as String? ?? 'send failed',
          remoteCode: '${data['code']}',
        );
      }
      final messageId =
          ((data['data'] as Map?)?['message_id'] as String?) ?? '';
      return BridgeSuccess(messageId);
    } on DioException catch (e) {
      return BridgeError(e.message ?? 'network error',
          remoteCode: e.response?.statusCode?.toString());
    }
  }

  Future<String> _getTenantToken() async {
    final now = DateTime.now();
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        now.isBefore(_tokenExpiresAt!)) {
      return _cachedToken!;
    }
    final resp = await _dio.post(
      '$_baseUrl/open-apis/auth/v3/tenant_access_token/internal',
      data: {'app_id': appId, 'app_secret': appSecret},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final j = resp.data as Map<String, dynamic>;
    if (j['code'] != 0) {
      throw Exception('tenant_access_token failed: ${j['msg']}');
    }
    final token = j['tenant_access_token'] as String;
    final expireSec = j['expire'] as int? ?? 7000;
    _cachedToken = token;
    // 提前 5 分钟过期
    _tokenExpiresAt = now.add(Duration(seconds: expireSec - 300));
    return token;
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }

  // ---------------- AES-256-CBC pkcs7（飞书加密事件）----------------
  static String _aesDecrypt(String encryptedB64, String encryptKey) {
    final keyBytes = crypto.sha256.convert(utf8.encode(encryptKey)).bytes;
    final cipherBytes = base64.decode(encryptedB64);
    if (cipherBytes.length < 16) throw Exception('cipher too short');
    final iv = cipherBytes.sublist(0, 16);
    final body = cipherBytes.sublist(16);

    final cipher = pc.PaddedBlockCipherImpl(
      pc.PKCS7Padding(),
      pc.CBCBlockCipher(pc.AESEngine()),
    )..init(
        false,
        pc.PaddedBlockCipherParameters(
          pc.ParametersWithIV(
            pc.KeyParameter(Uint8List.fromList(keyBytes)),
            Uint8List.fromList(iv),
          ),
          null,
        ),
      );

    final plainBytes = cipher.process(Uint8List.fromList(body));
    return utf8.decode(plainBytes);
  }

  /// 验证签名（事件订阅可选启用）。
  /// 算法：sha256(timestamp + nonce + encrypt_key + raw_body) hex
  static bool verifySignature({
    required String timestamp,
    required String nonce,
    required String encryptKey,
    required String rawBody,
    required String signature,
  }) {
    final input = '$timestamp$nonce$encryptKey$rawBody';
    final hex = crypto.sha256.convert(utf8.encode(input)).toString();
    return hex == signature;
  }
}
