// test/recovery_benchmark.dart
//
// 恢复算法核心原语的性能 benchmark。
//
// 测什么：单次"候选 ID 组合 → 公钥比对"全程的耗时分解。
//   1. BIP-39 校验位检查
//   2. PBKDF2-HMAC-SHA512 2048 轮
//   3. secp256k1 公钥派生
//   4. SHA-256 公钥哈希
//   5. set 比对
//
// 怎么用：
//   flutter test test/recovery_benchmark.dart --plain-name benchmark
//   或 release 模式：
//   dart compile exe test/recovery_benchmark.dart -o build/bench.exe
//
// 给恢复算法的 K（每列候选数）和 D（汉明距离上限）设计提供基准。

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/keypair.dart';
import 'package:hanako/identity/mnemonic.dart';
import 'package:hanako/identity/word_dict.dart';
import 'package:pointycastle/digests/sha256.dart';

/// 计时器：累加 N 次 [body] 的总耗时（micros），返回平均 micros/次。
double _bench(int n, void Function() body) {
  // warmup
  for (var i = 0; i < n ~/ 10 + 1; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    body();
  }
  sw.stop();
  return sw.elapsedMicroseconds / n;
}

void main() {
  test('benchmark · 全链路单次组合验证', () {
    // 准备：一组真实 12 词 + 派生出的真实公钥哈希（作为 target）
    final mn = generateMnemonic();
    final pair = HanakoKeyPair.fromPrivateKeyBytes(mn.privateKeyBytes);
    final targetHash = pair.publicKeyHash;
    final targetSet = {targetHash};

    // ID 列表（模拟恢复期 LLM 输出）
    final ids = mn.words.map((w) => idByWord(w)!).toList();

    // ============ 各阶段单独计时 =============
    print('\n=== 单阶段基准 (取 100 次平均) ===');

    // 阶段 1：BIP-39 校验位
    final t1 = _bench(100, () {
      tryMnemonicFromIds(ids);
    });
    print('  PBKDF2 + 校验位 (一次完整 mnemonic→seed): ${t1.toStringAsFixed(0)} µs');

    // 阶段 2：仅 secp256k1 公钥派生（不含 PBKDF2）
    final priv = mn.privateKeyBytes;
    final t2 = _bench(100, () {
      HanakoKeyPair.fromPrivateKeyBytes(priv);
    });
    print('  secp256k1 公钥派生:                       ${t2.toStringAsFixed(0)} µs');

    // 阶段 3：SHA-256 公钥哈希
    final pubBytes = pair.publicKeyBytes;
    final t3 = _bench(1000, () {
      SHA256Digest().process(pubBytes);
    });
    print('  SHA-256 公钥哈希:                         ${t3.toStringAsFixed(0)} µs');

    // 阶段 4：set 比对
    final t4 = _bench(100000, () {
      targetSet.contains(targetHash);
    });
    print('  Set.contains:                             ${t4.toStringAsFixed(2)} µs');

    // 全链路：模拟"一次候选组合的完整 verify"
    print('\n=== 全链路一次完整验证 (取 50 次平均) ===');
    final tFull = _bench(50, () {
      final seed = tryMnemonicFromIds(ids);
      if (seed == null) return;
      final kp = HanakoKeyPair.fromPrivateKeyBytes(seed.privateKeyBytes);
      targetSet.contains(kp.publicKeyHex);
    });
    print('  完整一次:                                  ${tFull.toStringAsFixed(0)} µs');
    print('  → 每秒可跑:                                ${(1e6 / tFull).toStringAsFixed(0)} 次/s');

    // ============ 推算搜索空间预算 =============
    final perAttemptMs = tFull / 1000;
    final budget5min = 5 * 60 * 1000 / perAttemptMs;
    final budget10min = 10 * 60 * 1000 / perAttemptMs;

    print('\n=== 时间预算反推 ===');
    print('  5 分钟可跑:  ${budget5min.toStringAsFixed(0)} 次完整尝试');
    print('  10 分钟可跑: ${budget10min.toStringAsFixed(0)} 次完整尝试');

    // 校验位过滤：只有 1/16 通过 BIP-39 校验，所以"完整 PBKDF2"的次数会减少。
    // 但这里 tryMnemonicFromIds 本身已经做了校验位检查，校验失败时会立刻抛
    // FormatException 不走 PBKDF2，所以 tFull 反而是"校验通过"的情况。
    // 校验失败的快速路径单独测：
    final wrongIds = [...ids];
    wrongIds[0] = (wrongIds[0] + 1) % hanakoWordlistSize; // 故意打乱
    final tFastFail = _bench(10000, () {
      tryMnemonicFromIds(wrongIds);
    });
    print('\n=== 校验位失败快速路径 (取 10000 次平均) ===');
    print('  快速失败:                                  ${tFastFail.toStringAsFixed(2)} µs');
    print('  这条路径占组合空间的 15/16');

    // 加权平均：1/16 慢路径 + 15/16 快速失败
    final weightedAvg = tFull / 16 + tFastFail * 15 / 16;
    print('\n  加权平均 (实际搜索每次):                  ${weightedAvg.toStringAsFixed(2)} µs');
    final weightedBudget5min = 5 * 60 * 1e6 / weightedAvg;
    final weightedBudget10min = 10 * 60 * 1e6 / weightedAvg;
    print('  → 5 分钟实际可枚举组合:                    ${weightedBudget5min.toStringAsFixed(0)}');
    print('  → 10 分钟实际可枚举组合:                   ${weightedBudget10min.toStringAsFixed(0)}');

    // ============ K 和 D 的可行域 =============
    print('\n=== 搜索空间 vs 各 (K, D) 组合 ===');
    print('  K = 每列候选数, D = 汉明距离上限');
    print('  组合数 = Σ_{d=0..D} C(12,d) · (K-1)^d');
    print('  ┌──────┬───────────┬───────────┬───────────┬───────────┐');
    print('  │ K\\D  │ D=4       │ D=6       │ D=8       │ D=12      │');
    print('  ├──────┼───────────┼───────────┼───────────┼───────────┤');
    for (final k in [3, 4, 5]) {
      final cells = <String>[];
      for (final d in [4, 6, 8, 12]) {
        final n = _searchSpace(12, k, d);
        cells.add(n.toString().padLeft(9));
      }
      print('  │ K=$k  │ ${cells.join(' │ ')} │');
    }
    print('  └──────┴───────────┴───────────┴───────────┴───────────┘');
    print('  5 分钟可承受上限:  ${weightedBudget5min.toStringAsFixed(0)}');
    print('  10 分钟可承受上限: ${weightedBudget10min.toStringAsFixed(0)}');

    // 验证：K=3 D=12 (理论最大) 在预算内吗？
    final maxSpaceK3 = _searchSpace(12, 3, 12);
    final maxSpaceK4 = _searchSpace(12, 4, 12);
    final maxSpaceK5 = _searchSpace(12, 5, 12);
    print('\n  全空间 K=3 D=12: $maxSpaceK3   (= 3^12)');
    print('  全空间 K=4 D=12: $maxSpaceK4   (= 4^12)');
    print('  全空间 K=5 D=12: $maxSpaceK5   (= 5^12)');
  });
}

int _searchSpace(int cols, int k, int dMax) {
  // Σ_{d=0..dMax} C(cols,d) · (k-1)^d
  var total = 0;
  for (var d = 0; d <= dMax; d++) {
    total += _binom(cols, d) * _pow((k - 1), d);
  }
  return total;
}

int _binom(int n, int k) {
  if (k < 0 || k > n) return 0;
  var r = 1;
  for (var i = 0; i < k; i++) {
    r = r * (n - i) ~/ (i + 1);
  }
  return r;
}

int _pow(int base, int exp) {
  var r = 1;
  for (var i = 0; i < exp; i++) {
    r *= base;
  }
  return r;
}
