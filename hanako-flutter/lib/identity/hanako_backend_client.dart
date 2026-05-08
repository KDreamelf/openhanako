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

import '../llm/provider.dart';
import '../shared/diagnostics_log.dart';
import 'ecdh.dart';
import 'keypair.dart';
import 'signed_request.dart';

class HanakoBackendClient {
  HanakoBackendClient({
    this.authBaseUrl = defaultAuthBaseUrl,
    this.aiBaseUrl = defaultAiBaseUrl,
    this.backendDiagnosticsLog,
    this.publicStoryDiagnosticsLog,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  static const defaultAuthBaseUrl = 'https://auth.xn--lbtx0e.cn';

  static const defaultAiBaseUrl = 'https://ai.xn--lbtx0e.cn';

  /// auth-gateway 基础 URL。生产默认是 `https://auth.xn--lbtx0e.cn`。
  final String authBaseUrl;

  /// ai-gateway 基础 URL。生产默认是 `https://ai.xn--lbtx0e.cn`。
  final String aiBaseUrl;

  /// 公开故事/恢复链路本地 JSONL 诊断日志。
  final DiagnosticsLog? publicStoryDiagnosticsLog;

  /// 通用认证/AI 网关传输诊断日志。
  final DiagnosticsLog? backendDiagnosticsLog;

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
      cooldownSeconds: (body['cooldown_seconds'] as num?)?.toInt() ?? 60,
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

  /// 密钥轮换第一步：当前有效旧私钥签名后，请求绑定邮箱验证码。
  Future<PubkeyRotationEmailChallenge> startPubkeyRotationEmail({
    required HanakoKeyPair keyPair,
    required String username,
  }) async {
    final startedAt = DateTime.now();
    const endpoint = '/api/v1/auth/rotate_pubkey_email/start';
    final req = signRequest(
      keyPair: keyPair,
      businessPayload: {'username': username.trim()},
    );
    _writeBackendTransportLog(
      'transport_request',
      operation: 'pubkey_rotation_email_start',
      phase: 'request',
      status: 'start',
      method: 'POST',
      endpoint: endpoint,
      fields: {'has_current_key': true},
    );
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl$endpoint'),
        data: req.toJson(),
        options: Options(contentType: Headers.jsonContentType),
      );
      final body = resp.data!;
      final result = PubkeyRotationEmailChallenge(
        challengeId: body['challenge_id'] as String,
        delivery: body['delivery'] as String,
        expiresIn: (body['expires_in'] as num).toInt(),
        cooldownSeconds: (body['cooldown_seconds'] as num?)?.toInt() ?? 60,
      );
      _writeBackendTransportLog(
        'transport_success',
        operation: 'pubkey_rotation_email_start',
        phase: 'response',
        status: 'success',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'status_code': resp.statusCode,
          'delivery': result.delivery,
        },
      );
      return result;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(
        e,
        action: '发送密钥轮换验证码',
      );
      _writeBackendTransportLog(
        'transport_failure',
        operation: 'pubkey_rotation_email_start',
        phase: 'response',
        status: 'failure',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          ..._backendExceptionLogFields(error),
        },
      );
      throw error;
    }
  }

  /// 密钥轮换第二步：仍由旧私钥签名，提交邮箱验证码和新公钥。
  Future<PubkeyRotationResult> rotatePubkey({
    required HanakoKeyPair keyPair,
    required String username,
    required String emailChallengeId,
    required String emailCode,
    required String newPubkeyHex,
  }) async {
    final startedAt = DateTime.now();
    const endpoint = '/api/v1/auth/rotate_pubkey';
    final cleanNewPubkey = newPubkeyHex.trim();
    final req = signRequest(
      keyPair: keyPair,
      businessPayload: {
        'username': username.trim(),
        'email_challenge_id': emailChallengeId.trim(),
        'email_code': emailCode.trim(),
        'new_pubkey_hex': cleanNewPubkey,
      },
    );
    _writeBackendTransportLog(
      'transport_request',
      operation: 'pubkey_rotation',
      phase: 'request',
      status: 'start',
      method: 'POST',
      endpoint: endpoint,
      fields: {
        'has_current_key': true,
        'new_pubkey_hex_chars': cleanNewPubkey.length,
      },
    );
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl$endpoint'),
        data: req.toJson(),
        options: Options(contentType: Headers.jsonContentType),
      );
      final body = resp.data!;
      final result = PubkeyRotationResult(
        userId: (body['user_id'] as num).toInt(),
        username: body['username'] as String,
        tier: body['tier'] as String,
        oldPubkeyHash: body['old_pubkey_hash'] as String,
        newPubkeyHash: body['new_pubkey_hash'] as String,
        effectiveAt: (body['effective_at'] as num).toInt(),
        revokedPreviousCount: (body['revoked_previous_count'] as num).toInt(),
      );
      _writeBackendTransportLog(
        'transport_success',
        operation: 'pubkey_rotation',
        phase: 'response',
        status: 'success',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'status_code': resp.statusCode,
          'user_id': result.userId,
          'revoked_previous_count': result.revokedPreviousCount,
        },
      );
      return result;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(e, action: '轮换密钥');
      _writeBackendTransportLog(
        'transport_failure',
        operation: 'pubkey_rotation',
        phase: 'response',
        status: 'failure',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          ..._backendExceptionLogFields(error),
        },
      );
      throw error;
    }
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
      cooldownSeconds: (body['cooldown_seconds'] as num?)?.toInt() ?? 60,
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
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse(callbackUrl),
      data: body,
      options: Options(contentType: Headers.jsonContentType),
    );
    final respBody = resp.data;
    if (respBody == null) return;
    if (respBody['success'] == false) {
      final message = respBody['message'] ?? respBody['error'] ?? respBody;
      throw StateError('AI gateway protocol login failed: $message');
    }
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

  /// 读取注册/恢复期公开故事流程允许使用的模型列表。
  ///
  /// 该接口走 AI 网关的 PH01 root public carrier，不依赖当前身份，也不会覆盖
  /// 普通聊天的 ECDH [_channel]。
  Future<GatewayModelList> listPublicStoryModels() async {
    final startedAt = DateTime.now();
    final ch = _currentChannelOrNull();
    final mode = ch == null ? 'plaintext' : 'encrypted';
    _writePublicStoryTransportLog(
      'transport_request',
      operation: 'public_story_models',
      phase: 'request',
      status: 'start',
      method: ch == null ? 'GET' : 'POST',
      endpoint: '/api/v1/public/story/models',
      mode: mode,
      fields: {
        'has_channel': ch != null,
        'channel_expires_in_ms': _channelExpiresInMs(ch),
      },
    );
    try {
      final Response<Map<String, dynamic>> resp;
      Map<String, dynamic> body;
      if (ch != null) {
        resp = await _dio.postUri<Map<String, dynamic>>(
          Uri.parse('$aiBaseUrl/api/v1/public/story/models'),
          data: _encryptedEnvelope(ch, {'purpose': 'public_story_models'}),
          options: Options(contentType: Headers.jsonContentType),
        );
        body = _decryptEnvelope(ch, resp.data!);
        _extendChannel(ch);
      } else {
        resp = await _dio.getUri<Map<String, dynamic>>(
          Uri.parse('$aiBaseUrl/api/v1/public/story/models'),
          options: Options(contentType: Headers.jsonContentType),
        );
        body = resp.data!;
      }
      final result = GatewayModelList(
        models: (body['models'] as List?)?.cast<String>() ?? const <String>[],
        tier: body['tier'] as String?,
      );
      _writePublicStoryTransportLog(
        'transport_success',
        operation: 'public_story_models',
        phase: 'response',
        status: 'success',
        method: ch == null ? 'GET' : 'POST',
        endpoint: '/api/v1/public/story/models',
        mode: mode,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'status_code': resp.statusCode,
          'model_count': result.models.length,
          if (result.tier != null) 'tier': result.tier,
          'response_keys': _mapKeys(body),
        },
      );
      return result;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(
        e,
        action: '获取公开故事模型列表',
      );
      _writePublicStoryTransportLog(
        'transport_failure',
        operation: 'public_story_models',
        phase: 'response',
        status: 'failure',
        method: ch == null ? 'GET' : 'POST',
        endpoint: '/api/v1/public/story/models',
        mode: mode,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          ..._backendExceptionLogFields(error),
        },
      );
      throw error;
    } catch (error, stackTrace) {
      _writePublicStoryTransportLog(
        'transport_decrypt_failure',
        operation: 'public_story_models',
        phase: 'decrypt',
        status: 'failure',
        method: ch == null ? 'GET' : 'POST',
        endpoint: '/api/v1/public/story/models',
        mode: mode,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          ..._objectExceptionLogFields(error),
        },
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 非流式 LLM 调用（解密响应整体返回）。
  Future<Map<String, dynamic>> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Tool>? tools,
    Object? toolChoice,
    Map<String, dynamic>? extra,
  }) async {
    final ch = _requireChannel();
    final plaintext = jsonEncode(
      _chatPayload(
        model: model,
        messages: messages,
        stream: false,
        tools: tools,
        toolChoice: toolChoice,
        extra: extra,
      ),
    );
    final enc = encryptGcm(
      ch.aesKey,
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    final Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$aiBaseUrl/api/v1/llm/chat'),
        data: {
          'channel_id': ch.channelId,
          'nonce': enc.nonceHex,
          'ciphertext': enc.ciphertextHex,
          'tag': enc.tagHex,
        },
        options: Options(contentType: Headers.jsonContentType),
      );
    } on DioException catch (e) {
      throw await HanakoBackendException.fromDio(e, action: '发送对话');
    }
    final env = resp.data!;
    final pt = decryptGcm(
      ch.aesKey,
      nonceHex: env['nonce'] as String,
      ciphertextHex: env['ciphertext'] as String,
      tagHex: env['tag'] as String,
    );
    return jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
  }

  /// 注册/恢复期公开故事 LLM 调用。
  ///
  /// 只用于助记词故事生成与故事解析；服务端会使用 root 用户的
  /// `PH01 Public Key` 托管配置执行调用。
  Future<Map<String, dynamic>> publicStoryChat({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? extra,
  }) async {
    final startedAt = DateTime.now();
    final payload = _chatPayload(
      model: model,
      messages: messages,
      stream: false,
      extra: extra,
    );
    final ch = _currentChannelOrNull();
    final mode = ch == null ? 'plaintext' : 'encrypted';
    _writePublicStoryTransportLog(
      'transport_request',
      operation: 'public_story_chat',
      phase: 'request',
      status: 'start',
      method: 'POST',
      endpoint: '/api/v1/public/story/chat',
      mode: mode,
      fields: {
        'model': model,
        'has_channel': ch != null,
        'channel_expires_in_ms': _channelExpiresInMs(ch),
        'request_payload_chars': jsonEncode(payload).length,
        ..._messageStats(messages),
      },
    );
    try {
      final Response<Map<String, dynamic>> resp;
      Map<String, dynamic> body;
      if (ch != null) {
        resp = await _dio.postUri<Map<String, dynamic>>(
          Uri.parse('$aiBaseUrl/api/v1/public/story/chat'),
          data: _encryptedEnvelope(ch, payload),
          options: Options(contentType: Headers.jsonContentType),
        );
        body = _decryptEnvelope(ch, resp.data!);
        _extendChannel(ch);
      } else {
        resp = await _dio.postUri<Map<String, dynamic>>(
          Uri.parse('$aiBaseUrl/api/v1/public/story/chat'),
          data: payload,
          options: Options(contentType: Headers.jsonContentType),
        );
        body = resp.data!;
      }
      _writePublicStoryTransportLog(
        'transport_success',
        operation: 'public_story_chat',
        phase: 'response',
        status: 'success',
        method: 'POST',
        endpoint: '/api/v1/public/story/chat',
        mode: mode,
        fields: {
          'model': model,
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'status_code': resp.statusCode,
          'response_keys': _mapKeys(body),
          'choice_count': _choiceCount(body),
        },
      );
      return body;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(e, action: '调用公开故事模型');
      _writePublicStoryTransportLog(
        'transport_failure',
        operation: 'public_story_chat',
        phase: 'response',
        status: 'failure',
        method: 'POST',
        endpoint: '/api/v1/public/story/chat',
        mode: mode,
        fields: {
          'model': model,
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          ..._backendExceptionLogFields(error),
        },
      );
      throw error;
    } catch (error, stackTrace) {
      _writePublicStoryTransportLog(
        'transport_decrypt_failure',
        operation: 'public_story_chat',
        phase: 'decrypt',
        status: 'failure',
        method: 'POST',
        endpoint: '/api/v1/public/story/chat',
        mode: mode,
        fields: {
          'model': model,
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          ..._objectExceptionLogFields(error),
        },
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 流式 LLM 调用：只返回正文文本，兼容旧调用点。
  Stream<String> chatStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Tool>? tools,
    Object? toolChoice,
    Map<String, dynamic>? extra,
    CancelToken? cancelToken,
  }) async* {
    await for (final event in chatEvents(
      model: model,
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      extra: extra,
      cancelToken: cancelToken,
    )) {
      if (event is TextDelta) {
        yield event.text;
      }
    }
  }

  /// 流式 LLM 调用：每个 SSE chunk 解密后转成正文、思考或工具事件。
  /// 服务端 SSE 行格式：`data: {EncryptedEnvelope JSON}\n\n`，
  /// 最后一行 `data: [DONE]\n\n`。
  Stream<LlmEvent> chatEvents({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Tool>? tools,
    Object? toolChoice,
    Map<String, dynamic>? extra,
    CancelToken? cancelToken,
  }) async* {
    final ch = _requireChannel();
    final plaintext = jsonEncode(
      _chatPayload(
        model: model,
        messages: messages,
        stream: true,
        tools: tools,
        toolChoice: toolChoice,
        extra: extra,
      ),
    );
    final enc = encryptGcm(
      ch.aesKey,
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    final Response<ResponseBody> resp;
    try {
      resp = await _dio.postUri<ResponseBody>(
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
    } on DioException catch (e) {
      throw await HanakoBackendException.fromDio(e, action: '发送对话');
    }

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
          for (final event in _extractChatStreamEvents(utf8.decode(pt))) {
            yield event;
          }
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

  HanakoChannel? _currentChannelOrNull() {
    final ch = _channel;
    if (ch == null) return null;
    if (DateTime.now().isAfter(ch.expiresAt)) {
      _channel = null;
      return null;
    }
    return ch;
  }

  Map<String, dynamic> _encryptedEnvelope(
    HanakoChannel channel,
    Map<String, dynamic> plaintext,
  ) {
    final enc = encryptGcm(
      channel.aesKey,
      Uint8List.fromList(utf8.encode(jsonEncode(plaintext))),
    );
    return {
      'channel_id': channel.channelId,
      'nonce': enc.nonceHex,
      'ciphertext': enc.ciphertextHex,
      'tag': enc.tagHex,
    };
  }

  Map<String, dynamic> _decryptEnvelope(
    HanakoChannel channel,
    Map<String, dynamic> envelope,
  ) {
    final channelId = envelope['channel_id'];
    if (channelId is String &&
        channelId.isNotEmpty &&
        channelId != channel.channelId) {
      throw StateError('AI 网关返回了不匹配的加密通道');
    }
    final plaintext = decryptGcm(
      channel.aesKey,
      nonceHex: envelope['nonce'] as String,
      ciphertextHex: envelope['ciphertext'] as String,
      tagHex: envelope['tag'] as String,
    );
    return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
  }

  void _extendChannel(HanakoChannel channel) {
    if (_channel?.channelId != channel.channelId) return;
    _channel = HanakoChannel(
      channelId: channel.channelId,
      aesKey: channel.aesKey,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      allowedModels: channel.allowedModels,
    );
  }

  void _writePublicStoryTransportLog(
    String event, {
    required String operation,
    required String phase,
    required String status,
    required String method,
    required String endpoint,
    required String mode,
    Map<String, dynamic> fields = const {},
  }) {
    publicStoryDiagnosticsLog?.write(
      event,
      layer: 'backend_client',
      fields: {
        'operation': operation,
        'phase': phase,
        'status': status,
        'method': method,
        'endpoint': endpoint,
        'mode': mode,
        ...fields,
      },
    );
  }

  void _writeBackendTransportLog(
    String event, {
    required String operation,
    required String phase,
    required String status,
    required String method,
    required String endpoint,
    Map<String, dynamic> fields = const {},
  }) {
    backendDiagnosticsLog?.write(
      event,
      layer: 'backend_client',
      fields: {
        'operation': operation,
        'phase': phase,
        'status': status,
        'method': method,
        'endpoint': endpoint,
        ...fields,
      },
    );
  }
}

Map<String, dynamic> _chatPayload({
  required String model,
  required List<Map<String, dynamic>> messages,
  required bool stream,
  List<Tool>? tools,
  Object? toolChoice,
  Map<String, dynamic>? extra,
}) {
  final payload = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': stream,
    ...?(_optionalExtra(extra)),
  };
  if (tools != null && tools.isNotEmpty) {
    payload['tools'] = tools.map((tool) => tool.toOpenAI()).toList();
  }
  if (toolChoice != null) {
    payload['tool_choice'] = toolChoice;
  }
  return payload;
}

Map<String, dynamic>? _optionalExtra(Map<String, dynamic>? extra) {
  if (extra == null) return null;
  return {'extra': extra};
}

int? _channelExpiresInMs(HanakoChannel? channel) {
  if (channel == null) return null;
  return channel.expiresAt.difference(DateTime.now()).inMilliseconds;
}

Map<String, dynamic> _messageStats(List<Map<String, dynamic>> messages) {
  var totalChars = 0;
  var systemChars = 0;
  var userChars = 0;
  final roles = <String>[];
  for (final message in messages) {
    final role = message['role']?.toString() ?? '';
    if (role.isNotEmpty) roles.add(role);
    final chars = _contentChars(message['content']);
    totalChars += chars;
    if (role == 'system') {
      systemChars += chars;
    } else if (role == 'user') {
      userChars += chars;
    }
  }
  return {
    'message_count': messages.length,
    'message_roles': roles,
    'message_chars_total': totalChars,
    'system_prompt_chars': systemChars,
    'user_prompt_chars': userChars,
  };
}

int _contentChars(Object? content) {
  if (content == null) return 0;
  if (content is String) return content.length;
  if (content is Iterable) {
    var chars = 0;
    for (final item in content) {
      if (item is Map) {
        chars += _contentChars(item['text'] ?? item['content']);
      } else {
        chars += _contentChars(item);
      }
    }
    return chars;
  }
  return content.toString().length;
}

List<String> _mapKeys(Map<String, dynamic> body) {
  final keys = body.keys.map((key) => key.toString()).toList(growable: false);
  keys.sort();
  return keys;
}

int _choiceCount(Map<String, dynamic> body) {
  final choices = body['choices'];
  return choices is List ? choices.length : 0;
}

Map<String, dynamic> _backendExceptionLogFields(HanakoBackendException error) {
  return {
    'error_type': error.runtimeType.toString(),
    'message': error.message,
    if (error.statusCode != null) 'status_code': error.statusCode,
    if (error.details != null && error.details!.isNotEmpty)
      'details': error.details,
    ..._gatewayErrorLogFieldsFromDetails(error.details),
  };
}

Map<String, dynamic> _objectExceptionLogFields(Object error) {
  if (error is HanakoBackendException) return _backendExceptionLogFields(error);
  return {'error_type': error.runtimeType.toString(), 'message': '$error'};
}

Map<String, dynamic> _gatewayErrorLogFieldsFromDetails(String? details) {
  final body = _serverPlaintextFromDetails(details);
  final parsed = _gatewayErrorBody(body);
  return {
    if (parsed.code.isNotEmpty) 'gateway_error_code': parsed.code,
    if (parsed.message.isNotEmpty) 'gateway_error_message': parsed.message,
  };
}

String _serverPlaintextFromDetails(String? details) {
  if (details == null || details.isEmpty) return '';
  const marker = '服务端返回明文：';
  final index = details.indexOf(marker);
  if (index < 0) return '';
  return details.substring(index + marker.length).trim();
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

class HanakoBackendException implements Exception {
  HanakoBackendException({
    required this.message,
    this.details,
    this.statusCode,
  });

  final String message;
  final String? details;
  final int? statusCode;

  static Future<HanakoBackendException> fromDio(
    DioException error, {
    required String action,
  }) async {
    final response = error.response;
    final status = response?.statusCode;
    final body = await _responseBodyText(response?.data);
    final uri = error.requestOptions.uri;
    final method = error.requestOptions.method;
    final summary = _gatewayErrorSummary(action, status, body);
    final details = StringBuffer()
      ..writeln('$action失败')
      ..writeln('HTTP 状态：${status ?? "无响应"}')
      ..writeln('请求：$method $uri')
      ..writeln('错误类型：${error.type}');
    final statusMessage = response?.statusMessage;
    if (statusMessage != null && statusMessage.trim().isNotEmpty) {
      details.writeln('状态描述：$statusMessage');
    }
    if (body.trim().isNotEmpty) {
      details
        ..writeln()
        ..writeln('服务端返回明文：')
        ..write(body.trim());
    } else if (error.message != null && error.message!.trim().isNotEmpty) {
      details
        ..writeln()
        ..writeln('Dio 信息：')
        ..write(error.message!.trim());
    }
    return HanakoBackendException(
      message: summary,
      details: details.toString(),
      statusCode: status,
    );
  }

  @override
  String toString() => message;
}

String _gatewayErrorSummary(String action, int? status, String body) {
  if (status == null) return '$action失败：无法连接服务器';
  if (status == 400) return '$action失败：AI 网关拒绝了请求参数';
  if (status == 401) return '$action失败：身份或通信通道已失效';
  if (status == 403) return _gatewayForbiddenSummary(action, body);
  if (status == 404) return '$action失败：服务接口不存在或未部署最新版本';
  if (status == 429) return '$action失败：请求过于频繁';
  if (status >= 500) return '$action失败：AI 网关或上游模型服务异常';
  return '$action失败：服务器返回 HTTP $status';
}

String _gatewayForbiddenSummary(String action, String body) {
  final parsed = _gatewayErrorBody(body);
  final code = parsed.code;
  final message = parsed.message;
  final publicStoryAction = action.contains('公开故事');
  if (publicStoryAction && code == 'model_not_allowed') {
    if (message.isNotEmpty) {
      return '$action失败：root 公开故事密钥模型配置不可用：$message';
    }
    return '$action失败：root 公开故事密钥未允许该模型';
  }
  if (publicStoryAction && code == 'access_denied') {
    if (message.isNotEmpty) {
      return '$action失败：root 公开故事密钥 IP 限制拒绝：$message';
    }
    return '$action失败：root 公开故事密钥 IP 限制拒绝了当前请求';
  }
  if (message.isNotEmpty) return '$action失败：$message';
  return '$action失败：当前身份无权使用该模型';
}

({String code, String message}) _gatewayErrorBody(String body) {
  if (body.trim().isEmpty) return (code: '', message: '');
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final rawCode = decoded['error'] ?? decoded['code'];
      final rawMessage = decoded['message'] ?? decoded['msg'];
      return (
        code: rawCode?.toString().trim() ?? '',
        message: rawMessage?.toString().trim() ?? '',
      );
    }
  } catch (_) {
    // 非 JSON 响应保持原有按 HTTP 状态归纳。
  }
  return (code: '', message: '');
}

Future<String> _responseBodyText(Object? data) async {
  if (data == null) return '';
  if (data is ResponseBody) {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in data.stream) {
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
  if (data is Map || data is List) {
    return const JsonEncoder.withIndent('  ').convert(data);
  }
  return data.toString();
}

Iterable<LlmEvent> _extractChatStreamEvents(String decoded) sync* {
  final lines = const LineSplitter().convert(decoded);
  final source = lines.isEmpty ? <String>[decoded] : lines;
  for (final rawLine in source) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith(':') || line.startsWith('event:')) {
      continue;
    }
    if (line.startsWith('data:')) {
      line = line.substring(5).trimLeft();
    }
    if (line.isEmpty || line == '[DONE]') continue;

    try {
      final parsed = jsonDecode(line);
      for (final event in _chatDeltaEvents(parsed)) {
        yield event;
      }
    } catch (_) {
      yield TextDelta(line);
    }
  }
}

Iterable<LlmEvent> _chatDeltaEvents(Object? parsed) sync* {
  if (parsed is! Map) return;
  final streamError = _streamErrorEvent(parsed);
  if (streamError != null) {
    yield streamError;
    return;
  }
  final choices = parsed['choices'];
  if (choices is List && choices.isNotEmpty) {
    for (final choice in choices) {
      if (choice is! Map) continue;
      final delta = choice['delta'];
      if (delta is Map) {
        for (final key in const ['reasoning_content', 'reasoning']) {
          final reasoning = delta[key];
          if (reasoning is String && reasoning.isNotEmpty) {
            yield ThinkingDelta(reasoning);
          }
        }
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield TextDelta(content);
        }
        yield* _toolCallEvents(delta['tool_calls']);
      }
      yield* _toolCallEvents(choice['tool_calls']);
      final message = choice['message'];
      if (message is Map) {
        final reasoning = message['reasoning_content'] ?? message['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield ThinkingDelta(reasoning);
        }
        final content = message['content'];
        if (content is String && content.isNotEmpty) yield TextDelta(content);
        yield* _toolCallEvents(message['tool_calls']);
      }
      final text = choice['text'];
      if (text is String && text.isNotEmpty) yield TextDelta(text);
    }
  }
  final content = parsed['content'];
  if (content is String && content.isNotEmpty) yield TextDelta(content);
}

LlmError? _streamErrorEvent(Map parsed) {
  final rawError = parsed['error'];
  if (rawError == null) return null;

  String message = '发送对话失败：AI 网关或上游模型服务异常';
  Object? code;
  if (rawError is Map) {
    final rawMessage = rawError['message'];
    if (rawMessage is String && rawMessage.trim().isNotEmpty) {
      message = '发送对话失败：${rawMessage.trim()}';
    }
    code = rawError['code'];
  } else if (rawError is String && rawError.trim().isNotEmpty) {
    message = '发送对话失败：${rawError.trim()}';
  }

  final statusCode = _intFromAny(parsed['status_code'] ?? parsed['statusCode']);
  final details = StringBuffer()
    ..writeln('发送对话失败')
    ..writeln('错误来源：AI 网关流式响应');
  if (statusCode != null) {
    details.writeln('HTTP 状态：$statusCode');
  }
  if (code != null && code.toString().trim().isNotEmpty) {
    details.writeln('错误代码：$code');
  }
  details
    ..writeln()
    ..writeln('服务端返回明文：')
    ..write(const JsonEncoder.withIndent('  ').convert(parsed));

  return LlmError(
    message: message,
    statusCode: statusCode,
    details: details.toString(),
  );
}

int? _intFromAny(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

Iterable<LlmEvent> _toolCallEvents(Object? raw) sync* {
  if (raw is! List) return;
  for (var index = 0; index < raw.length; index++) {
    final item = raw[index];
    if (item is! Map) continue;
    final id = (item['id'] ?? item['call_id'] ?? 'tool_call_$index').toString();
    final function = item['function'];
    String? name;
    String? args;
    String? thoughtSignature;
    if (function is Map) {
      final rawName = function['name'];
      if (rawName is String && rawName.isNotEmpty) name = rawName;
      final rawArgs = function['arguments'];
      if (rawArgs is String && rawArgs.isNotEmpty) args = rawArgs;
      final rawThoughtSignature =
          function['thought_signature'] ?? function['thoughtSignature'];
      if (rawThoughtSignature is String && rawThoughtSignature.isNotEmpty) {
        thoughtSignature = rawThoughtSignature;
      }
    } else {
      final rawName = item['name'];
      if (rawName is String && rawName.isNotEmpty) name = rawName;
      final rawArgs = item['arguments'] ?? item['input'];
      if (rawArgs is String && rawArgs.isNotEmpty) {
        args = rawArgs;
      } else if (rawArgs is Map) {
        args = jsonEncode(rawArgs);
      }
      final rawThoughtSignature =
          item['thought_signature'] ?? item['thoughtSignature'];
      if (rawThoughtSignature is String && rawThoughtSignature.isNotEmpty) {
        thoughtSignature = rawThoughtSignature;
      }
    }
    if (name != null) {
      yield ToolCallStart(
        id: id,
        name: name,
        thoughtSignature: thoughtSignature,
      );
    }
    if (args != null) yield ToolCallArgsDelta(id: id, argsJson: args);
  }
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
    required this.cooldownSeconds,
  });

  final String challengeId;
  final String delivery;
  final int expiresIn;
  final int cooldownSeconds;
}

/// 密钥轮换邮箱验证码挑战。
class PubkeyRotationEmailChallenge {
  PubkeyRotationEmailChallenge({
    required this.challengeId,
    required this.delivery,
    required this.expiresIn,
    required this.cooldownSeconds,
  });

  final String challengeId;
  final String delivery;
  final int expiresIn;
  final int cooldownSeconds;
}

/// 密钥轮换成功后的新旧公钥摘要。
class PubkeyRotationResult {
  PubkeyRotationResult({
    required this.userId,
    required this.username,
    required this.tier,
    required this.oldPubkeyHash,
    required this.newPubkeyHash,
    required this.effectiveAt,
    required this.revokedPreviousCount,
  });

  final int userId;
  final String username;
  final String tier;
  final String oldPubkeyHash;
  final String newPubkeyHash;
  final int effectiveAt;
  final int revokedPreviousCount;
}

/// 邮箱 RFA 挑战。
class RecoveryRfaChallenge {
  RecoveryRfaChallenge({
    required this.challengeId,
    required this.delivery,
    required this.expiresIn,
    required this.cooldownSeconds,
  });

  final String challengeId;
  final String delivery;
  final int expiresIn;
  final int cooldownSeconds;
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
