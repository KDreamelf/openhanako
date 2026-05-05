// lib/identity/signed_request.dart
//
// 把业务请求体（JSON 字符串）包装成 ph01-backend 能验证的 SignedRequest。
//
// 与 protocol-spec.md §3.1 / §3.2 对齐：
//   待签名内容 = payload + "\n" + pubkey + "\n" + timestamp + "\n" + nonce
//   SHA-256 摘要 → ECDSA secp256k1 签名 → 64 字节 r‖s hex

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'keypair.dart';

class SignedRequest {
  SignedRequest({
    required this.payload,
    required this.pubkey,
    required this.signature,
    required this.timestamp,
    required this.nonce,
  });

  /// 原始业务请求体的 JSON 字符串（不是嵌套对象）。
  final String payload;
  final String pubkey;
  final String signature;
  final int timestamp;
  final String nonce;

  Map<String, dynamic> toJson() => {
        'payload': payload,
        'pubkey': pubkey,
        'signature': signature,
        'timestamp': timestamp,
        'nonce': nonce,
      };

  String toJsonString() => jsonEncode(toJson());
}

/// 用 [keyPair] 的私钥对 [businessPayload] 做签名包装。
///
/// [businessPayload] 是业务请求体的 dart 对象，会先 jsonEncode 成字符串。
SignedRequest signRequest({
  required HanakoKeyPair keyPair,
  required Object businessPayload,
}) {
  final payloadStr = jsonEncode(businessPayload);
  final pubHex = keyPair.publicKeyHex;
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final nonce = _randomNonceHex(8);

  final signed = '$payloadStr\n$pubHex\n$ts\n$nonce';
  final sigBytes = keyPair.sign(Uint8List.fromList(utf8.encode(signed)));
  final sigHex = _hex(sigBytes);

  return SignedRequest(
    payload: payloadStr,
    pubkey: pubHex,
    signature: sigHex,
    timestamp: ts,
    nonce: nonce,
  );
}

String _randomNonceHex(int bytes) {
  final rng = Random.secure();
  final out = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    out[i] = rng.nextInt(256);
  }
  return _hex(out);
}

String _hex(Uint8List b) {
  const c = '0123456789abcdef';
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(c[(x >> 4) & 0x0f]);
    sb.write(c[x & 0x0f]);
  }
  return sb.toString();
}
