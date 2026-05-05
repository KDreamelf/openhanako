// lib/identity/keypair.dart
//
// ECDSA secp256k1 密钥对：子体身份的核心载体。
//
// 设计原则：
//   1. 私钥永远只在本地（明文不落盘，落盘必须经 SecureKeystore 加密）。
//   2. 公钥可自由上传、广播、附在签名上——它不是秘密。
//   3. 签名 / 验签使用 ECDSA-SHA256，与 MVP §3.5 / §10.5 约定一致。
//
// 选 secp256k1 而非 ed25519 的原因：
//   - MVP §3.5 明确写"ECDSA secp256k1 或 ed25519"，主脑端实现倾向 secp256k1；
//   - pointycastle 对 secp256k1 支持成熟，无需引入新依赖；
//   - 以太坊 / 比特币体系大量复用，未来如果要做链上凭证可平滑过渡。
//
// 注：本文件只做底层密钥对原语，不涉及"如何派生""如何持久化"。
//     派生逻辑见 mnemonic.dart，存储逻辑见 secure_keystore.dart。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// 一对 ECDSA secp256k1 密钥。
///
/// 内部使用大整数表达；对外通过 [privateKeyHex] / [publicKeyHex] 暴露
/// 紧凑十六进制串，便于序列化、传输、与服务端比对。
class HanakoKeyPair {
  HanakoKeyPair._({
    required this.privateKey,
    required this.publicKey,
  });

  /// 完整随机生成（注册流程的入口）。使用 Fortuna PRNG 自动播种。
  factory HanakoKeyPair.generate() {
    final rng = FortunaRandom()
      ..seed(KeyParameter(_secureSeed(32)));
    final params = ECKeyGeneratorParameters(_curve);
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(params, rng));
    final pair = generator.generateKeyPair();
    return HanakoKeyPair._(
      privateKey: pair.privateKey as ECPrivateKey,
      publicKey: pair.publicKey as ECPublicKey,
    );
  }

  /// 从已知 32 字节私钥还原（mnemonic 派生 / 密钥库读取后用）。
  factory HanakoKeyPair.fromPrivateKeyBytes(Uint8List bytes) {
    if (bytes.length != 32) {
      throw ArgumentError('secp256k1 私钥必须为 32 字节，收到 ${bytes.length}');
    }
    final d = _bytesToBigInt(bytes);
    final priv = ECPrivateKey(d, _curve);
    final q = _curve.G * d;
    if (q == null) {
      throw StateError('从私钥还原公钥失败：曲线点为空');
    }
    final pub = ECPublicKey(q, _curve);
    return HanakoKeyPair._(privateKey: priv, publicKey: pub);
  }

  final ECPrivateKey privateKey;
  final ECPublicKey publicKey;

  /// 私钥的 32 字节大端表示。
  Uint8List get privateKeyBytes {
    final d = privateKey.d;
    if (d == null) throw StateError('私钥 d 字段为空');
    return _bigIntToBytes(d, 32);
  }

  /// 公钥的非压缩 65 字节表示（前缀 0x04 + X(32) + Y(32)）。
  ///
  /// 选非压缩是因为 MVP §10.4 提到"接收方需要公钥本体做密码学验签"，
  /// 非压缩格式无须二次解压、解析跨语言一致。
  Uint8List get publicKeyBytes {
    final q = publicKey.Q;
    if (q == null) throw StateError('公钥 Q 字段为空');
    final x = _bigIntToBytes(q.x!.toBigInteger()!, 32);
    final y = _bigIntToBytes(q.y!.toBigInteger()!, 32);
    final out = Uint8List(65);
    out[0] = 0x04;
    out.setRange(1, 33, x);
    out.setRange(33, 65, y);
    return out;
  }

  String get privateKeyHex => _hexEncode(privateKeyBytes);
  String get publicKeyHex => _hexEncode(publicKeyBytes);

  /// 公钥哈希（SHA-256），用于公钥服务批量查询时的索引。
  String get publicKeyHash {
    final hash = SHA256Digest().process(publicKeyBytes);
    return _hexEncode(hash);
  }

  /// 用本对私钥对 [message] 做 ECDSA-SHA256 签名。
  ///
  /// 返回 64 字节固定长度签名（r 32 字节 + s 32 字节，大端）。
  /// 不采用 DER 编码——固定长度便于跨语言解析与定长存储。
  Uint8List sign(Uint8List message) {
    final signer = ECDSASigner(SHA256Digest())
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(privateKey),
          FortunaRandom()..seed(KeyParameter(_secureSeed(32))),
        ),
      );
    final sig = signer.generateSignature(message) as ECSignature;
    final r = _bigIntToBytes(sig.r, 32);
    final s = _bigIntToBytes(sig.s, 32);
    final out = Uint8List(64);
    out.setRange(0, 32, r);
    out.setRange(32, 64, s);
    return out;
  }

  /// 静态验签：用 [publicKeyBytes65] 验证 [signature64] 是否对 [message] 有效。
  ///
  /// 客户端本地"密码学验签"链路就走这一步；公钥合法性确认走公钥管理服务。
  static bool verify({
    required Uint8List message,
    required Uint8List signature64,
    required Uint8List publicKeyBytes65,
  }) {
    if (signature64.length != 64) return false;
    if (publicKeyBytes65.length != 65 || publicKeyBytes65[0] != 0x04) {
      return false;
    }
    final r = _bytesToBigInt(signature64.sublist(0, 32));
    final s = _bytesToBigInt(signature64.sublist(32, 64));
    final x = _bytesToBigInt(publicKeyBytes65.sublist(1, 33));
    final y = _bytesToBigInt(publicKeyBytes65.sublist(33, 65));
    final q = _curve.curve.createPoint(x, y);
    final pub = ECPublicKey(q, _curve);
    final verifier = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(pub));
    return verifier.verifySignature(message, ECSignature(r, s));
  }
}

/// secp256k1 曲线常量（pointycastle 内置）。
final ECDomainParameters _curve = ECCurve_secp256k1();

/// 从系统熵源拉 [n] 字节随机数，用于 Fortuna 播种。
Uint8List _secureSeed(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// 大整数 → 定长大端字节串（不足左侧补零，超长截断会抛错）。
Uint8List _bigIntToBytes(BigInt n, int length) {
  if (n.isNegative) {
    throw ArgumentError('不支持负数私钥/坐标');
  }
  var hex = n.toRadixString(16);
  if (hex.length > length * 2) {
    throw ArgumentError('整数超过 $length 字节：$hex');
  }
  if (hex.length.isOdd) hex = '0$hex';
  if (hex.length < length * 2) {
    hex = hex.padLeft(length * 2, '0');
  }
  return _hexDecode(hex);
}

BigInt _bytesToBigInt(Uint8List bytes) {
  return BigInt.parse(_hexEncode(bytes), radix: 16);
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

Uint8List _hexDecode(String hex) {
  final clean = hex.replaceAll(' ', '');
  if (clean.length.isOdd) {
    throw ArgumentError('hex 长度必须为偶数');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 打包成 base64 url-safe 串便于在配置文件 / URL 中传输。
String publicKeyToBase64Url(HanakoKeyPair pair) =>
    base64UrlEncode(pair.publicKeyBytes);
