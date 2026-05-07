import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/engine.dart';
import 'package:hanako/identity/identity.dart';
import 'package:hanako/llm/provider.dart';
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

    test('故事生成走 root 公开故事接口且不要求当前身份', () async {
      final backend = _PublicStoryBackendClient(
        models: const ['public-story-model'],
        responses: const ['公开故事正文'],
      );
      final engine = await HanaEngine.initialize(
        home: home,
        backendClient: backend,
      );
      addTearDown(engine.dispose);

      final result = await engine.identityRepository.composer.compose(
        hanakoWordlist.take(12).toList(growable: false),
      );

      expect(result.fallback, isFalse);
      expect(result.story, '公开故事正文');
      expect(backend.publicModelListCalls, 1);
      expect(backend.publicChatCalls, 1);
      expect(backend.requestedModels, ['public-story-model']);
      expect(backend.handshakeCalls, 0);
      expect(backend.privateChatCalls, 0);
    });

    test('故事恢复解析同样走 root 公开故事接口', () async {
      final matrix = List.generate(12, (index) => [index, index]);
      final backend = _PublicStoryBackendClient(
        models: const ['public-story-model'],
        responses: [
          jsonEncode({'columns': matrix}),
        ],
      );
      final engine = await HanaEngine.initialize(
        home: home,
        backendClient: backend,
      );
      addTearDown(engine.dispose);

      final parsed = await engine.identityRepository.parser.parse('一段模糊故事');

      expect(parsed.isWellFormed, isTrue);
      expect(parsed.columns, matrix);
      expect(backend.publicModelListCalls, 1);
      expect(backend.publicChatCalls, 1);
      expect(backend.handshakeCalls, 0);
      expect(backend.privateChatCalls, 0);
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

class _PublicStoryBackendClient extends HanakoBackendClient {
  _PublicStoryBackendClient({required this.models, required this.responses});

  final List<String> models;
  final List<String> responses;
  final requestedModels = <String>[];
  int publicModelListCalls = 0;
  int publicChatCalls = 0;
  int handshakeCalls = 0;
  int privateChatCalls = 0;

  @override
  Future<GatewayModelList> listPublicStoryModels() async {
    publicModelListCalls++;
    return GatewayModelList(models: models);
  }

  @override
  Future<Map<String, dynamic>> publicStoryChat({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? extra,
  }) async {
    requestedModels.add(model);
    final response = responses[publicChatCalls];
    publicChatCalls++;
    return {
      'choices': [
        {
          'message': {'content': response},
        },
      ],
    };
  }

  @override
  Future<HanakoChannel> handshake({required HanakoKeyPair keyPair}) async {
    handshakeCalls++;
    throw StateError('故事流程不应建立私有通道');
  }

  @override
  Future<Map<String, dynamic>> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Tool>? tools,
    Object? toolChoice,
    Map<String, dynamic>? extra,
  }) async {
    privateChatCalls++;
    throw StateError('故事流程不应使用私有聊天接口');
  }
}
