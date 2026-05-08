import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

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
    final publicStoryCaller = _PublicStoryGatewayCaller(
      gateway,
      logFile: File(p.join(h.logsDir.path, 'public-story-recovery.jsonl')),
    );
    late final IdentityRepository identityRepo;
    late final ModelManager models;
    identityRepo =
        identityRepository ??
        IdentityRepository(
          keystore: PlatformSecureKeystore(hanaHome: h.root),
          composer: StoryComposer(caller: publicStoryCaller.call),
          parser: StoryParser(caller: publicStoryCaller.call),
          recoveryAccelerator: Platform.isWindows
              ? const WindowsRecoveryAccelerator()
              : null,
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

const int _publicStoryRateLimitMaxAttempts = 100;
const int _publicStoryMaxConcurrentCalls = 3;
const Duration _publicStoryRateLimitInitialBackoff = Duration(
  milliseconds: 350,
);
const Duration _publicStoryRateLimitMaxBackoff = Duration(seconds: 30);

class _PublicStoryGatewayCaller {
  _PublicStoryGatewayCaller(this.gateway, {required this.logFile});

  final HanakoBackendClient gateway;
  final File logFile;
  final Queue<_PublicStoryJob> _ready = Queue<_PublicStoryJob>();
  final Random _random = Random();
  Future<String>? _modelFuture;
  int _active = 0;
  int _sleeping = 0;
  int _nextJobId = 0;

  Future<String> call({
    required String systemPrompt,
    required String userPrompt,
    int? maxTokens,
  }) async {
    final response = await _enqueue(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
    );
    return _extractAssistantText(response);
  }

  Future<Map<String, dynamic>> _enqueue({
    required String systemPrompt,
    required String userPrompt,
  }) {
    final metadata = _detectPublicStoryJob(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
    );
    final job = _PublicStoryJob(
      id: ++_nextJobId,
      kind: metadata.kind,
      rowIndex: metadata.rowIndex,
      systemPromptChars: systemPrompt.length,
      userPromptChars: userPrompt.length,
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
    );
    _ready.add(job);
    _writeLog(
      'enqueue',
      job: job,
      fields: {
        'system_prompt_chars': systemPrompt.length,
        'user_prompt_chars': userPrompt.length,
      },
    );
    _pump();
    return job.completer.future;
  }

  void _pump() {
    while (_active < _publicStoryMaxConcurrentCalls && _ready.isNotEmpty) {
      final job = _ready.removeFirst();
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_PublicStoryJob job) async {
    final startedAt = DateTime.now();
    _writeLog('start', job: job);
    try {
      final model = await _resolveModel();
      final response = await gateway.publicStoryChat(
        model: model,
        messages: job.messages,
      );
      _writeLog(
        'success',
        job: job,
        fields: {
          'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
          'model': model,
        },
      );
      if (!job.completer.isCompleted) job.completer.complete(response);
    } on HanakoBackendException catch (error, stackTrace) {
      if (_isPublicStoryRateLimit(error) &&
          job.attempt < _publicStoryRateLimitMaxAttempts) {
        _scheduleRetry(job, error);
      } else if (!job.completer.isCompleted) {
        _writeLog(
          'failure',
          job: job,
          fields: {
            'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
            'max_attempts_exhausted':
                job.attempt >= _publicStoryRateLimitMaxAttempts,
            ..._backendErrorFields(error),
          },
        );
        job.completer.completeError(error, stackTrace);
      }
    } catch (error, stackTrace) {
      if (!job.completer.isCompleted) {
        _writeLog(
          'failure',
          job: job,
          fields: {
            'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
            ..._objectErrorFields(error),
          },
        );
        job.completer.completeError(error, stackTrace);
      }
    } finally {
      _active--;
      _pump();
    }
  }

  void _scheduleRetry(_PublicStoryJob job, HanakoBackendException error) {
    final failedAttempt = job.attempt;
    final delay = _publicStoryRateLimitBackoff(
      attempt: failedAttempt,
      random: _random,
    );
    job.attempt++;
    _sleeping++;
    _writeLog(
      'rate_limit_retry',
      job: job,
      fields: {
        'failed_attempt': failedAttempt,
        'next_attempt': job.attempt,
        'retry_delay_ms': delay.inMilliseconds,
        'retry_at': DateTime.now().add(delay).toUtc().toIso8601String(),
        ..._backendErrorFields(error),
      },
    );
    Timer(delay, () {
      _sleeping--;
      if (job.completer.isCompleted) return;
      _ready.add(job);
      _writeLog('retry_ready', job: job);
      _pump();
    });
  }

  Future<String> _resolveModel() {
    return _modelFuture ??= _loadModel();
  }

  Future<String> _loadModel() async {
    _writeLog('model_list_start');
    try {
      final modelList = await gateway.listPublicStoryModels();
      final model = _selectStoryModel(modelList.models);
      if (model == null) {
        throw StateError('未找到可用于故事生成/恢复的公开模型');
      }
      _writeLog(
        'model_list_success',
        fields: {
          'model_count': modelList.models.length,
          'selected_model': model,
        },
      );
      return model;
    } catch (error) {
      _writeLog('model_list_failure', fields: _objectErrorFields(error));
      rethrow;
    }
  }

  void _writeLog(
    String event, {
    _PublicStoryJob? job,
    Map<String, dynamic>? fields,
  }) {
    final now = DateTime.now();
    final payload = <String, dynamic>{
      'ts': now.toUtc().toIso8601String(),
      'event': event,
      'active': _active,
      'ready': _ready.length,
      'sleeping': _sleeping,
      'max_concurrency': _publicStoryMaxConcurrentCalls,
    };
    if (job != null) {
      payload.addAll({
        'job_id': job.id,
        'kind': job.kind,
        'attempt': job.attempt,
        'age_ms': now.difference(job.createdAt).inMilliseconds,
        'system_prompt_chars': job.systemPromptChars,
        'user_prompt_chars': job.userPromptChars,
      });
      if (job.rowIndex != null) {
        payload['row_index'] = job.rowIndex;
        payload['row_number'] = job.rowIndex! + 1;
      }
    }
    if (fields != null) payload.addAll(fields);

    try {
      logFile.parent.createSync(recursive: true);
      logFile.writeAsStringSync(
        '${jsonEncode(payload)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 诊断日志不能影响登录恢复主流程。
    }
  }
}

class _PublicStoryJob {
  _PublicStoryJob({
    required this.id,
    required this.kind,
    required this.rowIndex,
    required this.systemPromptChars,
    required this.userPromptChars,
    required this.messages,
  });

  final int id;
  final String kind;
  final int? rowIndex;
  final int systemPromptChars;
  final int userPromptChars;
  final DateTime createdAt = DateTime.now();
  final List<Map<String, dynamic>> messages;
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();
  int attempt = 1;
}

class _PublicStoryJobMetadata {
  const _PublicStoryJobMetadata({required this.kind, this.rowIndex});

  final String kind;
  final int? rowIndex;
}

_PublicStoryJobMetadata _detectPublicStoryJob({
  required String systemPrompt,
  required String userPrompt,
}) {
  if (systemPrompt.contains('记忆故事锚点提取器')) {
    return const _PublicStoryJobMetadata(kind: 'anchor_extraction');
  }
  if (systemPrompt.contains('语义候选生成器')) {
    final match = RegExp(r'当前只处理第\s*(\d+)\s*个锚点').firstMatch(userPrompt);
    final rowNumber = match == null ? null : int.tryParse(match.group(1)!);
    return _PublicStoryJobMetadata(
      kind: 'candidate_row',
      rowIndex: rowNumber == null ? null : rowNumber - 1,
    );
  }
  if (systemPrompt.contains('记忆宫殿故事生成器')) {
    return const _PublicStoryJobMetadata(kind: 'story_composition');
  }
  return const _PublicStoryJobMetadata(kind: 'unknown');
}

Map<String, dynamic> _backendErrorFields(HanakoBackendException error) {
  return {
    'error_type': error.runtimeType.toString(),
    'message': error.message,
    if (error.statusCode != null) 'status_code': error.statusCode,
    if (error.details != null && error.details!.isNotEmpty)
      'details': error.details,
  };
}

Map<String, dynamic> _objectErrorFields(Object error) {
  if (error is HanakoBackendException) {
    return _backendErrorFields(error);
  }
  return {'error_type': error.runtimeType.toString(), 'message': '$error'};
}

bool _isPublicStoryRateLimit(HanakoBackendException error) {
  if (error.statusCode == 429) return true;
  final text = '${error.message}\n${error.details ?? ''}'.toLowerCase();
  return text.contains('请求过于频繁') ||
      text.contains('too many requests') ||
      text.contains('rate limit') ||
      text.contains('rate_limit');
}

Duration _publicStoryRateLimitBackoff({
  required int attempt,
  required Random random,
}) {
  final multiplier = 1 << (attempt - 1);
  final exponentialMs =
      _publicStoryRateLimitInitialBackoff.inMilliseconds * multiplier;
  final cappedMs = exponentialMs.clamp(
    _publicStoryRateLimitInitialBackoff.inMilliseconds,
    _publicStoryRateLimitMaxBackoff.inMilliseconds,
  );
  final jitterMs = random.nextInt(cappedMs + 1);
  return Duration(
    milliseconds: _publicStoryRateLimitInitialBackoff.inMilliseconds + jitterMs,
  );
}

String? _selectStoryModel(List<String> models) {
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
