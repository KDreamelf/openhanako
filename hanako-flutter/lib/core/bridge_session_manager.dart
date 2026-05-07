import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../bridge/bridge_adapter.dart';
import '../bridge/bridge_identity_resolver.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'config_coordinator.dart';
import 'model_manager.dart';
import 'preferences_manager.dart';
import 'session_coordinator.dart';

/// BridgeSessionManager 与 legacy core/bridge-session-manager.js 对齐。
///
/// 核心职责：
///   1. 维护 sessionKey → bridge session 的索引（持久化到 bridge-sessions.json）
///   2. 收到外部消息时路由到正确的 session（owner / guest 模式）：
///      - owner 模式：完整 agent 配置 + 工具集（按 preferences.bridge.readOnly 过滤）
///      - guest 模式：只读，system prompt = yuan + publicIshiki + contextTag
///   3. 调 SessionCoordinator.prompt 跑流式生成
///   4. 把生成的回复通过 BridgeAdapter 推回外部平台
///
/// **owner / guest 判断**：通过 [BridgeIdentityResolver] 抽象。当前默认走
/// [PreferencesBridgeIdentityResolver]（读 preferences.bridge.owner.{platform}）；
/// 等用户后端就位后可切换到 [RemoteBridgeIdentityResolver]。
class BridgeSessionManager {
  BridgeSessionManager({
    required this.home,
    required this.agentManager,
    required this.modelManager,
    required this.config,
    required this.preferences,
    required this.sessionCoordinator,
    BridgeIdentityResolver? identityResolver,
  }) : identityResolver =
           identityResolver ?? PreferencesBridgeIdentityResolver(preferences);

  final HanaHome home;
  final AgentManager agentManager;
  final ModelManager modelManager;
  final ConfigCoordinator config;
  final PreferencesManager preferences;
  final SessionCoordinator sessionCoordinator;
  final BridgeIdentityResolver identityResolver;

  final _adapters = <String, BridgeAdapter>{};
  final _streamingSessions = <String>{};
  final _adapterSubs = <String, StreamSubscription<IncomingMessage>>{};

  Future<void> register(BridgeAdapter adapter) async {
    _adapters[adapter.platform] = adapter;
    _adapterSubs[adapter.platform]?.cancel();
    _adapterSubs[adapter.platform] = adapter.messages.listen(
      (msg) => _onIncoming(adapter, msg),
    );
  }

  BridgeAdapter? get(String platform) => _adapters[platform];

  Future<void> unregister(String platform) async {
    await _adapterSubs.remove(platform)?.cancel();
    final adapter = _adapters.remove(platform);
    await adapter?.dispose();
  }

  bool isSessionStreaming(String sessionKey) =>
      _streamingSessions.contains(sessionKey);

  Future<bool> abortSession(String sessionKey) async {
    return _streamingSessions.remove(sessionKey);
  }

  Future<void> dispose() async {
    for (final sub in _adapterSubs.values) {
      await sub.cancel();
    }
    _adapterSubs.clear();
    for (final a in _adapters.values) {
      await a.dispose();
    }
    _adapters.clear();
  }

  // ---------------- bridge-sessions.json 索引 ----------------

  File _indexFile([String? targetAgentId]) {
    final agentId = targetAgentId ?? agentManager.activeAgentId;
    if (agentId == null || agentId.trim().isEmpty) {
      throw StateError('no active agent for bridge index');
    }
    final dir = Directory(
      p.join(home.agentDir(agentId).path, 'sessions', 'bridge'),
    )..createSync(recursive: true);
    return File(p.join(dir.path, 'bridge-sessions.json'));
  }

  Map<String, dynamic> readIndex([String? agentId]) {
    try {
      final f = _indexFile(agentId);
      if (!f.existsSync()) return <String, dynamic>{};
      return (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void writeIndex(Map<String, dynamic> index, [String? agentId]) {
    try {
      final f = _indexFile(agentId);
      f.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(index),
        flush: true,
      );
    } catch (_) {}
  }

  // ---------------- 收到外部消息 ----------------

  Future<void> _onIncoming(BridgeAdapter adapter, IncomingMessage msg) async {
    final platform = adapter.platform;
    final isGroup =
        (msg.raw['chat_type'] == 'group') ||
        (msg.chatId != null && msg.chatId!.startsWith('oc_')) ||
        (msg.raw['message']?['chat_type'] == 'group');
    final platformPrefix = switch (platform) {
      'telegram' => 'tg',
      'feishu' => 'fs',
      'lark' => 'fs',
      'qq' => 'qq',
      _ => platform,
    };
    final sessionKey = isGroup
        ? '${platformPrefix}_group_${msg.chatId ?? msg.userId}'
        : '${platformPrefix}_dm_${msg.userId}';

    // 决定 owner / guest（通过 BridgeIdentityResolver 抽象，未来可切换到远程实现）
    final scope = await identityResolver.resolve(
      platform: platform,
      externalUserId: msg.userId,
    );
    final isOwner = scope == HanakoIdentityScope.owner;

    String? reply;
    try {
      reply = await executeExternalMessage(
        msg.text,
        sessionKey,
        agentId: await _configuredAgentId(platform),
        meta: {'name': msg.userName, 'userId': msg.userId},
        guest: !isOwner,
        contextTag: '与外部用户 ($platform) 对话',
      );
    } catch (e) {
      reply = '桥接处理失败：${_humanError(e)}';
      // ignore: avoid_print
      print('[bridge] incoming failed: $e');
    }

    if (reply != null && reply.isNotEmpty && msg.chatId != null) {
      final result = await adapter.send(
        OutgoingMessage(chatId: msg.chatId!, text: reply),
      );
      if (result is BridgeError) {
        // 显式错误（规避 BUG-4 静默失败）
        // ignore: avoid_print
        print('[bridge] send failed: ${result.reason}');
      }
    }
  }

  String _humanError(Object error) {
    final text = error.toString();
    return text.startsWith('Bad state: ')
        ? text.substring('Bad state: '.length)
        : text;
  }

  /// 外部消息触发的 session prompt：根据 guest 标志决定模式。
  Future<String?> executeExternalMessage(
    String prompt,
    String sessionKey, {
    String? agentId,
    Map<String, dynamic>? meta,
    bool guest = true,
    String? contextTag,
  }) async {
    final targetAgentId = await _resolveTargetAgentId(agentId);
    final streamingKey = '$targetAgentId:$sessionKey';
    if (_streamingSessions.contains(streamingKey)) {
      // 已在生成中，把新消息追加到 buffer 由 SessionCoordinator 内部处理
      return null;
    }
    _streamingSessions.add(streamingKey);
    try {
      final index = readIndex(targetAgentId);
      final entry =
          (index[sessionKey] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      BridgePromptResult result;
      try {
        result = await sessionCoordinator.runBridgePrompt(
          agentId: targetAgentId,
          sessionKey: sessionKey,
          prompt: prompt,
          existingSessionPath: entry['sessionPath']?.toString(),
        );
      } catch (e) {
        // ignore: avoid_print
        print('[bridge] llm error: $e');
        rethrow;
      }
      // 更新索引
      final updated = <String, dynamic>{
        'agentId': targetAgentId,
        'sessionPath': result.sessionPath,
        'lastUsedAt': DateTime.now().toUtc().toIso8601String(),
        ...?meta,
        'guest': guest,
      };
      if (contextTag != null) updated['contextTag'] = contextTag;
      entry.addAll(updated);
      index[sessionKey] = entry;
      writeIndex(index, targetAgentId);
      return result.reply;
    } finally {
      _streamingSessions.remove(streamingKey);
    }
  }

  Future<String?> _configuredAgentId(String platform) async {
    final bridge = preferences.get<Map>('bridge');
    final key = platform == 'lark' ? 'feishu' : platform;
    final raw = bridge?[key];
    if (raw is Map) {
      final configured = raw['agentId']?.toString().trim();
      if (configured != null && configured.isNotEmpty) return configured;
    }
    return null;
  }

  Future<String> _resolveTargetAgentId(String? configuredAgentId) async {
    final clean = configuredAgentId?.trim();
    if (clean != null && clean.isNotEmpty) {
      final agent = await agentManager.getAgent(clean);
      if (agent == null) {
        throw StateError('桥接目标 Agent 不存在：$clean');
      }
      return clean;
    }
    final active = agentManager.activeAgentId;
    if (active != null && await agentManager.getAgent(active) != null) {
      return active;
    }
    final fallback = await agentManager.resolveDefaultAgentId();
    if (fallback == null) {
      throw StateError('没有可用 Agent');
    }
    return fallback;
  }

  /// session_key 解析（platform / type）。
  ({String? platform, String? type, String? id}) parseSessionKey(String key) {
    final m = RegExp(r'^(tg|fs|qq)_(dm|group)_(.+)$').firstMatch(key);
    if (m == null) return (platform: null, type: null, id: null);
    return (
      platform: switch (m.group(1)) {
        'tg' => 'telegram',
        'fs' => 'feishu',
        'qq' => 'qq',
        _ => null,
      },
      type: m.group(2),
      id: m.group(3),
    );
  }
}
