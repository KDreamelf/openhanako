// lib/identity/identity_repository.dart
//
// Identity 模块业务封装。把 keypair / mnemonic / keystore / 故事生成与解析
// / 恢复 串成几个高层 API，让 UI 层（OnboardingPage / LoginPage）只面对
// "注册一份新身份"、"用故事登录"、"加载已保存身份" 这几件事。
//
// 与未来用户后端的对接点：
//   - registerNew() 完成后会调用 [PubkeyRegistrar.upload] 把新公钥上报；
//     当前未实装，留 hook，本地先把身份写入平台 keystore。
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

class IdentityRepository {
  IdentityRepository({
    required this.keystore,
    required this.composer,
    required this.parser,
  });

  final SecureKeystore keystore;
  final StoryComposer composer;
  final StoryParser parser;

  /// 当前进程内已加载的身份。null 表示尚未持有长期身份私钥。
  HanakoIdentity? _current;
  HanakoIdentity? get current => _current;

  /// 是否已有保存过的身份（首次启动判断用）。
  Future<bool> hasSavedIdentity() => keystore.exists();

  /// 注册：本地生成 ECDSA 密钥对、派生助记词、调 LLM 编故事、写入密钥库。
  ///
  Future<IdentityRegistration> registerNew({String? pin}) async {
    final mnemonic = generateMnemonic();
    final keyPair = HanakoKeyPair.fromPrivateKeyBytes(mnemonic.privateKeyBytes);

    // LLM 故事生成（失败兜底，不阻塞主流程）。
    final composition = await composer.compose(mnemonic.words);

    // 私钥与助记词 ID 组落地存储；Windows 默认由 DPAPI 保护 vault DEK。
    await keystore.writeVault(
      IdentityVault(
        privateKey: Uint8List.fromList(keyPair.privateKeyBytes),
        mnemonicIds: mnemonic.words.map((word) => idByWord(word)!).toList(),
        wordlistVersion: hanakoWordlistVersion,
      ),
      pin: pin,
    );

    final identity = HanakoIdentity(keyPair: keyPair, mnemonic: mnemonic);
    _current = identity;

    // TODO: 等用户后端就位后，这里把 keyPair.publicKeyHex 上报到 pubkey-service。
    //       现在先只在本地完成注册，子体可以离线运转。

    return IdentityRegistration(
      identity: identity,
      story: composition.story,
      fallback: composition.fallback,
    );
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

  /// 在已登录/已解锁状态下自检一段故事是否能恢复当前身份。
  ///
  /// 这不是词表快捷校验；它复用 [loginWithStory] 的完整解析与矩阵恢复流程。
  /// 目标集合限定为当前身份，避免同一账号存在历史公钥时验证到别的旧身份。
  Future<LoginOutcome> verifyCurrentStory({
    required String storyOrWords,
    String? pin,
    Duration softDeadline = const Duration(seconds: 30),
    Duration hardDeadline = const Duration(seconds: 30),
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
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
  /// [softDeadline] / [hardDeadline] 软 / 硬超时；第一阶段缺省 30 秒。
  /// [onProgress] 进度回调，UI 用于显示"已尝试 X 次"。
  Future<LoginOutcome> loginWithStory({
    required String storyOrWords,
    String? pin,
    required Set<String> targetPublicKeyHashes,
    PublicKeyChecker? checker,
    Duration softDeadline = const Duration(seconds: 30),
    Duration hardDeadline = const Duration(seconds: 30),
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
  }) async {
    final parsed = await parser.parse(storyOrWords);
    if (!parsed.isWellFormed) {
      return LoginOutcome.malformedMatrix(parsed.rawResponse);
    }

    setKnownPublicKeyHashes(targetPublicKeyHashes);
    final recovery = Recovery(
      checker: checker ?? ((pub) async => targetPublicKeyHashes.isNotEmpty),
      kPerColumn: parsed.candidatesPerColumn,
      softDeadline: softDeadline,
      hardDeadline: hardDeadline,
      onProgress: onProgress == null
          ? null
          : (p) =>
                onProgress(p.attempted, p.elapsedMs, p.currentHammingDistance),
    );
    final outcome = await recovery.tryRecover(parsed.columns);
    if (!outcome.success) {
      return LoginOutcome.failed(
        attempted: outcome.attempted,
        timedOut: outcome.timedOut,
        elapsedMs: outcome.elapsedMs,
      );
    }
    final seed = outcome.seed!;
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
    return LoginOutcome.success(
      identity,
      attempted: outcome.attempted,
      elapsedMs: outcome.elapsedMs,
    );
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

MnemonicSeed? _mnemonicFromVault(IdentityVault vault) {
  final ids = vault.mnemonicIds;
  if (ids == null) return null;
  final seed = tryMnemonicFromIds(ids);
  if (seed == null) {
    throw StateError('身份 vault 中的助记词 ID 组校验失败');
  }
  return seed;
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
    this.rawResponse,
  });

  factory LoginOutcome.success(
    HanakoIdentity identity, {
    required int attempted,
    required int elapsedMs,
  }) => LoginOutcome._(
    identity: identity,
    attempted: attempted,
    elapsedMs: elapsedMs,
  );

  factory LoginOutcome.malformedMatrix(String rawResponse) =>
      LoginOutcome._(malformed: true, rawResponse: rawResponse);

  factory LoginOutcome.failed({
    required int attempted,
    required bool timedOut,
    required int elapsedMs,
  }) => LoginOutcome._(
    failed: true,
    attempted: attempted,
    timedOut: timedOut,
    elapsedMs: elapsedMs,
  );

  final HanakoIdentity? identity;

  /// LLM 输出不符合矩阵协议（缺列、ID 越界、JSON 解析失败等）。
  final bool malformed;
  final bool failed;
  final bool timedOut;
  final int attempted;
  final int elapsedMs;

  /// LLM 原始响应（malformed 时保留供调试）。
  final String? rawResponse;

  bool get success => identity != null;
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
