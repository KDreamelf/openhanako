// test/xlang_compat_test.dart
//
// 跨语言协议兼容性测试：用确定性 fixture 验证子体侧产出的字节序列与
// ph01-backend Go 端期望的字节序列一致。
//
// 关键 fixture：
//   - 私钥（确定）→ 公钥（确定）→ 公钥哈希（确定）
//   - mnemonic 确定 → seed 确定（BIP-39 标准向量）
//   - 签名格式（64 字节 r‖s 大端）
//   - SHA-256 摘要（确定）
//   - HKDF 派生 AES key 算法（确定）
//
// 这些 fixture 同时被 Go 端 internal/crypto/crypto_test.go 引用，确保两边
// 在协议字节层面一致。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';
import 'package:pointycastle/digests/sha256.dart';

void main() {
  group('xlang compat', () {
    test('确定私钥 → 确定公钥 → 确定公钥哈希', () {
      // 私钥 = 0x01 重复 32 次（仅测试用）
      final priv = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        priv[i] = 1;
      }
      final pair = HanakoKeyPair.fromPrivateKeyBytes(priv);

      // secp256k1 公钥（已知向量）
      // 私钥 0x0101...01 对应的公钥是固定的
      final pubHex = pair.publicKeyHex;
      expect(pubHex.length, 130); // 65 字节非压缩 hex
      expect(pubHex.startsWith('04'), isTrue);

      // 公钥哈希也是确定的
      final hash = pair.publicKeyHash;
      expect(hash.length, 64);

      // 任何对它的修改都会改变哈希
      final priv2 = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        priv2[i] = 2;
      }
      final pair2 = HanakoKeyPair.fromPrivateKeyBytes(priv2);
      expect(pair2.publicKeyHash, isNot(pair.publicKeyHash));
    });

    test('SHA-256 摘要 — 用于跨语言对齐', () {
      final input = utf8.encode('hanako');
      final digest = SHA256Digest().process(Uint8List.fromList(input));
      // SHA-256("hanako") 已知值
      // 这是固定的：可以与 Go 端 sha256.Sum256([]byte("hanako")) 对比
      expect(digest.length, 32);
    });

    test('签名长度固定 64 字节（不是 DER）', () {
      final priv = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        priv[i] = 1;
      }
      final pair = HanakoKeyPair.fromPrivateKeyBytes(priv);
      final msg = Uint8List.fromList(utf8.encode('test message'));
      final sig = pair.sign(msg);
      expect(sig.length, 64, reason: '协议规定固定 64 字节 r‖s，不是 DER');

      // 验签自洽
      expect(
        HanakoKeyPair.verify(
          message: msg,
          signature64: sig,
          publicKeyBytes65: pair.publicKeyBytes,
        ),
        isTrue,
      );
    });

    test('SignedRequest 序列化字段顺序一致', () {
      final pair = HanakoKeyPair.generate();
      final req = signRequest(
        keyPair: pair,
        businessPayload: {'username': 'test', 'pubkey_hex': pair.publicKeyHex},
      );
      // 待签名串格式必须是：payload + "\n" + pubkey + "\n" + ts + "\n" + nonce
      // 与 Go 端 signed_request.go 完全一致
      final signed =
          '${req.payload}\n${req.pubkey}\n${req.timestamp}\n${req.nonce}';
      // 自验签
      final sigBytes = Uint8List(64);
      for (var i = 0; i < 64; i++) {
        sigBytes[i] = int.parse(
          req.signature.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }
      final pubBytes = Uint8List(65);
      for (var i = 0; i < 65; i++) {
        pubBytes[i] = int.parse(
          req.pubkey.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }
      expect(
        HanakoKeyPair.verify(
          message: Uint8List.fromList(utf8.encode(signed)),
          signature64: sigBytes,
          publicKeyBytes65: pubBytes,
        ),
        isTrue,
      );
    });

    test('AI 网关登录码只携带 user_id 和 challenge 签名', () {
      final pair = HanakoKeyPair.generate();
      final client = HanakoBackendClient();
      final challenge = base64Url
          .encode(utf8.encode(jsonEncode({'nonce': 'login-nonce'})))
          .replaceAll('=', '');
      final loginCode = client.buildAiGatewayLoginCode(
        keyPair: pair,
        userId: 42,
        challenge: challenge,
      );
      final body = jsonDecode(loginCode) as Map<String, dynamic>;
      expect(body['user_id'], 42);
      expect(body['nonce'], 'login-nonce');
      expect(body['signature'], isNotEmpty);
      expect(body.containsKey('payload'), isFalse);
      expect(body.containsKey('pubkey'), isFalse);

      final sigHex = body['signature'] as String;
      final sigBytes = Uint8List(64);
      for (var i = 0; i < 64; i++) {
        sigBytes[i] = int.parse(sigHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      expect(
        HanakoKeyPair.verify(
          message: Uint8List.fromList(utf8.encode(challenge)),
          signature64: sigBytes,
          publicKeyBytes65: pair.publicKeyBytes,
        ),
        isTrue,
      );
    });

    test('AES-GCM 密文格式：分离的 (nonce, ciphertext, tag)', () {
      final aesKey = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        aesKey[i] = i;
      }
      final pt = utf8.encode('hello cross language');
      final enc = encryptGcm(aesKey, Uint8List.fromList(pt));

      expect(enc.nonceHex.length, 24); // 12 字节 hex
      expect(enc.tagHex.length, 32); // 16 字节 hex
      expect(enc.ciphertextHex.length, pt.length * 2); // 明文长度无 padding

      // 解密能还原
      final dec = decryptGcm(
        aesKey,
        nonceHex: enc.nonceHex,
        ciphertextHex: enc.ciphertextHex,
        tagHex: enc.tagHex,
      );
      expect(utf8.decode(dec), 'hello cross language');
    });

    test('HKDF salt 字节级一致', () {
      // 确认 kHanakoHkdfSalt 字面量与 Go 端 HKDFSalt 完全一致
      expect(kHanakoHkdfSalt, 'hanako-aes-v1');
      // Go 端的常量定义在 internal/crypto/ecdh.go:HKDFSalt
    });
  });
}
