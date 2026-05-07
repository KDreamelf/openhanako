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
    final gateway = backendClient ?? HanakoBackendClient();
    late final IdentityRepository identityRepo;
    late final ModelManager models;
    identityRepo =
        identityRepository ??
        IdentityRepository(
          keystore: PlatformSecureKeystore(hanaHome: h.root),
          composer: StoryComposer(
            caller: ({required systemPrompt, required userPrompt, maxTokens}) =>
                _callGatewayForStory(
                  gateway: gateway,
                  identityRepository: identityRepo,
                  modelManager: models,
                  systemPrompt: systemPrompt,
                  userPrompt: userPrompt,
                  maxTokens: maxTokens,
                ),
          ),
          parser: StoryParser(caller: _missingLlmCaller),
        );
    await _restoreSavedIdentity(identityRepo);
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

    models = ModelManager(h);
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
    await sessionCoordinator.dispose();
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

Future<void> _restoreSavedIdentity(IdentityRepository repo) async {
  try {
    if (await repo.hasSavedIdentity()) {
      await repo.unlock();
    }
  } catch (_) {
    // 自动恢复不能阻断启动。旧 PIN keystore、用户取消系统解锁、
    // vault 损坏等情况仍可在设置页由用户显式处理。
  }
}

Future<String> _missingLlmCaller({
  required String systemPrompt,
  required String userPrompt,
  int? maxTokens,
}) async {
  throw UnsupportedError('LLM 网关尚未接入，故事生成走 fallback 路径');
}

Future<String> _callGatewayForStory({
  required HanakoBackendClient gateway,
  required IdentityRepository identityRepository,
  required ModelManager modelManager,
  required String systemPrompt,
  required String userPrompt,
  int? maxTokens,
}) async {
  final identity = identityRepository.current;
  if (identity == null) {
    throw StateError('身份未解锁，无法调用 AI 网关生成故事');
  }

  final channel = await _ensureGatewayChannel(
    gateway: gateway,
    identity: identity,
  );
  final model = _selectStoryModel(modelManager, channel);
  if (model == null) {
    throw StateError('未找到可用于生成故事的模型');
  }

  final response = await gateway.chat(
    model: model,
    messages: [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ],
    extra: maxTokens == null ? null : {'max_tokens': maxTokens},
  );
  return _extractAssistantText(response);
}

Future<HanakoChannel> _ensureGatewayChannel({
  required HanakoBackendClient gateway,
  required HanakoIdentity identity,
}) async {
  final current = gateway.channel;
  if (current != null && DateTime.now().isBefore(current.expiresAt)) {
    return current;
  }
  return gateway.handshake(keyPair: identity.keyPair);
}

String? _selectStoryModel(ModelManager modelManager, HanakoChannel channel) {
  final current = modelManager.currentModelId;
  if (current != null &&
      current.isNotEmpty &&
      channel.allowedModels.contains(current)) {
    return current;
  }
  if (channel.allowedModels.isNotEmpty) return channel.allowedModels.first;
  return current?.isEmpty == false ? current : null;
}

String _extractAssistantText(Map<String, dynamic> response) {
  final choices = response['choices'];
  if (choices is List) {
    for (final choice in choices) {
      if (choice is! Map) continue;
      final message = choice['message'];
      if (message is Map) {
        final content = message['content'];
        if (content is String && content.trim().isNotEmpty) {
          return content.trim();
        }
      }
      final text = choice['text'];
      if (text is String && text.trim().isNotEmpty) return text.trim();
    }
  }
  final content = response['content'];
  if (content is String && content.trim().isNotEmpty) return content.trim();
  throw StateError('AI 网关未返回故事正文');
}
