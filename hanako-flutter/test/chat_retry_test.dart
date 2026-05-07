import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/app/providers.dart';
import 'package:hanako/core/agent_manager.dart';
import 'package:hanako/core/engine.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/core/runtime_session_store.dart';
import 'package:hanako/identity/identity.dart';
import 'package:hanako/llm/provider.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:hanako/ui/chat_page.dart';

void main() {
  test('发送失败后自动重试，重试中错误不写入会话记录', () async {
    final tmp = await Directory.systemTemp.createTemp('hanako_chat_retry_');
    addTearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    final home = HanaHome.debugFromDirectory(tmp);
    final prefs = PreferencesManager(home);
    final agents = AgentManager(home, prefs);
    await agents.createAgent(name: '测试 Agent', id: 'agent_01');

    final repo =
        IdentityRepository(
          keystore: _MemoryKeystore(),
          composer: StoryComposer(caller: _unusedLlmCaller),
          parser: StoryParser(caller: _unusedLlmCaller),
        )..debugSetCurrent(
          HanakoIdentity(keyPair: HanakoKeyPair.generate(), mnemonic: null),
        );
    final backend = _FakeBackendClient([
      [
        const LlmError(
          message: '发送对话失败：AI 网关或上游模型服务异常',
          statusCode: 500,
          details: '上游返回 429 capacity exhausted',
        ),
      ],
      [const TextDelta('重试成功')],
    ]);
    final engine = await HanaEngine.initialize(
      home: home,
      identityRepository: repo,
      backendClient: backend,
    );
    addTearDown(engine.dispose);
    await engine.modelManager.replaceAvailableModels(const [
      'test-model',
    ], preferredModelId: 'test-model');

    final container = ProviderContainer(
      overrides: [
        engineProvider.overrideWithValue(engine),
        identityRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    final send = container.read(chatProvider.notifier).send('你好');
    ChatRetryNotice? retrying;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      retrying = container.read(chatProvider).retrying;
      if (retrying != null) break;
    }
    final midwayState = container.read(chatProvider);
    expect(
      retrying,
      isNotNull,
      reason:
          'state streaming=${midwayState.streaming} error=${midwayState.error} history=${midwayState.history.map((m) => m.visibleText).toList()}',
    );
    expect(retrying!.retryIndex, 1);
    expect(engine.sessionCoordinator.currentMessages().map((m) => m.content), [
      '你好',
    ]);

    await send;

    expect(backend.requests, hasLength(2));
    expect(
      backend.requests[1].where((message) => message['role'] == 'user'),
      hasLength(1),
    );
    expect(engine.sessionCoordinator.currentMessages().map((m) => m.content), [
      '你好',
      '重试成功',
    ]);
    final state = container.read(chatProvider);
    expect(state.retrying, isNull);
    expect(state.error, isNull);
  });

  test('不可重试错误后的下一条请求会合并连续 user 上下文', () async {
    final tmp = await Directory.systemTemp.createTemp(
      'hanako_chat_context_after_403_',
    );
    addTearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    final home = HanaHome.debugFromDirectory(tmp);
    final prefs = PreferencesManager(home);
    final agents = AgentManager(home, prefs);
    await agents.createAgent(name: '测试 Agent', id: 'agent_01');

    final repo =
        IdentityRepository(
          keystore: _MemoryKeystore(),
          composer: StoryComposer(caller: _unusedLlmCaller),
          parser: StoryParser(caller: _unusedLlmCaller),
        )..debugSetCurrent(
          HanakoIdentity(keyPair: HanakoKeyPair.generate(), mnemonic: null),
        );
    final backend = _FakeBackendClient([
      [
        const LlmError(
          message: '发送对话失败：当前身份无权使用该模型',
          statusCode: 403,
          details: 'HTTP 403',
        ),
      ],
      [const TextDelta('收到完整上下文')],
    ]);
    final engine = await HanaEngine.initialize(
      home: home,
      identityRepository: repo,
      backendClient: backend,
    );
    addTearDown(engine.dispose);
    await engine.modelManager.replaceAvailableModels(const [
      'test-model',
    ], preferredModelId: 'test-model');

    final container = ProviderContainer(
      overrides: [
        engineProvider.overrideWithValue(engine),
        identityRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatProvider.notifier).send('你好');

    expect(container.read(chatProvider).errorStatusCode, 403);
    expect(engine.sessionCoordinator.currentMessages().map((m) => m.content), [
      '你好',
    ]);

    await container.read(chatProvider.notifier).send('了');

    expect(backend.requests, hasLength(2));
    final userMessages = backend.requests[1]
        .where((message) => message['role'] == 'user')
        .toList(growable: false);
    expect(userMessages, hasLength(1));
    expect(userMessages.single['content'], contains('你好'));
    expect(userMessages.single['content'], contains('了'));
    expect(engine.sessionCoordinator.currentMessages().map((m) => m.content), [
      '你好',
      '了',
      '收到完整上下文',
    ]);
  });

  test('重试中出现有效输出后结束当前重试段，后续错误从第 1 次重新计数', () async {
    final tmp = await Directory.systemTemp.createTemp(
      'hanako_chat_retry_reset_',
    );
    addTearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    final home = HanaHome.debugFromDirectory(tmp);
    final prefs = PreferencesManager(home);
    final agents = AgentManager(home, prefs);
    await agents.createAgent(name: '测试 Agent', id: 'agent_01');

    final repo =
        IdentityRepository(
          keystore: _MemoryKeystore(),
          composer: StoryComposer(caller: _unusedLlmCaller),
          parser: StoryParser(caller: _unusedLlmCaller),
        )..debugSetCurrent(
          HanakoIdentity(keyPair: HanakoKeyPair.generate(), mnemonic: null),
        );
    final afterProgress = Completer<void>();
    final backend = _FakeBackendClient([
      [
        const LlmError(
          message: '发送对话失败：AI 网关或上游模型服务异常',
          statusCode: 500,
          details: '第一次失败',
        ),
      ],
      [
        const TextDelta('中途已有输出，足够长，可以立即越过思考标签缓冲'),
        afterProgress.future,
        const LlmError(
          message: '发送对话失败：AI 网关或上游模型服务异常',
          statusCode: 500,
          details: '输出后再次失败',
        ),
      ],
      [const TextDelta('最终成功')],
    ]);
    final engine = await HanaEngine.initialize(
      home: home,
      identityRepository: repo,
      backendClient: backend,
    );
    addTearDown(engine.dispose);
    await engine.modelManager.replaceAvailableModels(const [
      'test-model',
    ], preferredModelId: 'test-model');

    final container = ProviderContainer(
      overrides: [
        engineProvider.overrideWithValue(engine),
        identityRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    final send = container.read(chatProvider.notifier).send('你好');

    await _waitUntil(() {
      final retrying = container.read(chatProvider).retrying;
      return backend.requests.length == 1 &&
          retrying?.retryIndex == 1 &&
          retrying?.waiting == true;
    });

    await _waitUntil(() {
      final state = container.read(chatProvider);
      return backend.requests.length == 2 &&
          state.retrying == null &&
          state.currentBlocks.whereType<RuntimeDisplayTextBlock>().any(
            (block) => block.text.contains('中途已有输出'),
          );
    });

    afterProgress.complete();

    await _waitUntil(() {
      final retrying = container.read(chatProvider).retrying;
      return backend.requests.length == 2 &&
          retrying?.retryIndex == 1 &&
          retrying?.waiting == true;
    });

    await send;

    expect(backend.requests, hasLength(3));
    expect(engine.sessionCoordinator.currentMessages().map((m) => m.content), [
      '你好',
      '最终成功',
    ]);
    expect(container.read(chatProvider).retrying, isNull);
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

class _FakeBackendClient extends HanakoBackendClient {
  _FakeBackendClient(this.rounds);

  final List<List<Object>> rounds;
  final requests = <List<Map<String, dynamic>>>[];
  int _round = 0;

  @override
  HanakoChannel? get channel => HanakoChannel(
    channelId: 'test-channel',
    aesKey: Uint8List(32),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    allowedModels: const ['test-model'],
  );

  @override
  Future<HanakoChannel> handshake({required HanakoKeyPair keyPair}) async {
    return channel!;
  }

  @override
  Future<GatewayModelList> listModels({String? channelId}) async {
    return GatewayModelList(models: const ['test-model']);
  }

  @override
  Stream<LlmEvent> chatEvents({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Tool>? tools,
    Object? toolChoice,
    Map<String, dynamic>? extra,
    dynamic cancelToken,
  }) async* {
    requests.add(
      messages
          .map(
            (message) =>
                jsonDecode(jsonEncode(message)) as Map<String, dynamic>,
          )
          .toList(growable: false),
    );
    final events = _round < rounds.length ? rounds[_round] : const <Object>[];
    _round++;
    for (final event in events) {
      if (event is Duration) {
        await Future<void>.delayed(event);
      } else if (event is Future<void>) {
        await event;
      } else if (event is LlmEvent) {
        yield event;
      }
    }
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met before timeout');
}
