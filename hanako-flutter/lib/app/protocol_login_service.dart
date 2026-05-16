import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../identity/identity.dart';

const ph01AiGatewayLoginPurpose = 'ph01_ai_gateway_login';
const ph01AuthAdminLoginPurpose = 'ph01_auth_admin_login';

typedef ProtocolLoginAuthorizationConfirmer =
    Future<bool> Function(ProtocolLoginRequest request);

class ProtocolLoginService {
  ProtocolLoginService(
    this._engine, {
    this.messengerKey,
    this.onIdentityChanged,
    this.authorizationConfirmer,
  });

  final HanaEngine _engine;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  final VoidCallback? onIdentityChanged;
  final ProtocolLoginAuthorizationConfirmer? authorizationConfirmer;

  static List<String> urlsFromArgs(List<String> args) {
    return args
        .map((arg) => arg.trim())
        .where((arg) => arg.toLowerCase().startsWith('ph01://'))
        .toList(growable: false);
  }

  Future<void> handleArgs(List<String> args) async {
    await handleUrls(urlsFromArgs(args));
  }

  Future<void> handleUrls(List<String> urls) async {
    for (final url in urls) {
      await handleUrl(url);
    }
  }

  Future<void> handleUrl(String rawUrl) async {
    final request = ProtocolLoginRequest.parse(rawUrl);
    final serviceLabel = request.detail.serviceLabel;
    try {
      _notify('收到 $serviceLabel 登录请求，请确认授权');
      final approved = await authorizationConfirmer?.call(request) ?? false;
      if (!approved) {
        _notify('已取消 $serviceLabel 登录授权');
        return;
      }
      if (!request.isTrustedCallback(
        aiBaseUrl: _engine.backendClient.aiBaseUrl,
        authBaseUrl: _engine.backendClient.authBaseUrl,
      )) {
        throw StateError('$serviceLabel 回调地址不受信任：${request.callbackHost}');
      }
      _notify('正在完成 $serviceLabel 登录...');
      final existing = _engine.identityRepository.current;
      final identity = existing ?? await _engine.identityRepository.unlock();
      if (existing == null) {
        onIdentityChanged?.call();
      }
      final userId = await resolveProtocolLoginUserId(_engine, identity);

      await _engine.backendClient.completeProtocolLogin(
        keyPair: identity.keyPair,
        userId: userId,
        challenge: request.challenge,
        callbackUrl: request.callbackUrl,
      );
      _notify('$serviceLabel 登录已授权');
    } catch (e, st) {
      debugPrint('[ph01 protocol login failed] $e\n$st');
      _notify('$serviceLabel 登录失败：$e', isError: true);
    }
  }

  void _notify(String message, {bool isError = false}) {
    final messenger = messengerKey?.currentState;
    if (messenger == null) {
      debugPrint(message);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError
              ? messenger.context.mounted
                    ? Theme.of(messenger.context).colorScheme.error
                    : null
              : null,
          duration: Duration(seconds: isError ? 5 : 2),
        ),
      );
  }
}

Future<int> resolveProtocolLoginUserId(
  HanaEngine engine,
  HanakoIdentity identity,
) async {
  final cfg = engine.config.read();
  final auth = cfg['auth'] is Map ? cfg['auth'] as Map : const {};
  final existing = _parsePositiveInt(auth['user_id']);
  if (existing != null) return existing;

  final username =
      _nullableString(auth['username']) ??
      _nullableString(
        (cfg['user'] is Map ? cfg['user'] as Map : const {})['name'],
      );
  if (username == null) {
    throw StateError('本地配置缺少 auth.user_id，且无法用用户名补全身份');
  }

  final login = await engine.backendClient.login(
    keyPair: identity.keyPair,
    username: username,
  );
  engine.config.writeAt(['auth', 'user_id'], login.userId);
  engine.config.writeAt(['auth', 'username'], login.username);
  engine.config.writeAt(['auth', 'tier'], login.tier);
  engine.config.writeAt(['auth', 'pubkey_hash'], login.pubkeyHash);
  return login.userId;
}

class ProtocolLoginRequest {
  const ProtocolLoginRequest({
    required this.rawUrl,
    required this.challenge,
    required this.callbackUrl,
    required this.callbackUri,
    required this.detail,
  });

  final String rawUrl;
  final String challenge;
  final String callbackUrl;
  final Uri callbackUri;
  final ProtocolLoginChallengeDetail detail;

  String get callbackHost => callbackUri.host;
  String get callbackOrigin =>
      '${callbackUri.scheme}://${callbackUri.authority}';

  bool isTrustedCallback({
    required String aiBaseUrl,
    required String authBaseUrl,
  }) {
    final baseUrl = detail.purpose == ph01AuthAdminLoginPurpose
        ? authBaseUrl
        : aiBaseUrl;
    final expected = Uri.tryParse(baseUrl.trim());
    if (expected == null || expected.host.isEmpty) return false;
    if (callbackUri.path != detail.callbackPath) {
      return false;
    }
    if (!callbackNonceMatches) return false;
    final expectedScheme = expected.scheme.toLowerCase();
    final callbackScheme = callbackUri.scheme.toLowerCase();
    if (expectedScheme != 'https' && expectedScheme != 'http') return false;
    return callbackScheme == expectedScheme &&
        callbackUri.host.toLowerCase() == expected.host.toLowerCase() &&
        _effectivePort(callbackUri) == _effectivePort(expected);
  }

  bool get callbackNonceMatches {
    final nonce = callbackUri.queryParameters['nonce']?.trim();
    final challengeId = callbackUri.queryParameters['challenge_id']?.trim();
    return nonce == detail.nonce || challengeId == detail.nonce;
  }

  static ProtocolLoginRequest parse(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'ph01') {
      throw const FormatException('不是有效的 ph01 协议地址');
    }
    if (uri.host.toLowerCase() != 'login') {
      throw FormatException('不支持的 ph01 协议动作：${uri.host}');
    }
    final challenge = uri.queryParameters['challenge']?.trim();
    final callbackUrl = uri.queryParameters['callback']?.trim();
    if (challenge == null || challenge.isEmpty) {
      throw const FormatException('协议地址缺少 challenge');
    }
    if (callbackUrl == null || callbackUrl.isEmpty) {
      throw const FormatException('协议地址缺少 callback');
    }
    final callback = Uri.tryParse(callbackUrl);
    final callbackScheme = callback?.scheme.toLowerCase();
    if (callback == null ||
        (callbackScheme != 'https' && callbackScheme != 'http')) {
      throw const FormatException('callback URL 必须是 http 或 https');
    }

    final detail = ProtocolLoginChallengeDetail.decode(challenge);
    if (detail.version != 1) {
      throw FormatException('不支持的 PH01 登录挑战版本：${detail.version}');
    }
    if (!detail.isSupportedPurpose) {
      throw FormatException('不支持的 PH01 登录用途：${detail.purpose}');
    }
    if (detail.nonce.isEmpty) {
      throw const FormatException('PH01 登录挑战缺少 nonce');
    }
    if (detail.isExpired(DateTime.now())) {
      throw const FormatException('PH01 登录挑战已过期');
    }
    final request = ProtocolLoginRequest(
      rawUrl: rawUrl,
      challenge: challenge,
      callbackUrl: callbackUrl,
      callbackUri: callback,
      detail: detail,
    );
    if (!request.callbackNonceMatches) {
      throw const FormatException('callback nonce 与登录挑战不匹配');
    }
    return request;
  }
}

class ProtocolLoginChallengeDetail {
  const ProtocolLoginChallengeDetail({
    required this.version,
    required this.purpose,
    required this.nonce,
    required this.challengeId,
    required this.ip,
    required this.ipLocation,
    required this.userAgent,
    required this.issuedAt,
    required this.expiresAt,
  });

  final int version;
  final String purpose;
  final String nonce;
  final String challengeId;
  final String ip;
  final String ipLocation;
  final String userAgent;
  final int issuedAt;
  final int expiresAt;

  bool get isSupportedPurpose =>
      purpose == ph01AiGatewayLoginPurpose ||
      purpose == ph01AuthAdminLoginPurpose;

  String get serviceLabel => switch (purpose) {
    ph01AuthAdminLoginPurpose => '认证中心管理端',
    ph01AiGatewayLoginPurpose => 'AI 网关',
    _ => 'PH01 服务',
  };

  String get callbackPath => switch (purpose) {
    ph01AuthAdminLoginPurpose => '/admin/session/protocol/complete',
    _ => '/api/ph01/auth/protocol/complete',
  };

  bool isExpired(DateTime now) =>
      expiresAt <= now.millisecondsSinceEpoch ~/ 1000;

  DateTime get issuedAtTime =>
      DateTime.fromMillisecondsSinceEpoch(issuedAt * 1000);

  DateTime get expiresAtTime =>
      DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);

  static ProtocolLoginChallengeDetail decode(String encoded) {
    try {
      final normalized = base64Url.normalize(encoded.trim());
      final raw = utf8.decode(base64Url.decode(normalized));
      final json = jsonDecode(raw);
      if (json is! Map) {
        throw const FormatException('challenge JSON 不是对象');
      }
      return ProtocolLoginChallengeDetail.fromJson(json);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('无法解析 PH01 登录挑战：$e');
    }
  }

  factory ProtocolLoginChallengeDetail.fromJson(Map<dynamic, dynamic> json) {
    return ProtocolLoginChallengeDetail(
      version: _intValue(json['version']),
      purpose: _stringValue(json['purpose']),
      nonce: _stringValue(json['nonce']),
      challengeId: _stringValue(json['challenge_id']),
      ip: _stringValue(json['ip']),
      ipLocation: _stringValue(json['ip_location']),
      userAgent: _stringValue(json['ua']),
      issuedAt: _intValue(json['issued_at']),
      expiresAt: _intValue(json['expires_at']),
    );
  }
}

typedef AiGatewayLoginChallengeDetail = ProtocolLoginChallengeDetail;

int _intValue(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v.trim()) ?? 0,
  _ => 0,
};

String _stringValue(Object? value) {
  if (value == null) return '';
  return '$value'.trim();
}

int? _parsePositiveInt(Object? value) {
  final parsed = switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v.trim()),
    _ => null,
  };
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

String? _nullableString(Object? value) {
  if (value is! String && value is! num) return null;
  final trimmed = '$value'.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme.toLowerCase()) {
    'https' => 443,
    'http' => 80,
    _ => null,
  };
}
