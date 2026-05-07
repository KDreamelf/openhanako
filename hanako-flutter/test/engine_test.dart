import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/engine.dart';
import 'package:hanako/identity/identity.dart';
import 'package:hanako/shared/hana_home.dart';

void main() {
  group('HanaEngine 身份恢复', () {
    late Directory tmp;
    late HanaHome home;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hanako_engine_test_');
      home = HanaHome.debugFromDirectory(tmp);
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('启动时自动解锁已保存身份', () async {
      final keyPair = HanakoKeyPair.generate();
      final repo = IdentityRepository(
        keystore: _MemoryKeystore(
          IdentityVault(
            privateKey: Uint8List.fromList(keyPair.privateKeyBytes),
          ),
        ),
        composer: StoryComposer(caller: _unusedLlmCaller),
        parser: StoryParser(caller: _unusedLlmCaller),
      );

      final engine = await HanaEngine.initialize(
        home: home,
        identityRepository: repo,
      );
      addTearDown(engine.dispose);

      expect(repo.current?.publicKeyHex, keyPair.publicKeyHex);
    });

    test('自动解锁失败不阻断启动', () async {
      final repo = IdentityRepository(
        keystore: _FailingReadKeystore(),
        composer: StoryComposer(caller: _unusedLlmCaller),
        parser: StoryParser(caller: _unusedLlmCaller),
      );

      final engine = await HanaEngine.initialize(
        home: home,
        identityRepository: repo,
      );
      addTearDown(engine.dispose);

      expect(engine.isInitialized, isTrue);
      expect(repo.current, isNull);
    });
  });
}

Future<String> _unusedLlmCaller({
  required String systemPrompt,
  required String userPrompt,
  int? maxTokens,
}) async {
  throw UnsupportedError('测试不应调用 LLM');
}

class _MemoryKeystore extends SecureKeystore {
  _MemoryKeystore(this._vault);

  IdentityVault? _vault;

  @override
  Future<void> deleteAll() async {
    _vault = null;
  }

  @override
  Future<bool> exists() async => _vault != null;

  @override
  Future<IdentityVault> readVault({String? pin}) async {
    final vault = _vault;
    if (vault == null) throw StateError('empty keystore');
    return vault;
  }

  @override
  Future<void> writeVault(IdentityVault vault, {String? pin}) async {
    _vault = vault;
  }
}

class _FailingReadKeystore extends SecureKeystore {
  @override
  Future<void> deleteAll() async {}

  @override
  Future<bool> exists() async => true;

  @override
  Future<IdentityVault> readVault({String? pin}) async {
    throw const KeystoreAccessDeniedException('测试解锁失败');
  }

  @override
  Future<void> writeVault(IdentityVault vault, {String? pin}) async {}
}
