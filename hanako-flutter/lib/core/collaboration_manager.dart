import 'package:uuid/uuid.dart';

import '../channels/channel_store.dart';
import 'activity_store.dart';
import 'agent_manager.dart';
import 'channel_manager.dart';
import 'cron_scheduler.dart';
import 'preferences_manager.dart';
import 'runtime_session_store.dart';

typedef ExecuteAgentTask =
    Future<IsolatedCronSessionResult> Function({
      required String agentId,
      required String prompt,
      String? modelId,
      required String source,
    });

class CollaborationManager {
  CollaborationManager({
    required this.preferences,
    required this.agentManager,
    required this.channelManager,
    required this.activityStore,
    required this.executeAgentTask,
  });

  final PreferencesManager preferences;
  final AgentManager agentManager;
  final ChannelManager channelManager;
  final ActivityStore activityStore;
  final ExecuteAgentTask executeAgentTask;
  final _uuid = const Uuid();

  CollaborationSettings readSettings() {
    final raw = preferences.get<Map>('collaboration');
    return CollaborationSettings.fromJson(
      raw?.cast<String, dynamic>() ?? const <String, dynamic>{},
    );
  }

  void saveSettings(CollaborationSettings settings) {
    final prefs = preferences.getPreferences();
    prefs['collaboration'] = settings.toJson();
    preferences.savePreferences(prefs);
  }

  Future<Map<String, dynamic>> delegate(
    Map<String, dynamic> args, {
    required String? sourceAgentId,
    String toolName = 'delegate',
  }) async {
    final task =
        args['task']?.toString().trim() ?? args['message']?.toString().trim();
    if (task == null || task.isEmpty) {
      return _error('missing_task', '$toolName 需要 task/message 参数');
    }
    final target = await _resolveTargetAgent(
      args['agent']?.toString() ??
          args['to']?.toString() ??
          args['targetAgentId']?.toString(),
      sourceAgentId,
    );
    final settings = readSettings();
    final depth = _intValue(args['depth'], 0);
    if (depth >= settings.maxDepth) {
      return _logAndReturnLoopGuard(
        type: toolName,
        sourceAgentId: sourceAgentId,
        targetAgentId: target,
        summary: task,
      );
    }

    final startedAt = DateTime.now().toUtc();
    try {
      final result = await executeAgentTask(
        agentId: target,
        prompt: _delegatePrompt(
          sourceAgentId: sourceAgentId,
          task: task,
          depth: depth + 1,
        ),
        modelId: args['model']?.toString(),
        source: '$toolName:${sourceAgentId ?? "unknown"}',
      );
      final summary = _assistantSummary(result.sessionPath);
      activityStore.add(
        ActivityRecord(
          id: _uuid.v4(),
          type: toolName,
          agentId: target,
          status: 'success',
          label: 'from ${sourceAgentId ?? "unknown"}',
          summary: summary ?? task,
          sessionPath: result.sessionPath,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      final response = <String, dynamic>{
        'ok': true,
        'action': toolName,
        'agentId': target,
        'sessionPath': result.sessionPath,
        'message': '已委派给 $target',
      };
      if (summary != null) response['summary'] = summary;
      return response;
    } catch (e) {
      activityStore.add(
        ActivityRecord(
          id: _uuid.v4(),
          type: toolName,
          agentId: target,
          status: 'error',
          label: 'from ${sourceAgentId ?? "unknown"}',
          summary: task,
          error: e.toString(),
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      return _error('delegate_failed', '委派执行失败：$e');
    }
  }

  Future<Map<String, dynamic>> dm(
    Map<String, dynamic> args, {
    required String? sourceAgentId,
  }) async {
    final action = args['action']?.toString().trim();
    if (action == 'status') {
      return {'ok': true, 'settings': readSettings().toJson()};
    }
    if (action == 'configure') {
      final settings = readSettings().copyWith(
        dmAutoReply:
            _boolValue(args['auto_reply']) ??
            _boolValue(args['enabled']) ??
            readSettings().dmAutoReply,
      );
      saveSettings(settings);
      return {'ok': true, 'settings': settings.toJson()};
    }
    final message = args['message']?.toString().trim();
    if (message == null || message.isEmpty) {
      return _error('missing_message', 'dm 需要 message 参数');
    }
    return delegate(
      {...args, 'task': '收到来自 ${sourceAgentId ?? "unknown"} 的私信：\n$message'},
      sourceAgentId: sourceAgentId,
      toolName: 'dm',
    );
  }

  Future<Map<String, dynamic>> channel(
    Map<String, dynamic> args, {
    required String? sourceAgentId,
  }) async {
    final action = args['action']?.toString().trim();
    switch (action) {
      case 'status':
        return {'ok': true, 'settings': readSettings().toJson()};
      case 'configure':
        final current = readSettings();
        final settings = current.copyWith(
          channelAutoTriage:
              _boolValue(args['auto_triage']) ??
              _boolValue(args['enabled']) ??
              current.channelAutoTriage,
        );
        saveSettings(settings);
        return {'ok': true, 'settings': settings.toJson()};
      case 'list':
        final channels = await channelManager.listChannels();
        return {
          'ok': true,
          'channels': channels.map((channel) => channel.toJson()).toList(),
        };
      case 'create':
        final channel = await channelManager.createChannel(
          id: args['channel']?.toString(),
          name: args['name']?.toString(),
          description: args['description']?.toString(),
          members: _stringList(args['members']),
          intro: args['intro']?.toString(),
        );
        return {'ok': true, 'channel': channel.toJson()};
      case 'read':
        final id = args['channel']?.toString();
        if (id == null || id.trim().isEmpty) {
          return _error('missing_channel', 'channel read 需要 channel 参数');
        }
        final messages = await channelManager.readRecent(
          id,
          limit: _intValue(args['count'], 50),
        );
        return {
          'ok': true,
          'messages': messages.map((message) => message.toJson()).toList(),
        };
      case 'post':
        final id = args['channel']?.toString();
        final content = args['content']?.toString();
        if (id == null || id.trim().isEmpty) {
          return _error('missing_channel', 'channel post 需要 channel 参数');
        }
        if (content == null || content.trim().isEmpty) {
          return _error('missing_content', 'channel post 需要 content 参数');
        }
        final sender = args['sender']?.toString().trim();
        await channelManager.appendMessage(
          id,
          sender?.isNotEmpty == true
              ? sender!
              : 'agent:${sourceAgentId ?? "unknown"}',
          content,
        );
        final shouldTriage =
            _boolValue(args['triage']) ?? readSettings().channelAutoTriage;
        if (!shouldTriage) return {'ok': true, 'triage': 'disabled'};
        return triageChannel(
          id,
          sourceAgentId: sourceAgentId,
          requestedAgentId:
              args['agent']?.toString() ?? args['targetAgentId']?.toString(),
        );
      case 'triage':
        final id = args['channel']?.toString();
        if (id == null || id.trim().isEmpty) {
          return _error('missing_channel', 'channel triage 需要 channel 参数');
        }
        return triageChannel(
          id,
          sourceAgentId: sourceAgentId,
          requestedAgentId:
              args['agent']?.toString() ?? args['targetAgentId']?.toString(),
        );
      default:
        return _error('unknown_action', '未知 channel 操作：$action');
    }
  }

  Future<Map<String, dynamic>> triageChannel(
    String channelId, {
    required String? sourceAgentId,
    String? requestedAgentId,
  }) async {
    final settings = readSettings();
    if (!settings.channelAutoTriage && requestedAgentId == null) {
      return {
        'ok': true,
        'triage': 'skipped',
        'reason': 'auto_triage_disabled',
      };
    }
    final meta = await channelManager.readChannel(channelId);
    if (meta == null) {
      return _error('channel_not_found', '频道不存在：$channelId');
    }
    final recent = await channelManager.readRecent(channelId, limit: 12);
    if (recent.isEmpty) {
      return {'ok': true, 'triage': 'skipped', 'reason': 'empty_channel'};
    }
    final latest = recent.last;
    final target = await _selectChannelTarget(
      meta,
      latest,
      requestedAgentId,
      sourceAgentId,
    );
    if (target == null) {
      return {'ok': true, 'triage': 'skipped', 'reason': 'no_target_agent'};
    }
    if (_isLoop(latest, target)) {
      return _logAndReturnLoopGuard(
        type: 'channel_triage',
        sourceAgentId: sourceAgentId,
        targetAgentId: target,
        summary: latest.body,
      );
    }

    final startedAt = DateTime.now().toUtc();
    final prompt = _channelPrompt(meta, recent);
    try {
      final result = await executeAgentTask(
        agentId: target,
        prompt: prompt,
        source: 'channel:${meta.id}',
      );
      final summary = _assistantSummary(result.sessionPath) ?? '已处理频道消息';
      await channelManager.appendMessage(meta.id, 'agent:$target', summary);
      activityStore.add(
        ActivityRecord(
          id: _uuid.v4(),
          type: 'channel_triage',
          agentId: target,
          status: 'success',
          label: meta.id,
          summary: summary,
          sessionPath: result.sessionPath,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      return {
        'ok': true,
        'triage': 'triggered',
        'agentId': target,
        'sessionPath': result.sessionPath,
        'summary': summary,
      };
    } catch (e) {
      activityStore.add(
        ActivityRecord(
          id: _uuid.v4(),
          type: 'channel_triage',
          agentId: target,
          status: 'error',
          label: meta.id,
          summary: latest.body,
          error: e.toString(),
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      return _error('channel_triage_failed', '频道 triage 失败：$e');
    }
  }

  Future<String> _resolveTargetAgent(
    String? requested,
    String? sourceAgentId,
  ) async {
    final clean = requested?.trim();
    final agents = await agentManager.listAgents(forceRefresh: true);
    if (clean != null && clean.isNotEmpty) {
      if (agents.any((agent) => agent.id == clean)) return clean;
      throw StateError('目标 Agent 不存在：$clean');
    }
    for (final agent in agents) {
      if (agent.id != sourceAgentId) return agent.id;
    }
    throw StateError('没有可委派的目标 Agent');
  }

  Future<String?> _selectChannelTarget(
    ChannelMeta meta,
    ChannelMessage latest,
    String? requested,
    String? sourceAgentId,
  ) async {
    final clean = requested?.trim();
    if (clean != null && clean.isNotEmpty) {
      return _resolveTargetAgent(clean, sourceAgentId);
    }
    final mention = RegExp(r'@([A-Za-z0-9_-]+)').firstMatch(latest.body);
    final mentioned = mention?.group(1);
    if (mentioned != null && meta.members.contains(mentioned)) {
      return mentioned;
    }
    for (final member in meta.members) {
      if (member != sourceAgentId && latest.sender != 'agent:$member') {
        return member;
      }
    }
    return null;
  }

  bool _isLoop(ChannelMessage latest, String targetAgentId) {
    return latest.sender == targetAgentId ||
        latest.sender == 'agent:$targetAgentId' ||
        latest.body.contains('[auto:$targetAgentId]');
  }

  String _delegatePrompt({
    required String? sourceAgentId,
    required String task,
    required int depth,
  }) {
    return [
      '你收到一个多 Agent 委派任务。',
      '来源 Agent：${sourceAgentId ?? "unknown"}',
      '协作深度：$depth',
      '请独立完成任务，避免再次把同一任务委派回来源 Agent。',
      '',
      task,
    ].join('\n');
  }

  String _channelPrompt(ChannelMeta meta, List<ChannelMessage> recent) {
    final lines = recent
        .map((message) => '${message.sender}: ${message.body}')
        .join('\n\n');
    return [
      '你正在处理频道 ${meta.id} 的消息。',
      if (meta.name != null) '频道名：${meta.name}',
      if (meta.description != null) '说明：${meta.description}',
      '请根据最近消息给出需要发回频道的简短回复。',
      '',
      lines,
    ].join('\n');
  }

  String? _assistantSummary(String sessionPath) {
    final messages = RuntimeSessionStore.loadVisibleMessages(sessionPath);
    for (final message in messages.reversed) {
      if (message.role == 'assistant' && message.content.trim().isNotEmpty) {
        final content = message.content.trim();
        return content.length > 2000
            ? '${content.substring(0, 2000)}...'
            : content;
      }
    }
    return null;
  }

  Map<String, dynamic> _logAndReturnLoopGuard({
    required String type,
    required String? sourceAgentId,
    required String targetAgentId,
    required String summary,
  }) {
    final now = DateTime.now().toUtc();
    activityStore.add(
      ActivityRecord(
        id: _uuid.v4(),
        type: type,
        agentId: targetAgentId,
        status: 'skipped',
        label: 'from ${sourceAgentId ?? "unknown"}',
        summary: summary,
        error: 'loop_guard',
        startedAt: now,
        finishedAt: now,
      ),
    );
    return {
      'ok': false,
      'error': 'loop_guard',
      'message': '已阻止可能的循环协作。',
      'agentId': targetAgentId,
    };
  }

  Map<String, dynamic> _error(String code, String message) => {
    'ok': false,
    'error': code,
    'message': message,
  };
}

class CollaborationSettings {
  const CollaborationSettings({
    this.dmAutoReply = false,
    this.channelAutoTriage = false,
    this.maxDepth = 2,
  });

  final bool dmAutoReply;
  final bool channelAutoTriage;
  final int maxDepth;

  CollaborationSettings copyWith({
    bool? dmAutoReply,
    bool? channelAutoTriage,
    int? maxDepth,
  }) => CollaborationSettings(
    dmAutoReply: dmAutoReply ?? this.dmAutoReply,
    channelAutoTriage: channelAutoTriage ?? this.channelAutoTriage,
    maxDepth: maxDepth ?? this.maxDepth,
  );

  Map<String, dynamic> toJson() => {
    'dmAutoReply': dmAutoReply,
    'channelAutoTriage': channelAutoTriage,
    'maxDepth': maxDepth,
  };

  static CollaborationSettings fromJson(Map<String, dynamic> json) {
    return CollaborationSettings(
      dmAutoReply: json['dmAutoReply'] == true,
      channelAutoTriage: json['channelAutoTriage'] == true,
      maxDepth: _intValue(json['maxDepth'], 2).clamp(1, 8),
    );
  }
}

List<String> _stringList(Object? raw) {
  if (raw is List) {
    return raw
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  final text = raw?.toString() ?? '';
  if (text.trim().isEmpty) return const [];
  return text
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

int _intValue(Object? raw, int fallback) {
  if (raw is int) return raw;
  return int.tryParse(raw?.toString() ?? '') ?? fallback;
}

bool? _boolValue(Object? raw) {
  if (raw is bool) return raw;
  final text = raw?.toString().toLowerCase().trim();
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return null;
}
