// lib/identity/mnemonic.dart
//
// 助记词 ↔ 私钥派生（BIP-39 中文变体）。
//
// 与标准 BIP-39 的差异：
//   1. wordlist 替换为 word_dict.dart 中的中文 2048 词字典；
//   2. 派生过程沿用 BIP-39 标准：mnemonic_str 作 PBKDF2 输入、
//      "mnemonic" + passphrase 作 salt、HMAC-SHA512 / 2048 轮迭代、
//      输出 64 字节 seed；
//   3. 简化点：不做 BIP-32 HD 派生，直接取 seed 前 32 字节作为 secp256k1
//      私钥（足够 MVP 阶段使用，未来要 HD 钱包再加层即可）。
//
// 与 MVP §10.5 对齐：
//   - 注册期：随机熵 → 12 中文名词（有序）→ 用户保存
//   - 恢复期：12 中文名词（有序）→ 还原同一私钥
//   - 字典与算法版本固定后，同一组词永远派生出同一私钥
//
// 安全说明：
//   - mnemonic 字符串本身就是密钥的"完整形态"，泄漏即等同私钥泄漏；
//   - 内存中持有 mnemonic 的时间应尽量短，用完即清；
//   - 如需更高安全级别可加 passphrase（"BIP-39 25th word"），目前留空。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/pointycastle.dart' show Pbkdf2Parameters;

import 'word_dict.dart';

/// 助记词长度（固定 12 词 = 132 bit = 128 entropy + 4 checksum）。
const int kMnemonicLength = 12;

/// 熵字节数（128 bit）。
const int kEntropyBytes = 16;

/// 一组助记词及其派生产物。
class MnemonicSeed {
  MnemonicSeed({
    required this.words,
    required this.entropy,
    required this.seed,
  });

  /// 12 个中文名词（有序）。
  final List<String> words;

  /// 原始熵（16 字节）。
  final Uint8List entropy;

  /// PBKDF2 派生的 64 字节种子。
  final Uint8List seed;

  /// 取 secp256k1 私钥（seed 前 32 字节）。
  Uint8List get privateKeyBytes => Uint8List.fromList(seed.sublist(0, 32));

  /// 用空格拼接的助记词原文（PBKDF2 的输入格式）。
  String get mnemonicString => words.join(' ');
}

/// 注册期入口：生成全新助记词与对应种子。
///
/// 流程：
///   1. 调系统安全 PRNG 拉 16 字节熵；
///   2. 计算 SHA-256 校验和的高 4 bit 拼到末尾，得到 132 bit；
///   3. 按 11 bit 切片得到 12 个 ID，查字典得 12 个中文名词；
///   4. PBKDF2 派生 64 字节种子。
MnemonicSeed generateMnemonic() {
  if (hanakoWordlistSize < kMnemonicLength) {
    throw StateError(
      '字典词数过少（$hanakoWordlistSize），无法生成助记词。'
      '请扩充 word_dict.dart 至少到 $kMnemonicLength 词以上。',
    );
  }
  final entropy = _secureRandom(kEntropyBytes);
  final words = _entropyToWords(entropy);
  final seed = _mnemonicToSeed(words.join(' '));
  return MnemonicSeed(words: words, entropy: entropy, seed: seed);
}

/// 恢复期入口：把已知 12 词还原成同一种子。
///
/// 抛 [ArgumentError]：
///   - 词数不对；
///   - 词不在字典里；
///   - 校验位不对（说明用户记错了某个词）。
MnemonicSeed mnemonicFromWords(List<String> words) {
  if (words.length != kMnemonicLength) {
    throw ArgumentError('助记词必须为 $kMnemonicLength 个词，收到 ${words.length}');
  }
  final ids = <int>[];
  for (final w in words) {
    final id = idByWord(w);
    if (id == null) {
      throw ArgumentError('词不在字典里：$w');
    }
    ids.add(id);
  }
  final entropy = _idsToEntropy(ids);
  final seed = _mnemonicToSeed(words.join(' '));
  return MnemonicSeed(words: words, entropy: entropy, seed: seed);
}

/// 用一组候选 ID 列表尝试恢复（恢复期 LLM 解析后用），
/// 不抛错，校验失败返回 null，便于穷举循环外层判断。
MnemonicSeed? tryMnemonicFromIds(List<int> ids) {
  if (ids.length != kMnemonicLength) return null;
  for (final id in ids) {
    if (id < 0 || id >= hanakoWordlistSize) return null;
  }
  // 校验逻辑藏在 _idsToEntropy 内部，校验失败抛 [FormatException]。
  try {
    final entropy = _idsToEntropy(ids);
    final words = ids.map((i) => wordById(i)!).toList();
    final seed = _mnemonicToSeed(words.join(' '));
    return MnemonicSeed(words: words, entropy: entropy, seed: seed);
  } on FormatException {
    return null;
  }
}

// ---------------------------------------------------------------------------

/// entropy(16B) → 12 个 ID → 12 个词。
List<String> _entropyToWords(Uint8List entropy) {
  // 1. 算 4-bit 校验位（SHA-256 首字节高 4 bit）。
  final hash = SHA256Digest().process(entropy);
  final checksum = hash[0] >> 4; // 0..15
  // 2. 把 entropy + checksum 拼成 132-bit 大整数 ↔ BigInt 操作最直观。
  var bits = BigInt.zero;
  for (final b in entropy) {
    bits = (bits << 8) | BigInt.from(b);
  }
  bits = (bits << 4) | BigInt.from(checksum);
  // 3. 11-bit 一组切，从高到低输出 12 个 ID。
  final ids = <int>[];
  for (var i = kMnemonicLength - 1; i >= 0; i--) {
    final shift = 11 * i;
    final mask = BigInt.from(0x7ff); // 11 bit
    final id = ((bits >> shift) & mask).toInt();
    ids.add(id);
  }
  return ids.map((id) {
    final w = wordById(id);
    if (w == null) {
      throw StateError('字典越界：ID $id（字典大小 $hanakoWordlistSize）');
    }
    return w;
  }).toList();
}

/// 12 个 ID → entropy(16B)，同时校验 4-bit 校验位。
Uint8List _idsToEntropy(List<int> ids) {
  var bits = BigInt.zero;
  for (final id in ids) {
    bits = (bits << 11) | BigInt.from(id);
  }
  // 拆出末尾 4 bit 校验位。
  final checksumExpected = (bits & BigInt.from(0xf)).toInt();
  bits = bits >> 4;
  // 高 128 bit 还原成 16 字节。
  final out = Uint8List(kEntropyBytes);
  for (var i = kEntropyBytes - 1; i >= 0; i--) {
    out[i] = (bits & BigInt.from(0xff)).toInt();
    bits = bits >> 8;
  }
  // 重新计算校验位比对。
  final hash = SHA256Digest().process(out);
  final checksumActual = hash[0] >> 4;
  if (checksumExpected != checksumActual) {
    throw const FormatException('助记词校验位不匹配（很可能某个词记错了）');
  }
  return out;
}

/// PBKDF2-HMAC-SHA512(mnemonic, "mnemonic"+passphrase, 2048, 64)
/// — BIP-39 标准 seed 派生流程。passphrase 留空。
Uint8List _mnemonicToSeed(String mnemonic, {String passphrase = ''}) {
  final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128))
    ..init(Pbkdf2Parameters(
      utf8.encode('mnemonic$passphrase'),
      2048,
      64,
    ));
  return pbkdf2.process(utf8.encode(mnemonic));
}

Uint8List _secureRandom(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}
