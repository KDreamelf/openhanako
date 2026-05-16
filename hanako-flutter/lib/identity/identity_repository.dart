// lib/identity/identity_repository.dart
//
// Identity 模块业务封装。把 keypair / mnemonic / keystore / 故事生成与解析
// / 恢复 串成几个高层 API，让 UI 层（OnboardingPage / LoginPage）只面对
// "注册一份新身份"、"用故事登录"、"加载已保存身份" 这几件事。
//
// 与用户后端的对接点：
//   - generateRegistrationPreview() 只生成未落盘身份；服务端注册成功后，
//     UI 再调用 replaceCurrentIdentity() 写入平台 keystore。
//   - loginWithStory() 在 LLM 解析得到 12×K 矩阵后，进入 [Recovery] 按汉明
//     距离搜索；目标公钥哈希集合通过 [setKnownPublicKeyHashes] 注入：
//       离线自检：用本地 keystore 中已存身份的公钥哈希
//       在线恢复：先调 auth-gateway 拉到公开候选哈希集合，再注入

import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'keypair.dart';
import 'mnemonic.dart';
import 'recovery.dart';
import 'recovery_accelerator.dart';
import 'secure_keystore.dart';
import 'story_composer.dart';
import 'story_parser.dart';
import 'word_dict.dart';

/// 一份"已加载/已就绪"的身份对象。运行期允许常驻内存，用于高频签名与密钥协商。
class HanakoIdentity {
  HanakoIdentity({required this.keyPair, required this.mnemonic});

  final HanakoKeyPair keyPair;

  /// 注册 / 恢复期会有完整助记词；新版 DPAPI vault 也会加密保存助记词 ID 组。
  final MnemonicSeed? mnemonic;

  String get publicKeyHex => keyPair.publicKeyHex;
  String get publicKeyHash => keyPair.publicKeyHash;
}

/// 注册产物。供 UI 展示给用户保存。
class IdentityRegistration {
  IdentityRegistration({
    required this.identity,
    required this.story,
    required this.fallback,
  });

  final HanakoIdentity identity;

  /// LLM 编出来的故事；fallback 时为空字符串。
  final String story;

  /// 是否走了兜底（LLM 调用失败，用户需直接记忆 12 个词）。
  final bool fallback;

  List<String> get words => identity.mnemonic!.words;
}

enum StoryRecoveryProgressStage {
  aiSemanticAnalysis,
  matrixReady,
  matrixRecovery,
}

class StoryRecoveryProgress {
  StoryRecoveryProgress.aiSemanticAnalysis()
    : stage = StoryRecoveryProgressStage.aiSemanticAnalysis,
      attempted = null,
      elapsedMs = null,
      currentHammingDistance = null,
      combinationId = null,
      columns = const [],
      anchors = const [],
      candidateRanks = const [],
      wordIds = const [],
      activePositions = const [],
      candidatesPerColumn = 0,
      usedLlm = true;

  StoryRecoveryProgress.matrixReady({
    required List<List<int>> columns,
    required List<String> anchors,
    required this.candidatesPerColumn,
    required this.usedLlm,
  }) : stage = StoryRecoveryProgressStage.matrixReady,
       attempted = null,
       elapsedMs = null,
       currentHammingDistance = null,
       combinationId = null,
       columns = _copyMatrix(columns),
       anchors = List<String>.unmodifiable(anchors),
       candidateRanks = const [],
       wordIds = const [],
       activePositions = const [];

  StoryRecoveryProgress.matrixRecovery({
    required this.attempted,
    required this.elapsedMs,
    required this.currentHammingDistance,
    this.combinationId,
    List<int> candidateRanks = const [],
    List<int> wordIds = const [],
    List<int> activePositions = const [],
  }) : stage = StoryRecoveryProgressStage.matrixRecovery,
       columns = const [],
       anchors = const [],
       candidateRanks = List<int>.unmodifiable(candidateRanks),
       wordIds = List<int>.unmodifiable(wordIds),
       activePositions = List<int>.unmodifiable(activePositions),
       candidatesPerColumn = 0,
       usedLlm = true;

  final StoryRecoveryProgressStage stage;
  final int? attempted;
  final int? elapsedMs;
  final int? currentHammingDistance;
  final int? combinationId;
  final List<List<int>> columns;
  final List<String> anchors;
  final List<int> candidateRanks;
  final List<int> wordIds;
  final List<int> activePositions;
  final int candidatesPerColumn;
  final bool usedLlm;
}

class IdentityRepository {
  IdentityRepository({
    required this.keystore,
    required this.composer,
    required this.parser,
    this.recoveryAccelerator,
  });

  final SecureKeystore keystore;
  final StoryComposer composer;
  final StoryParser parser;
  final RecoveryAccelerator? recoveryAccelerator;

  /// 当前进程内已加载的身份。null 表示尚未持有长期身份私钥。
  HanakoIdentity? _current;
  HanakoIdentity? get current => _current;

  /// 是否已有保存过的身份（首次启动判断用）。
  Future<bool> hasSavedIdentity() => keystore.exists();

  /// 注册：本地生成 ECDSA 密钥对、派生助记词、调 LLM 编故事、写入密钥库。
  ///
  Future<IdentityRegistration> registerNew({String? pin}) async {
    final registration = await generateRegistrationPreview();
    await replaceCurrentIdentity(registration.identity, pin: pin);

    // TODO: 等用户后端就位后，这里把 keyPair.publicKeyHex 上报到 pubkey-service。
    //       现在先只在本地完成注册，子体可以离线运转。

    return registration;
  }

  /// 解锁已保存的身份（Windows 走 DPAPI；旧文件 fallback 可传 PIN 迁移）。
  Future<HanakoIdentity> unlock({String? pin}) async {
    final vault = await keystore.readVault(pin: pin);
    final keyPair = HanakoKeyPair.fromPrivateKeyBytes(vault.privateKey);
    final mnemonic = _mnemonicFromVault(vault);
    final identity = HanakoIdentity(keyPair: keyPair, mnemonic: mnemonic);
    _current = identity;
    return identity;
  }

  /// 兼容旧调用名；Windows DPAPI 路径会忽略 [pin]。
  Future<HanakoIdentity> unlockWithPin(String pin) => unlock(pin: pin);

  /// 用当前身份的 12 个名词重新生成记忆故事。
  ///
  /// 若当前进程尚未解锁身份，会先从本机 vault 解锁；旧版仅保存私钥、
  /// 没有保存助记词 ID 的 vault 无法反推出助记词，此时会抛出 [StateError]。
  Future<IdentityRegistration> regenerateStoryForCurrent({String? pin}) async {
    final identity = _current ?? await unlock(pin: pin);
    final mnemonic = identity.mnemonic;
    if (mnemonic == null) {
      throw StateError('当前身份没有保存助记词，无法重新生成故事');
    }

    final composition = await composer.compose(mnemonic.words);
    return IdentityRegistration(
      identity: identity,
      story: composition.story,
      fallback: composition.fallback,
    );
  }

  /// 生成一份新的未落盘身份，用于注册预览。
  ///
  /// 该方法只生成新私钥、助记词和故事，不覆盖当前 vault。调用方必须先完成
  /// 服务端注册，再调用 [replaceCurrentIdentity] 持久化新身份。
  Future<IdentityRegistration> generateRegistrationPreview() async {
    final mnemonic = generateMnemonic();
    final keyPair = HanakoKeyPair.fromPrivateKeyBytes(mnemonic.privateKeyBytes);
    final composition = await composer.compose(mnemonic.words);
    return IdentityRegistration(
      identity: HanakoIdentity(keyPair: keyPair, mnemonic: mnemonic),
      story: composition.story,
      fallback: composition.fallback,
    );
  }

  /// 生成一份新的未落盘身份，用于密钥轮换预览。
  ///
  /// 该方法只生成新私钥、助记词和故事，不覆盖当前 vault。调用方必须先完成
  /// 服务端轮换，再调用 [replaceCurrentIdentity] 持久化新身份。
  Future<IdentityRegistration> generateReplacementIdentityPreview() {
    return generateRegistrationPreview();
  }

  /// 用新身份覆盖本机 vault，并把运行期当前身份切换到新身份。
  Future<void> replaceCurrentIdentity(
    HanakoIdentity identity, {
    String? pin,
  }) async {
    final mnemonic = identity.mnemonic;
    if (mnemonic == null) {
      throw StateError('新身份没有助记词，不能覆盖本机身份 vault');
    }
    await keystore.writeVault(
      IdentityVault(
        privateKey: Uint8List.fromList(identity.keyPair.privateKeyBytes),
        mnemonicIds: mnemonic.words.map((word) => idByWord(word)!).toList(),
        wordlistVersion: hanakoWordlistVersion,
      ),
      pin: pin,
    );
    _current = identity;
  }

  /// 在已登录/已解锁状态下自检一段故事是否能恢复当前身份。
  ///
  /// 这不是词表快捷校验；它复用 [loginWithStory] 的完整解析与矩阵恢复流程。
  /// 目标集合限定为当前身份，避免同一账号存在历史公钥时验证到别的旧身份。
  Future<LoginOutcome> verifyCurrentStory({
    required String storyOrWords,
    String? pin,
    Duration softDeadline = const Duration(minutes: 5),
    Duration hardDeadline = const Duration(minutes: 10),
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
    void Function(StoryRecoveryProgress progress)? onRecoveryProgress,
  }) async {
    final identity = _current ?? await unlock(pin: pin);
    return loginWithStory(
      storyOrWords: storyOrWords,
      pin: pin,
      targetPublicKeyHashes: {identity.publicKeyHash},
      checker: (pub) async => pub == identity.publicKeyHex,
      softDeadline: softDeadline,
      hardDeadline: hardDeadline,
      onProgress: onProgress,
      onRecoveryProgress: onRecoveryProgress,
    );
  }

  /// 用故事恢复长期身份私钥（换设备 / 重装时走这条）。
  ///
  /// [storyOrWords] 可以是模糊故事，也可以直接是逗号 / 空格分隔的词组。
  /// [pin] 仅供非 Windows 文件 fallback 或旧版迁移；Windows 默认由 DPAPI 保护。
  /// [targetPublicKeyHashes] 候选目标公钥哈希集合：
  ///   - 离线自检：本地 keystore 中已存身份的公钥哈希
  ///   - 在线恢复：先调 pubkey-service 把"该用户名下所有历史公钥"拉到本地，再传入
  /// [checker] 主 isolate 二次确认回调。worker isolate 命中 hash 后会传回种子，
  ///   主 isolate 用 [checker] 做最终确认（防 hash 碰撞 + 兼容历史公钥轮换语义）。
  /// [softDeadline] / [hardDeadline] 软 / 硬超时；第一阶段缺省 10 分钟硬预算。
  /// [onProgress] 进度回调，UI 用于显示"已尝试 X 次"。
  Future<LoginOutcome> loginWithStory({
    required String storyOrWords,
    String? pin,
    required Set<String> targetPublicKeyHashes,
    PublicKeyChecker? checker,
    Duration softDeadline = const Duration(minutes: 5),
    Duration hardDeadline = const Duration(minutes: 10),
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
    void Function(StoryRecoveryProgress progress)? onRecoveryProgress,
  }) async {
    void emitAiProgress() {
      onRecoveryProgress?.call(StoryRecoveryProgress.aiSemanticAnalysis());
    }

    void emitMatrixProgress(StoryParseResult result) {
      if (!result.usedLlm) return;
      onRecoveryProgress?.call(
        StoryRecoveryProgress.matrixReady(
          columns: result.columns,
          anchors: result.anchors,
          candidatesPerColumn: result.candidatesPerColumn,
          usedLlm: result.usedLlm,
        ),
      );
    }

    var activeAnchors = const <String>[];

    void emitAnchorProgress(List<String> anchors) {
      activeAnchors = List<String>.unmodifiable(anchors);
      onRecoveryProgress?.call(
        StoryRecoveryProgress.matrixReady(
          columns: [for (final _ in anchors) const <int>[]],
          anchors: anchors,
          candidatesPerColumn: parser.candidatesPerColumn,
          usedLlm: true,
        ),
      );
    }

    void emitCandidateProgress(List<String> anchors, List<List<int>> columns) {
      onRecoveryProgress?.call(
        StoryRecoveryProgress.matrixReady(
          columns: columns,
          anchors: anchors,
          candidatesPerColumn: parser.candidatesPerColumn,
          usedLlm: true,
        ),
      );
    }

    final parsed = await parser.parse(
      storyOrWords,
      onLlm: emitAiProgress,
      onAnchorsReady: emitAnchorProgress,
      onCandidateMatrixProgress: (columns) =>
          emitCandidateProgress(activeAnchors, columns),
    );
    emitMatrixProgress(parsed);
    final firstOutcome = await _recoverParsedStory(
      parsed: parsed,
      pin: pin,
      targetPublicKeyHashes: targetPublicKeyHashes,
      checker: checker,
      softDeadline: softDeadline,
      hardDeadline: hardDeadline,
      onProgress: onProgress,
      onRecoveryProgress: onRecoveryProgress,
    );
    if (firstOutcome.success || parsed.usedLlm) {
      return firstOutcome;
    }

    // 确定性解析只说明故事里能扫出 12 个字典词，不代表用户复述完全正确。
    // 如果这条快速路径恢复失败，继续走 LLM 语义匹配处理同义词、错记和顺序小偏差。
    final semanticParsed = await parser.parse(
      storyOrWords,
      forceLlm: true,
      onLlm: emitAiProgress,
      onAnchorsReady: emitAnchorProgress,
      onCandidateMatrixProgress: (columns) =>
          emitCandidateProgress(activeAnchors, columns),
    );
    emitMatrixProgress(semanticParsed);
    return _recoverParsedStory(
      parsed: semanticParsed,
      pin: pin,
      targetPublicKeyHashes: targetPublicKeyHashes,
      checker: checker,
      softDeadline: softDeadline,
      hardDeadline: hardDeadline,
      onProgress: onProgress,
      onRecoveryProgress: onRecoveryProgress,
    );
  }

  Future<LoginOutcome> _recoverParsedStory({
    required StoryParseResult parsed,
    required String? pin,
    required Set<String> targetPublicKeyHashes,
    required PublicKeyChecker? checker,
    required Duration softDeadline,
    required Duration hardDeadline,
    required void Function(
      int attempted,
      int elapsedMs,
      int currentHammingDistance,
    )?
    onProgress,
    required void Function(StoryRecoveryProgress progress)? onRecoveryProgress,
  }) async {
    if (!parsed.isWellFormed) {
      return LoginOutcome.malformedMatrix(
        parsed.rawResponse,
        usedLlm: parsed.usedLlm,
        parsedColumns: parsed.columns,
        candidatesPerColumn: parsed.candidatesPerColumn,
        anchors: parsed.anchors,
      );
    }

    setKnownPublicKeyHashes(targetPublicKeyHashes);
    final dMaxHard = _hardHammingLimit(parsed.candidatesPerColumn);
    final useAccelerator = parsed.candidatesPerColumn > 1;
    final accelerated = useAccelerator
        ? await _tryAcceleratedRecovery(
            parsed: parsed,
            targetPublicKeyHashes: targetPublicKeyHashes,
            checker: checker,
            dMaxHard: dMaxHard,
            hardDeadline: hardDeadline,
            onProgress: onProgress,
            onRecoveryProgress: onRecoveryProgress,
          )
        : null;
    if (accelerated != null) {
      if (!accelerated.success) {
        return LoginOutcome.failed(
          attempted: accelerated.attempted,
          timedOut: accelerated.timedOut,
          elapsedMs: accelerated.elapsedMs,
          hammingDistance: accelerated.hammingDistance,
          usedLlm: parsed.usedLlm,
          parsedColumns: parsed.columns,
          candidatesPerColumn: parsed.candidatesPerColumn,
          anchors: parsed.anchors,
          rawResponse: parsed.rawResponse,
        );
      }
      final identity = await _persistRecoveredSeed(accelerated.seed!, pin: pin);
      return LoginOutcome.success(
        identity,
        attempted: accelerated.attempted,
        elapsedMs: accelerated.elapsedMs,
        hammingDistance: accelerated.hammingDistance,
        usedLlm: parsed.usedLlm,
        parsedColumns: parsed.columns,
        candidatesPerColumn: parsed.candidatesPerColumn,
        anchors: parsed.anchors,
        rawResponse: parsed.rawResponse,
      );
    }

    final reportMatrixProgress = parsed.candidatesPerColumn > 1;
    final recovery = Recovery(
      checker: checker ?? ((pub) async => targetPublicKeyHashes.isNotEmpty),
      kPerColumn: parsed.candidatesPerColumn,
      dMaxSoft: _softHammingLimit(parsed.candidatesPerColumn),
      dMaxHard: dMaxHard,
      softDeadline: softDeadline,
      hardDeadline: hardDeadline,
      onProgress:
          !reportMatrixProgress ||
              (onProgress == null && onRecoveryProgress == null)
          ? null
          : (p) {
              onProgress?.call(
                p.attempted,
                p.elapsedMs,
                p.currentHammingDistance,
              );
              onRecoveryProgress?.call(
                StoryRecoveryProgress.matrixRecovery(
                  attempted: p.attempted,
                  elapsedMs: p.elapsedMs,
                  currentHammingDistance: p.currentHammingDistance,
                  combinationId: p.combinationId,
                  candidateRanks: p.candidateRanks,
                  wordIds: p.wordIds,
                  activePositions: p.activePositions,
                ),
              );
            },
    );
    final outcome = await recovery.tryRecover(parsed.columns);
    if (!outcome.success) {
      return LoginOutcome.failed(
        attempted: outcome.attempted,
        timedOut: outcome.timedOut,
        elapsedMs: outcome.elapsedMs,
        hammingDistance: outcome.hammingDistance,
        usedLlm: parsed.usedLlm,
        parsedColumns: parsed.columns,
        candidatesPerColumn: parsed.candidatesPerColumn,
        anchors: parsed.anchors,
        rawResponse: parsed.rawResponse,
      );
    }
    final identity = await _persistRecoveredSeed(outcome.seed!, pin: pin);
    return LoginOutcome.success(
      identity,
      attempted: outcome.attempted,
      elapsedMs: outcome.elapsedMs,
      hammingDistance: outcome.hammingDistance,
      usedLlm: parsed.usedLlm,
      parsedColumns: parsed.columns,
      candidatesPerColumn: parsed.candidatesPerColumn,
      anchors: parsed.anchors,
      rawResponse: parsed.rawResponse,
    );
  }

  Future<_RecoveredSeedResult?> _tryAcceleratedRecovery({
    required StoryParseResult parsed,
    required Set<String> targetPublicKeyHashes,
    required PublicKeyChecker? checker,
    required int dMaxHard,
    required Duration hardDeadline,
    required void Function(
      int attempted,
      int elapsedMs,
      int currentHammingDistance,
    )?
    onProgress,
    required void Function(StoryRecoveryProgress progress)? onRecoveryProgress,
  }) async {
    final accelerator = recoveryAccelerator;
    if (accelerator == null || targetPublicKeyHashes.isEmpty) {
      return null;
    }
    void emitProgress(AcceleratedRecoveryProgress progress) {
      onProgress?.call(
        progress.attempted,
        progress.elapsedMs,
        progress.currentHammingDistance,
      );
      onRecoveryProgress?.call(
        StoryRecoveryProgress.matrixRecovery(
          attempted: progress.attempted,
          elapsedMs: progress.elapsedMs,
          currentHammingDistance: progress.currentHammingDistance,
          combinationId: progress.combinationId,
          candidateRanks: progress.candidateRanks,
          wordIds: progress.wordIds,
          activePositions: progress.activePositions,
        ),
      );
    }

    try {
      final outcome = await accelerator.tryRecover(
        matrix: parsed.columns,
        targetPublicKeyHashes: targetPublicKeyHashes,
        dMaxHard: dMaxHard,
        hardDeadline: hardDeadline,
        onProgress: emitProgress,
      );
      emitProgress(
        AcceleratedRecoveryProgress(
          attempted: outcome.attempted,
          elapsedMs: outcome.elapsedMs,
          currentHammingDistance: outcome.hammingDistance,
        ),
      );
      if (!outcome.found) {
        return _RecoveredSeedResult.failed(
          attempted: outcome.attempted,
          timedOut: outcome.timedOut,
          elapsedMs: outcome.elapsedMs,
          hammingDistance: outcome.hammingDistance,
        );
      }
      final ids = outcome.ids;
      final publicKeyHex = outcome.publicKeyHex;
      if (ids == null ||
          ids.length != kMnemonicLength ||
          publicKeyHex == null) {
        return null;
      }
      if (checker != null && !await checker(publicKeyHex)) {
        return null;
      }
      final seed = tryMnemonicFromIds(ids);
      if (seed == null) {
        return null;
      }
      return _RecoveredSeedResult.success(
        seed,
        attempted: outcome.attempted,
        elapsedMs: outcome.elapsedMs,
        hammingDistance: outcome.hammingDistance,
      );
    } catch (_) {
      return null;
    }
  }

  Future<HanakoIdentity> _persistRecoveredSeed(
    MnemonicSeed seed, {
    required String? pin,
  }) async {
    final keyPair = HanakoKeyPair.fromPrivateKeyBytes(seed.privateKeyBytes);
    await keystore.writeVault(
      IdentityVault(
        privateKey: Uint8List.fromList(keyPair.privateKeyBytes),
        mnemonicIds: seed.words.map((word) => idByWord(word)!).toList(),
        wordlistVersion: hanakoWordlistVersion,
      ),
      pin: pin,
    );
    final identity = HanakoIdentity(keyPair: keyPair, mnemonic: seed);
    _current = identity;
    return identity;
  }

  /// 注销：清空内存身份并删除本地密钥库（不可逆）。
  Future<void> logout() async {
    _current = null;
    await keystore.deleteAll();
  }

  /// 锁定：只清空本进程内的身份，不删除本机加密 vault。
  Future<void> lock() async {
    _current = null;
  }

  /// 仅供测试：手动塞一个身份进去。
  @visibleForTesting
  void debugSetCurrent(HanakoIdentity? id) => _current = id;
}

int _softHammingLimit(int candidatesPerColumn) {
  if (candidatesPerColumn <= 1) return 0;
  if (candidatesPerColumn == 2) return 8;
  return 3;
}

int _hardHammingLimit(int candidatesPerColumn) {
  if (candidatesPerColumn <= 1) return 0;
  return kMnemonicLength;
}

MnemonicSeed? _mnemonicFromVault(IdentityVault vault) {
  final ids = vault.mnemonicIds;
  if (ids == null) return null;
  final seed = tryMnemonicFromIds(ids);
  if (seed == null) {
    throw StateError('身份 vault 中的助记词 ID 组校验失败');
  }
  return seed;
}

class _RecoveredSeedResult {
  _RecoveredSeedResult.success(
    this.seed, {
    required this.attempted,
    required this.elapsedMs,
    required this.hammingDistance,
  }) : timedOut = false;

  _RecoveredSeedResult.failed({
    required this.attempted,
    required this.timedOut,
    required this.elapsedMs,
    required this.hammingDistance,
  }) : seed = null;

  final MnemonicSeed? seed;
  final int attempted;
  final bool timedOut;
  final int elapsedMs;
  final int hammingDistance;

  bool get success => seed != null;
}

/// 登录尝试结果。
class LoginOutcome {
  LoginOutcome._({
    this.identity,
    this.malformed = false,
    this.failed = false,
    this.timedOut = false,
    this.attempted = 0,
    this.elapsedMs = 0,
    this.hammingDistance = 0,
    this.usedLlm = false,
    this.parsedColumns = const [],
    this.candidatesPerColumn = 0,
    this.anchors = const [],
    this.rawResponse,
  });

  factory LoginOutcome.success(
    HanakoIdentity identity, {
    required int attempted,
    required int elapsedMs,
    required int hammingDistance,
    required bool usedLlm,
    List<List<int>> parsedColumns = const [],
    int candidatesPerColumn = 0,
    List<String> anchors = const [],
    String? rawResponse,
  }) => LoginOutcome._(
    identity: identity,
    attempted: attempted,
    elapsedMs: elapsedMs,
    hammingDistance: hammingDistance,
    usedLlm: usedLlm,
    parsedColumns: _copyMatrix(parsedColumns),
    candidatesPerColumn: candidatesPerColumn,
    anchors: List<String>.unmodifiable(anchors),
    rawResponse: rawResponse,
  );

  factory LoginOutcome.malformedMatrix(
    String rawResponse, {
    bool usedLlm = false,
    List<List<int>> parsedColumns = const [],
    int candidatesPerColumn = 0,
    List<String> anchors = const [],
  }) => LoginOutcome._(
    malformed: true,
    rawResponse: rawResponse,
    usedLlm: usedLlm,
    parsedColumns: _copyMatrix(parsedColumns),
    candidatesPerColumn: candidatesPerColumn,
    anchors: List<String>.unmodifiable(anchors),
  );

  factory LoginOutcome.failed({
    required int attempted,
    required bool timedOut,
    required int elapsedMs,
    required int hammingDistance,
    required bool usedLlm,
    List<List<int>> parsedColumns = const [],
    int candidatesPerColumn = 0,
    List<String> anchors = const [],
    String? rawResponse,
  }) => LoginOutcome._(
    failed: true,
    attempted: attempted,
    timedOut: timedOut,
    elapsedMs: elapsedMs,
    hammingDistance: hammingDistance,
    usedLlm: usedLlm,
    parsedColumns: _copyMatrix(parsedColumns),
    candidatesPerColumn: candidatesPerColumn,
    anchors: List<String>.unmodifiable(anchors),
    rawResponse: rawResponse,
  );

  final HanakoIdentity? identity;

  /// LLM 输出不符合矩阵协议（缺列、ID 越界、JSON 解析失败等）。
  final bool malformed;
  final bool failed;
  final bool timedOut;
  final int attempted;
  final int elapsedMs;
  final int hammingDistance;
  final bool usedLlm;
  final List<List<int>> parsedColumns;
  final int candidatesPerColumn;
  final List<String> anchors;

  /// LLM 原始响应（malformed 时保留供调试）。
  final String? rawResponse;

  bool get success => identity != null;
}

List<List<int>> _copyMatrix(List<List<int>> matrix) {
  return List<List<int>>.unmodifiable([
    for (final row in matrix) List<int>.unmodifiable(row),
  ]);
}

// ---- 默认离线 hash 集合：从本地 keystore 取已存身份的公钥哈希 -------------

/// 离线场景：拿出本地 keystore 中已存身份的公钥哈希作为目标集合。
/// 仅用于"同一设备重装"等罕见场景，正式登录请走联网（先调 pubkey-service
/// 把候选范围拉到本地，再注入到 [IdentityRepository.loginWithStory]）。
Future<Set<String>> offlineTargetHashesFromKeystore({
  required SecureKeystore keystore,
  String? pin,
}) async {
  if (!await keystore.exists()) return const {};
  try {
    final priv = await keystore.readPrivateKey(pin: pin);
    final pair = HanakoKeyPair.fromPrivateKeyBytes(priv);
    return {pair.publicKeyHash};
  } catch (_) {
    return const {};
  }
}

// 本文件保留对 dart:io 的依赖，但 checker 工厂仅在桌面端使用——纯算法层
// （keypair/mnemonic/recovery）依旧无 IO 依赖，方便单测。
// ignore: unused_element
void _ioGuard() => Platform.isWindows;
