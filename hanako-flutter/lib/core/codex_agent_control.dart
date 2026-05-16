import 'dart:async';

import 'agent_manager.dart';

typedef CodexAgentPromptRunner =
    Future<String> Function({
      required String agentId,
      required String prompt,
      String? cwd,
      String? modelId,
      required String source,
    });

class CodexAgentControl {
  CodexAgentControl({required this.agentManager, required this.runPrompt});

  final AgentManager agentManager;
  final CodexAgentPromptRunner runPrompt;
  final _tasks = <String, _CodexAgentTask>{};
  int _nextTask = 1;

  Future<Map<String, dynamic>> spawnAgent(
    Map<String, dynamic> args, {
    String? sourceAgentId,
    String? cwd,
  }) async {
    final message = _stringArg(args, 'message');
    if (message == null) {
      return _error('missing_message', 'spawn_agent 需要 message。');
    }
    final taskName = _cleanTaskName(
      _stringArg(args, 'task_name') ?? 'task_${_nextTask++}',
    );
    final taskId = _uniqueTaskId(taskName);
    final agentId = await _resolveAgentId(args, sourceAgentId);
    final task = _CodexAgentTask(
      id: taskId,
      name: taskName,
      agentId: agentId,
      agentType: _stringArg(args, 'agent_type'),
      cwd: _stringArg(args, 'cwd') ?? cwd,
      modelId: _stringArg(args, 'model'),
      reasoningEffort: _stringArg(args, 'reasoning_effort'),
    );
    _tasks[taskId] = task;
    task.enqueueRun(message, runner: runPrompt, source: 'codex_agent:$taskId');
    return <String, dynamic>{
      'ok': true,
      'agent': task.toJson(),
      'message': 'Agent spawned and started.',
    };
  }

  Future<Map<String, dynamic>> sendMessage(Map<String, dynamic> args) async {
    final resolved = _targetTask(args);
    if (resolved == null) return _missingTarget();
    final message = _stringArg(args, 'message');
    if (message == null) {
      return _error('missing_message', 'send_message 需要 message。');
    }
    resolved.queueMessage(message);
    return <String, dynamic>{
      'ok': true,
      'agent': resolved.toJson(),
      'message': 'Message queued. Does not trigger a turn.',
    };
  }

  Future<Map<String, dynamic>> followupTask(Map<String, dynamic> args) async {
    final resolved = _targetTask(args);
    if (resolved == null) return _missingTarget();
    final message = _stringArg(args, 'message');
    if (message == null) {
      return _error('missing_message', 'followup_task 需要 message。');
    }
    final prompt = resolved.drainQueuedMessagesWith(message);
    resolved.enqueueRun(
      prompt,
      runner: runPrompt,
      source: 'codex_agent:${resolved.id}',
    );
    return <String, dynamic>{
      'ok': true,
      'agent': resolved.toJson(),
      'message': 'Follow-up queued and will trigger a turn.',
    };
  }

  Future<Map<String, dynamic>> waitAgent(Map<String, dynamic> args) async {
    final targets = _targets(args);
    if (targets.isEmpty) {
      return _error('missing_target', 'wait_agent 需要 target 或 targets。');
    }
    final timeoutMs = _timeoutMs(args);
    final tasks = <_CodexAgentTask>[];
    final missing = <String>[];
    for (final target in targets) {
      final task = _resolveTask(target);
      if (task == null) {
        missing.add(target);
      } else {
        tasks.add(task);
      }
    }
    if (tasks.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': 'target_not_found',
        'missing': missing,
        'message': '没有找到可等待的 Agent。',
      };
    }

    var timedOut = false;
    try {
      await Future.wait(
        tasks.map((task) => task.completion),
      ).timeout(Duration(milliseconds: timeoutMs));
    } on TimeoutException {
      timedOut = true;
    }
    return <String, dynamic>{
      'ok': true,
      'timed_out': timedOut,
      'agents': tasks.map((task) => task.toJson()).toList(growable: false),
      if (missing.isNotEmpty) 'missing': missing,
      'message': _waitSummary(tasks, timedOut),
    };
  }

  Future<Map<String, dynamic>> closeAgent(Map<String, dynamic> args) async {
    final resolved = _targetTask(args);
    if (resolved == null) return _missingTarget();
    final previousStatus = resolved.status;
    resolved.close();
    return <String, dynamic>{
      'ok': true,
      'previous_status': previousStatus,
      'agent': resolved.toJson(),
    };
  }

  Future<Map<String, dynamic>> listAgents(Map<String, dynamic> args) async {
    final prefix = _stringArg(args, 'path_prefix');
    final tasks = _tasks.values
        .where((task) => prefix == null || task.id.startsWith(prefix))
        .map((task) => task.toJson())
        .toList(growable: false);
    return <String, dynamic>{'ok': true, 'agents': tasks};
  }

  Future<String> _resolveAgentId(
    Map<String, dynamic> args,
    String? sourceAgentId,
  ) async {
    final requested =
        _stringArg(args, 'agent_id') ??
        _stringArg(args, 'agentId') ??
        _stringArg(args, 'agent');
    if (requested != null) {
      final existing = await agentManager.getAgent(requested);
      if (existing == null) {
        throw StateError('Agent $requested not found');
      }
      return requested;
    }
    if (sourceAgentId != null && sourceAgentId.trim().isNotEmpty) {
      return sourceAgentId.trim();
    }
    final resolved = await agentManager.resolveDefaultAgentId();
    if (resolved == null || resolved.trim().isEmpty) {
      throw StateError('No active agent');
    }
    return resolved;
  }

  _CodexAgentTask? _targetTask(Map<String, dynamic> args) {
    final target =
        _stringArg(args, 'target') ??
        _stringArg(args, 'agent') ??
        _stringArg(args, 'agent_id') ??
        _stringArg(args, 'task');
    if (target == null) return null;
    return _resolveTask(target);
  }

  _CodexAgentTask? _resolveTask(String target) {
    final clean = target.trim();
    final direct =
        _tasks[clean] ?? _tasks[clean.replaceAll(RegExp(r'^/+'), '')];
    if (direct != null) return direct;
    for (final task in _tasks.values) {
      if (task.name == clean) return task;
    }
    return null;
  }

  List<String> _targets(Map<String, dynamic> args) {
    final rawTargets = args['targets'];
    if (rawTargets is List) {
      return rawTargets
          .map((target) => target.toString().trim())
          .where((target) => target.isNotEmpty)
          .toList(growable: false);
    }
    final target = _stringArg(args, 'target');
    return target == null ? const <String>[] : <String>[target];
  }

  String _uniqueTaskId(String name) {
    var candidate = name;
    var suffix = 2;
    while (_tasks.containsKey(candidate)) {
      candidate = '${name}_$suffix';
      suffix++;
    }
    return candidate;
  }
}

class _CodexAgentTask {
  _CodexAgentTask({
    required this.id,
    required this.name,
    required this.agentId,
    this.agentType,
    this.cwd,
    this.modelId,
    this.reasoningEffort,
  }) : createdAt = DateTime.now().millisecondsSinceEpoch,
       updatedAt = DateTime.now().millisecondsSinceEpoch;

  final String id;
  final String name;
  final String agentId;
  final String? agentType;
  final String? cwd;
  final String? modelId;
  final String? reasoningEffort;
  final int createdAt;
  int updatedAt;
  String status = 'queued';
  String? lastTaskMessage;
  String? sessionPath;
  String? error;
  bool closed = false;
  final _queuedMessages = <String>[];
  Future<void> _tail = Future.value();

  Future<void> get completion => _tail;

  void queueMessage(String message) {
    if (closed) {
      error = 'Agent is closed';
      return;
    }
    _queuedMessages.add(message);
    lastTaskMessage = message;
    if (status == 'completed') status = 'message_queued';
    updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  String drainQueuedMessagesWith(String message) {
    final parts = <String>[..._queuedMessages, message];
    _queuedMessages.clear();
    lastTaskMessage = message;
    return parts.join('\n\n');
  }

  void enqueueRun(
    String message, {
    required CodexAgentPromptRunner runner,
    required String source,
  }) {
    if (closed) {
      error = 'Agent is closed';
      status = 'closed';
      updatedAt = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    lastTaskMessage = message;
    status = 'running';
    updatedAt = DateTime.now().millisecondsSinceEpoch;
    _tail = _tail.catchError((_) {}).then((_) async {
      if (closed) return;
      status = 'running';
      updatedAt = DateTime.now().millisecondsSinceEpoch;
      try {
        sessionPath = await runner(
          agentId: agentId,
          prompt: message,
          cwd: cwd,
          modelId: modelId,
          source: source,
        );
        if (!closed) status = 'completed';
        error = null;
      } catch (e) {
        if (!closed) status = 'failed';
        error = e.toString();
      } finally {
        updatedAt = DateTime.now().millisecondsSinceEpoch;
      }
    });
  }

  void close() {
    closed = true;
    status = 'closed';
    updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'task_name': name,
    'agent_id': agentId,
    'status': status,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'last_task_message': lastTaskMessage,
    if (agentType != null) 'agent_type': agentType,
    if (cwd != null) 'cwd': cwd,
    if (modelId != null) 'model': modelId,
    if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
    if (sessionPath != null) 'session_path': sessionPath,
    if (error != null) 'error': error,
    if (_queuedMessages.isNotEmpty) 'queued_messages': _queuedMessages.length,
  };
}

Map<String, dynamic> _error(String error, String message) => <String, dynamic>{
  'ok': false,
  'error': error,
  'message': message,
};

Map<String, dynamic> _missingTarget() =>
    _error('target_not_found', '没有找到目标 Agent。');

String? _stringArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

String _cleanTaskName(String raw) {
  final lower = raw.trim().toLowerCase();
  final normalized = lower.replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
  final clean = normalized.replaceAll(RegExp(r'_+'), '_');
  final trimmed = clean.replaceAll(RegExp(r'^_|_$'), '');
  return trimmed.isEmpty ? 'task' : trimmed;
}

int _timeoutMs(Map<String, dynamic> args) {
  final value = args['timeout_ms'] ?? args['yield_time_ms'];
  if (value is int) return value.clamp(100, 3600000);
  if (value is num) return value.toInt().clamp(100, 3600000);
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed.clamp(100, 3600000);
  }
  return 30000;
}

String _waitSummary(List<_CodexAgentTask> tasks, bool timedOut) {
  final statuses = tasks.map((task) => '${task.id}:${task.status}').join(', ');
  if (timedOut) {
    return 'Timed out waiting for agents. Current status: $statuses';
  }
  return 'Agents reached current completion point: $statuses';
}
