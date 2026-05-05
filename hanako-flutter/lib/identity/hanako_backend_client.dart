// lib/identity/hanako_backend_client.dart
//
// 子体与 ph01-backend 三方（auth-gateway / ai-gateway）的统一客户端。
//
// 职责：
//   - 注册 / 身份确认 / 公钥恢复（auth-gateway）
//   - ECDH 短期通信通道 + 加密 LLM chat（ai-gateway）
//   - 把签名包装、加密、JSON 序列化全部封装好，UI 层只面对业务对象。
//
// 与协议契约（docs/protocol-spec.md）一一对应。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'ecdh.dart';
import 'keypair.dart';
import 'signed_request.dart';

class HanakoBackendClient {
  HanakoBackendClient({
    this.authBaseUrl = defaultAuthBaseUrl,
    this.aiBaseUrl = defaultAiBaseUrl,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  static const defaultAuthBaseUrl = 'https://auth.幻宙.cn';

  static const defaultAiBaseUrl = 'https://ai.幻宙.cn';

  /// auth-gateway 基础 URL。生产默认是 `https://auth.幻宙.cn`。
  final String authBaseUrl;

  /// ai-gateway 基础 URL。生产默认是 `https://ai.幻宙.cn`。
  final String aiBaseUrl;

  final Dio _dio;

  /// 当前短期通信通道（ECDH 握手后建立）。这不是登录态。
  HanakoChannel? _channel;
  HanakoChannel? get channel => _channel;

  // ============== auth-gateway ==============

  /// 公开用户名预检：用于首次引导判断进入注册还是既有账号登录流程。
  Future<UsernameAvailability> checkUsernameAvailability(
    String username,
  ) async {
    final normalized = username.trim();
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse(
        '$authBaseUrl/api/v1/auth/username_available',
      ).replace(queryParameters: {'username': normalized}),
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return UsernameAvailability(
      username: body['username'] as String,
      available: body['available'] as bool,
    );
  }

  /// 注册：用本地新生成的密钥对调 /api/v1/auth/register。
  Future<RegisterResult> register({
    required HanakoKeyPair keyPair,
    required String username,
    required String nickname,
    required String email,
    required String emailChallengeId,
    required String emailCode,
  }) async {
    final payload = {
      'username': username,
      'nickname': nickname,
      'email': email.trim(),
      'email_challenge_id': emailChallengeId.trim(),
      'email_code': emailCode.trim(),
      'pubkey_hex': keyPair.publicKeyHex,
    };
    final req = signRequest(keyPair: keyPair, businessPayload: payload);
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$authBaseUrl/api/v1/auth/register'),
      data: req.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return RegisterResult(
      userId: (body['user_id'] as num).toInt(),
      username: body['username'] as String,
      tier: body['tier'] as String,
      pubkeyHash: body['pubkey_hash'] as String,
    );
  }

  /// 注册邮箱验证：用户名可用后，先向邮箱发送验证码。
  Future<RegistrationEmailChallenge> startRegistrationEmail({
    required String username,
    required String email,
  }) async {
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$authBaseUrl/api/v1/auth/register_email/start'),
      data: {'username': username.trim(), 'email': email.trim()},
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return RegistrationEmailChallenge(
      challengeId: body['challenge_id'] as String,
      delivery: body['delivery'] as String,
      expiresIn: (body['expires_in'] as num).toInt(),
    );
  }

  /// 身份确认（已知 username + 持有私钥）。
  /// 服务端只返回身份摘要，不签发 token。
  Future<RegisterResult> login({
    required HanakoKeyPair keyPair,
    required String username,
  }) async {
    final req = signRequest(
      keyPair: keyPair,
      businessPayload: {'username': username},
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$authBaseUrl/api/v1/auth/login'),
      data: req.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return RegisterResult(
      userId: (body['user_id'] as num).toInt(),
      username: body['username'] as String,
      tier: body['tier'] as String,
      pubkeyHash: body['pubkey_hash'] as String,
    );
  }

  /// 故事恢复长期身份的第一步：拉某 username 名下所有公钥哈希。
  /// 不签名（因为子体此时尚未持有私钥），但服务端限频。
  Future<List<String>> fetchRecoveryCandidates(String username) async {
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$authBaseUrl/api/v1/auth/recovery_candidates'),
      data: {'username': username},
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return (body['pubkey_hashes'] as List).cast<String>();
  }

  /// 第二阶段恢复：请求邮箱验证码。服务端返回挑战 ID 和脱敏投递地址。
  Future<RecoveryRfaChallenge> startRecoveryRfa(String username) async {
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$authBaseUrl/api/v1/auth/recovery_rfa/start'),
      data: {'username': username},
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return RecoveryRfaChallenge(
      challengeId: body['challenge_id'] as String,
      delivery: body['delivery'] as String,
      expiresIn: (body['expires_in'] as num).toInt(),
    );
  }

  /// 第二阶段恢复：提交邮箱验证码，换取短期 recovery grant。
  ///
  /// grant 只用于开放更宽的恢复矩阵，不是登录态。
  Future<RecoveryGrant> verifyRecoveryRfa({
    required String challengeId,
    required String code,
  }) async {
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$authBaseUrl/api/v1/auth/recovery_rfa/verify'),
      data: {'challenge_id': challengeId, 'code': code},
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return RecoveryGrant(
      recoveryGrant: body['recovery_grant'] as String,
      expiresIn: (body['expires_in'] as num).toInt(),
      maxCandidatesPerColumn: (body['max_candidates_per_column'] as num)
          .toInt(),
    );
  }

  // ============== ai-gateway ==============

  /// 生成 AI 网关登录授权结果。
  ///
  /// 返回值用于两条路径：
  ///   - 登录码：把 JSON 字符串复制给网页粘贴框
  ///   - 协议登录：POST 到 `ph01://login` 给出的 callback
  ///
  /// 签名内容就是原始 base64url challenge 字符串。
  Map<String, dynamic> buildAiGatewayLoginAuthorization({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
  }) {
    if (userId <= 0) {
      throw ArgumentError.value(userId, 'userId', 'must be positive');
    }
    final nonce = _decodeAiGatewayChallengeNonce(challenge);
    final signature = keyPair.sign(Uint8List.fromList(utf8.encode(challenge)));
    return {
      'user_id': userId,
      'nonce': nonce,
      'signature': _hexEncode(signature),
    };
  }

  /// 生成网页登录码输入框可直接粘贴的 JSON 字符串。
  String buildAiGatewayLoginCode({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
  }) {
    return jsonEncode(
      buildAiGatewayLoginAuthorization(
        keyPair: keyPair,
        userId: userId,
        challenge: challenge,
      ),
    );
  }

  /// 协议登录授权后，把签名结果回传给 AI 网关 callback。
  Future<void> completeAiGatewayProtocolLogin({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
    required String callbackUrl,
  }) async {
    final body = buildAiGatewayLoginAuthorization(
      keyPair: keyPair,
      userId: userId,
      challenge: challenge,
    );
    await _dio.postUri<Map<String, dynamic>>(
      Uri.parse(callbackUrl),
      data: body,
      options: Options(contentType: Headers.jsonContentType),
    );
  }

  /// ECDH 握手：建立短期通信通道，缓存到 [_channel]。
  /// 必须在调 [chat] 之前调用一次。
  Future<HanakoChannel> handshake({required HanakoKeyPair keyPair}) async {
    final ephemeral = EphemeralKey.generate();
    final req = signRequest(
      keyPair: keyPair,
      businessPayload: {'ephemeral_pubkey': ephemeral.publicKeyHex},
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$aiBaseUrl/api/v1/channel/handshake'),
      data: req.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    final serverPubHex = body['ephemeral_pubkey'] as String;
    final aesKey = deriveSharedAesKey(ephemeral.privateKey, serverPubHex);
    final ch = HanakoChannel(
      channelId: body['channel_id'] as String,
      aesKey: aesKey,
      expiresAt: DateTime.now().add(
        Duration(seconds: (body['idle_expires_in'] as num).toInt()),
      ),
      allowedModels: (body['allowed_models'] as List).cast<String>(),
    );
    _channel = ch;
    return ch;
  }

  /// 读取当前短期通信通道允许使用的模型列表。
  ///
  /// 该接口必须绑定 channel_id；channel_id 只能通过私钥签名 + ECDH 握手得到。
  Future<GatewayModelList> listModels({String? channelId}) async {
    final id = channelId ?? _requireChannel().channelId;
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse(
        '$aiBaseUrl/api/v1/models',
      ).replace(queryParameters: {'channel_id': id}),
      options: Options(contentType: Headers.jsonContentType),
    );
    final body = resp.data!;
    return GatewayModelList(
      models: (body['models'] as List?)?.cast<String>() ?? const <String>[],
      tier: body['tier'] as String?,
    );
  }

  /// 非流式 LLM 调用（解密响应整体返回）。
  Future<Map<String, dynamic>> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? extra,
  }) async {
    final ch = _requireChannel();
    final plaintext = jsonEncode({
      'model': model,
      'messages': messages,
      'stream': false,
      ...?(_optionalExtra(extra)),
    });
    final enc = encryptGcm(
      ch.aesKey,
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$aiBaseUrl/api/v1/llm/chat'),
      data: {
        'channel_id': ch.channelId,
        'nonce': enc.nonceHex,
        'ciphertext': enc.ciphertextHex,
        'tag': enc.tagHex,
      },
      options: Options(contentType: Headers.jsonContentType),
    );
    final env = resp.data!;
    final pt = decryptGcm(
      ch.aesKey,
      nonceHex: env['nonce'] as String,
      ciphertextHex: env['ciphertext'] as String,
      tagHex: env['tag'] as String,
    );
    return jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
  }

  /// 流式 LLM 调用：每个 SSE chunk 解密后 yield 出去。
  /// 服务端 SSE 行格式：`data: {EncryptedEnvelope JSON}\n\n`，
  /// 最后一行 `data: [DONE]\n\n`。
  Stream<String> chatStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? extra,
    CancelToken? cancelToken,
  }) async* {
    final ch = _requireChannel();
    final plaintext = jsonEncode({
      'model': model,
      'messages': messages,
      'stream': true,
      ...?(_optionalExtra(extra)),
    });
    final enc = encryptGcm(
      ch.aesKey,
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    final resp = await _dio.postUri<ResponseBody>(
      Uri.parse('$aiBaseUrl/api/v1/llm/chat'),
      data: {
        'channel_id': ch.channelId,
        'nonce': enc.nonceHex,
        'ciphertext': enc.ciphertextHex,
        'tag': enc.tagHex,
      },
      options: Options(
        contentType: Headers.jsonContentType,
        responseType: ResponseType.stream,
      ),
      cancelToken: cancelToken,
    );

    final stream = resp.data!.stream;
    final buffer = StringBuffer();
    await for (final chunk in stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      while (true) {
        final str = buffer.toString();
        final idx = str.indexOf('\n');
        if (idx < 0) break;
        final line = str.substring(0, idx);
        buffer.clear();
        buffer.write(str.substring(idx + 1));
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') return;
        if (data.isEmpty) continue;
        try {
          final env = jsonDecode(data) as Map<String, dynamic>;
          final pt = decryptGcm(
            ch.aesKey,
            nonceHex: env['nonce'] as String,
            ciphertextHex: env['ciphertext'] as String,
            tagHex: env['tag'] as String,
          );
          yield utf8.decode(pt);
        } catch (_) {
          // 跳过坏行
        }
      }
    }
  }

  HanakoChannel _requireChannel() {
    final ch = _channel;
    if (ch == null) {
      throw StateError('未握手，请先调用 handshake()');
    }
    if (DateTime.now().isAfter(ch.expiresAt)) {
      _channel = null;
      throw StateError('通信通道已过期，请重新 handshake()');
    }
    return ch;
  }
}

Map<String, dynamic>? _optionalExtra(Map<String, dynamic>? extra) {
  if (extra == null) return null;
  return {'extra': extra};
}

String _decodeAiGatewayChallengeNonce(String challenge) {
  final raw = base64Url.decode(base64Url.normalize(challenge));
  final decoded = jsonDecode(utf8.decode(raw));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('AI gateway challenge must be a JSON object');
  }
  final nonce = decoded['nonce'];
  if (nonce is! String || nonce.trim().isEmpty) {
    throw const FormatException('AI gateway challenge nonce is missing');
  }
  return nonce.trim();
}

String _hexEncode(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(chars[(b >> 4) & 0x0f]);
    buf.write(chars[b & 0x0f]);
  }
  return buf.toString();
}

/// 用户名预检返回值。
class UsernameAvailability {
  UsernameAvailability({required this.username, required this.available});

  final String username;
  final bool available;
}

/// 注册 / 身份确认的返回值。
class RegisterResult {
  RegisterResult({
    required this.userId,
    required this.username,
    required this.tier,
    required this.pubkeyHash,
  });
  final int userId;
  final String username;
  final String tier;
  final String pubkeyHash;
}

/// 注册邮箱验证码挑战。
class RegistrationEmailChallenge {
  RegistrationEmailChallenge({
    required this.challengeId,
    required this.delivery,
    required this.expiresIn,
  });

  final String challengeId;
  final String delivery;
  final int expiresIn;
}

/// 邮箱 RFA 挑战。
class RecoveryRfaChallenge {
  RecoveryRfaChallenge({
    required this.challengeId,
    required this.delivery,
    required this.expiresIn,
  });

  final String challengeId;
  final String delivery;
  final int expiresIn;
}

/// 邮箱 RFA 验证后得到的短期深度恢复授权。
class RecoveryGrant {
  RecoveryGrant({
    required this.recoveryGrant,
    required this.expiresIn,
    required this.maxCandidatesPerColumn,
  });

  final String recoveryGrant;
  final int expiresIn;
  final int maxCandidatesPerColumn;
}

/// AI 网关当前通道授权模型列表。
class GatewayModelList {
  GatewayModelList({required this.models, this.tier});

  final List<String> models;
  final String? tier;
}

/// ECDH 握手后建立的短期加密通信通道。
class HanakoChannel {
  HanakoChannel({
    required this.channelId,
    required this.aesKey,
    required this.expiresAt,
    required this.allowedModels,
  });
  final String channelId;
  final Uint8List aesKey;
  final DateTime expiresAt;
  final List<String> allowedModels;
}
