import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/agent_manager.dart';
import 'package:hanako/core/config_coordinator.dart';
import 'package:hanako/core/model_manager.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/core/runtime_session_store.dart';
import 'package:hanako/core/session_coordinator.dart';
import 'package:hanako/core/skill_manager.dart';
import 'package:hanako/identity/identity.dart';
import 'package:hanako/llm/provider.dart';
import 'package:hanako/shared/hana_home.dart';

void main() {
  late Directory tmp;
  late HanaHome home;
  late AgentManager agents;
  late ConfigCoordinator config;
  late ModelManager models;
  late IdentityRepository identityRepository;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hanako_sessions_');
    home = HanaHome.debugFromDirectory(tmp);
    final preferences = PreferencesManager(home);
    agents = AgentManager(home, preferences);
    final agent = await agents.createAgent(name: '测试 Agent', id: 'agent_01');
    await agents.switchAgent(agent.id);
    config = ConfigCoordinator(home, agent.id);
    await config.initialize();
    models = ModelManager(home);
    await models.initialize();
    identityRepository = IdentityRepository(
      keystore: _MemoryKeystore(),
      composer: StoryComposer(caller: _unusedLlmCaller),
      parser: StoryParser(caller: _unusedLlmCaller),
    );
  });

  tearDown(() async {
    await config.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('恢复最近会话并读取 JSONL 历史', () async {
    final first = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
    );

    final oldSession = await first.createSession();
    first.replaceCurrentMessages(const [
      Message(role: 'user', content: '旧会话'),
      Message(role: 'assistant', content: '旧回复'),
    ]);

    final lastSession = await first.createSession();
    first.replaceCurrentMessages(const [
      Message(role: 'user', content: '最近会话'),
      Message(role: 'assistant', content: '最近回复'),
    ]);

    final second = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
    );
    final restored = await second.restoreLastSession();

    expect(restored?.path, lastSession.path);
    expect(second.currentMessages().map((message) => message.content), [
      '最近会话',
      '最近回复',
    ]);

    await second.switchSession(oldSession.path);
    expect(second.currentMessages().map((message) => message.content), [
      '旧会话',
      '旧回复',
    ]);
  });

  test('新会话默认工作目录收敛到当前 Agent desk', () async {
    final coordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
    );

    final session = await coordinator.createSession();

    expect(session.cwd, home.agentDesk('agent_01').path);
    final header =
        jsonDecode(File(session.path).readAsLinesSync().first)
            as Map<String, dynamic>;
    expect(header['cwd'], session.cwd);
  });

  test('读取旧扁平 JSONL 时迁移为 entry 格式', () async {
    final coordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
    );
    final session = await coordinator.createSession(cwd: tmp.path);
    final file = File(session.path);
    file.writeAsStringSync(
      [
        jsonEncode({'role': 'user', 'content': '旧格式问题'}),
        jsonEncode({
          'role': 'assistant',
          'content': '需要工具',
          'tool_calls': [
            {
              'id': 'legacy_call',
              'type': 'function',
              'function': {'name': 'ls', 'arguments': '{"path":"."}'},
            },
          ],
        }),
        jsonEncode({
          'role': 'tool',
          'tool_call_id': 'legacy_call',
          'name': 'ls',
          'content': '{"ok":true}',
        }),
        jsonEncode({'role': 'assistant', 'content': '旧格式回答'}),
      ].join('\n'),
      flush: true,
    );

    final visible = coordinator.loadSessionMessages(session.path);

    expect(visible.map((message) => message.content), [
      '旧格式问题',
      '需要工具\n\n旧格式回答',
    ]);
    final display = coordinator.loadSessionDisplayMessages(session.path);
    expect(display, hasLength(2));
    expect(display[1].blocks.map((block) => block.runtimeType), [
      RuntimeDisplayTextBlock,
      RuntimeDisplayToolCallBlock,
      RuntimeDisplayTextBlock,
    ]);
    expect((display[1].blocks[1] as RuntimeDisplayToolCallBlock).name, 'ls');
    final lines = file.readAsLinesSync();
    expect(jsonDecode(lines.first), containsPair('type', 'session'));
    expect(
      lines.skip(1).map((line) => jsonDecode(line)['type']),
      everyElement('message'),
    );
    expect(file.readAsStringSync(), contains('"toolCall"'));
    expect(file.readAsStringSync(), contains('"toolResult"'));
  });

  test('工具调用与工具结果在重启后仍进入下一次请求上下文', () async {
    await _prepareOnlineState(
      identityRepository: identityRepository,
      models: models,
    );
    final backend = _FakeBackendClient([
      [
        const ToolCallStart(id: 'call_1', name: 'ls'),
        const ToolCallArgsDelta(id: 'call_1', argsJson: '{"path":"."}'),
        const ToolCallEnd('call_1'),
      ],
      [const TextDelta('目录已列出')],
    ]);
    final first = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: backend,
    );
    final session = await first.createSession(cwd: tmp.path);

    final events = await _drain(first.prompt('列一下目录'));

    expect(events.whereType<MessageDone>(), hasLength(1));
    expect(backend.requests, hasLength(2));
    expect(backend.requests[1].map((msg) => msg['role']), [
      'system',
      'user',
      'assistant',
      'tool',
    ]);
    final assistant = backend.requests[1].firstWhere(
      (msg) => msg['role'] == 'assistant',
    );
    expect(assistant['tool_calls'], isA<List>());
    final tool = backend.requests[1].firstWhere((msg) => msg['role'] == 'tool');
    expect(tool['tool_call_id'], 'call_1');
    expect(tool['content'], contains('"ok": true'));

    final restartedBackend = _FakeBackendClient([
      [const TextDelta('继续完成')],
    ]);
    final restarted = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: restartedBackend,
    );
    await restarted.switchSession(session.path);

    await _drain(restarted.prompt('继续'));

    final request = restartedBackend.requests.single;
    expect(
      request
          .where((msg) => msg['role'] == 'assistant')
          .any((msg) => msg['tool_calls'] is List),
      isTrue,
    );
    expect(request.where((msg) => msg['role'] == 'tool'), hasLength(1));
    expect(request.last['role'], 'user');
    expect(request.last['content'], '继续');
  });

  test('已启用 Skill 会注入 system prompt，禁用后移除', () async {
    final skills = SkillManager(home);
    await skills.initialize();
    await skills.installFromContent(
      'agent_01',
      skillContent: '''---
name: prompt-skill
description: 用于检查 prompt 注入。
---

完整说明。
''',
      enable: true,
    );
    await _prepareOnlineState(
      identityRepository: identityRepository,
      models: models,
    );
    final enabledBackend = _FakeBackendClient([
      [const TextDelta('ok')],
    ]);
    final enabledCoordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: enabledBackend,
      skillManager: skills,
    );
    await enabledCoordinator.createSession(cwd: tmp.path);

    await _drain(enabledCoordinator.prompt('检查 skill'));

    expect(
      enabledBackend.requests.single.first['content'],
      contains('prompt-skill'),
    );

    await skills.setSkillEnabled('agent_01', 'prompt-skill', false);
    final disabledBackend = _FakeBackendClient([
      [const TextDelta('ok')],
    ]);
    final disabledCoordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: disabledBackend,
      skillManager: skills,
    );
    await disabledCoordinator.createSession(cwd: tmp.path);

    await _drain(disabledCoordinator.prompt('再次检查'));

    expect(
      disabledBackend.requests.single.first['content'],
      isNot(contains('prompt-skill')),
    );
  });

  test('工具执行失败作为 tool result 继续交给模型', () async {
    await _prepareOnlineState(
      identityRepository: identityRepository,
      models: models,
    );
    final backend = _FakeBackendClient([
      [
        const ToolCallStart(id: 'call_bad', name: 'not_existing_tool'),
        const ToolCallArgsDelta(id: 'call_bad', argsJson: '{}'),
        const ToolCallEnd('call_bad'),
      ],
      [const TextDelta('我看到工具不可用')],
    ]);
    final coordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: backend,
    );
    await coordinator.createSession(cwd: tmp.path);

    await _drain(coordinator.prompt('调用一个不存在的工具'));

    expect(backend.requests, hasLength(2));
    final tool = backend.requests[1].firstWhere((msg) => msg['role'] == 'tool');
    expect(tool['tool_call_id'], 'call_bad');
    expect(tool['content'], contains('"ok": false'));
    expect(tool['content'], contains('unknown_tool'));
    expect(coordinator.currentMessages().last.content, contains('我看到工具不可用'));
  });

  test('工具调用后上游错误不清理已完成工具上下文', () async {
    await _prepareOnlineState(
      identityRepository: identityRepository,
      models: models,
    );
    final backend = _FakeBackendClient([
      [
        const ToolCallStart(id: 'call_1', name: 'ls'),
        const ToolCallArgsDelta(id: 'call_1', argsJson: '{"path":"."}'),
        const ToolCallEnd('call_1'),
      ],
      [
        const LlmError(
          message: '发送对话失败：AI 网关或上游模型服务异常',
          statusCode: 500,
          details: '上游容量不足',
        ),
      ],
      [const TextDelta('已根据工具结果继续')],
    ]);
    final coordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: backend,
    );
    final session = await coordinator.createSession(cwd: tmp.path);

    final failedEvents = await _drain(coordinator.prompt('列一下目录'));

    expect(failedEvents.whereType<LlmError>(), hasLength(1));
    final persisted = RuntimeSessionStore.loadRuntimeMessages(session.path);
    expect(persisted.map((message) => message.role), [
      'user',
      'assistant',
      'toolResult',
    ]);
    expect(persisted[1].toolCalls.single.name, 'ls');
    expect(persisted[2].toolCallId, 'call_1');

    await _drain(coordinator.retryCurrentTurn());

    expect(backend.requests, hasLength(3));
    expect(backend.requests[2].map((message) => message['role']), [
      'system',
      'user',
      'assistant',
      'tool',
    ]);
    expect(
      backend.requests[2].where((message) => message['role'] == 'user'),
      hasLength(1),
    );
    expect(coordinator.currentMessages().last.content, contains('已根据工具结果继续'));
  });

  test('上游错误不落错误回复，下一轮请求保留失败用户输入', () async {
    await _prepareOnlineState(
      identityRepository: identityRepository,
      models: models,
    );
    final failingBackend = _FakeBackendClient([
      [
        const TextDelta('半截回复'),
        const LlmError(
          message: '发送对话失败：AI 网关拒绝了请求参数',
          statusCode: 400,
          details: '服务端返回明文',
        ),
      ],
    ]);
    final coordinator = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: failingBackend,
    );
    final session = await coordinator.createSession(cwd: tmp.path);
    coordinator.replaceCurrentMessages(const [
      Message(role: 'user', content: '之前的问题'),
      Message(role: 'assistant', content: '之前的回答'),
    ]);

    final events = await _drain(coordinator.prompt('触发错误'));

    expect(events.whereType<LlmError>(), hasLength(1));
    expect(coordinator.currentMessages().map((message) => message.content), [
      '之前的问题',
      '之前的回答',
      '触发错误',
    ]);

    final continueBackend = _FakeBackendClient([
      [const TextDelta('已继续')],
    ]);
    final restarted = _coordinator(
      home: home,
      agents: agents,
      models: models,
      config: config,
      identityRepository: identityRepository,
      backendClient: continueBackend,
    );
    await restarted.switchSession(session.path);

    await _drain(restarted.prompt('继续'));

    final encodedRequest = continueBackend.requests.single
        .map((message) => message.toString())
        .join('\n');
    expect(encodedRequest, contains('之前的回答'));
    expect(encodedRequest, contains('触发错误'));
    expect(encodedRequest, isNot(contains('半截回复')));
    expect(encodedRequest, isNot(contains('服务端返回明文')));
  });
}

SessionCoordinator _coordinator({
  required HanaHome home,
  required AgentManager agents,
  required ModelManager models,
  required ConfigCoordinator config,
  required IdentityRepository identityRepository,
  HanakoBackendClient? backendClient,
  SkillManager? skillManager,
}) {
  return SessionCoordinator(
    home: home,
    agentManager: agents,
    modelManager: models,
    config: config,
    identityRepository: identityRepository,
    backendClient: backendClient ?? HanakoBackendClient(),
    skillManager: skillManager,
  );
}

Future<void> _prepareOnlineState({
  required IdentityRepository identityRepository,
  required ModelManager models,
}) async {
  identityRepository.debugSetCurrent(
    HanakoIdentity(keyPair: HanakoKeyPair.generate(), mnemonic: null),
  );
  await models.replaceAvailableModels(const [
    'test-model',
  ], preferredModelId: 'test-model');
}

Future<List<LlmEvent>> _drain(Stream<LlmEvent> stream) async {
  final events = <LlmEvent>[];
  await for (final event in stream) {
    events.add(event);
  }
  return events;
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

  @override
  Future<void> writePrivateKey(Uint8List privateKey, {String? pin}) async {
    _vault = IdentityVault(privateKey: privateKey);
  }
}

class _FakeBackendClient extends HanakoBackendClient {
  _FakeBackendClient(this.rounds);

  final List<List<LlmEvent>> rounds;
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
    final events = _round < rounds.length ? rounds[_round] : const <LlmEvent>[];
    _round++;
    for (final event in events) {
      yield event;
    }
  }
}
