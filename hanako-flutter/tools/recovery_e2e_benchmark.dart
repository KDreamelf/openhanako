// tools/recovery_e2e_benchmark.dart
//
// 端到端恢复算法基准测试。
//
// 流程：
//   1. 生成一个真实 mnemonic（已知正确 ID 序列）
//   2. 构造一个 12×3 矩阵：把正确 ID 藏在指定 D 个位置的 rank-1 上，
//      其它位置 rank-0 = 正确 ID（即真实汉明距离 = D_actual）
//   3. 跑 Recovery.tryRecover()，测量端到端耗时与尝试次数
//   4. 在不同 (D_actual, workerCount) 下跑，输出表格
//
// 用法：
//   dart run tools/recovery_e2e_benchmark.dart
//
// 注意：
//   - 这是 JIT 模式数据。Flutter release / AOT 通常再快 1.3-2x。
//   - PBKDF2 占主要耗时，与具体平台（CPU 频率 / 是否有 SIMD）强相关。
//   - 4 核 / 8 核机器结果会显著不同；脚本会自动选 cores-1。

import 'dart:io';

import 'package:hanako/identity/keypair.dart';
import 'package:hanako/identity/mnemonic.dart';
import 'package:hanako/identity/recovery.dart';
import 'package:hanako/identity/word_dict.dart';

/// 构造一个 12×3 矩阵：[hideAt] 列上正确 ID 在 rank-1，其他列在 rank-0。
List<List<int>> _buildMatrix({
  required List<int> correctIds,
  required Set<int> hideAt,
}) {
  final matrix = <List<int>>[];
  for (var i = 0; i < correctIds.length; i++) {
    final correct = correctIds[i];
    final wrong1 = (correct + 17) % hanakoWordlistSize;
    final wrong2 = (correct + 31) % hanakoWordlistSize;
    if (hideAt.contains(i)) {
      // rank-0=错, rank-1=正确, rank-2=错
      matrix.add([wrong1, correct, wrong2]);
    } else {
      // rank-0=正确, rank-1=错, rank-2=错
      matrix.add([correct, wrong1, wrong2]);
    }
  }
  return matrix;
}

Future<({int elapsedMs, int attempted, bool success})> _runOnce({
  required List<List<int>> matrix,
  required String targetHash,
  required int workerCount,
  required Duration hardDeadline,
}) async {
  setKnownPublicKeyHashes({targetHash});
  final recovery = Recovery(
    checker: (pub) async => true, // 二次确认我们留给 hash 集合做
    kPerColumn: 3,
    dMaxSoft: 12,
    dMaxHard: 12,
    softDeadline: hardDeadline,
    hardDeadline: hardDeadline,
    workerCount: workerCount,
  );
  final outcome = await recovery.tryRecover(matrix);
  return (
    elapsedMs: outcome.elapsedMs,
    attempted: outcome.attempted,
    success: outcome.success,
  );
}

void main() async {
  final cores = Platform.numberOfProcessors;
  final concurrent = cores <= 2 ? 1 : cores - 1;

  print('=== 端到端恢复算法 Benchmark ===');
  print('CPU 核心数: $cores');
  print('并行 worker 数: $concurrent (留 1 核给 UI)');
  print('字典版本: $hanakoWordlistVersion');
  print('');

  // 准备一个真实 mnemonic
  final m = generateMnemonic();
  final pair = HanakoKeyPair.fromPrivateKeyBytes(m.privateKeyBytes);
  final ids = m.words.map((w) => idByWord(w)!).toList();

  print('测试 mnemonic 已生成（前 3 词: ${m.words.sublist(0, 3).join(" ")} ...）');
  print('');

  // 测试场景：D_actual = 0 / 1 / 2 / 3 / 4
  // 不再跑 D≥5 因为耗时长，用线性外推
  final scenarios = <int>[0, 1, 2, 3, 4];

  print('┌──────┬───────────┬───────────┬───────────┬───────────┐');
  print('│ D    │ 单 isolate          │ $concurrent isolates             │');
  print('│ 实际 │ 时间 (ms) │ 尝试次数  │ 时间 (ms) │ 尝试次数  │');
  print('├──────┼───────────┼───────────┼───────────┼───────────┤');

  final timeSingleByD = <int, int>{};
  final timeParallelByD = <int, int>{};

  for (final dActual in scenarios) {
    // 选 dActual 个列藏 rank-1
    final hideAt = <int>{};
    for (var i = 0; i < dActual; i++) {
      hideAt.add(i * 2);
    }
    final matrix = _buildMatrix(correctIds: ids, hideAt: hideAt);

    // 单 isolate
    final r1 = await _runOnce(
      matrix: matrix,
      targetHash: pair.publicKeyHash,
      workerCount: 1,
      hardDeadline: const Duration(minutes: 30),
    );
    timeSingleByD[dActual] = r1.elapsedMs;

    // 多 isolate
    final rN = await _runOnce(
      matrix: matrix,
      targetHash: pair.publicKeyHash,
      workerCount: concurrent,
      hardDeadline: const Duration(minutes: 30),
    );
    timeParallelByD[dActual] = rN.elapsedMs;

    final ok1 = r1.success ? '✓' : '✗';
    final okN = rN.success ? '✓' : '✗';
    print(
      '│ $dActual    │ ${r1.elapsedMs.toString().padLeft(8)}$ok1 │ '
      '${r1.attempted.toString().padLeft(9)} │ '
      '${rN.elapsedMs.toString().padLeft(8)}$okN │ '
      '${rN.attempted.toString().padLeft(9)} │',
    );
  }
  print('└──────┴───────────┴───────────┴───────────┴───────────┘');

  // ============ 外推到 D=8 / D=12 =============
  print('');
  print('=== 外推到 D=8 / D=12 ===');
  print('（基于 D=4 实测时间 + 搜索空间比例线性外推）');
  print('');

  final time4Single = timeSingleByD[4] ?? 0;
  final time4Parallel = timeParallelByD[4] ?? 0;

  // 当真实 D=k 时，搜索会跑遍 d=0..k-1 的所有组合 + d=k 的平均一半
  // 所以期望尝试次数 = SUM_{d=0..k-1} C(12,d)*2^d + 0.5 * C(12,k) * 2^k
  final searchSize4 = _expectedSearchSpace(4);
  final searchSize8 = _expectedSearchSpace(8);
  final searchSize12 = _expectedSearchSpace(12);

  final est8Single = time4Single * searchSize8 ~/ searchSize4;
  final est8Parallel = time4Parallel * searchSize8 ~/ searchSize4;
  final est12Single = time4Single * searchSize12 ~/ searchSize4;
  final est12Parallel = time4Parallel * searchSize12 ~/ searchSize4;

  print('┌──────┬───────────────┬───────────────┐');
  print('│ D    │ 单 isolate (s)│ $concurrent isolates (s)    │');
  print('├──────┼───────────────┼───────────────┤');
  print(
    '│ D=4  │ ${(time4Single / 1000).toStringAsFixed(1).padLeft(13)} │ '
    '${(time4Parallel / 1000).toStringAsFixed(1).padLeft(13)} │',
  );
  print(
    '│ D=8  │ ${(est8Single / 1000).toStringAsFixed(1).padLeft(13)} │ '
    '${(est8Parallel / 1000).toStringAsFixed(1).padLeft(13)} │',
  );
  print(
    '│ D=12 │ ${(est12Single / 1000).toStringAsFixed(1).padLeft(13)} │ '
    '${(est12Parallel / 1000).toStringAsFixed(1).padLeft(13)} │',
  );
  print('└──────┴───────────────┴───────────────┘');

  print('');
  print('=== 5 分钟 / 10 分钟边界 ===');
  print('（$concurrent isolate 实测，未叠加 AOT 加速）');
  print('');
  final budget5min = 5 * 60 * 1000;
  final budget10min = 10 * 60 * 1000;
  final boundaryD5 = _findMaxD(time4Parallel, searchSize4, budget5min);
  final boundaryD10 = _findMaxD(time4Parallel, searchSize4, budget10min);
  print('  5 分钟内可覆盖 D ≤ $boundaryD5');
  print('  10 分钟内可覆盖 D ≤ $boundaryD10');
  print('');
  print('  AOT 编译额外加速 1.5-2x，预计：');
  print('  5 分钟内可覆盖 D ≤ ${_findMaxD(time4Parallel ~/ 2, searchSize4, budget5min)} ~ '
      '${_findMaxD((time4Parallel * 2) ~/ 3, searchSize4, budget5min)}');
  print('  10 分钟内可覆盖 D ≤ ${_findMaxD(time4Parallel ~/ 2, searchSize4, budget10min)} ~ '
      '${_findMaxD((time4Parallel * 2) ~/ 3, searchSize4, budget10min)}');
}

/// 给定 D=k，计算"真实命中点是 D=k"时的期望尝试次数。
int _expectedSearchSpace(int k) {
  // sum_{d=0..k-1} C(12,d)*2^d + 0.5 * C(12,k) * 2^k
  var total = 0;
  for (var d = 0; d < k; d++) {
    total += _binom(12, d) * _pow(2, d);
  }
  total += _binom(12, k) * _pow(2, k) ~/ 2;
  return total;
}

int _findMaxD(int time4ms, int size4, int budgetMs) {
  for (var d = 0; d <= 12; d++) {
    final estMs = time4ms * _expectedSearchSpace(d) ~/ size4;
    if (estMs > budgetMs) return d - 1;
  }
  return 12;
}

int _binom(int n, int k) {
  if (k < 0 || k > n) return 0;
  if (k == 0 || k == n) return 1;
  var r = 1;
  final kk = k > n - k ? n - k : k;
  for (var i = 0; i < kk; i++) {
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
