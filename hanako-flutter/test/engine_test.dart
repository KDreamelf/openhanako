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
      await engine.modelManager.replaceAvailableModels(const [
        'public-story-model',
        'gpt-5.5',
      ], preferredModelId: 'gpt-5.5');

      final result = await engine.identityRepository.composer.compose(
        hanakoWordlist.take(12).toList(growable: false),
      );

      expect(result.fallback, isFalse);
      expect(result.story, '公开故事正文');
      expect(backend.publicModelListCalls, 1);
      expect(backend.publicChatCalls, 1);
      expect(backend.requestedModels, ['public-story-model']);
      expect(backend.extras.single, isNull);
      expect(backend.handshakeCalls, 0);
      expect(backend.privateChatCalls, 0);
    });

    test('公开故事模型请求过于频繁时会指数退避重试', () async {
      final backend = _PublicStoryBackendClient(
        models: const ['public-story-model'],
        responses: const ['公开故事正文'],
        publicStoryRateLimitFailures: 1,
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
      expect(backend.publicChatCalls, 2);
      expect(backend.handshakeCalls, 0);
      expect(backend.privateChatCalls, 0);

      final logFile = File(
        '${home.logsDir.path}${Platform.pathSeparator}public-story-recovery.jsonl',
      );
      expect(logFile.existsSync(), isTrue);
      final logs = logFile.readAsStringSync();
      expect(logs, contains('"event":"rate_limit_retry"'));
      expect(logs, contains('"status_code":429'));
      expect(logs, contains('上游模型 API 返回 429 Too Many Requests'));
      expect(logs, contains('"sleeping"'));
    });

    test('公开故事网关自身 429 不会按上游限流长重试', () async {
      final backend = _PublicStoryBackendClient(
        models: const ['public-story-model'],
        responses: const ['不应返回'],
        gatewayRateLimitFailures: 1,
      );
      final engine = await HanaEngine.initialize(
        home: home,
        backendClient: backend,
      );
      addTearDown(engine.dispose);

      final result = await engine.identityRepository.composer.compose(
        hanakoWordlist.take(12).toList(growable: false),
      );

      expect(result.fallback, isTrue);
      expect(backend.publicModelListCalls, 1);
      expect(backend.publicChatCalls, 1);

      final logFile = File(
        '${home.logsDir.path}${Platform.pathSeparator}public-story-recovery.jsonl',
      );
      final logs = logFile.readAsStringSync();
      expect(logs, contains('"event":"failure"'));
      expect(logs, contains('"status_code":429'));
      expect(logs, isNot(contains('"event":"rate_limit_retry"')));
    });

    test('故事恢复解析同样走 root 公开故事接口', () async {
      final matrix = List.generate(
        12,
        (index) => [index, index, index, index, index],
      );
      final backend = _PublicStoryBackendClient(
        models: const ['public-story-model'],
        responses: [
          jsonEncode({
            'anchors': [for (var index = 0; index < 12; index++) '锚$index'],
          }),
          for (final row in matrix) jsonEncode({'candidates': row}),
        ],
        chatDelay: const Duration(milliseconds: 20),
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
      expect(backend.publicChatCalls, 13);
      expect(backend.maxConcurrentPublicChatCalls, lessThanOrEqualTo(3));
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
  _PublicStoryBackendClient({
    required this.models,
    required this.responses,
    this.publicStoryRateLimitFailures = 0,
    this.gatewayRateLimitFailures = 0,
    this.chatDelay = Duration.zero,
  });

  final List<String> models;
  final List<String> responses;
  final int publicStoryRateLimitFailures;
  final int gatewayRateLimitFailures;
  final Duration chatDelay;
  final requestedModels = <String>[];
  final extras = <Map<String, dynamic>?>[];
  int publicModelListCalls = 0;
  int publicChatCalls = 0;
  int activePublicChatCalls = 0;
  int maxConcurrentPublicChatCalls = 0;
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
    extras.add(extra);
    activePublicChatCalls++;
    if (activePublicChatCalls > maxConcurrentPublicChatCalls) {
      maxConcurrentPublicChatCalls = activePublicChatCalls;
    }
    publicChatCalls++;
    final callNumber = publicChatCalls;
    try {
      if (chatDelay > Duration.zero) {
        await Future<void>.delayed(chatDelay);
      }
      if (callNumber <= gatewayRateLimitFailures) {
        throw HanakoBackendException(
          message: '调用公开故事模型失败：请求过于频繁',
          details: '调用公开故事模型失败\nHTTP 状态：429\n请求被网关前置限流拦截',
          statusCode: 429,
        );
      }
      if (callNumber <=
          gatewayRateLimitFailures + publicStoryRateLimitFailures) {
        throw HanakoBackendException(
          message: '调用公开故事模型失败：请求过于频繁',
          details: '上游模型 API 返回 429 Too Many Requests',
          statusCode: 429,
        );
      }
      final response =
          responses[callNumber -
              gatewayRateLimitFailures -
              publicStoryRateLimitFailures -
              1];
      return {
        'choices': [
          {
            'message': {'content': response},
          },
        ],
      };
    } finally {
      activePublicChatCalls--;
    }
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
