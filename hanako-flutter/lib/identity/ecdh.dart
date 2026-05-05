// lib/identity/ecdh.dart
//
// 子体侧 ECDH 密钥协商 + AES-256-GCM 会话加解密。
// 与 ph01-backend/internal/crypto/ecdh.go 完全对齐。
//
// 协议参见 ph01-backend/docs/protocol-spec.md §6。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/hkdf.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';

import 'keypair.dart';

/// HKDF salt（必须与 ph01-backend 一致）。
const String kHanakoHkdfSalt = 'hanako-aes-v1';

/// AES key 长度（AES-256）。
const int kAesKeyLength = 32;

/// AES-GCM nonce 长度。
const int kAesNonceLength = 12;

/// AES-GCM tag 长度。
const int kAesTagLength = 16;

/// 临时 ECDH 密钥（一次握手用）。
class EphemeralKey {
  EphemeralKey._({required this.privateKey, required this.publicKey});

  final ECPrivateKey privateKey;
  final ECPublicKey publicKey;

  /// 生成新的临时密钥对。
  factory EphemeralKey.generate() {
    final rng = FortunaRandom()..seed(KeyParameter(_secureSeed(32)));
    final params = ECKeyGeneratorParameters(_curve);
    final gen = ECKeyGenerator()..init(ParametersWithRandom(params, rng));
    final pair = gen.generateKeyPair();
    return EphemeralKey._(
      privateKey: pair.privateKey as ECPrivateKey,
      publicKey: pair.publicKey as ECPublicKey,
    );
  }

  /// 65 字节非压缩公钥的 hex 表示（与服务端约定一致）。
  String get publicKeyHex {
    final q = publicKey.Q!;
    final x = _bigIntTo32(q.x!.toBigInteger()!);
    final y = _bigIntTo32(q.y!.toBigInteger()!);
    final out = Uint8List(65);
    out[0] = 0x04;
    out.setRange(1, 33, x);
    out.setRange(33, 65, y);
    return _hex(out);
  }
}

/// 用本端临时私钥与对端临时/长期公钥（65 字节非压缩 hex）做 ECDH 协商，
/// 再用 HKDF-SHA256 派生 32 字节 AES key。
Uint8List deriveSharedAesKey(ECPrivateKey local, String remotePubkeyHex) {
  final remoteRaw = _unhex(remotePubkeyHex);
  if (remoteRaw.length != 65 || remoteRaw[0] != 0x04) {
    throw ArgumentError('remote pubkey 必须是 65 字节非压缩格式');
  }
  final x = _bytesToBigInt(remoteRaw.sublist(1, 33));
  final y = _bytesToBigInt(remoteRaw.sublist(33, 65));
  final remoteQ = _curve.curve.createPoint(x, y);

  // ECDH = priv * remoteQ
  final shared = (remoteQ * local.d!)!;
  final sharedX = shared.x!.toBigInteger()!;
  final sharedBytes = _bigIntTo32(sharedX);

  // HKDF-SHA256(shared, salt="hanako-aes-v1", info="") → 32 字节
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(
      sharedBytes,
      kAesKeyLength,
      Uint8List.fromList(utf8.encode(kHanakoHkdfSalt)),
      Uint8List(0),
    ));
  final aesKey = Uint8List(kAesKeyLength);
  hkdf.deriveKey(null, 0, aesKey, 0);
  return aesKey;
}

/// AES-256-GCM 加密。返回 (nonceHex, ciphertextHex, tagHex)。
({String nonceHex, String ciphertextHex, String tagHex}) encryptGcm(
  Uint8List aesKey,
  Uint8List plaintext,
) {
  final nonce = _secureSeed(kAesNonceLength);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(aesKey), kAesTagLength * 8, nonce, Uint8List(0)),
    );
  final combined = cipher.process(plaintext);
  final ct = combined.sublist(0, combined.length - kAesTagLength);
  final tag = combined.sublist(combined.length - kAesTagLength);
  return (
    nonceHex: _hex(nonce),
    ciphertextHex: _hex(ct),
    tagHex: _hex(tag),
  );
}

/// AES-256-GCM 解密。失败抛 [InvalidCipherTextException]。
Uint8List decryptGcm(
  Uint8List aesKey, {
  required String nonceHex,
  required String ciphertextHex,
  required String tagHex,
}) {
  final nonce = _unhex(nonceHex);
  final ct = _unhex(ciphertextHex);
  final tag = _unhex(tagHex);
  if (nonce.length != kAesNonceLength) {
    throw ArgumentError('nonce 必须是 $kAesNonceLength 字节');
  }
  if (tag.length != kAesTagLength) {
    throw ArgumentError('tag 必须是 $kAesTagLength 字节');
  }
  final combined = Uint8List(ct.length + tag.length)
    ..setRange(0, ct.length, ct)
    ..setRange(ct.length, ct.length + tag.length, tag);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(KeyParameter(aesKey), kAesTagLength * 8, nonce, Uint8List(0)),
    );
  return cipher.process(combined);
}

// ---- internals ----

final ECDomainParameters _curve = ECCurve_secp256k1();

Uint8List _secureSeed(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

Uint8List _bigIntTo32(BigInt n) {
  if (n.isNegative) throw ArgumentError('big int negative');
  var hex = n.toRadixString(16);
  if (hex.length > 64) throw ArgumentError('big int > 32 bytes');
  if (hex.length.isOdd) hex = '0$hex';
  hex = hex.padLeft(64, '0');
  return _unhex(hex);
}

BigInt _bytesToBigInt(Uint8List bytes) {
  return BigInt.parse(_hex(bytes), radix: 16);
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

Uint8List _unhex(String s) {
  if (s.length.isOdd) throw ArgumentError('hex 长度必须是偶数');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// 让 keypair.dart 的私钥能直接做 ECDH（取 d 字段即可，dart:HanakoKeyPair 已暴露）。
extension HanakoKeyPairEcdh on HanakoKeyPair {
  /// 用本对长期私钥与对端公钥协商 AES key。
  Uint8List deriveSharedAesKeyWith(String remotePubkeyHex) {
    return deriveSharedAesKey(privateKey, remotePubkeyHex);
  }
}
