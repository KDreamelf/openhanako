import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/app/protocol_login_service.dart';

void main() {
  test('协议登录解析 challenge 并识别可信 AI 网关 callback', () {
    final challenge = _challenge();
    final request = ProtocolLoginRequest.parse(
      'ph01://login?challenge=$challenge&callback=${Uri.encodeComponent('https://ai.xn--lbtx0e.cn/api/ph01/auth/protocol/complete?nonce=n-1')}',
    );

    expect(request.detail.purpose, 'ph01_ai_gateway_login');
    expect(request.detail.ip, '203.0.113.9');
    expect(request.callbackNonceMatches, isTrue);
    expect(request.isTrustedCallback('https://ai.xn--lbtx0e.cn'), isTrue);
  });

  test('协议登录拒绝 callback nonce 与 challenge 不一致', () {
    final challenge = _challenge();
    expect(
      () => ProtocolLoginRequest.parse(
        'ph01://login?challenge=$challenge&callback=${Uri.encodeComponent('https://ai.xn--lbtx0e.cn/api/ph01/auth/protocol/complete?nonce=evil')}',
      ),
      throwsFormatException,
    );
  });

  test('协议登录识别钓鱼 callback 为不可信', () {
    final challenge = _challenge();
    final request = ProtocolLoginRequest.parse(
      'ph01://login?challenge=$challenge&callback=${Uri.encodeComponent('https://evil.example/api/ph01/auth/protocol/complete?nonce=n-1')}',
    );

    expect(request.isTrustedCallback('https://ai.xn--lbtx0e.cn'), isFalse);
  });
}

String _challenge() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'purpose': 'ph01_ai_gateway_login',
            'nonce': 'n-1',
            'challenge_id': 'n-1',
            'ip': '203.0.113.9',
            'ip_location': 'CN / Hubei',
            'ua': 'Mozilla/5.0',
            'issued_at': now,
            'expires_at': now + 300,
          }),
        ),
      )
      .replaceAll('=', '');
}
