// test/ecdh_test.dart
//
// 与 ph01-backend/internal/crypto/crypto_test.go 对齐的 Dart 端测试。
// 验证子体侧 ECDH + AES-GCM 的自洽性。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';

void main() {
  group('ecdh', () {
    test('双方派生应得到同一 AES key', () {
      final a = EphemeralKey.generate();
      final b = EphemeralKey.generate();

      final keyA = deriveSharedAesKey(a.privateKey, b.publicKeyHex);
      final keyB = deriveSharedAesKey(b.privateKey, a.publicKeyHex);

      expect(keyA.length, kAesKeyLength);
      expect(keyA, keyB, reason: 'ECDH + HKDF 必须双向一致');
    });

    test('AES-GCM 加密 / 解密自洽', () {
      final pair = HanakoKeyPair.generate();
      final a = EphemeralKey.generate();
      final aesKey = deriveSharedAesKey(a.privateKey, pair.publicKeyHex);

      final pt = utf8.encode('hello hanako encrypted');
      final enc = encryptGcm(aesKey, Uint8List.fromList(pt));

      final dec = decryptGcm(
        aesKey,
        nonceHex: enc.nonceHex,
        ciphertextHex: enc.ciphertextHex,
        tagHex: enc.tagHex,
      );
      expect(utf8.decode(dec), 'hello hanako encrypted');
    });

    test('错误密钥解密应失败', () {
      final a = EphemeralKey.generate();
      final aesKey = deriveSharedAesKey(
        a.privateKey,
        EphemeralKey.generate().publicKeyHex,
      );
      final pt = utf8.encode('secret');
      final enc = encryptGcm(aesKey, Uint8List.fromList(pt));

      final wrongKey = Uint8List(kAesKeyLength); // 全零
      expect(
        () => decryptGcm(
          wrongKey,
          nonceHex: enc.nonceHex,
          ciphertextHex: enc.ciphertextHex,
          tagHex: enc.tagHex,
        ),
        throwsA(anything),
      );
    });
  });

  group('signed_request', () {
    test('签名包装：自洽签名内容格式', () {
      final pair = HanakoKeyPair.generate();
      final req = signRequest(
        keyPair: pair,
        businessPayload: {'username': 'alice', 'pubkey_hex': pair.publicKeyHex},
      );

      // payload 应该是 JSON 字符串（不是 dart 对象）
      expect(req.payload, isA<String>());
      expect(jsonDecode(req.payload), isA<Map>());

      // pubkey 等于 keyPair 的公钥
      expect(req.pubkey, pair.publicKeyHex);

      // 签名长度 = 64 字节 hex = 128 字符
      expect(req.signature.length, 128);

      // 时间戳合理（最近 5 秒内）
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(req.timestamp, inInclusiveRange(now - 5, now + 5));

      // nonce 8 字节 hex = 16 字符
      expect(req.nonce.length, 16);
    });

    test('签名内容是可验签的（自验签）', () {
      final pair = HanakoKeyPair.generate();
      final req = signRequest(
        keyPair: pair,
        businessPayload: {'username': 'bob'},
      );
      final signed = '${req.payload}\n${req.pubkey}\n${req.timestamp}\n${req.nonce}';
      final ok = HanakoKeyPair.verify(
        message: Uint8List.fromList(utf8.encode(signed)),
        signature64: _hexDecode(req.signature),
        publicKeyBytes65: _hexDecode(req.pubkey),
      );
      expect(ok, isTrue);
    });
  });
}

Uint8List _hexDecode(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
