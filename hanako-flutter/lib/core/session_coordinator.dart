import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../identity/identity.dart';
import '../llm/provider.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'config_coordinator.dart';
import 'model_manager.dart';
import 'session.dart';

/// SessionCoordinator 与 legacy core/session-coordinator.js 对齐。
/// Phase 2 spike 版：能 createSession / switchSession / prompt（流式）/ listSessions。
class SessionCoordinator {
  SessionCoordinator({
    required this.home,
    required this.agentManager,
    required this.modelManager,
    required this.config,
    required this.identityRepository,
    required this.backendClient,
  });

  final HanaHome home;
  final AgentManager agentManager;
  final ModelManager modelManager;
  final ConfigCoordinator config;
  final IdentityRepository identityRepository;
  final HanakoBackendClient backendClient;

  Session? _current;
  final _uuid = const Uuid();

  Session? get current => _current;

  Future<Session> createSession({
    String? cwd,
    bool memoryEnabled = true,
  }) async {
    final agentId =
        agentManager.activeAgentId ??
        await agentManager.resolveDefaultAgentId();
    if (agentId == null) {
      throw StateError('No active agent');
    }
    final sessionId = _uuid.v4();
    final dir = home.agentSessions(agentId);
    final path = p.join(dir.path, '$sessionId.jsonl');
    File(path).writeAsStringSync('', flush: true);

    // 写 session-meta.json
    final metaFile = File(p.join(dir.path, 'session-meta.json'));
    Map<String, dynamic> meta = <String, dynamic>{};
    if (metaFile.existsSync()) {
      try {
        meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {}
    }
    meta[sessionId] = {
      'cwd': cwd,
      'memoryEnabled': memoryEnabled,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    metaFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(meta),
      flush: true,
    );

    final s = Session(
      path: path,
      title: '',
      agentId: agentId,
      cwd: cwd,
      memoryEnabled: memoryEnabled,
    );
    _current = s;
    return s;
  }

  Future<Session> switchSession(String sessionPath) async {
    final f = File(sessionPath);
    if (!f.existsSync()) throw StateError('Session not found: $sessionPath');
    final agentId = _agentIdFromPath(sessionPath);
    final meta = _readMeta(p.dirname(sessionPath));
    final sessionId = p.basenameWithoutExtension(sessionPath);
    final mEntry = meta[sessionId] as Map<String, dynamic>?;
    final s = Session(
      path: sessionPath,
      title: _readTitle(p.dirname(sessionPath), sessionId) ?? '',
      agentId: agentId,
      cwd: mEntry?['cwd'] as String?,
      memoryEnabled: mEntry?['memoryEnabled'] as bool? ?? true,
    );
    _current = s;
    return s;
  }

  /// 列出当前 agent 的所有 session。
  Future<List<SessionListEntry>> listSessions() async {
    final agentId = agentManager.activeAgentId;
    if (agentId == null) return const [];
    final dir = home.agentSessions(agentId);
    if (!dir.existsSync()) return const [];

    final titles = _readTitles(dir.path);
    final out = <SessionListEntry>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.jsonl')) continue;
      final sessionId = p.basenameWithoutExtension(f.path);
      out.add(
        SessionListEntry(
          path: f.path,
          title: titles[sessionId] ?? '',
          agentId: agentId,
          modified: f.statSync().modified,
        ),
      );
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// 流式发送一条消息。返回事件流。
  /// 所有 LLM 请求只通过 AI 网关短期加密通道发送。
  Stream<LlmEvent> prompt(String text) async* {
    if (_current == null) {
      await createSession();
    }
    final session = _current!;
    final cfg = config.read();

    final identity = identityRepository.current;
    if (identity == null) {
      yield LlmError(message: '请先创建或解锁子体身份');
      return;
    }

    var modelId = _configuredChatModelId(cfg) ?? modelManager.currentModelId;
    if (modelId == null || !modelManager.contains(modelId)) {
      try {
        await _syncGatewayModels(identity, preferredModelId: modelId);
      } catch (e) {
        yield LlmError(message: '同步模型列表失败：$e');
        return;
      }
      modelId = modelManager.currentModelId;
    }
    if (modelId == null || modelId.trim().isEmpty) {
      yield LlmError(message: '请先选择模型');
      return;
    }
    final channel = backendClient.channel;
    if (channel == null || DateTime.now().isAfter(channel.expiresAt)) {
      try {
        await _syncGatewayModels(identity, preferredModelId: modelId);
      } catch (e) {
        yield LlmError(message: '建立 AI 网关加密通道失败：$e');
        return;
      }
      modelId = modelManager.currentModelId;
      if (modelId == null || modelId.trim().isEmpty) {
        yield LlmError(message: '请先选择模型');
        return;
      }
    }

    // 加载历史 messages
    final history = _loadMessages(session.path);
    final user = Message(role: 'user', content: text);
    history.add(user);

    // 写入 user 消息
    _appendMessage(session.path, user);

    final assistantBuf = StringBuffer();
    await for (final chunk in backendClient.chatStream(
      model: modelId,
      messages: history.map((m) => m.toJson()).toList(),
    )) {
      assistantBuf.write(chunk);
      yield TextDelta(chunk);
    }
    _appendMessage(
      session.path,
      Message(role: 'assistant', content: assistantBuf.toString()),
    );
    yield const MessageDone();
  }

  // -- internals --
  String? _configuredChatModelId(Map<String, dynamic> cfg) {
    final models = cfg['models'] as Map?;
    final value = (models?['chat'] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _syncGatewayModels(
    HanakoIdentity identity, {
    String? preferredModelId,
  }) async {
    final channel = await backendClient.handshake(keyPair: identity.keyPair);
    GatewayModelList models;
    try {
      models = await backendClient.listModels(channelId: channel.channelId);
    } catch (_) {
      models = GatewayModelList(models: channel.allowedModels);
    }
    await modelManager.replaceAvailableModels(
      models.models,
      preferredModelId: preferredModelId,
    );
    final selected = modelManager.currentModelId;
    if (selected != null && selected.isNotEmpty) {
      config.writeAt(['models', 'chat'], selected);
    }
  }

  List<Message> _loadMessages(String sessionPath) {
    final f = File(sessionPath);
    if (!f.existsSync()) return [];
    final out = <Message>[];
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        final role = j['role'] as String?;
        final content = j['content'];
        if (role == null) continue;
        if (content is String) {
          out.add(Message(role: role, content: content));
        }
      } catch (_) {}
    }
    return out;
  }

  void _appendMessage(String sessionPath, Message msg) {
    final f = File(sessionPath);
    f.parent.createSync(recursive: true);
    final raf = f.openSync(mode: FileMode.append);
    try {
      raf.writeStringSync(
        jsonEncode({
              'role': msg.role,
              'content': msg.content,
              'ts': DateTime.now().toUtc().toIso8601String(),
            }) +
            '\n',
      );
    } finally {
      raf.closeSync();
    }
  }

  String _agentIdFromPath(String sessionPath) {
    // sessions/<sessionId>.jsonl 的父级是 sessions，再上一级是 agentDir
    final parent = Directory(sessionPath).parent;
    return p.basename(parent.parent.path);
  }

  Map<String, dynamic> _readMeta(String sessionsDir) {
    final f = File(p.join(sessionsDir, 'session-meta.json'));
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      return (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, String> _readTitles(String sessionsDir) {
    final f = File(p.join(sessionsDir, 'session-titles.json'));
    if (!f.existsSync()) return <String, String>{};
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return <String, String>{};
    }
  }

  String? _readTitle(String sessionsDir, String sessionId) =>
      _readTitles(sessionsDir)[sessionId];

  void saveTitle(String title) {
    if (_current == null) return;
    _current!.title = title;
    final dir = p.dirname(_current!.path);
    final f = File(p.join(dir, 'session-titles.json'));
    final titles = _readTitles(dir);
    final sessionId = p.basenameWithoutExtension(_current!.path);
    titles[sessionId] = title;
    f.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(titles),
      flush: true,
    );
  }
}

class SessionListEntry {
  final String path;
  final String title;
  final String agentId;
  final DateTime modified;
  SessionListEntry({
    required this.path,
    required this.title,
    required this.agentId,
    required this.modified,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    'agentId': agentId,
    'modified': modified.toIso8601String(),
  };
}
