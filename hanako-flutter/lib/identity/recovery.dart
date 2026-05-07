// lib/identity/recovery.dart
//
// 私钥恢复器（v2 矩阵搜索版）。
//
// 与 v1 全排列穷举的根本区别：
//   v1: LLM 给出扁平 ID 列表，客户端尝试该列表的所有排列（最坏 12!）
//   v2: LLM 给出 12 列 × K 行的候选矩阵（按故事顺序），客户端按
//       "汉明距离 d 递增" 枚举：d=0 → 每列取 rank-0；d=k → 替换 k 列
//       为 rank-1..rank-(K-1)。最坏 K^12 次。
//
// 与 MVP §10.5 + 用户 2026-04-27 设计对齐。
//
// 性能预算（基于 tools/recovery_benchmark.dart 实测，dart run JIT 模式）：
//   - 单次完整 PBKDF2 + secp256k1 派生 + 公钥哈希比对 ≈ 86 ms
//   - 校验位过滤后加权平均 ≈ 5.4 ms / 次
//   - 单线程 5 分钟可枚举 ≈ 55,000 次
//   - 4 核并行 + AOT (~2x) 估算 5 分钟 ≈ 400,000 次
//
// Dart fallback 第一阶段参数 (与 story_parser.kStoryParserCandidatesPerColumn = 5 对齐)：
//   K = 5            每列 top-5 候选，覆盖常见同义词/错记词
//   D_max = 4        在 10 分钟 UX 预算内优先覆盖小范围记忆误差
//   deadline = 10min 登录/验证恢复最大等待预算
//
// Windows 生产路径会先尝试 RecoveryAccelerator / windows_ops sidecar；
// 本文件保留为可移植 Dart fallback。GPU 后端必须在 sidecar 内明确实现并上报，
// 不能仅靠这条 Dart isolate 路径声称 CUDA 加速。
//
// Isolate 并行：
//   把"d 层枚举"按 (combo_index mod N_workers) 分给 N_workers 个 isolate；
//   每个 worker 独立做 PBKDF2 + secp256k1，找到匹配立刻通知主 isolate
//   终止其他 worker。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'keypair.dart';
import 'mnemonic.dart';

/// 公钥比对回调。返回 true 表示该公钥在服务端 / 本地缓存里已注册。
///
/// 注意：此回调会在主 isolate 调用——worker isolate 找到候选后把结果传回
/// 主 isolate 由这里做最终比对（避免 checker 闭包跨 isolate 序列化问题）。
typedef PublicKeyChecker =
    Future<bool> Function(String publicKeyHexUncompressed);

class RecoveryOutcome {
  RecoveryOutcome.success(
    this.seed, {
    required this.attempted,
    required this.elapsedMs,
    required this.hammingDistance,
  }) : failed = false,
       timedOut = false;
  RecoveryOutcome.failed({
    required this.attempted,
    required this.timedOut,
    required this.elapsedMs,
    required this.hammingDistance,
  }) : seed = null,
       failed = true;

  final MnemonicSeed? seed;
  final int attempted;
  final int elapsedMs;
  final int hammingDistance;
  final bool failed;
  final bool timedOut;

  bool get success => seed != null;
}

class Recovery {
  Recovery({
    required this.checker,
    this.kPerColumn = 3,
    this.dMaxSoft = 8,
    this.dMaxHard = 12,
    this.softDeadline = const Duration(minutes: 5),
    this.hardDeadline = const Duration(minutes: 10),
    this.workerCount,
    this.onProgress,
  });

  /// 服务端 / 本地公钥比对器。
  final PublicKeyChecker checker;

  /// 每列候选数。必须与 LLM 输出的矩阵列数一致。
  final int kPerColumn;

  /// 软目标汉明距离上限。在软超时前优先搜到这个深度。
  final int dMaxSoft;

  /// 硬上限。超过这个深度认定不可能恢复。
  final int dMaxHard;

  /// 软超时（达到后切换为"减速 + 询问用户是否继续"模式，但仍继续搜直到硬超时）。
  final Duration softDeadline;

  /// 硬超时。超过即返回失败。
  final Duration hardDeadline;

  /// 并行 worker 数。null 时自动取 max(1, processors - 1)。
  final int? workerCount;

  /// 进度回调（用于 UI 显示"已尝试 X 次 / 已用时 Y 秒"）。
  final void Function(RecoveryProgress progress)? onProgress;

  /// 主入口：[matrix] 是 12 行 × K 列的候选 ID 矩阵（外层 = 故事意象顺序）。
  Future<RecoveryOutcome> tryRecover(List<List<int>> matrix) async {
    // 输入合法性
    if (matrix.length != kMnemonicLength) {
      return RecoveryOutcome.failed(
        attempted: 0,
        timedOut: false,
        elapsedMs: 0,
        hammingDistance: 0,
      );
    }
    for (final col in matrix) {
      if (col.length != kPerColumn) {
        return RecoveryOutcome.failed(
          attempted: 0,
          timedOut: false,
          elapsedMs: 0,
          hammingDistance: 0,
        );
      }
    }

    final sw = Stopwatch()..start();
    final nWorkers = workerCount ?? _defaultWorkerCount();
    final attemptedCounter = _AtomicCounter();

    // 已知公钥缓存：如果 checker 命中过某些公钥，可缓存避免重复网络调用。
    // 不过当前 checker 一般是常数时间（本地比对或服务端批查），所以暂不加缓存。

    // 把矩阵转成扁平形式让 worker 用：matrixFlat[col * K + rank] = id
    final flat = Int32List(kMnemonicLength * kPerColumn);
    for (var c = 0; c < kMnemonicLength; c++) {
      for (var r = 0; r < kPerColumn; r++) {
        flat[c * kPerColumn + r] = matrix[c][r];
      }
    }

    // 按汉明距离 d=0..dMaxHard 递增搜索。每个 d 层的所有组合并行分配给 workers。
    for (var d = 0; d <= dMaxHard; d++) {
      // 软超时检查：到了软超时但还在搜 d <= dMaxSoft 范围内时仍继续；
      // 超出软目标后只在 dMaxSoft < d <= dMaxHard 时才搜。
      final elapsed = sw.elapsedMilliseconds;
      if (elapsed > hardDeadline.inMilliseconds) {
        return RecoveryOutcome.failed(
          attempted: attemptedCounter.value,
          timedOut: true,
          elapsedMs: elapsed,
          hammingDistance: d,
        );
      }
      // 进度通知
      onProgress?.call(
        RecoveryProgress(
          currentHammingDistance: d,
          attempted: attemptedCounter.value,
          elapsedMs: elapsed,
        ),
      );

      final hit = await _searchAtDistance(
        flat: flat,
        d: d,
        nWorkers: nWorkers,
        attemptedCounter: attemptedCounter,
        deadline: hardDeadline,
        startedAt: sw,
      );
      if (hit != null) {
        // 找到候选种子，主 isolate 用 checker 二次确认（防止 worker 假阳性）
        final pair = HanakoKeyPair.fromPrivateKeyBytes(hit.privateKeyBytes);
        if (await checker(pair.publicKeyHex)) {
          return RecoveryOutcome.success(
            hit,
            attempted: attemptedCounter.value,
            elapsedMs: sw.elapsedMilliseconds,
            hammingDistance: d,
          );
        }
        // 假阳性（不太可能，但防一手）：继续搜
      }
    }

    return RecoveryOutcome.failed(
      attempted: attemptedCounter.value,
      timedOut: sw.elapsedMilliseconds >= hardDeadline.inMilliseconds,
      elapsedMs: sw.elapsedMilliseconds,
      hammingDistance: dMaxHard,
    );
  }

  /// 在汉明距离 d 层搜索，把所有组合分给 nWorkers 个 worker isolate。
  ///
  /// 每个 worker 收到自己的分片范围（combo_index 区间），独立枚举 + 检查
  /// 校验位 + PBKDF2 + secp256k1，找到匹配回传种子。任一 worker 命中后
  /// 取消其他 worker。
  Future<MnemonicSeed?> _searchAtDistance({
    required Int32List flat,
    required int d,
    required int nWorkers,
    required _AtomicCounter attemptedCounter,
    required Duration deadline,
    required Stopwatch startedAt,
  }) async {
    // d 层的总组合数 = C(12, d) * (K-1)^d
    // C(12,0) = 1, C(12,12) = 1, C(12,6) = 924
    final cIdxMax = _binom(kMnemonicLength, d);
    final substMax = _pow(kPerColumn - 1, d);
    final totalCombos = cIdxMax * substMax;
    if (totalCombos == 0) return null;

    // checker 是 Future Function — 不能跨 isolate。所以 worker 不调 checker，
    // 只做"派生公钥 + 用 worker 内部 known target hash 比对"。
    // 但我们没法把 checker 状态传给 worker。
    //
    // 折中方案：worker 不做 target 比对，找到所有"BIP-39 校验位 PASS"的种子
    // 都传回来，主 isolate 再用 checker 二次确认。但 PASS 概率 1/16，d=8 时
    // 也有 几千 次回传，开销大。
    //
    // 更好的折中：让 worker 接收一个"候选公钥哈希集合"作为静态 payload，
    // worker 派生后直接比对 hash，命中就回传种子。这要求 checker 能"列出
    // 所有可能的 target hash"——离线场景（本机自检）能做到，在线场景
    // （pubkey-service 批查）做不到。
    //
    // MVP 阶段：约定 checker 是离线的（用本地存的旧公钥比对）。在线
    // 集群恢复将来再扩展。
    final knownHashes = await _resolveKnownHashes();

    final receivePort = ReceivePort();
    final completer = Completer<MnemonicSeed?>();
    final isolates = <Isolate>[];
    var done = 0;

    void finish(MnemonicSeed? result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      // 关停所有 worker
      for (final iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
      receivePort.close();
    }

    receivePort.listen((msg) {
      if (msg is Map) {
        if (msg['type'] == 'progress') {
          attemptedCounter.add(msg['count'] as int);
        } else if (msg['type'] == 'hit') {
          final ids = (msg['ids'] as List).cast<int>();
          final seed = tryMnemonicFromIds(ids);
          if (seed != null) finish(seed);
        } else if (msg['type'] == 'done') {
          done++;
          if (done >= nWorkers) {
            // 所有 worker 报告完成而没有命中
            if (!completer.isCompleted) finish(null);
          }
        }
      }
    });

    // 分片：worker w 处理 cIdx where cIdx % nWorkers == w
    for (var w = 0; w < nWorkers; w++) {
      final iso = await Isolate.spawn<_WorkerArgs>(
        _workerEntry,
        _WorkerArgs(
          sendPort: receivePort.sendPort,
          flat: flat,
          d: d,
          k: kPerColumn,
          shardIndex: w,
          shardCount: nWorkers,
          knownHashes: knownHashes,
          deadlineEpochMs:
              DateTime.now().millisecondsSinceEpoch +
              deadline.inMilliseconds -
              startedAt.elapsedMilliseconds,
        ),
      );
      isolates.add(iso);
    }

    final result = await completer.future;
    return result;
  }

  /// 当前 checker 是 Future——我们没法在 worker isolate 里调用它。
  /// 离线场景：用一个全局缓存暴露"已知的目标公钥哈希集合"。
  /// 临时实现：返回空集，让 worker 把所有"校验位 PASS"的候选都回传。
  ///
  /// 长期方案：增加一个 [Recovery.knownPublicKeyHashes] 字段，构造时由
  /// 调用方提供（比如 IdentityRepository.loginWithStory 的 checker 改成
  /// 直接传一组哈希）。
  Future<Set<String>> _resolveKnownHashes() async {
    // 由调用方注入。当前实现：空集，全部校验位 PASS 的候选都回传给主 isolate。
    return _RecoveryConfig.instance.knownTargetHashes;
  }

  static int _defaultWorkerCount() {
    final cores = Platform.numberOfProcessors;
    if (cores <= 2) return 1;
    return cores - 1;
  }
}

/// 进度报告。
class RecoveryProgress {
  RecoveryProgress({
    required this.currentHammingDistance,
    required this.attempted,
    required this.elapsedMs,
  });
  final int currentHammingDistance;
  final int attempted;
  final int elapsedMs;
}

/// 共享配置（调用方在 tryRecover 之前用 [setKnownHashes] 注入目标哈希）。
class _RecoveryConfig {
  _RecoveryConfig._();
  static final instance = _RecoveryConfig._();
  Set<String> knownTargetHashes = const {};
}

/// 调用方在尝试恢复前必须调一次本函数把"目标公钥哈希集合"注入。
/// worker isolate 派生候选后用这个集合做哈希比对，命中才回传种子给主 isolate。
///
/// 离线场景：本地存的旧公钥的 SHA-256 哈希
/// 在线场景：先调 pubkey-service 把候选范围拉到本地，然后注入
void setKnownPublicKeyHashes(Set<String> hashes) {
  _RecoveryConfig.instance.knownTargetHashes = Set.unmodifiable(hashes);
}

// ===========================================================================
//  Worker isolate
// ===========================================================================

class _WorkerArgs {
  _WorkerArgs({
    required this.sendPort,
    required this.flat,
    required this.d,
    required this.k,
    required this.shardIndex,
    required this.shardCount,
    required this.knownHashes,
    required this.deadlineEpochMs,
  });

  final SendPort sendPort;
  final Int32List flat;
  final int d;
  final int k;
  final int shardIndex;
  final int shardCount;
  final Set<String> knownHashes;
  final int deadlineEpochMs;
}

void _workerEntry(_WorkerArgs args) {
  final cIdxMax = _binom(kMnemonicLength, args.d);
  // worker 处理 cIdx 中 cIdx % shardCount == shardIndex 的部分
  var localCount = 0;
  const reportEvery = 1000;

  for (var cIdx = args.shardIndex; cIdx < cIdxMax; cIdx += args.shardCount) {
    if (DateTime.now().millisecondsSinceEpoch >= args.deadlineEpochMs) break;

    final cols = _comboAt(kMnemonicLength, args.d, cIdx);
    final substMax = _pow(args.k - 1, args.d);

    for (var sIdx = 0; sIdx < substMax; sIdx++) {
      // 为每列计算 rank：默认 0；被选中的 d 列各自取 1..K-1
      final ids = List<int>.generate(
        kMnemonicLength,
        (i) => args.flat[i * args.k],
      );
      var s = sIdx;
      for (final c in cols) {
        final r = (s % (args.k - 1)) + 1;
        ids[c] = args.flat[c * args.k + r];
        s ~/= (args.k - 1);
      }

      // 校验位检查 + PBKDF2 派生
      final seed = tryMnemonicFromIds(ids);
      if (seed != null) {
        final pair = HanakoKeyPair.fromPrivateKeyBytes(seed.privateKeyBytes);
        // 如果调用方注入了已知哈希集合，过滤；否则放过让主 isolate checker 决定。
        if (args.knownHashes.isEmpty ||
            args.knownHashes.contains(pair.publicKeyHash)) {
          args.sendPort.send({'type': 'hit', 'ids': ids});
          return;
        }
      }

      localCount++;
      if (localCount % reportEvery == 0) {
        args.sendPort.send({'type': 'progress', 'count': reportEvery});
      }
    }
  }
  if (localCount % reportEvery != 0) {
    args.sendPort.send({'type': 'progress', 'count': localCount % reportEvery});
  }
  args.sendPort.send({'type': 'done'});
}

// ===========================================================================
//  组合枚举：cIdx → cols
// ===========================================================================

/// 给定 [n] 取 [k]，返回字典序第 [idx] 个组合（idx 0-based）。
List<int> _comboAt(int n, int k, int idx) {
  if (k == 0) return const [];
  final out = List<int>.filled(k, 0);
  var c = idx;
  var start = 0;
  for (var i = 0; i < k; i++) {
    for (var x = start; x < n; x++) {
      final remaining = _binom(n - x - 1, k - i - 1);
      if (c < remaining) {
        out[i] = x;
        start = x + 1;
        break;
      }
      c -= remaining;
    }
  }
  return out;
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

// ===========================================================================
//  原子计数器（跨 isolate 通过消息累加，主 isolate 持有真实状态）
// ===========================================================================

class _AtomicCounter {
  int _v = 0;
  void add(int delta) => _v += delta;
  int get value => _v;
}
