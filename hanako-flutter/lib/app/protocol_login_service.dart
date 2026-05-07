import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../identity/identity.dart';

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
    try {
      _notify('收到 AI 网关登录请求，请确认授权');
      final approved = await authorizationConfirmer?.call(request) ?? false;
      if (!approved) {
        _notify('已取消 AI 网关登录授权');
        return;
      }
      if (!request.isTrustedCallback(_engine.backendClient.aiBaseUrl)) {
        throw StateError('AI 网关回调地址不受信任：${request.callbackHost}');
      }
      _notify('正在完成 AI 网关登录...');
      final existing = _engine.identityRepository.current;
      final identity = existing ?? await _engine.identityRepository.unlock();
      if (existing == null) {
        onIdentityChanged?.call();
      }
      final userId = await _resolveUserId(identity);

      await _engine.backendClient.completeAiGatewayProtocolLogin(
        keyPair: identity.keyPair,
        userId: userId,
        challenge: request.challenge,
        callbackUrl: request.callbackUrl,
      );
      _notify('AI 网关登录已授权');
    } catch (e, st) {
      debugPrint('[ph01 protocol login failed] $e\n$st');
      _notify('AI 网关登录失败：$e', isError: true);
    }
  }

  Future<int> _resolveUserId(HanakoIdentity identity) async {
    final cfg = _engine.config.read();
    final auth = cfg['auth'] is Map ? cfg['auth'] as Map : const {};
    final existing = _parsePositiveInt(auth['user_id']);
    if (existing != null) return existing;

    final username =
        _stringValue(auth['username']) ??
        _stringValue(
          (cfg['user'] is Map ? cfg['user'] as Map : const {})['name'],
        );
    if (username == null) {
      throw StateError('本地配置缺少 auth.user_id，且无法用用户名补全身份');
    }

    final login = await _engine.backendClient.login(
      keyPair: identity.keyPair,
      username: username,
    );
    _engine.config.writeAt(['auth', 'user_id'], login.userId);
    _engine.config.writeAt(['auth', 'username'], login.username);
    _engine.config.writeAt(['auth', 'tier'], login.tier);
    _engine.config.writeAt(['auth', 'pubkey_hash'], login.pubkeyHash);
    return login.userId;
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

  String? _stringValue(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
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
  final AiGatewayLoginChallengeDetail detail;

  String get callbackHost => callbackUri.host;
  String get callbackOrigin => '${callbackUri.scheme}://${callbackUri.host}';

  bool isTrustedCallback(String aiBaseUrl) {
    final expected = Uri.tryParse(aiBaseUrl.trim());
    if (expected == null || expected.host.isEmpty) return false;
    if (callbackUri.path != '/api/ph01/auth/protocol/complete') {
      return false;
    }
    if (!callbackNonceMatches) return false;
    if (_isLoopbackHost(callbackUri.host)) {
      return callbackUri.scheme == 'http' || callbackUri.scheme == 'https';
    }
    return callbackUri.scheme == 'https' &&
        callbackUri.host.toLowerCase() == expected.host.toLowerCase();
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

    final detail = AiGatewayLoginChallengeDetail.decode(challenge);
    if (detail.version != 1) {
      throw FormatException('不支持的 AI 网关登录挑战版本：${detail.version}');
    }
    if (detail.purpose != 'ph01_ai_gateway_login') {
      throw FormatException('不支持的 AI 网关登录用途：${detail.purpose}');
    }
    if (detail.nonce.isEmpty) {
      throw const FormatException('AI 网关登录挑战缺少 nonce');
    }
    if (detail.isExpired(DateTime.now())) {
      throw const FormatException('AI 网关登录挑战已过期');
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

class AiGatewayLoginChallengeDetail {
  const AiGatewayLoginChallengeDetail({
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

  bool isExpired(DateTime now) =>
      expiresAt <= now.millisecondsSinceEpoch ~/ 1000;

  DateTime get issuedAtTime =>
      DateTime.fromMillisecondsSinceEpoch(issuedAt * 1000);

  DateTime get expiresAtTime =>
      DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);

  static AiGatewayLoginChallengeDetail decode(String encoded) {
    try {
      final normalized = base64Url.normalize(encoded.trim());
      final raw = utf8.decode(base64Url.decode(normalized));
      final json = jsonDecode(raw);
      if (json is! Map) {
        throw const FormatException('challenge JSON 不是对象');
      }
      return AiGatewayLoginChallengeDetail.fromJson(json);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('无法解析 AI 网关登录挑战：$e');
    }
  }

  factory AiGatewayLoginChallengeDetail.fromJson(Map<dynamic, dynamic> json) {
    return AiGatewayLoginChallengeDetail(
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

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}
