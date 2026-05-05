import 'dart:async';

import '../identity/identity.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'bridge_session_manager.dart';
import 'channel_manager.dart';
import 'config_coordinator.dart';
import 'model_manager.dart';
import 'preferences_manager.dart';
import 'session_coordinator.dart';
import 'skill_manager.dart';

/// HanaEngine — Facade。
///
/// 单一入口，UI / CLI / Server 三种形态共用。负责按依赖顺序串联各 Manager 初始化。
class HanaEngine {
  HanaEngine._({
    required this.home,
    required this.preferences,
    required this.agentManager,
    required this.modelManager,
    required this.config,
    required this.identityRepository,
    required this.backendClient,
    required this.sessionCoordinator,
    required this.channelManager,
    required this.bridgeSessionManager,
    required this.skillManager,
  });

  final HanaHome home;
  final PreferencesManager preferences;
  final AgentManager agentManager;
  final ModelManager modelManager;
  final ConfigCoordinator config;
  final IdentityRepository identityRepository;
  final HanakoBackendClient backendClient;
  final SessionCoordinator sessionCoordinator;
  final ChannelManager channelManager;
  final BridgeSessionManager bridgeSessionManager;
  final SkillManager skillManager;

  bool _initialized = false;

  /// 初始化。可幂等调用。
  static Future<HanaEngine> initialize({
    HanaHome? home,
    IdentityRepository? identityRepository,
    HanakoBackendClient? backendClient,
  }) async {
    final h = home ?? await HanaHome.resolve();
    final identityRepo =
        identityRepository ??
        IdentityRepository(
          keystore: PlatformSecureKeystore(hanaHome: h.root),
          composer: StoryComposer(caller: _missingLlmCaller),
          parser: StoryParser(caller: _missingLlmCaller),
        );
    final gateway = backendClient ?? HanakoBackendClient();
    final prefs = PreferencesManager(h);
    final agents = AgentManager(h, prefs);

    // 决定活动 agent
    final activeId = await agents.resolveDefaultAgentId();
    if (activeId != null) {
      await agents.switchAgent(activeId);
    }

    // ConfigCoordinator 依赖 active agent；若 0 个 agent，传一个占位 ID
    // （写入会失败但 read() 返回空 map，不会崩）。
    final cfg = ConfigCoordinator(h, activeId ?? '_no_agent');
    await cfg.initialize();

    final models = ModelManager(h);
    await models.initialize();

    final sessions = SessionCoordinator(
      home: h,
      agentManager: agents,
      modelManager: models,
      config: cfg,
      identityRepository: identityRepo,
      backendClient: gateway,
    );

    final channels = ChannelManager(h);
    final bridge = BridgeSessionManager(
      home: h,
      agentManager: agents,
      modelManager: models,
      config: cfg,
      preferences: prefs,
      sessionCoordinator: sessions,
    );
    final skills = SkillManager(h);

    final eng = HanaEngine._(
      home: h,
      preferences: prefs,
      agentManager: agents,
      modelManager: models,
      config: cfg,
      identityRepository: identityRepo,
      backendClient: gateway,
      sessionCoordinator: sessions,
      channelManager: channels,
      bridgeSessionManager: bridge,
      skillManager: skills,
    );
    eng._initialized = true;
    return eng;
  }

  bool get isInitialized => _initialized;

  Future<void> dispose() async {
    await config.dispose();
    await bridgeSessionManager.dispose();
    _initialized = false;
  }

  Future<void> syncGatewayModels(
    HanakoIdentity identity, {
    String? preferredModelId,
  }) async {
    final channel = await backendClient.handshake(keyPair: identity.keyPair);
    GatewayModelList modelList;
    try {
      modelList = await backendClient.listModels(channelId: channel.channelId);
    } catch (_) {
      modelList = GatewayModelList(models: channel.allowedModels);
    }
    await modelManager.replaceAvailableModels(
      modelList.models,
      preferredModelId: preferredModelId,
    );
    final selected = modelManager.currentModelId;
    if (selected != null && selected.isNotEmpty) {
      config.writeAt(['models', 'chat'], selected);
    }
  }
}

Future<String> _missingLlmCaller({
  required String systemPrompt,
  required String userPrompt,
  int? maxTokens,
}) async {
  throw UnsupportedError('LLM 网关尚未接入，故事生成走 fallback 路径');
}
