import 'dart:async';

import '../identity/identity.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'browser_manager.dart';
import 'bridge_source_manager.dart';
import 'activity_store.dart';
import 'bridge_session_manager.dart';
import 'channel_manager.dart';
import 'collaboration_manager.dart';
import 'config_coordinator.dart';
import 'cron_scheduler.dart';
import 'cron_store.dart';
import 'desk_manager.dart';
import 'heartbeat_runtime.dart';
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
    required this.activityStore,
    required this.cronStore,
    required this.cronScheduler,
    required this.heartbeatRuntime,
    required this.deskManager,
    required this.browserManager,
    required this.channelManager,
    required this.collaborationManager,
    required this.bridgeSessionManager,
    required this.bridgeSourceManager,
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
  final ActivityStore activityStore;
  final CronStore cronStore;
  final CronScheduler cronScheduler;
  final HeartbeatRuntime heartbeatRuntime;
  final DeskManager deskManager;
  final BrowserManager browserManager;
  final ChannelManager channelManager;
  final CollaborationManager collaborationManager;
  final BridgeSessionManager bridgeSessionManager;
  final BridgeSourceManager bridgeSourceManager;
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
                  modelManager: models,
                  systemPrompt: systemPrompt,
                  userPrompt: userPrompt,
                  maxTokens: maxTokens,
                ),
          ),
          parser: StoryParser(
            caller: ({required systemPrompt, required userPrompt, maxTokens}) =>
                _callGatewayForStory(
                  gateway: gateway,
                  modelManager: models,
                  systemPrompt: systemPrompt,
                  userPrompt: userPrompt,
                  maxTokens: maxTokens,
                ),
          ),
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

    final activityStore = ActivityStore(file: h.activityFile);
    final cronStore = CronStore(
      jobsFile: h.cronJobsFile,
      runsDir: h.cronRunsDir,
    );
    final skills = SkillManager(h);
    await skills.initialize();
    final browser = BrowserManager(preferences: prefs);
    final channels = ChannelManager(h);
    late final CronScheduler cronScheduler;
    final sessions = SessionCoordinator(
      home: h,
      agentManager: agents,
      modelManager: models,
      config: cfg,
      identityRepository: identityRepo,
      backendClient: gateway,
      cronStore: cronStore,
      runCronNow: (jobId) => cronScheduler.runNow(jobId),
      skillManager: skills,
      browserManager: browser,
      channelManager: channels,
    );
    cronScheduler = CronScheduler(
      cronStore: cronStore,
      executeJob: (job) => sessions.runIsolatedPrompt(
        agentId: job.agentId,
        prompt: job.prompt,
        modelId: job.model.isEmpty ? null : job.model,
        source: 'cron:${job.id}',
      ),
    );
    final heartbeat = HeartbeatRuntime(
      configFile: h.heartbeatConfigFile,
      registryFile: h.jianRegistryFile,
      activityStore: activityStore,
      resolveAgentId: () => agents.activeAgentId ?? activeId ?? '_no_agent',
      executeJian: ({required agentId, required prompt, required cwd}) =>
          sessions.runIsolatedPrompt(
            agentId: agentId,
            prompt: prompt,
            cwd: cwd,
            source: 'heartbeat',
          ),
    );

    final deskManager = DeskManager(h);
    final collaboration = CollaborationManager(
      preferences: prefs,
      agentManager: agents,
      channelManager: channels,
      activityStore: activityStore,
      executeAgentTask:
          ({required agentId, required prompt, modelId, required source}) =>
              sessions.runIsolatedPrompt(
                agentId: agentId,
                prompt: prompt,
                modelId: modelId,
                source: source,
              ),
    );
    sessions.collaborationManager = collaboration;
    final bridge = BridgeSessionManager(
      home: h,
      agentManager: agents,
      modelManager: models,
      config: cfg,
      preferences: prefs,
      sessionCoordinator: sessions,
    );
    final bridgeSources = BridgeSourceManager(
      preferences: prefs,
      bridgeSessionManager: bridge,
    );

    final eng = HanaEngine._(
      home: h,
      preferences: prefs,
      agentManager: agents,
      modelManager: models,
      config: cfg,
      identityRepository: identityRepo,
      backendClient: gateway,
      sessionCoordinator: sessions,
      activityStore: activityStore,
      cronStore: cronStore,
      cronScheduler: cronScheduler,
      heartbeatRuntime: heartbeat,
      deskManager: deskManager,
      browserManager: browser,
      channelManager: channels,
      collaborationManager: collaboration,
      bridgeSessionManager: bridge,
      bridgeSourceManager: bridgeSources,
      skillManager: skills,
    );
    eng._initialized = true;
    return eng;
  }

  bool get isInitialized => _initialized;

  void startAutomation() {
    cronScheduler.start();
    heartbeatRuntime.start();
    unawaited(bridgeSourceManager.startEnabled());
  }

  Future<void> dispose() async {
    await heartbeatRuntime.stop();
    await cronScheduler.stop();
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

Future<String> _callGatewayForStory({
  required HanakoBackendClient gateway,
  required ModelManager modelManager,
  required String systemPrompt,
  required String userPrompt,
  int? maxTokens,
}) async {
  final modelList = await gateway.listPublicStoryModels();
  final model = _selectStoryModel(modelManager, modelList.models);
  if (model == null) {
    throw StateError('未找到可用于故事生成/恢复的公开模型');
  }

  final response = await gateway.publicStoryChat(
    model: model,
    messages: [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ],
    extra: maxTokens == null ? null : {'max_tokens': maxTokens},
  );
  return _extractAssistantText(response);
}

String? _selectStoryModel(ModelManager modelManager, List<String> models) {
  final current = modelManager.currentModelId;
  if (current != null && current.isNotEmpty && models.contains(current)) {
    return current;
  }
  if (models.isNotEmpty) return models.first;
  return null;
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
