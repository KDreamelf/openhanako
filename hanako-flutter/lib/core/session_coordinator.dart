import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../identity/identity.dart';
import '../llm/provider.dart';
import '../local_tools/local_tools.dart';
import '../shared/hana_home.dart';
import '../windows_ops/windows_ops_capabilities.dart';
import '../windows_ops/windows_ops_client.dart';
import '../windows_ops/windows_ops_tools.dart';
import 'agent_runtime.dart';
import 'agent_manager.dart';
import 'config_coordinator.dart';
import 'model_manager.dart';
import 'runtime_session_store.dart';
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
    WindowsOpsClient? windowsOpsClient,
  }) : _windowsOpsClient = windowsOpsClient ?? WindowsOpsClient();

  final HanaHome home;
  final AgentManager agentManager;
  final ModelManager modelManager;
  final ConfigCoordinator config;
  final IdentityRepository identityRepository;
  final HanakoBackendClient backendClient;
  final WindowsOpsClient _windowsOpsClient;

  Session? _current;
  final _uuid = const Uuid();
  Future<WindowsOpsCapabilities>? _windowsOpsCapabilities;

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
    RuntimeSessionStore.createSessionFile(path, sessionId: sessionId, cwd: cwd);

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
    _writeSessionState(s);
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
    _writeSessionState(s);
    return s;
  }

  /// 恢复当前 agent 最近使用的 session。
  ///
  /// 旧版本没有 session-state.json 时，回退到最近修改的 JSONL，避免升级后
  /// 用户看起来像丢了历史。
  Future<Session?> restoreLastSession() async {
    if (_current != null && File(_current!.path).existsSync()) {
      return _current;
    }
    final agentId = agentManager.activeAgentId;
    if (agentId == null) return null;
    final dir = home.agentSessions(agentId);
    if (!dir.existsSync()) return null;

    final lastSessionId = _readSessionState(dir.path)['lastSessionId'];
    if (lastSessionId is String && lastSessionId.trim().isNotEmpty) {
      final path = p.join(dir.path, '${lastSessionId.trim()}.jsonl');
      if (File(path).existsSync()) {
        return switchSession(path);
      }
    }

    final sessions = await listSessions();
    if (sessions.isEmpty) return null;
    return switchSession(sessions.first.path);
  }

  List<Message> currentMessages() {
    final session = _current;
    if (session == null) return const [];
    return loadSessionMessages(session.path);
  }

  List<RuntimeDisplayMessage> currentDisplayMessages() {
    final session = _current;
    if (session == null) return const [];
    return loadSessionDisplayMessages(session.path);
  }

  List<Message> loadSessionMessages(String sessionPath) =>
      RuntimeSessionStore.loadVisibleMessages(sessionPath);

  List<RuntimeDisplayMessage> loadSessionDisplayMessages(String sessionPath) =>
      RuntimeSessionStore.loadDisplayMessages(sessionPath);

  void replaceCurrentMessages(List<Message> messages) {
    final session = _current;
    if (session == null) return;
    replaceSessionMessages(session.path, messages);
  }

  void replaceSessionMessages(String sessionPath, List<Message> messages) {
    RuntimeSessionStore.replaceVisibleMessages(
      sessionPath,
      messages,
      sessionId: p.basenameWithoutExtension(sessionPath),
      cwd: _current?.path == sessionPath ? _current?.cwd : null,
    );
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
  Stream<LlmEvent> prompt(String text, {CancelToken? cancelToken}) async* {
    yield* _runRuntimeTurn(
      cancelToken: cancelToken,
      run: (runtime) => runtime.runUserPrompt(text),
    );
  }

  /// 基于当前已落盘上下文继续当前轮次，不追加新的 user 消息。
  ///
  /// 用于瞬时上游错误后的重试：用户消息、已完成工具调用和工具结果已经由
  /// runtime 正常写入会话，重试时只需要继续 assistant turn。
  Stream<LlmEvent> retryCurrentTurn({CancelToken? cancelToken}) async* {
    yield* _runRuntimeTurn(
      cancelToken: cancelToken,
      run: (runtime) => runtime.continueAssistantTurn(),
    );
  }

  Stream<LlmEvent> _runRuntimeTurn({
    CancelToken? cancelToken,
    required Stream<LlmEvent> Function(AgentRuntimeLoop runtime) run,
  }) async* {
    if (_current == null) {
      await restoreLastSession();
    }
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

    try {
      final tools = await _buildAvailableTools();
      final selectedModelId = modelId.trim();
      final runtime = AgentRuntimeLoop(
        history: RuntimeSessionStore.loadRuntimeMessages(session.path),
        systemPrompt: await _buildSystemPrompt(session),
        tools: tools,
        streamChat: ({required messages, required tools, Object? toolChoice}) =>
            _chatEventsForRuntime(
              model: selectedModelId,
              messages: messages,
              tools: tools,
              toolChoice: toolChoice,
              cancelToken: cancelToken,
            ),
        executeTool: (call) => _executeToolCall(session, call),
        onNewMessages: (messages) {
          RuntimeSessionStore.appendMessages(
            session.path,
            messages,
            sessionId: p.basenameWithoutExtension(session.path),
            cwd: session.cwd,
          );
        },
      );

      await for (final event in run(runtime)) {
        yield event;
      }
    } catch (e) {
      yield LlmError(message: '发送对话失败：客户端处理异常', details: e.toString());
      return;
    }
  }

  // -- internals --
  Future<List<Tool>> _buildAvailableTools() async {
    final localTools = LocalToolRegistry.buildTools();
    final windowsTools = WindowsOpsToolRegistry.buildTools(
      await _resolveWindowsOpsCapabilities(),
    );
    return <Tool>[...localTools, ...windowsTools];
  }

  Future<WindowsOpsCapabilities> _resolveWindowsOpsCapabilities() {
    return _windowsOpsCapabilities ??=
        WindowsOpsCapabilityProbe(_windowsOpsClient).probe().catchError(
          (Object error) => WindowsOpsCapabilities.unavailable(
            unavailableReasons: <String, String>{'sidecar': error.toString()},
          ),
        );
  }

  Stream<LlmEvent> _chatEventsForRuntime({
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Tool> tools,
    Object? toolChoice,
    CancelToken? cancelToken,
  }) async* {
    try {
      await for (final event in backendClient.chatEvents(
        model: model,
        messages: messages,
        tools: tools,
        toolChoice: toolChoice,
        cancelToken: cancelToken,
      )) {
        yield event;
      }
    } on HanakoBackendException catch (e) {
      yield LlmError(
        message: e.message,
        statusCode: e.statusCode,
        details: e.details,
      );
    } catch (e) {
      yield LlmError(message: '发送对话失败：客户端处理异常', details: e.toString());
    }
  }

  Future<RuntimeToolExecutionResult> _executeToolCall(
    Session session,
    RuntimeToolCallBlock call,
  ) async {
    final args = call.arguments;
    final name = call.name.trim();
    if (_isWindowsOpsTool(name)) {
      try {
        final result = await WindowsOpsToolExecutor(
          _windowsOpsClient,
        ).execute(name, args);
        final content = const JsonEncoder.withIndent(
          '  ',
        ).convert({'ok': true, 'tool': name, 'result': result});
        return RuntimeToolExecutionResult(content: content);
      } catch (e) {
        return RuntimeToolExecutionResult(
          content: const JsonEncoder.withIndent('  ').convert({
            'ok': false,
            'tool': name,
            'error': 'windows_ops_failed',
            'message': e.toString(),
          }),
          isError: true,
        );
      }
    }
    final content = await LocalToolRegistry.execute(
      name,
      args,
      cwd: session.cwd,
      agentDir: home.agentDir(session.agentId).path,
    );
    return RuntimeToolExecutionResult(
      content: content,
      isError: _toolOutputIsError(content),
    );
  }

  bool _isWindowsOpsTool(String name) => switch (name) {
    WindowsOpsToolNames.captureRegion ||
    WindowsOpsToolNames.uiaTree ||
    WindowsOpsToolNames.uiaInvoke ||
    WindowsOpsToolNames.ocrRecognize ||
    WindowsOpsToolNames.uiParse => true,
    _ => false,
  };

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

  Future<String> _buildSystemPrompt(Session session) async {
    final agent = await agentManager.getAgent(session.agentId);
    final parts = <String>[
      '你运行在用户本机的“幻宙01”子体客户端中。',
      '需要本地信息或桌面操作时，使用请求中提供的原生 function tools；不要把工具调用写成正文。',
      '如果工具失败，说明失败原因和还缺什么信息。',
      if (session.cwd != null && session.cwd!.trim().isNotEmpty)
        '当前会话工作目录：${session.cwd}',
      if (agent != null) '当前 Agent：${agent.name} (${agent.id})',
      if (agent?.identity?.trim().isNotEmpty == true)
        'Agent 身份：\n${agent!.identity!.trim()}',
      if (agent?.ishiki?.trim().isNotEmpty == true)
        'Agent 意识/行为设定：\n${agent!.ishiki!.trim()}',
    ];
    return parts.where((part) => part.trim().isNotEmpty).join('\n\n');
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

  Map<String, dynamic> _readSessionState(String sessionsDir) {
    final f = File(p.join(sessionsDir, 'session-state.json'));
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      return (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _writeSessionState(Session session) {
    final dir = p.dirname(session.path);
    final sessionId = p.basenameWithoutExtension(session.path);
    final f = File(p.join(dir, 'session-state.json'));
    f.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'lastSessionId': sessionId,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

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

  Future<void> dispose() => _windowsOpsClient.dispose();
}

bool _toolOutputIsError(String content) {
  try {
    final decoded = jsonDecode(content);
    return decoded is Map && decoded['ok'] == false;
  } catch (_) {
    return false;
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
