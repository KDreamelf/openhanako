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
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart' as crypto;

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
    try {
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
    } on DioException catch (e) {
      throw await HanakoBackendException.fromDio(e, action: '注册账号');
    }
  }

  /// 注册邮箱验证：用户名可用后，先向邮箱发送验证码。
  Future<RegistrationEmailChallenge> startRegistrationEmail({
    required String username,
    required String email,
  }) async {
    try {
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
    } on DioException catch (e) {
      throw await HanakoBackendException.fromDio(e, action: '发送注册邮箱验证码');
    }
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

  /// 用户 PoW：不影响注册/登录，只在用户主动做“真人/反黑产验证”时调用。
  Future<UserPowChallenge> startUserPow({required String pubkeyHash}) async {
    final startedAt = DateTime.now();
    const endpoint = '/api/v1/auth/pow/challenge';
    final normalized = pubkeyHash.trim();
    _writeBackendTransportLog(
      'transport_request',
      operation: 'user_pow_challenge',
      phase: 'request',
      status: 'start',
      method: 'POST',
      endpoint: endpoint,
      fields: {'pubkey_hash': _shortLogHash(normalized)},
    );
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl$endpoint'),
        data: {'pubkey_hash': normalized},
        options: Options(contentType: Headers.jsonContentType),
      );
      final challenge = UserPowChallenge.fromJson(resp.data!);
      _writeBackendTransportLog(
        'transport_success',
        operation: 'user_pow_challenge',
        phase: 'response',
        status: 'success',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'status_code': resp.statusCode,
          'challenge_id': challenge.challengeId,
          'difficulty_bits': challenge.difficultyBits,
          'memory_kib': challenge.memoryKiB,
          'round_count': challenge.roundCount,
          'expires_at': challenge.expiresAt,
        },
      );
      return challenge;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(e, action: '发起工作量证明');
      _writeBackendTransportLog(
        'transport_failure',
        operation: 'user_pow_challenge',
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

  Future<UserPowStatus> completeUserPow({
    required HanakoKeyPair keyPair,
    UserPowChallenge? challenge,
  }) async {
    return completeUserPowWithProgress(keyPair: keyPair, challenge: challenge);
  }

  Future<UserPowStatus> completeUserPowWithProgress({
    required HanakoKeyPair keyPair,
    UserPowChallenge? challenge,
    void Function(UserPowProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const UserPowProgress(
        stage: UserPowProgressStage.challenge,
        message: '正在向认证中心领取账号工作量证明挑战',
        completed: 0,
        total: 1,
        fraction: 0.04,
      ),
    );
    final activeChallenge =
        challenge ?? await startUserPow(pubkeyHash: keyPair.publicKeyHash);
    onProgress?.call(
      UserPowProgress(
        stage: UserPowProgressStage.compute,
        message:
            '正在本机分阶段计算 ${activeChallenge.algorithm}，难度 ${activeChallenge.difficultyBits}bit',
        completed: 0,
        total: 1,
        fraction: 0.12,
      ),
    );
    final solutionNonce = await solveUserPowInBackground(
      activeChallenge,
      onProgress: (progress) {
        onProgress?.call(
          progress.copyWith(fraction: 0.12 + progress.fraction * 0.72),
        );
      },
    );
    onProgress?.call(
      const UserPowProgress(
        stage: UserPowProgressStage.submit,
        message: '计算完成，正在签名并提交证明',
        completed: 1,
        total: 1,
        fraction: 0.88,
      ),
    );
    final req = signRequest(
      keyPair: keyPair,
      businessPayload: {
        'challenge_id': activeChallenge.challengeId,
        'pubkey_hash': activeChallenge.pubkeyHash,
        'solution_nonce': solutionNonce,
      },
    );
    final submitStartedAt = DateTime.now();
    const endpoint = '/api/v1/auth/pow/verify';
    _writeBackendTransportLog(
      'transport_request',
      operation: 'user_pow_verify',
      phase: 'request',
      status: 'start',
      method: 'POST',
      endpoint: endpoint,
      fields: {
        'challenge_id': activeChallenge.challengeId,
        'pubkey_hash': _shortLogHash(activeChallenge.pubkeyHash),
        'difficulty_bits': activeChallenge.difficultyBits,
        'memory_kib': activeChallenge.memoryKiB,
        'round_count': activeChallenge.roundCount,
        'solution_nonce_chars': solutionNonce.length,
      },
    );
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl$endpoint'),
        data: req.toJson(),
        options: Options(contentType: Headers.jsonContentType),
      );
      final status = UserPowStatus.fromJson(resp.data!);
      _writeBackendTransportLog(
        'transport_success',
        operation: 'user_pow_verify',
        phase: 'response',
        status: 'success',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now()
              .difference(submitStartedAt)
              .inMilliseconds,
          'status_code': resp.statusCode,
          'pubkey_hash': _shortLogHash(status.pubkeyHash),
          'pow_verified': status.powVerified,
          'pow_score': status.powScore,
          'pow_algorithm': status.powAlgorithm,
          'pow_verified_at': status.powVerifiedAt,
        },
      );
      onProgress?.call(
        const UserPowProgress(
          stage: UserPowProgressStage.done,
          message: '证明已写入认证中心',
          completed: 1,
          total: 1,
          fraction: 1,
        ),
      );
      return status;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(e, action: '提交工作量证明');
      _writeBackendTransportLog(
        'transport_failure',
        operation: 'user_pow_verify',
        phase: 'response',
        status: 'failure',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now()
              .difference(submitStartedAt)
              .inMilliseconds,
          'challenge_id': activeChallenge.challengeId,
          ..._backendExceptionLogFields(error),
        },
      );
      throw error;
    }
  }

  Future<UserPowStatus?> fetchUserPowStatus({
    required String pubkeyHash,
  }) async {
    final normalized = pubkeyHash.trim();
    if (normalized.isEmpty) return null;
    final startedAt = DateTime.now();
    const endpoint = '/api/v1/auth/pubkeys/status';
    _writeBackendTransportLog(
      'transport_request',
      operation: 'user_pow_status',
      phase: 'request',
      status: 'start',
      method: 'POST',
      endpoint: endpoint,
      fields: {'pubkey_hash': _shortLogHash(normalized)},
    );
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl$endpoint'),
        data: {
          'pubkey_hashes': [normalized],
        },
        options: Options(contentType: Headers.jsonContentType),
      );
      final items = resp.data?['items'];
      if (items is! List || items.isEmpty) {
        _writeBackendTransportLog(
          'transport_success',
          operation: 'user_pow_status',
          phase: 'response',
          status: 'success',
          method: 'POST',
          endpoint: endpoint,
          fields: {
            'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
            'status_code': resp.statusCode,
            'item_count': items is List ? items.length : 0,
          },
        );
        return null;
      }
      final first = items.first;
      if (first is! Map) {
        _writeBackendTransportLog(
          'transport_success',
          operation: 'user_pow_status',
          phase: 'response',
          status: 'success',
          method: 'POST',
          endpoint: endpoint,
          fields: {
            'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
            'status_code': resp.statusCode,
            'item_count': items.length,
            'first_item_type': first.runtimeType.toString(),
          },
        );
        return null;
      }
      final status = UserPowStatus.fromJson(Map<String, dynamic>.from(first));
      _writeBackendTransportLog(
        'transport_success',
        operation: 'user_pow_status',
        phase: 'response',
        status: 'success',
        method: 'POST',
        endpoint: endpoint,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'status_code': resp.statusCode,
          'item_count': items.length,
          'pubkey_hash': _shortLogHash(status.pubkeyHash),
          'valid': status.valid,
          'pow_verified': status.powVerified,
          'pow_score': status.powScore,
          'pow_algorithm': status.powAlgorithm,
          'pow_verified_at': status.powVerifiedAt,
        },
      );
      return status;
    } on DioException catch (e) {
      final error = await HanakoBackendException.fromDio(
        e,
        action: '查询工作量证明状态',
      );
      _writeBackendTransportLog(
        'transport_failure',
        operation: 'user_pow_status',
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

  Future<DelegatedPowChallenge> fetchDelegatedPowChallenge({
    required String challengeId,
  }) async {
    final normalized = challengeId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(challengeId, 'challengeId', 'empty');
    }
    final endpoint = '/api/v1/auth/pow/delegated/challenge/$normalized';
    try {
      final resp = await _dio.getUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl$endpoint'),
        options: Options(contentType: Headers.jsonContentType),
      );
      return DelegatedPowChallenge.fromJson(resp.data!);
    } on DioException catch (e) {
      throw await HanakoBackendException.fromDio(e, action: '领取委托工作量证明挑战');
    }
  }

  Future<DelegatedPowStatus> completeDelegatedPowWithProgress({
    required HanakoKeyPair keyPair,
    required String challengeId,
    DelegatedPowChallenge? challenge,
    void Function(UserPowProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const UserPowProgress(
        stage: UserPowProgressStage.challenge,
        message: '正在向认证中心领取委托工作量证明挑战',
        completed: 0,
        total: 1,
        fraction: 0.04,
      ),
    );
    final activeChallenge =
        challenge ?? await fetchDelegatedPowChallenge(challengeId: challengeId);
    onProgress?.call(
      UserPowProgress(
        stage: UserPowProgressStage.compute,
        message: '正在执行静默工作量证明，难度 ${activeChallenge.difficultyBits}bit',
        completed: 0,
        total: 1,
        fraction: 0.12,
      ),
    );
    final solutionNonce = await solveUserPowInBackground(
      activeChallenge.toUserPowChallenge(),
      onProgress: (progress) {
        onProgress?.call(
          progress.copyWith(fraction: 0.12 + progress.fraction * 0.72),
        );
      },
    );
    onProgress?.call(
      const UserPowProgress(
        stage: UserPowProgressStage.submit,
        message: '证明计算完成，正在写入认证中心缓存',
        completed: 1,
        total: 1,
        fraction: 0.9,
      ),
    );
    final req = signRequest(
      keyPair: keyPair,
      businessPayload: {
        'challenge_id': activeChallenge.challengeId,
        'purpose': activeChallenge.purpose,
        'subject_hash': activeChallenge.subjectHash,
        'pubkey_hash': activeChallenge.pubkeyHash,
        'solution_nonce': solutionNonce,
      },
    );
    final Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$authBaseUrl/api/v1/auth/pow/delegated/verify'),
        data: req.toJson(),
        options: Options(contentType: Headers.jsonContentType),
      );
    } on DioException catch (e) {
      throw await HanakoBackendException.fromDio(e, action: '提交委托工作量证明');
    }
    final status = DelegatedPowStatus.fromJson(resp.data!);
    onProgress?.call(
      const UserPowProgress(
        stage: UserPowProgressStage.done,
        message: '委托工作量证明已完成',
        completed: 1,
        total: 1,
        fraction: 1,
      ),
    );
    return status;
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
        gatewayRevokeWarning: body['gateway_revoke_warning'] as String?,
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

  // ============== ph01 protocol login ==============

  /// 生成 PH01 协议登录授权结果。
  ///
  /// 返回值用于两条路径：
  ///   - 登录码：把 JSON 字符串复制给网页粘贴框
  ///   - 协议登录：POST 到 `ph01://login` 给出的 callback
  ///
  /// 签名内容就是原始 base64url challenge 字符串。
  Map<String, dynamic> buildProtocolLoginAuthorization({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
  }) {
    if (userId <= 0) {
      throw ArgumentError.value(userId, 'userId', 'must be positive');
    }
    final nonce = _decodeProtocolChallengeNonce(challenge);
    final signature = keyPair.sign(Uint8List.fromList(utf8.encode(challenge)));
    return {
      'user_id': userId,
      'nonce': nonce,
      'signature': _hexEncode(signature),
    };
  }

  Map<String, dynamic> buildAiGatewayLoginAuthorization({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
  }) {
    return buildProtocolLoginAuthorization(
      keyPair: keyPair,
      userId: userId,
      challenge: challenge,
    );
  }

  /// 生成网页登录码输入框可直接粘贴的 JSON 字符串。
  String buildProtocolLoginCode({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
  }) {
    return jsonEncode(
      buildProtocolLoginAuthorization(
        keyPair: keyPair,
        userId: userId,
        challenge: challenge,
      ),
    );
  }

  String buildAiGatewayLoginCode({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
  }) {
    return buildProtocolLoginCode(
      keyPair: keyPair,
      userId: userId,
      challenge: challenge,
    );
  }

  /// 协议登录授权后，把签名结果回传给 callback。
  Future<void> completeProtocolLogin({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
    required String callbackUrl,
  }) async {
    final body = buildProtocolLoginAuthorization(
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
      throw StateError('PH01 protocol login failed: $message');
    }
  }

  Future<void> completeAiGatewayProtocolLogin({
    required HanakoKeyPair keyPair,
    required int userId,
    required String challenge,
    required String callbackUrl,
  }) async {
    return completeProtocolLogin(
      keyPair: keyPair,
      userId: userId,
      challenge: challenge,
      callbackUrl: callbackUrl,
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
    final decoder = _ChatStreamEventDecoder();
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
          for (final event in decoder.parse(utf8.decode(pt))) {
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

String _shortLogHash(String value) {
  final text = value.trim();
  if (text.length <= 16) return text;
  return '${text.substring(0, 16)}...';
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

String _decodeProtocolChallengeNonce(String challenge) {
  final raw = base64Url.decode(base64Url.normalize(challenge));
  final decoded = jsonDecode(utf8.decode(raw));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException(
      'PH01 protocol challenge must be a JSON object',
    );
  }
  final nonce = decoded['nonce'];
  if (nonce is! String || nonce.trim().isEmpty) {
    throw const FormatException('PH01 protocol challenge nonce is missing');
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
    final serviceLabel = _backendServiceLabel(uri);
    final summary = _gatewayErrorSummary(action, status, body, serviceLabel);
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

String _gatewayErrorSummary(
  String action,
  int? status,
  String body,
  String serviceLabel,
) {
  if (status == null) return '$action失败：无法连接$serviceLabel';
  final parsed = _gatewayErrorBody(body);
  switch (parsed.code) {
    case 'username_taken':
      return '$action失败：用户名已被占用，请更换用户名。';
    case 'email_taken':
      return '$action失败：该邮箱已绑定其他账号，请更换邮箱或登录原账号。';
    case 'email_verification_required':
      return '$action失败：邮箱验证码缺失、过期或与本次注册不匹配。';
    case 'rfa_code_invalid':
      return '$action失败：验证码错误，请重新输入。';
    case 'rfa_code_expired':
      return '$action失败：验证码已过期，请重新获取。';
    case 'invalid_signature':
    case 'timestamp_expired':
    case 'nonce_replayed':
      if (action.contains('注册')) {
        return '$action失败：注册请求签名校验未通过，请重新生成账号后再试。';
      }
      return '$action失败：身份或通信通道已失效';
    case 'invalid_payload':
      if (serviceLabel == '认证中心' && parsed.message.isNotEmpty) {
        return '$action失败：${parsed.message}';
      }
      break;
    case 'pubkey_not_found':
      return '$action失败：认证中心没有找到当前公钥，请重新登录或完成账号绑定';
    case 'user_disabled':
      return '$action失败：账号已被禁用';
  }
  if (parsed.message.isNotEmpty && action.contains('注册')) {
    return '$action失败：${parsed.message}';
  }
  if (status == 400) return '$action失败：$serviceLabel拒绝了请求参数';
  if (status == 401) return '$action失败：身份或通信通道已失效';
  if (status == 403) {
    return _gatewayForbiddenSummary(action, body, serviceLabel);
  }
  if (status == 404) return '$action失败：$serviceLabel接口不存在或未部署最新版本';
  if (status == 429) return '$action失败：请求过于频繁';
  if (status >= 500) return '$action失败：$serviceLabel异常';
  return '$action失败：服务器返回 HTTP $status';
}

String _gatewayForbiddenSummary(
  String action,
  String body,
  String serviceLabel,
) {
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
  if (serviceLabel == '认证中心') return '$action失败：认证中心拒绝访问';
  return '$action失败：当前身份无权使用该模型';
}

String _backendServiceLabel(Uri uri) {
  final path = uri.path;
  if (path.startsWith('/api/v1/auth/') || path.startsWith('/admin/')) {
    return '认证中心';
  }
  if (path.startsWith('/api/v1/channel/') ||
      path.startsWith('/api/v1/llm/') ||
      path.startsWith('/api/v1/models') ||
      path.startsWith('/api/v1/public/story/')) {
    return 'AI 网关';
  }

  final host = uri.host.toLowerCase();
  if (host.startsWith('auth.') || host.contains('auth')) {
    return '认证中心';
  }
  if (host.startsWith('ai.') || host.contains('gateway')) {
    return 'AI 网关';
  }
  return '服务器';
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

class _ChatStreamEventDecoder {
  final _toolCalls = _ToolCallDeltaState();

  Iterable<LlmEvent> parse(String decoded) sync* {
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
        for (final event in _chatDeltaEvents(parsed, _toolCalls)) {
          yield event;
        }
      } catch (_) {
        yield TextDelta(line);
      }
    }
  }
}

Iterable<LlmEvent> _chatDeltaEvents(
  Object? parsed,
  _ToolCallDeltaState toolCalls,
) sync* {
  if (parsed is! Map) return;
  final streamError = _streamErrorEvent(parsed);
  if (streamError != null) {
    yield streamError;
    return;
  }
  final choices = parsed['choices'];
  if (choices is List && choices.isNotEmpty) {
    for (var choiceIndex = 0; choiceIndex < choices.length; choiceIndex++) {
      final choice = choices[choiceIndex];
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
        yield* toolCalls.events(delta['tool_calls'], choiceIndex: choiceIndex);
      }
      yield* toolCalls.events(choice['tool_calls'], choiceIndex: choiceIndex);
      final message = choice['message'];
      if (message is Map) {
        final reasoning = message['reasoning_content'] ?? message['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield ThinkingDelta(reasoning);
        }
        final content = message['content'];
        if (content is String && content.isNotEmpty) yield TextDelta(content);
        yield* toolCalls.events(
          message['tool_calls'],
          choiceIndex: choiceIndex,
        );
      }
      final text = choice['text'];
      if (text is String && text.isNotEmpty) yield TextDelta(text);
    }
  }
  final content = parsed['content'];
  if (content is String && content.isNotEmpty) yield TextDelta(content);

  // OpenAI 标准 usage 字段（通常在最后一个 chunk 附带一次）。
  final usage = parsed['usage'];
  if (usage is Map) {
    final prompt = _intFromAny(usage['prompt_tokens']) ?? 0;
    final completion = _intFromAny(usage['completion_tokens']) ?? 0;
    final total = _intFromAny(usage['total_tokens']) ?? (prompt + completion);
    final cached = _intFromAny(
      usage['prompt_tokens_details'] is Map
          ? (usage['prompt_tokens_details'] as Map)['cached_tokens']
          : usage['cached_tokens'],
    );
    if (total > 0) {
      yield TokenUsage(
        promptTokens: prompt,
        completionTokens: completion,
        totalTokens: total,
        cachedTokens: cached,
      );
    }
  }
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

class _ToolCallDeltaState {
  final _pending = <String, _PendingToolCallDelta>{};

  Iterable<LlmEvent> events(Object? raw, {required int choiceIndex}) sync* {
    if (raw is! List) return;
    for (var position = 0; position < raw.length; position++) {
      final item = raw[position];
      if (item is! Map) continue;

      final toolIndex = _intFromAny(item['index']) ?? position;
      final key = '$choiceIndex:$toolIndex';
      final call = _pending.putIfAbsent(
        key,
        () => _PendingToolCallDelta(id: 'tool_call_${choiceIndex}_$toolIndex'),
      );

      final rawId =
          _nonEmptyString(item['id']) ?? _nonEmptyString(item['call_id']);
      if (rawId != null) call.id = rawId;

      final parts = _toolCallParts(item);
      if (parts.name != null) call.name = parts.name!;
      if (parts.thoughtSignature != null) {
        call.thoughtSignature = parts.thoughtSignature;
      }

      final name = call.name;
      if (!call.started && name != null && name.trim().isNotEmpty) {
        call.started = true;
        yield ToolCallStart(
          id: call.id,
          name: name,
          thoughtSignature: call.thoughtSignature,
        );
      }

      final argsJson = parts.argumentsJson;
      if (argsJson != null) {
        yield ToolCallArgsDelta(id: call.id, argsJson: argsJson);
      }
    }
  }
}

class _PendingToolCallDelta {
  _PendingToolCallDelta({required this.id});

  String id;
  String? name;
  String? thoughtSignature;
  bool started = false;
}

({String? name, String? argumentsJson, String? thoughtSignature})
_toolCallParts(Map item) {
  final function = item['function'];
  if (function is Map) {
    return (
      name: _nonEmptyString(function['name']),
      argumentsJson: _argumentsJson(function['arguments']),
      thoughtSignature:
          _nonEmptyString(function['thought_signature']) ??
          _nonEmptyString(function['thoughtSignature']),
    );
  }

  return (
    name: _nonEmptyString(item['name']),
    argumentsJson: _argumentsJson(item['arguments'] ?? item['input']),
    thoughtSignature:
        _nonEmptyString(item['thought_signature']) ??
        _nonEmptyString(item['thoughtSignature']),
  );
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

String? _argumentsJson(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is Map || value is List) return jsonEncode(value);
  return null;
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

class UserPowChallenge {
  UserPowChallenge({
    required this.challengeId,
    required this.pubkeyHash,
    required this.algorithm,
    required this.difficultyBits,
    required this.memoryKiB,
    required this.roundCount,
    required this.seed,
    required this.expiresAt,
  });

  factory UserPowChallenge.fromJson(Map<String, dynamic> json) {
    return UserPowChallenge(
      challengeId: json['challenge_id'] as String,
      pubkeyHash: json['pubkey_hash'] as String,
      algorithm: json['algorithm'] as String,
      difficultyBits: (json['difficulty_bits'] as num).toInt(),
      memoryKiB: (json['memory_kib'] as num).toInt(),
      roundCount: (json['round_count'] as num).toInt(),
      seed: json['seed'] as String,
      expiresAt: (json['expires_at'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'challenge_id': challengeId,
      'pubkey_hash': pubkeyHash,
      'algorithm': algorithm,
      'difficulty_bits': difficultyBits,
      'memory_kib': memoryKiB,
      'round_count': roundCount,
      'seed': seed,
      'expires_at': expiresAt,
    };
  }

  final String challengeId;
  final String pubkeyHash;
  final String algorithm;
  final int difficultyBits;
  final int memoryKiB;
  final int roundCount;
  final String seed;
  final int expiresAt;
}

class UserPowStatus {
  UserPowStatus({
    required this.valid,
    required this.userId,
    required this.username,
    required this.tier,
    required this.pubkeyHash,
    required this.powVerified,
    required this.powAlgorithm,
    required this.powScore,
    required this.powVerifiedAt,
  });

  factory UserPowStatus.fromJson(Map<String, dynamic> json) {
    return UserPowStatus(
      valid: json['valid'] as bool? ?? false,
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
      tier: json['tier']?.toString() ?? '',
      pubkeyHash: json['pubkey_hash']?.toString() ?? '',
      powVerified: json['pow_verified'] as bool? ?? false,
      powAlgorithm: json['pow_algorithm']?.toString() ?? '',
      powScore: (json['pow_score'] as num?)?.toInt() ?? 0,
      powVerifiedAt: (json['pow_verified_at'] as num?)?.toInt() ?? 0,
    );
  }

  final bool valid;
  final int userId;
  final String username;
  final String tier;
  final String pubkeyHash;
  final bool powVerified;
  final String powAlgorithm;
  final int powScore;
  final int powVerifiedAt;
}

class DelegatedPowChallenge {
  DelegatedPowChallenge({
    required this.challengeId,
    required this.purpose,
    required this.subjectHash,
    required this.pubkeyHash,
    required this.algorithm,
    required this.difficultyBits,
    required this.memoryKiB,
    required this.roundCount,
    required this.seed,
    required this.expiresAt,
  });

  factory DelegatedPowChallenge.fromJson(Map<String, dynamic> json) {
    return DelegatedPowChallenge(
      challengeId: json['challenge_id'] as String,
      purpose: json['purpose'] as String,
      subjectHash: json['subject_hash'] as String,
      pubkeyHash: json['pubkey_hash']?.toString() ?? '',
      algorithm: json['algorithm'] as String,
      difficultyBits: (json['difficulty_bits'] as num).toInt(),
      memoryKiB: (json['memory_kib'] as num).toInt(),
      roundCount: (json['round_count'] as num).toInt(),
      seed: json['seed'] as String,
      expiresAt: (json['expires_at'] as num).toInt(),
    );
  }

  UserPowChallenge toUserPowChallenge() {
    return UserPowChallenge(
      challengeId: challengeId,
      pubkeyHash: subjectHash,
      algorithm: algorithm,
      difficultyBits: difficultyBits,
      memoryKiB: memoryKiB,
      roundCount: roundCount,
      seed: seed,
      expiresAt: expiresAt,
    );
  }

  final String challengeId;
  final String purpose;
  final String subjectHash;
  final String pubkeyHash;
  final String algorithm;
  final int difficultyBits;
  final int memoryKiB;
  final int roundCount;
  final String seed;
  final int expiresAt;
}

class DelegatedPowStatus {
  DelegatedPowStatus({
    required this.challengeId,
    required this.purpose,
    required this.subjectHash,
    required this.pubkeyHash,
    required this.verified,
    required this.algorithm,
    required this.score,
    required this.verifiedAt,
    required this.expiresAt,
  });

  factory DelegatedPowStatus.fromJson(Map<String, dynamic> json) {
    return DelegatedPowStatus(
      challengeId: json['challenge_id']?.toString() ?? '',
      purpose: json['purpose']?.toString() ?? '',
      subjectHash: json['subject_hash']?.toString() ?? '',
      pubkeyHash: json['pubkey_hash']?.toString() ?? '',
      verified: json['verified'] as bool? ?? false,
      algorithm: json['algorithm']?.toString() ?? '',
      score: (json['score'] as num?)?.toInt() ?? 0,
      verifiedAt: (json['verified_at'] as num?)?.toInt() ?? 0,
      expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String challengeId;
  final String purpose;
  final String subjectHash;
  final String pubkeyHash;
  final bool verified;
  final String algorithm;
  final int score;
  final int verifiedAt;
  final int expiresAt;
}

abstract final class UserPowProgressStage {
  static const challenge = 'challenge';
  static const compute = 'compute';
  static const submit = 'submit';
  static const done = 'done';
}

class UserPowProgress {
  const UserPowProgress({
    required this.stage,
    required this.message,
    required this.completed,
    required this.total,
    required this.fraction,
  });

  UserPowProgress copyWith({
    String? stage,
    String? message,
    int? completed,
    int? total,
    double? fraction,
  }) {
    return UserPowProgress(
      stage: stage ?? this.stage,
      message: message ?? this.message,
      completed: completed ?? this.completed,
      total: total ?? this.total,
      fraction: fraction ?? this.fraction,
    );
  }

  final String stage;
  final String message;
  final int completed;
  final int total;
  final double fraction;
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
    this.gatewayRevokeWarning,
  });

  final int userId;
  final String username;
  final String tier;
  final String oldPubkeyHash;
  final String newPubkeyHash;
  final int effectiveAt;
  final int revokedPreviousCount;
  final String? gatewayRevokeWarning;
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

String solveUserPow(UserPowChallenge challenge, {int maxAttempts = 1 << 24}) {
  for (var i = 0; i < maxAttempts; i++) {
    final nonce = i.toRadixString(16);
    if (_verifyUserPowSolution(challenge, nonce)) return nonce;
  }
  throw StateError('工作量证明计算未在限制次数内完成');
}

Future<String> solveUserPowInBackground(
  UserPowChallenge challenge, {
  int maxAttempts = 1 << 24,
  int? workerCount,
  void Function(UserPowProgress progress)? onProgress,
}) async {
  final receivePort = ReceivePort();
  final isolates = <Isolate>[];
  final completer = Completer<String>();
  final normalizedWorkerCount = _normalizeUserPowWorkerCount(
    challenge,
    workerCount,
  );
  final unitsPerAttempt = _userPowAttemptProgressUnits(challenge);
  final expectedProgressWindow = _estimatedUserPowProgressTotal(
    challenge,
    maxAttempts,
  );
  final maxProgressUnits = maxAttempts * unitsPerAttempt;
  final workerCompleted = List<int>.filled(normalizedWorkerCount, 0);
  var finishedWorkers = 0;

  void emitProgress() {
    final completed = workerCompleted.fold<int>(0, (sum, value) => sum + value);
    var total = completed + expectedProgressWindow;
    if (maxProgressUnits > 0 && total > maxProgressUnits) {
      total = maxProgressUnits;
    }
    if (total < expectedProgressWindow) {
      total = expectedProgressWindow;
    }
    if (total < completed) {
      total = completed;
    }
    final rawFraction = total <= 0 ? 0 : completed / total;
    final taskLabel = normalizedWorkerCount > 1
        ? '（$normalizedWorkerCount 个计算任务）'
        : '';
    onProgress?.call(
      UserPowProgress(
        stage: UserPowProgressStage.compute,
        message: '正在本机计算工作量证明$taskLabel，请保持窗口开启',
        completed: completed,
        total: total,
        fraction: rawFraction.clamp(0, 0.98).toDouble(),
      ),
    );
  }

  late final StreamSubscription<dynamic> sub;
  sub = receivePort.listen((message) {
    if (message is! Map) return;
    switch (message['type']) {
      case 'progress':
        final worker = (message['worker'] as num?)?.toInt() ?? 0;
        if (worker < 0 || worker >= workerCompleted.length) return;
        final completed = (message['completed'] as num?)?.toInt() ?? 0;
        if (completed > workerCompleted[worker]) {
          workerCompleted[worker] = completed;
          emitProgress();
        }
        break;
      case 'done':
        if (!completer.isCompleted) {
          completer.complete(message['nonce']?.toString() ?? '');
        }
        break;
      case 'finished':
        finishedWorkers++;
        if (finishedWorkers >= normalizedWorkerCount &&
            !completer.isCompleted) {
          completer.completeError(StateError('工作量证明计算未在限制次数内完成'));
        }
        break;
      case 'error':
        if (!completer.isCompleted) {
          completer.completeError(
            StateError(message['message']?.toString() ?? '工作量证明计算失败'),
          );
        }
        break;
    }
  });

  try {
    for (var worker = 0; worker < normalizedWorkerCount; worker++) {
      isolates.add(
        await Isolate.spawn(_solveUserPowIsolateMain, {
          'send_port': receivePort.sendPort,
          'challenge': challenge.toJson(),
          'max_attempts': maxAttempts,
          'worker': worker,
          'worker_count': normalizedWorkerCount,
        }, debugName: 'hanako-user-pow-$worker'),
      );
    }
    return await completer.future;
  } finally {
    await sub.cancel();
    receivePort.close();
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

void _solveUserPowIsolateMain(Map<String, dynamic> args) {
  final sendPort = args['send_port'] as SendPort;
  try {
    final challenge = UserPowChallenge.fromJson(
      Map<String, dynamic>.from(args['challenge'] as Map),
    );
    final maxAttempts = (args['max_attempts'] as num?)?.toInt() ?? 1 << 24;
    final worker = (args['worker'] as num?)?.toInt() ?? 0;
    final workerCount = (args['worker_count'] as num?)?.toInt() ?? 1;
    final unitsPerAttempt = _userPowAttemptProgressUnits(challenge);
    final workspace = Uint64List(_userPowWordCount(challenge.memoryKiB));
    var completedUnits = 0;
    void sendProgress(int attemptUnit) {
      sendPort.send({
        'type': 'progress',
        'worker': worker,
        'completed': completedUnits + attemptUnit,
      });
    }

    for (var i = worker; i < maxAttempts; i += workerCount) {
      sendProgress(0);
      final nonce = i.toRadixString(16);
      final digest = _userPowDigest(
        seed: challenge.seed,
        pubkeyHash: challenge.pubkeyHash,
        nonce: nonce,
        memoryKiB: challenge.memoryKiB,
        roundCount: challenge.roundCount,
        workspace: workspace,
        onProgress: (completed, _) => sendProgress(completed),
      );
      if (_hasLeadingZeroBits(digest, challenge.difficultyBits)) {
        sendProgress(unitsPerAttempt);
        sendPort.send({'type': 'done', 'nonce': nonce});
        return;
      }
      completedUnits += unitsPerAttempt;
    }
    sendPort.send({'type': 'finished', 'worker': worker});
  } catch (e) {
    sendPort.send({'type': 'error', 'message': '$e'});
  }
}

bool _verifyUserPowSolution(UserPowChallenge challenge, String nonce) {
  final digest = _userPowDigest(
    seed: challenge.seed,
    pubkeyHash: challenge.pubkeyHash,
    nonce: nonce,
    memoryKiB: challenge.memoryKiB,
    roundCount: challenge.roundCount,
  );
  return _hasLeadingZeroBits(digest, challenge.difficultyBits);
}

int _estimatedUserPowProgressTotal(
  UserPowChallenge challenge,
  int maxAttempts,
) {
  final unitsPerAttempt = _userPowAttemptProgressUnits(challenge);
  final normalizedBits = challenge.difficultyBits.clamp(1, 28).toInt();
  final expectedAttempts = 1 << normalizedBits;
  final expectedUnits = expectedAttempts * unitsPerAttempt;
  final maxUnits = maxAttempts * unitsPerAttempt;
  return expectedUnits < maxUnits ? expectedUnits : maxUnits;
}

int _userPowAttemptProgressUnits(UserPowChallenge challenge) {
  return _normalizeUserPowRoundCount(challenge.roundCount) *
      _userPowUnitsPerStage;
}

int _normalizeUserPowWorkerCount(UserPowChallenge challenge, int? requested) {
  if (requested != null) {
    return requested.clamp(1, 64).toInt();
  }
  final cores = Platform.numberOfProcessors;
  if (cores <= 2) return 1;
  final cpuBound = math.min(cores - 1, 4);
  final memoryKiB = _normalizeUserPowMemoryKiB(challenge.memoryKiB);
  const memoryBudgetKiB = 2 * 1024 * 1024;
  final memoryBound = math.max(1, memoryBudgetKiB ~/ memoryKiB);
  return math.max(1, math.min(cpuBound, memoryBound));
}

Uint8List _userPowDigest({
  required String seed,
  required String pubkeyHash,
  required String nonce,
  required int memoryKiB,
  required int roundCount,
  Uint64List? workspace,
  void Function(int completed, int total)? onProgress,
}) {
  final normalizedRoundCount = _normalizeUserPowRoundCount(roundCount);
  final wordCount = _userPowWordCount(memoryKiB);
  final activeWorkspace = workspace?.length == wordCount
      ? workspace!
      : Uint64List(wordCount);
  final base = Uint8List.fromList(
    crypto.sha256
        .convert(
          utf8.encode(
            [
              'ph01.memory_pow.v1',
              seed.trim(),
              pubkeyHash.trim().toLowerCase(),
              nonce.trim(),
            ].join('\n'),
          ),
        )
        .bytes,
  );
  final acc = <int>[
    _readUint64LE(base, 0),
    _readUint64LE(base, 8),
    _readUint64LE(base, 16),
    _readUint64LE(base, 24),
  ];
  final totalUnits = normalizedRoundCount * _userPowUnitsPerStage;
  void report(int stage, int phase) {
    onProgress?.call(stage * _userPowUnitsPerStage + phase, totalUnits);
  }

  for (var round = 0; round < normalizedRoundCount; round++) {
    final stageSeed = _userPowStageSeed(base, acc, round);
    var state = _u64(_readUint64LE(stageSeed, 0) ^ (round + 1));
    if (state == 0) {
      state = 0x9e3779b97f4a7c15;
    }
    final step = _readUint64LE(stageSeed, 8) | 1;
    var nextFillUnit = 1;
    var nextFillAt = _userPowProgressBoundary(
      activeWorkspace.length,
      nextFillUnit,
      _userPowFillProgressUnits,
    );
    for (var i = 0; i < activeWorkspace.length; i++) {
      state = _userPowNextState(state + step);
      final word = _userPowSplitMix64(state ^ i ^ acc[i & 3]);
      activeWorkspace[i] = word;
      acc[i & 3] = _userPowSplitMix64(acc[i & 3] + word + i + round);
      if (i + 1 >= nextFillAt) {
        report(round, nextFillUnit);
        nextFillUnit++;
        nextFillAt = _userPowProgressBoundary(
          activeWorkspace.length,
          nextFillUnit,
          _userPowFillProgressUnits,
        );
      }
    }

    final probeCount = _userPowProbeCount(activeWorkspace.length);
    var nextProbeUnit = 1;
    var nextProbeAt = _userPowProgressBoundary(
      probeCount,
      nextProbeUnit,
      _userPowProbeProgressUnits,
    );
    for (var i = 0; i < probeCount; i++) {
      final lane = i & 3;
      final idx =
          (_userPowSplitMix64(acc[lane] + i * 0x9e3779b97f4a7c15 + round) %
          activeWorkspace.length);
      final word = activeWorkspace[idx];
      acc[lane] = _userPowSplitMix64(acc[(lane + 1) & 3] ^ word ^ idx ^ i);
      if (i + 1 >= nextProbeAt) {
        report(round, _userPowFillProgressUnits + nextProbeUnit);
        nextProbeUnit++;
        nextProbeAt = _userPowProgressBoundary(
          probeCount,
          nextProbeUnit,
          _userPowProbeProgressUnits,
        );
      }
    }

    final edge = activeWorkspace[(round * 0x9e3779b9) % activeWorkspace.length];
    acc[round & 3] = _userPowSplitMix64(
      acc[round & 3] ^ edge ^ probeCount ^ round,
    );
    report(round, _userPowUnitsPerStage);
  }
  return _userPowDigestAccumulators(acc);
}

const int _userPowWordBytes = 8;
const int _userPowMinMemoryKiB = 16;
const int _userPowMaxMemoryKiB = 1024 * 1024;
const int _userPowMaxRounds = 64;
const int _userPowFillProgressUnits = 12;
const int _userPowProbeProgressUnits = 3;
const int _userPowFoldProgressUnits = 1;
const int _userPowUnitsPerStage =
    _userPowFillProgressUnits +
    _userPowProbeProgressUnits +
    _userPowFoldProgressUnits;

int _normalizeUserPowMemoryKiB(int memoryKiB) {
  if (memoryKiB < _userPowMinMemoryKiB) return _userPowMinMemoryKiB;
  if (memoryKiB > _userPowMaxMemoryKiB) return _userPowMaxMemoryKiB;
  return memoryKiB;
}

int _normalizeUserPowRoundCount(int roundCount) {
  if (roundCount < 1) return 1;
  if (roundCount > _userPowMaxRounds) return _userPowMaxRounds;
  return roundCount;
}

int _userPowWordCount(int memoryKiB) {
  final normalizedMemoryKiB = _normalizeUserPowMemoryKiB(memoryKiB);
  return ((normalizedMemoryKiB * 1024) ~/ _userPowWordBytes)
      .clamp(1, 1 << 31)
      .toInt();
}

int _userPowProbeCount(int wordCount) {
  final probes = wordCount ~/ 16;
  return probes < 1024 ? 1024 : probes;
}

int _userPowProgressBoundary(int total, int unit, int units) {
  if (unit >= units) return total;
  final boundary = ((total * unit) / units).ceil();
  return boundary < 1 ? 1 : boundary;
}

int _readUint64LE(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes).getUint64(offset, Endian.little);
}

Uint8List _userPowStageSeed(Uint8List base, List<int> acc, int stage) {
  final bytes = Uint8List(72);
  bytes.setRange(0, 32, base);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < acc.length; i++) {
    view.setUint64(32 + i * 8, _u64(acc[i]), Endian.little);
  }
  view.setUint64(64, stage, Endian.little);
  return Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
}

Uint8List _userPowDigestAccumulators(List<int> acc) {
  final bytes = Uint8List(32);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < 4; i++) {
    view.setUint64(i * 8, _u64(acc[i]), Endian.little);
  }
  return Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
}

int _userPowNextState(int value) {
  var x = _u64(value);
  x = _u64(x ^ (x >>> 12));
  x = _u64(x ^ (x << 25));
  x = _u64(x ^ (x >>> 27));
  return _u64(x * 2685821657736338717);
}

int _userPowSplitMix64(int value) {
  var z = _u64(value + 0x9e3779b97f4a7c15);
  z = _u64((z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9);
  z = _u64((z ^ (z >>> 27)) * 0x94d049bb133111eb);
  return _u64(z ^ (z >>> 31));
}

int _u64(int value) => value.toUnsigned(64);

bool _hasLeadingZeroBits(Uint8List data, int bits) {
  final normalizedBits = bits.clamp(4, 28);
  final fullBytes = normalizedBits ~/ 8;
  final restBits = normalizedBits % 8;
  if (data.length < fullBytes) return false;
  for (var i = 0; i < fullBytes; i++) {
    if (data[i] != 0) return false;
  }
  if (restBits == 0) return true;
  if (data.length <= fullBytes) return false;
  final mask = 0xff << (8 - restBits);
  return data[fullBytes] & mask == 0;
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
