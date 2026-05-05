// tools/recovery_benchmark.dart
//
// 独立 benchmark 脚本（不依赖 flutter test runner），可以 AOT 编译跑，
// 反映正式打包后的真实性能。
//
// 用法：
//   dart compile exe tools/recovery_benchmark.dart -o build/bench.exe
//   build/bench.exe
//
// 或直接 dart run（仍是 JIT，比 AOT 慢但比 flutter test 快）：
//   dart run tools/recovery_benchmark.dart

import 'package:hanako/identity/keypair.dart';
import 'package:hanako/identity/mnemonic.dart';
import 'package:hanako/identity/word_dict.dart';
import 'package:pointycastle/digests/sha256.dart';

double _bench(int n, void Function() body) {
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
  final mn = generateMnemonic();
  final pair = HanakoKeyPair.fromPrivateKeyBytes(mn.privateKeyBytes);
  final targetSet = {pair.publicKeyHex};
  final ids = mn.words.map((w) => idByWord(w)!).toList();

  print('=== 单阶段基准 ===');
  final t1 = _bench(50, () => tryMnemonicFromIds(ids));
  print('  PBKDF2 + 校验位:                ${t1.toStringAsFixed(0)} µs');

  final priv = mn.privateKeyBytes;
  final t2 = _bench(50, () => HanakoKeyPair.fromPrivateKeyBytes(priv));
  print('  secp256k1 公钥派生:             ${t2.toStringAsFixed(0)} µs');

  final pubBytes = pair.publicKeyBytes;
  final t3 = _bench(1000, () => SHA256Digest().process(pubBytes));
  print('  SHA-256 公钥哈希:               ${t3.toStringAsFixed(0)} µs');

  print('\n=== 全链路一次完整验证 ===');
  final tFull = _bench(30, () {
    final seed = tryMnemonicFromIds(ids);
    if (seed == null) return;
    final kp = HanakoKeyPair.fromPrivateKeyBytes(seed.privateKeyBytes);
    targetSet.contains(kp.publicKeyHex);
  });
  print('  完整一次:                        ${tFull.toStringAsFixed(0)} µs');
  print('  每秒可跑:                        ${(1e6 / tFull).toStringAsFixed(0)} 次/s');

  final wrongIds = [...ids];
  wrongIds[0] = (wrongIds[0] + 1) % hanakoWordlistSize;
  final tFastFail = _bench(10000, () => tryMnemonicFromIds(wrongIds));
  print('\n=== 校验位失败快速路径 ===');
  print('  快速失败:                        ${tFastFail.toStringAsFixed(2)} µs');

  final weightedAvg = tFull / 16 + tFastFail * 15 / 16;
  print('\n  加权平均 (实际搜索每次):        ${weightedAvg.toStringAsFixed(2)} µs');
  print('  → 5 分钟可枚举组合:               ${(5 * 60 * 1e6 / weightedAvg).toStringAsFixed(0)}');
  print('  → 10 分钟可枚举组合:              ${(10 * 60 * 1e6 / weightedAvg).toStringAsFixed(0)}');

  print('\n=== 搜索空间表 ===');
  print('  ┌──────┬───────────┬───────────┬───────────┬───────────┐');
  print('  │ K\\D  │   D=4     │   D=6     │   D=8     │   D=12    │');
  print('  ├──────┼───────────┼───────────┼───────────┼───────────┤');
  for (final k in [3, 4, 5]) {
    final cells = <String>[];
    for (final d in [4, 6, 8, 12]) {
      cells.add(_searchSpace(12, k, d).toString().padLeft(9));
    }
    print('  │ K=$k  │ ${cells.join(' │ ')} │');
  }
  print('  └──────┴───────────┴───────────┴───────────┴───────────┘');
}

int _searchSpace(int cols, int k, int dMax) {
  var total = 0;
  for (var d = 0; d <= dMax; d++) {
    total += _binom(cols, d) * _pow((k - 1), d);
  }
  return total;
}

int _binom(int n, int k) {
  if (k < 0 || k > n) return 0;
  var r = 1;
  for (var i = 0; i < k; i++) r = r * (n - i) ~/ (i + 1);
  return r;
}

int _pow(int base, int exp) {
  var r = 1;
  for (var i = 0; i < exp; i++) r *= base;
  return r;
}
