// test/identity_test.dart
//
// Identity 模块端到端测试：
//   1. 注册 → 12 词 → 派生私钥 → 公钥可验签自洽；
//   2. 同样的 12 词二次输入能还原同一私钥；
//   3. 错一个词 → 助记词校验失败；
//   4. SecureKeystore 写入 / 读取 / PIN 错抛 InvalidPinException；
//   5. Recovery 在已知公钥下能从打乱顺序的 ID 恢复。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';
import 'package:path/path.dart' as p;

void main() {
  group('keypair', () {
    test('生成 → 自洽签名 / 验签', () {
      final pair = HanakoKeyPair.generate();
      final msg = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final sig = pair.sign(msg);
      expect(sig.length, 64);
      expect(
        HanakoKeyPair.verify(
          message: msg,
          signature64: sig,
          publicKeyBytes65: pair.publicKeyBytes,
        ),
        isTrue,
      );
    });

    test('私钥还原产生同一公钥', () {
      final pair1 = HanakoKeyPair.generate();
      final pair2 = HanakoKeyPair.fromPrivateKeyBytes(pair1.privateKeyBytes);
      expect(pair2.publicKeyHex, pair1.publicKeyHex);
    });
  });

  group('mnemonic', () {
    test('生成 → 用同样的词重新派生 → 同一私钥', () {
      final m1 = generateMnemonic();
      final m2 = mnemonicFromWords(m1.words);
      expect(m2.privateKeyBytes, m1.privateKeyBytes);
    });

    test('错一个词 → 校验失败', () {
      final m = generateMnemonic();
      // 寻找一个能让 BIP-39 4-bit 校验位失败的替换词。
      // 校验位通过率 ~1/16，所以单词替换有 ~1/16 概率不触发 FormatException。
      // 这里循环找到一个明确触发校验失败的词，避免测试随机失败。
      String? badSwap;
      for (final w in hanakoWordlist) {
        if (w == m.words.first) continue;
        final candidate = [w, ...m.words.sublist(1)];
        try {
          mnemonicFromWords(candidate);
        } on FormatException {
          badSwap = w;
          break;
        }
      }
      expect(badSwap, isNotNull, reason: '字典里至少应有一个词替换后让校验失败');
      final wrong = [badSwap!, ...m.words.sublist(1)];
      expect(() => mnemonicFromWords(wrong), throwsFormatException);
    });

    test('词不在字典里 → ArgumentError', () {
      final m = generateMnemonic();
      final wrong = ['不存在的词', ...m.words.sublist(1)];
      expect(() => mnemonicFromWords(wrong), throwsArgumentError);
    });
  });

  group('secure_keystore', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hanako_id_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('写入 → 读取 → PIN 正确', () async {
      final ks = FileSecureKeystore(hanaHome: tmp);
      final priv = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      await ks.writePrivateKey(priv, pin: '123456');
      final back = await ks.readPrivateKey(pin: '123456');
      expect(back, priv);
    });

    test('PIN 错 → InvalidPinException', () async {
      final ks = FileSecureKeystore(hanaHome: tmp);
      final priv = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      await ks.writePrivateKey(priv, pin: '123456');
      expect(
        () => ks.readPrivateKey(pin: 'wrong'),
        throwsA(isA<InvalidPinException>()),
      );
    });

    test('exists / delete', () async {
      final ks = FileSecureKeystore(hanaHome: tmp);
      expect(await ks.exists(), isFalse);
      await ks.writePrivateKey(Uint8List(32), pin: '0000');
      expect(await ks.exists(), isTrue);
      await ks.deleteAll();
      expect(await ks.exists(), isFalse);
    });

    test('文件路径在 identity/keystore.bin', () async {
      final ks = FileSecureKeystore(hanaHome: tmp);
      await ks.writePrivateKey(Uint8List(32), pin: '0000');
      final f = File(p.join(tmp.path, 'identity', 'keystore.bin'));
      expect(await f.exists(), isTrue);
    });

    test('vault 写入私钥与助记词 ID 组', () async {
      final ks = FileSecureKeystore(hanaHome: tmp);
      final mnemonic = generateMnemonic();
      final pair = HanakoKeyPair.fromPrivateKeyBytes(mnemonic.privateKeyBytes);
      final ids = mnemonic.words.map((word) => idByWord(word)!).toList();

      await ks.writeVault(
        IdentityVault(
          privateKey: Uint8List.fromList(pair.privateKeyBytes),
          mnemonicIds: ids,
          wordlistVersion: hanakoWordlistVersion,
        ),
        pin: '123456',
      );
      final vault = await ks.readVault(pin: '123456');
      expect(vault.privateKey, pair.privateKeyBytes);
      expect(vault.mnemonicIds, ids);
      expect(vault.wordlistVersion, hanakoWordlistVersion);
    });

    test('Windows DPAPI vault 可写入读取', () async {
      if (!Platform.isWindows) {
        markTestSkipped('DPAPI 仅在 Windows 上测试');
        return;
      }
      final ks = WindowsDpapiKeystore(hanaHome: tmp, promptOnRead: false);
      final privateKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final ids = List<int>.generate(12, (i) => i + 1);

      await ks.writeVault(
        IdentityVault(
          privateKey: privateKey,
          mnemonicIds: ids,
          wordlistVersion: hanakoWordlistVersion,
        ),
      );
      final vault = await ks.readVault();
      expect(vault.privateKey, privateKey);
      expect(vault.mnemonicIds, ids);
      expect(
        await File(p.join(tmp.path, 'identity', 'keystore.dpapi')).exists(),
        isTrue,
      );
    });
  });

  group('recovery', () {
    test('StoryComposer prompt 强制固定顺序且禁止可见编号', () {
      final prompt = StoryComposer.systemPromptForTesting;
      expect(prompt, contains('严格按用户输入顺序'));
      expect(prompt, contains('不要输出任何编号'));
      expect(prompt, contains('连续移动路径'));
      expect(prompt, contains('不要堆砌额外实体名词'));
      expect(prompt, isNot(contains('①②③④⑤⑥⑦⑧⑨⑩⑪⑫')));
    });

    test('StoryComposer 会清理模型误加的顺序标记', () async {
      final words = hanakoWordlist.take(4).toList(growable: false);
      final composer = StoryComposer(
        caller:
            ({
              required String systemPrompt,
              required String userPrompt,
              int? maxTokens,
            }) async =>
                '①${words[0]}撞开②${words[1]}，（3）${words[2]}飞进第十二站${words[3]}',
      );

      final result = await composer.compose([
        ...words,
        ...hanakoWordlist.skip(4).take(8),
      ]);

      expect(result.story, contains(words[0]));
      expect(result.story, contains(words[1]));
      expect(result.story, contains(words[2]));
      expect(result.story, contains(words[3]));
      expect(result.story, isNot(contains('①')));
      expect(result.story, isNot(contains('②')));
      expect(result.story, isNot(contains('（3）')));
      expect(result.story, isNot(contains('第十二站')));
    });

    test('StoryParser 默认第一阶段输出 top-5 矩阵', () async {
      final parser = StoryParser(
        caller: _semanticCaller(
          () => [
            for (var row = 0; row < 12; row++)
              [row * 5 + 1, row * 5 + 2, row * 5 + 3, row * 5 + 4, row * 5 + 5],
          ],
        ),
      );

      final parsed = await parser.parse('测试故事');
      expect(parsed.candidatesPerColumn, 5);
      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns.first, [1, 2, 3, 4, 5]);
    });

    test('StoryParser 会把锚点数量错误反馈给 LLM 重试', () async {
      var anchorCalls = 0;
      final parser = StoryParser(
        caller:
            ({
              required String systemPrompt,
              required String userPrompt,
              int? maxTokens,
            }) async {
              if (systemPrompt.contains('锚点提取器')) {
                anchorCalls++;
              }
              if (anchorCalls == 1) {
                return jsonEncode({
                  'anchors': [for (var row = 0; row < 14; row++) '锚$row'],
                });
              }
              if (anchorCalls == 2 && systemPrompt.contains('锚点提取器')) {
                expect(userPrompt, contains('不符合协议'));
                expect(userPrompt, contains('你输出了 14 个'));
                expect(userPrompt, contains('重新判断 12 个记忆锚点'));
                return jsonEncode({
                  'anchors': [for (var row = 0; row < 12; row++) '锚$row'],
                });
              }
              return jsonEncode({'candidates': List.filled(5, 0)});
            },
      );

      final parsed = await parser.parse('多出背景词的复述故事');

      expect(anchorCalls, 2);
      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns, hasLength(12));
      expect(parsed.columns.first, List.filled(5, 0));
    });

    test('StoryParser prompt 要求为错记近义词保留 top-5 候选', () {
      final parser = StoryParser(
        caller:
            ({
              required String systemPrompt,
              required String userPrompt,
              int? maxTokens,
            }) async => throw StateError('不应调用 LLM'),
      );
      final prompt = parser.systemPromptForTesting;

      expect(prompt, contains('凳子/板凳'));
      expect(prompt, contains('石台'));
      expect(prompt, contains('冷风'));
      expect(prompt, contains('立夏的凉粉摊'));
      expect(prompt, contains('涟漪/阳光/人群'));
      expect(prompt, contains('5 个候选'));
    });

    test('StoryParser 直接识别 12 个准确助记词，不调用 LLM', () async {
      final mnemonic = generateMnemonic();
      final ids = mnemonic.words.map((word) => idByWord(word)!).toList();
      final parser = StoryParser(
        caller:
            ({
              required String systemPrompt,
              required String userPrompt,
              int? maxTokens,
            }) async => throw StateError('不应调用 LLM'),
      );

      final parsed = await parser.parse(mnemonic.words.join('，'));
      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns.map((column) => column.first).toList(), ids);
      expect(parsed.columns.every((column) => column.length == 1), isTrue);
    });

    test('StoryParser 直接识别故事正文里的 12 个准确助记词，不调用 LLM', () async {
      final words = hanakoWordlist.take(12).toList(growable: false);
      final ids = words.map((word) => idByWord(word)!).toList();
      final parser = StoryParser(
        caller:
            ({
              required String systemPrompt,
              required String userPrompt,
              int? maxTokens,
            }) async => throw StateError('不应调用 LLM'),
      );

      final story = words.map((word) => '$word突然发光').join('，');
      final parsed = await parser.parse(story);

      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns.map((column) => column.first).toList(), ids);
      expect(parsed.columns.every((column) => column.length == 1), isTrue);
    });

    test('StoryParser 故事正文出现额外字典词时回退 LLM 解析', () async {
      final words = hanakoWordlist.take(13).toList(growable: false);
      var called = false;
      final parser = StoryParser(
        caller: _semanticCaller(
          () => [
            for (var row = 0; row < 12; row++)
              [row * 2 + 1, row * 2 + 2, row * 2 + 1, row * 2 + 1, row * 2 + 1],
          ],
          onCall: (systemPrompt, userPrompt) => called = true,
        ),
      );

      final parsed = await parser.parse(words.join('，'));

      expect(called, isTrue);
      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns.first.take(2), [1, 2]);
    });

    test('StoryParser 故事正文含同义词时保留 LLM 容错解析', () async {
      final words = hanakoWordlist.take(12).toList(growable: false);
      var called = false;
      final parser = StoryParser(
        caller: _semanticCaller(
          () => [
            for (var row = 0; row < 12; row++)
              [row * 2 + 1, row * 2 + 2, row * 2 + 1, row * 2 + 1, row * 2 + 1],
          ],
          onCall: (systemPrompt, userPrompt) => called = true,
        ),
      );

      final story = [
        ...words.take(5),
        '西红柿',
        ...words.skip(6),
      ].map((word) => '$word突然发光').join('，');
      final parsed = await parser.parse(story);

      expect(called, isTrue);
      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns.first.take(2), [1, 2]);
    });

    test('StoryParser 可为 RFA 深度恢复显式输出 top-3 矩阵', () async {
      final parser = StoryParser(
        candidatesPerColumn: 3,
        caller: _semanticCaller(
          () => [
            for (var row = 0; row < 12; row++)
              [row * 3 + 1, row * 3 + 2, row * 3 + 3],
          ],
        ),
      );

      final parsed = await parser.parse('测试故事');
      expect(parsed.candidatesPerColumn, 3);
      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns.first, [1, 2, 3]);
    });

    test('矩阵搜索：rank-0 命中 → 立即成功（D=0）', () async {
      final m = generateMnemonic();
      final pair = HanakoKeyPair.fromPrivateKeyBytes(m.privateKeyBytes);
      final ids = m.words.map((w) => idByWord(w)!).toList();

      // 12×3 矩阵，rank-0 是真实 ID，rank-1/2 随便填（不会被尝试）。
      final matrix = [
        for (final id in ids)
          [id, (id + 1) % hanakoWordlistSize, (id + 2) % hanakoWordlistSize],
      ];

      setKnownPublicKeyHashes({pair.publicKeyHash});
      final recovery = Recovery(
        checker: (pub) async => pub == pair.publicKeyHex,
        kPerColumn: 3,
        dMaxSoft: 1,
        dMaxHard: 1, // 只搜 D=0,1
        softDeadline: const Duration(seconds: 30),
        hardDeadline: const Duration(seconds: 60),
        workerCount: 2,
      );

      final outcome = await recovery.tryRecover(matrix);
      expect(outcome.success, isTrue, reason: 'rank-0 命中应立即成功');
      expect(outcome.seed!.privateKeyBytes, m.privateKeyBytes);
    });

    test('矩阵搜索：D=2 时正确词在 rank-1 → 应找到', () async {
      final m = generateMnemonic();
      final pair = HanakoKeyPair.fromPrivateKeyBytes(m.privateKeyBytes);
      final ids = m.words.map((w) => idByWord(w)!).toList();

      // 故意把第 0、5 列的 rank-0 设错，正确 ID 放 rank-1
      final matrix = [
        for (var i = 0; i < ids.length; i++)
          if (i == 0 || i == 5)
            [
              (ids[i] + 100) % hanakoWordlistSize,
              ids[i],
              (ids[i] + 200) % hanakoWordlistSize,
            ]
          else
            [
              ids[i],
              (ids[i] + 1) % hanakoWordlistSize,
              (ids[i] + 2) % hanakoWordlistSize,
            ],
      ];

      setKnownPublicKeyHashes({pair.publicKeyHash});
      final recovery = Recovery(
        checker: (pub) async => pub == pair.publicKeyHex,
        kPerColumn: 3,
        dMaxSoft: 4,
        dMaxHard: 4,
        softDeadline: const Duration(minutes: 2),
        hardDeadline: const Duration(minutes: 3),
        workerCount: 2,
      );

      final outcome = await recovery.tryRecover(matrix);
      expect(outcome.success, isTrue, reason: 'D=2 内应能找到（实际汉明距离=2）');
      expect(outcome.seed!.privateKeyBytes, m.privateKeyBytes);
    });

    test('矩阵列数不对 → 立即失败', () async {
      final recovery = Recovery(checker: (_) async => false, workerCount: 1);
      final outcome = await recovery.tryRecover([
        [1, 2, 3],
        [4, 5, 6],
      ]);
      expect(outcome.failed, isTrue);
      expect(outcome.timedOut, isFalse);
    });
  });

  group('identity_repository', () {
    late Directory tmp;
    late IdentityRepository repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hanako_repo_test_');
      repo = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: StoryComposer(
          // 测试中的 LLM caller：直接返回固定故事，避免外部依赖。
          caller:
              ({
                required String systemPrompt,
                required String userPrompt,
                int? maxTokens,
              }) async => '测试故事：$userPrompt',
        ),
        parser: StoryParser(
          caller:
              ({
                required String systemPrompt,
                required String userPrompt,
                int? maxTokens,
              }) async => '', // 不用解析路径
        ),
      );
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('registerNew → 写入 keystore → unlock 还原同一身份与助记词', () async {
      final reg = await repo.registerNew(pin: '1234');
      expect(reg.identity.mnemonic!.words.length, 12);
      expect(reg.story, isNotEmpty);
      expect(reg.fallback, isFalse);

      final originalPub = reg.identity.publicKeyHex;
      final originalWords = reg.identity.mnemonic!.words;
      // 重开 repo 模拟新会话。
      final repo2 = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: repo.composer,
        parser: repo.parser,
      );
      final loaded = await repo2.unlock(pin: '1234');
      expect(loaded.publicKeyHex, originalPub);
      expect(loaded.mnemonic!.words, originalWords);
    });

    test('regenerateStoryForCurrent → 使用已保存助记词重新生成故事', () async {
      var calls = 0;
      final repo2 = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: StoryComposer(
          caller:
              ({
                required String systemPrompt,
                required String userPrompt,
                int? maxTokens,
              }) async {
                calls++;
                return '第 $calls 版故事：$userPrompt';
              },
        ),
        parser: repo.parser,
      );

      final reg = await repo2.registerNew(pin: '1234');
      final originalWords = reg.words;
      await repo2.lock();

      final regenerated = await repo2.regenerateStoryForCurrent(pin: '1234');
      expect(regenerated.words, originalWords);
      expect(regenerated.story, startsWith('第 2 版故事：'));
      expect(regenerated.fallback, isFalse);
    });

    test('verifyCurrentStory → 不退出登录也走恢复链路验证当前身份', () async {
      final reg = await repo.registerNew(pin: '1234');
      final originalHash = reg.identity.publicKeyHash;
      await repo.lock();

      final outcome = await repo.verifyCurrentStory(
        storyOrWords: reg.words.join(' '),
        pin: '1234',
        softDeadline: const Duration(seconds: 5),
        hardDeadline: const Duration(seconds: 5),
      );

      expect(outcome.success, isTrue);
      expect(outcome.identity!.publicKeyHash, originalHash);
      expect(repo.current!.publicKeyHash, originalHash);
      expect(outcome.usedLlm, isFalse);
      expect(outcome.hammingDistance, 0);
      expect(outcome.candidatesPerColumn, 1);
      expect(outcome.parsedColumns, hasLength(12));
      expect(outcome.parsedColumns.first, [idByWord(reg.words.first)]);
    });

    test('loginWithStory → 精确恢复快速路径不走恢复加速后端', () async {
      var targetIds = <int>[];
      final accelerator = _FakeRecoveryAccelerator(() => targetIds);
      final repo2 = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: repo.composer,
        parser: repo.parser,
        recoveryAccelerator: accelerator,
      );

      final reg = await repo2.registerNew(pin: '1234');
      targetIds = reg.words.map((word) => idByWord(word)!).toList();

      final outcome = await repo2.verifyCurrentStory(
        storyOrWords: reg.words.join(' '),
        pin: '1234',
        softDeadline: const Duration(seconds: 5),
        hardDeadline: const Duration(seconds: 5),
      );

      expect(accelerator.calls, 0);
      expect(outcome.success, isTrue);
      expect(outcome.identity!.publicKeyHash, reg.identity.publicKeyHash);
      expect(outcome.hammingDistance, 0);
      expect(accelerator.lastDMaxHard, isNull);
    });

    test('loginWithStory → top-5 语义矩阵由时间预算控制搜索深度', () async {
      var targetIds = <int>[];
      final accelerator = _FakeRecoveryAccelerator(() => targetIds);
      final repo2 = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: repo.composer,
        parser: StoryParser(
          caller: _semanticCaller(
            () => [for (final id in targetIds) List.filled(5, id)],
          ),
        ),
        recoveryAccelerator: accelerator,
      );

      final reg = await repo2.registerNew(pin: '1234');
      targetIds = reg.words.map((word) => idByWord(word)!).toList();

      final outcome = await repo2.verifyCurrentStory(
        storyOrWords: '模糊复述故事',
        pin: '1234',
        softDeadline: const Duration(seconds: 5),
        hardDeadline: const Duration(seconds: 5),
      );

      expect(outcome.success, isTrue);
      expect(outcome.usedLlm, isTrue);
      expect(outcome.candidatesPerColumn, 5);
      expect(accelerator.lastDMaxHard, 12);
    });

    test('loginWithStory → 确定性恢复失败后回退 LLM 语义解析', () async {
      var anchorCalls = 0;
      var targetIds = <int>[];
      final repo2 = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: repo.composer,
        parser: StoryParser(
          caller: _semanticCaller(
            () => [for (final id in targetIds) List.filled(5, id)],
            onCall: (systemPrompt, _) {
              if (systemPrompt.contains('锚点提取器')) {
                anchorCalls++;
              }
            },
          ),
        ),
      );

      final reg = await repo2.registerNew(pin: '1234');
      targetIds = reg.words.map((word) => idByWord(word)!).toList();
      final recalled = [
        reg.words[1],
        reg.words[0],
        ...reg.words.skip(2),
      ].join('，');

      final outcome = await repo2.verifyCurrentStory(
        storyOrWords: recalled,
        pin: '1234',
        softDeadline: const Duration(seconds: 5),
        hardDeadline: const Duration(seconds: 5),
      );

      expect(anchorCalls, 1);
      expect(outcome.success, isTrue);
      expect(outcome.identity!.publicKeyHash, reg.identity.publicKeyHash);
      expect(outcome.usedLlm, isTrue);
      expect(outcome.hammingDistance, 0);
      expect(outcome.candidatesPerColumn, 5);
      expect(outcome.parsedColumns.first, List.filled(5, targetIds.first));
    });

    test('LLM 失败 → fallback=true，账号仍然生成', () async {
      final repo2 = IdentityRepository(
        keystore: FileSecureKeystore(hanaHome: tmp),
        composer: StoryComposer(
          caller:
              ({
                required String systemPrompt,
                required String userPrompt,
                int? maxTokens,
              }) async => throw Exception('网络故障模拟'),
        ),
        parser: repo.parser,
      );
      final reg = await repo2.registerNew(pin: '0000');
      expect(reg.fallback, isTrue);
      expect(reg.story, '');
      // 助记词依然完整。
      expect(reg.identity.mnemonic!.words.length, 12);
    });
  });
}

StoryLlmCaller _semanticCaller(
  List<List<int>> Function() rows, {
  void Function(String systemPrompt, String userPrompt)? onCall,
}) {
  var nextRow = 0;
  return ({
    required String systemPrompt,
    required String userPrompt,
    int? maxTokens,
  }) async {
    onCall?.call(systemPrompt, userPrompt);
    if (systemPrompt.contains('锚点提取器')) {
      nextRow = 0;
      return jsonEncode({
        'anchors': [for (var row = 0; row < 12; row++) '锚$row'],
      });
    }
    final matrix = rows();
    final row = matrix[nextRow % matrix.length];
    nextRow++;
    return jsonEncode({'candidates': row});
  };
}

class _FakeRecoveryAccelerator implements RecoveryAccelerator {
  _FakeRecoveryAccelerator(this._ids);

  final List<int> Function() _ids;
  int calls = 0;
  int? lastDMaxHard;

  @override
  Future<AcceleratedRecoveryOutcome> tryRecover({
    required List<List<int>> matrix,
    required Set<String> targetPublicKeyHashes,
    required int dMaxHard,
    required Duration hardDeadline,
    int? workerCount,
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
  }) async {
    calls++;
    lastDMaxHard = dMaxHard;
    onProgress?.call(3, 5, 0);
    final ids = _ids();
    final seed = tryMnemonicFromIds(ids)!;
    final pair = HanakoKeyPair.fromPrivateKeyBytes(seed.privateKeyBytes);
    return AcceleratedRecoveryOutcome(
      found: true,
      ids: ids,
      publicKeyHex: pair.publicKeyHex,
      attempted: 7,
      elapsedMs: 11,
      hammingDistance: 0,
      timedOut: false,
      backend: 'fake',
    );
  }
}
