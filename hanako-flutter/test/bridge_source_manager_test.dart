import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/bridge/bridge_adapter.dart';
import 'package:hanako/core/agent_manager.dart';
import 'package:hanako/core/bridge_session_manager.dart';
import 'package:hanako/core/bridge_source_manager.dart';
import 'package:hanako/core/config_coordinator.dart';
import 'package:hanako/core/model_manager.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/core/runtime_session_store.dart';
import 'package:hanako/core/session_coordinator.dart';
import 'package:hanako/identity/identity.dart';
import 'package:hanako/llm/provider.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanaHome home;
  late PreferencesManager prefs;
  late AgentManager agents;
  late ModelManager modelManager;
  late IdentityRepository identityRepository;
  late BridgeSessionManager bridgeSessions;
  late BridgeSourceManager sources;
  late ConfigCoordinator config;
  late _FakeBackendClient backend;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hanako_bridge_sources_');
    home = HanaHome.debugFromDirectory(tmp);
    prefs = PreferencesManager(home);
    agents = AgentManager(home, prefs);
    final agent = await agents.createAgent(id: 'agent_01', name: '测试 Agent');
    await agents.createAgent(id: 'agent_02', name: '目标 Agent');
    await agents.switchAgent(agent.id);
    config = ConfigCoordinator(home, agent.id);
    await config.initialize();
    modelManager = ModelManager(home);
    await modelManager.initialize();
    await modelManager.replaceAvailableModels(const [
      'test-model',
    ], preferredModelId: 'test-model');
    identityRepository =
        IdentityRepository(
          keystore: _MemoryKeystore(),
          composer: StoryComposer(caller: _unusedLlmCaller),
          parser: StoryParser(caller: _unusedLlmCaller),
        )..debugSetCurrent(
          HanakoIdentity(keyPair: HanakoKeyPair.generate(), mnemonic: null),
        );
    backend = _FakeBackendClient();
    final sessions = SessionCoordinator(
      home: home,
      agentManager: agents,
      modelManager: modelManager,
      config: config,
      identityRepository: identityRepository,
      backendClient: backend,
    );
    bridgeSessions = BridgeSessionManager(
      home: home,
      agentManager: agents,
      modelManager: modelManager,
      config: config,
      preferences: prefs,
      sessionCoordinator: sessions,
    );
    sources = BridgeSourceManager(
      preferences: prefs,
      bridgeSessionManager: bridgeSessions,
    );
  });

  tearDown(() async {
    await bridgeSessions.dispose();
    await config.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('保存、禁用和删除 Telegram 配置', () async {
    await sources.save(
      const BridgeSourceConfig(
        platform: 'telegram',
        enabled: false,
        agentId: 'agent_01',
        credentials: {'token': '123:abc'},
      ),
    );

    final telegram = sources.listSources().firstWhere(
      (source) => source.platform == 'telegram',
    );
    expect(telegram.configured, true);
    expect(telegram.enabled, false);
    expect(telegram.agentId, 'agent_01');

    await sources.setEnabled('telegram', false);
    expect(sources.status('telegram').state, 'disabled');

    await sources.delete('telegram');
    final deleted = sources.listSources().firstWhere(
      (source) => source.platform == 'telegram',
    );
    expect(deleted.configured, false);
  });

  test('QQ 保留配置模型并给出 adapter 占位状态', () async {
    await sources.save(
      const BridgeSourceConfig(
        platform: 'qq',
        enabled: true,
        credentials: {'appID': 'app', 'appSecret': 'secret'},
      ),
    );

    final qq = sources.listSources().firstWhere(
      (source) => source.platform == 'qq',
    );
    expect(qq.configured, true);
    expect(sources.status('qq').state, 'error');
    expect(sources.status('qq').error, contains('QQ 当前只保存配置'));
  });

  test('Telegram 外部消息按配置进入指定 Agent 会话', () async {
    backend.rounds.add([const TextDelta('桥接回复')]);
    await sources.save(
      const BridgeSourceConfig(
        platform: 'telegram',
        enabled: false,
        agentId: 'agent_02',
        credentials: {'token': '123:abc'},
      ),
    );
    final adapter = _FakeBridgeAdapter('telegram');
    await bridgeSessions.register(adapter);

    adapter.add(
      IncomingMessage(
        userId: 'u1',
        userName: '外部用户',
        chatId: 'chat_1',
        text: '外部消息',
        ts: DateTime.now(),
      ),
    );

    await _waitUntil(() => adapter.sent.isNotEmpty);
    expect(adapter.sent.single.text, '桥接回复');

    final targetSessions = home
        .agentSessions('agent_02')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.jsonl'))
        .toList(growable: false);
    expect(targetSessions, hasLength(1));
    final messages = RuntimeSessionStore.loadVisibleMessages(
      targetSessions.single.path,
    );
    expect(messages.map((message) => message.content), ['外部消息', '桥接回复']);
    final activeAgentSessions = home
        .agentSessions('agent_01')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.jsonl'))
        .toList(growable: false);
    expect(activeAgentSessions, isEmpty);

    final indexFile = File(
      p.join(
        home.agentSessions('agent_02').path,
        'bridge',
        'bridge-sessions.json',
      ),
    );
    final index = jsonDecode(indexFile.readAsStringSync()) as Map;
    expect(index['tg_dm_u1']['agentId'], 'agent_02');
    expect(index['tg_dm_u1']['sessionPath'], targetSessions.single.path);
    expect(backend.requests.single.toString(), contains('当前 Agent：目标 Agent'));
  });
}

Future<String> _unusedLlmCaller({
  required String systemPrompt,
  required String userPrompt,
  int? maxTokens,
}) async => throw UnsupportedError('测试不应调用 LLM');

class _MemoryKeystore extends SecureKeystore {
  @override
  Future<void> deleteAll() async {}

  @override
  Future<bool> exists() async => false;

  @override
  Future<IdentityVault> readVault({String? pin}) async {
    throw StateError('empty');
  }

  @override
  Future<void> writePrivateKey(Uint8List privateKey, {String? pin}) async {}

  @override
  Future<void> writeVault(IdentityVault vault, {String? pin}) async {}
}

class _FakeBridgeAdapter implements BridgeAdapter {
  _FakeBridgeAdapter(this.platform);

  @override
  final String platform;

  final _controller = StreamController<IncomingMessage>.broadcast();
  final sent = <OutgoingMessage>[];

  @override
  Stream<IncomingMessage> get messages => _controller.stream;

  void add(IncomingMessage message) => _controller.add(message);

  @override
  Future<BridgeResult> send(OutgoingMessage msg) async {
    sent.add(msg);
    return const BridgeSuccess('sent');
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

class _FakeBackendClient extends HanakoBackendClient {
  final rounds = <List<LlmEvent>>[];
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

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待异步桥接消息超时');
}
