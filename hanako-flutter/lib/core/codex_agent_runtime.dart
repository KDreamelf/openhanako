import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../llm/provider.dart';
import '../local_tools/local_tools.dart';
import '../windows_ops/windows_ops_capabilities.dart';
import '../windows_ops/windows_ops_client.dart';
import '../windows_ops/windows_ops_tools.dart';
import 'agent_runtime.dart';
import 'browser_manager.dart';
import 'codex_agent_control.dart';
import 'cron_store.dart';
import 'preferences_manager.dart';
import 'skill_manager.dart';

/// Codex 风格的工具运行时。
///
/// 该文件移植 Codex Agent 执行引擎的核心组织方式：工具以 Handler 形式注册，
/// Router 只负责可见工具列表和调用路由，Runtime 负责并行策略与错误归一化。
class CodexAgentToolRuntime {
  CodexAgentToolRuntime({required CodexToolRouter router}) : _router = router;

  final CodexToolRouter _router;

  List<Tool> get modelVisibleTools => _router.modelVisibleTools;

  Future<RuntimeToolExecutionResult> execute(RuntimeToolCallBlock call) {
    return _router.dispatchRuntimeCall(call);
  }

  Future<List<RuntimeToolExecutionResult>> executeAll(
    List<RuntimeToolCallBlock> calls,
  ) async {
    final results = List<RuntimeToolExecutionResult?>.filled(
      calls.length,
      null,
    );
    final parallelBatch = <_PendingParallelCall>[];

    Future<void> flushParallelBatch() async {
      if (parallelBatch.isEmpty) return;
      final completed = await Future.wait(
        parallelBatch.map((pending) async {
          final result = await _router.dispatchRuntimeCall(pending.call);
          return MapEntry(pending.index, result);
        }),
      );
      for (final entry in completed) {
        results[entry.key] = entry.value;
      }
      parallelBatch.clear();
    }

    for (var i = 0; i < calls.length; i++) {
      final call = calls[i];
      if (_router.toolSupportsParallel(call.name)) {
        parallelBatch.add(_PendingParallelCall(i, call));
        continue;
      }
      await flushParallelBatch();
      results[i] = await _router.dispatchRuntimeCall(call);
    }
    await flushParallelBatch();
    return results.cast<RuntimeToolExecutionResult>();
  }
}

class _PendingParallelCall {
  const _PendingParallelCall(this.index, this.call);

  final int index;
  final RuntimeToolCallBlock call;
}

class CodexToolRouter {
  CodexToolRouter(this._registry);

  final CodexToolRegistry _registry;

  List<Tool> get modelVisibleTools => _registry.modelVisibleTools;

  bool toolSupportsParallel(String name) {
    return _registry.handlerFor(name)?.supportsParallelToolCalls ?? false;
  }

  Future<RuntimeToolExecutionResult> dispatchRuntimeCall(
    RuntimeToolCallBlock call,
  ) {
    final invocation = CodexToolInvocation(
      callId: call.id,
      toolName: call.name,
      arguments: call.arguments,
      rawArgumentsJson: call.openAiArgumentsJson,
    );
    return _registry.dispatch(invocation);
  }
}

class CodexToolRegistry {
  CodexToolRegistry._(this._handlers, this._visibleSpecs);

  final Map<String, CodexToolHandler> _handlers;
  final List<Tool> _visibleSpecs;

  List<Tool> get modelVisibleTools => List.unmodifiable(_visibleSpecs);

  CodexToolHandler? handlerFor(String name) => _handlers[name.trim()];

  Future<RuntimeToolExecutionResult> dispatch(
    CodexToolInvocation invocation,
  ) async {
    final handler = handlerFor(invocation.toolName);
    if (handler == null) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'unknown_tool',
        'tool': invocation.toolName,
        'message': '当前 Codex 工具注册表中没有这个工具。',
      }, isError: true);
    }
    try {
      var nextInvocation = invocation;
      final preResult = await handler.beforeToolUse(nextInvocation);
      if (preResult != null) nextInvocation = preResult;
      var result = await handler.handle(nextInvocation);
      final postResult = await handler.afterToolUse(nextInvocation, result);
      if (postResult != null) result = postResult;
      return result;
    } catch (e, st) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'tool_failed',
        'tool': invocation.toolName,
        'message': e.toString(),
        'stack': st.toString().split('\n').take(12).join('\n'),
      }, isError: true);
    }
  }
}

class CodexToolRegistryBuilder {
  final _handlers = <String, CodexToolHandler>{};
  final _visibleSpecs = <Tool>[];

  void register(CodexToolHandler handler) {
    final name = handler.toolName.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(handler.toolName, 'toolName', '工具名不能为空');
    }
    final previous = _handlers[name];
    if (previous != null) {
      throw StateError('重复注册 Codex 工具：$name');
    }
    _handlers[name] = handler;
    final spec = handler.spec;
    if (spec != null) _visibleSpecs.add(spec);
  }

  CodexToolRegistry build() {
    return CodexToolRegistry._(
      Map.unmodifiable(_handlers),
      List.unmodifiable(_visibleSpecs),
    );
  }
}

class CodexToolInvocation {
  const CodexToolInvocation({
    required this.callId,
    required this.toolName,
    required this.arguments,
    required this.rawArgumentsJson,
  });

  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String rawArgumentsJson;
}

abstract class CodexToolHandler {
  String get toolName;

  Tool? get spec;

  CodexToolSearchInfo? get searchInfo => spec == null
      ? null
      : CodexToolSearchInfo(name: toolName, description: spec!.description);

  bool get supportsParallelToolCalls => false;

  CodexToolArgumentDiffConsumer? createDiffConsumer() => null;

  FutureOr<CodexToolInvocation?> beforeToolUse(
    CodexToolInvocation invocation,
  ) => null;

  FutureOr<RuntimeToolExecutionResult?> afterToolUse(
    CodexToolInvocation invocation,
    RuntimeToolExecutionResult result,
  ) => null;

  Future<RuntimeToolExecutionResult> handle(CodexToolInvocation invocation);
}

abstract class CodexToolArgumentDiffConsumer {
  void consumeDiff(String callId, String diff);

  Object? finish() => null;
}

class CodexToolSearchInfo {
  const CodexToolSearchInfo({required this.name, required this.description});

  final String name;
  final String description;
}

class CodexToolContext {
  const CodexToolContext({
    required this.cwd,
    required this.agentDir,
    required this.activeAgentId,
    required this.windowsOpsClient,
    required this.permissionPolicy,
    this.sessionPath,
    this.userInputPrompt,
    this.agentControl,
    this.goalStore,
    this.cronStore,
    this.runCronNow,
    this.skillManager,
    this.browserManager,
  });

  final String? cwd;
  final String? agentDir;
  final String? activeAgentId;
  final String? sessionPath;
  final WindowsOpsClient windowsOpsClient;
  final CodexPermissionPolicy permissionPolicy;
  final CodexUserInputPrompt? userInputPrompt;
  final CodexAgentControl? agentControl;
  final CodexGoalStore? goalStore;
  final CronStore? cronStore;
  final Future<CronRunRecord> Function(String jobId)? runCronNow;
  final SkillManager? skillManager;
  final BrowserManager? browserManager;
}

class CodexGoalStore {
  final _goals = <String, CodexThreadGoal>{};

  CodexThreadGoal? getGoal(String threadKey) => _goals[threadKey];

  CodexThreadGoal createGoal({
    required String threadKey,
    required String objective,
    int? tokenBudget,
  }) {
    final existing = _goals[threadKey];
    if (existing != null && existing.status != 'complete') {
      throw StateError('This thread already has an active goal.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final goal = CodexThreadGoal(
      id: 'goal_$now',
      objective: objective,
      status: 'active',
      tokenBudget: tokenBudget,
      createdAt: now,
      updatedAt: now,
    );
    _goals[threadKey] = goal;
    return goal;
  }

  CodexThreadGoal completeGoal(String threadKey) {
    final existing = _goals[threadKey];
    if (existing == null) {
      throw StateError('No active goal exists for this thread.');
    }
    final updated = existing.copyWith(
      status: 'complete',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _goals[threadKey] = updated;
    return updated;
  }
}

class CodexThreadGoal {
  const CodexThreadGoal({
    required this.id,
    required this.objective,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.tokenBudget,
  });

  final String id;
  final String objective;
  final String status;
  final int createdAt;
  final int updatedAt;
  final int? tokenBudget;

  CodexThreadGoal copyWith({String? status, int? updatedAt}) => CodexThreadGoal(
    id: id,
    objective: objective,
    status: status ?? this.status,
    tokenBudget: tokenBudget,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'goal_id': id,
    'objective': objective,
    'status': status,
    'created_at': createdAt,
    'updated_at': updatedAt,
    if (tokenBudget != null) 'token_budget': tokenBudget,
    if (tokenBudget != null) 'remaining_token_budget': tokenBudget,
  };
}

enum CodexPermissionMode {
  prompt,
  autoApprove,
  deny;

  static CodexPermissionMode fromPreferences(PreferencesManager preferences) {
    final codex = preferences.get<Map>('codex');
    final raw =
        (codex?['permission_mode'] ??
                codex?['permissions'] ??
                codex?['permissionMode'])
            ?.toString()
            .trim()
            .toLowerCase();
    return switch (raw) {
      'auto_approve' ||
      'autoapprove' ||
      'full' ||
      'always' => CodexPermissionMode.autoApprove,
      'deny' || 'never' => CodexPermissionMode.deny,
      _ => CodexPermissionMode.prompt,
    };
  }
}

class CodexPermissionRequest {
  const CodexPermissionRequest({
    required this.callId,
    required this.reason,
    required this.permissions,
  });

  final String callId;
  final String? reason;
  final Map<String, dynamic> permissions;
}

class CodexPermissionDecision {
  const CodexPermissionDecision({
    required this.approved,
    required this.scope,
    this.permissions = const <String, dynamic>{},
    this.message,
  });

  final bool approved;
  final String scope;
  final Map<String, dynamic> permissions;
  final String? message;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'approved': approved,
    'scope': scope,
    'permissions': permissions,
    if (message != null) 'message': message,
  };
}

typedef CodexPermissionPrompt =
    Future<CodexPermissionDecision?> Function(CodexPermissionRequest request);

class CodexUserInputOption {
  const CodexUserInputOption({required this.label, this.description});

  final String label;
  final String? description;
}

class CodexUserInputQuestion {
  const CodexUserInputQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.options,
  });

  final String id;
  final String header;
  final String question;
  final List<CodexUserInputOption> options;
}

class CodexUserInputRequest {
  const CodexUserInputRequest({required this.callId, required this.questions});

  final String callId;
  final List<CodexUserInputQuestion> questions;
}

class CodexUserInputResponse {
  const CodexUserInputResponse({required this.answers, this.cancelled = false});

  final Map<String, String> answers;
  final bool cancelled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cancelled': cancelled,
    'answers': answers,
  };
}

typedef CodexUserInputPrompt =
    Future<CodexUserInputResponse?> Function(CodexUserInputRequest request);

class CodexPermissionPolicy {
  const CodexPermissionPolicy({required this.mode, this.prompt});

  final CodexPermissionMode mode;
  final CodexPermissionPrompt? prompt;

  Future<CodexPermissionDecision> request(
    CodexPermissionRequest request,
  ) async {
    switch (mode) {
      case CodexPermissionMode.autoApprove:
        return CodexPermissionDecision(
          approved: true,
          scope: 'session',
          permissions: request.permissions,
          message: '已按客户端“完全授权”模式自动批准。',
        );
      case CodexPermissionMode.deny:
        return const CodexPermissionDecision(
          approved: false,
          scope: 'none',
          message: '已按客户端权限模式自动拒绝。',
        );
      case CodexPermissionMode.prompt:
        final decision = await prompt?.call(request);
        return decision ??
            const CodexPermissionDecision(
              approved: false,
              scope: 'none',
              message: '当前客户端没有可用的权限确认界面回调。',
            );
    }
  }
}

class CodexProcessSessionStore {
  final _sessions = <int, _CodexProcessSession>{};
  var _nextSessionId = 1;

  Future<Map<String, dynamic>> start({
    required String command,
    required String? workdir,
    required int yieldTimeMs,
    required int? maxOutputTokens,
  }) async {
    final process = await _startInteractiveShellProcess(command, workdir);
    final id = _nextSessionId++;
    final session = _CodexProcessSession(
      id: id,
      command: command,
      workdir: workdir,
      process: process,
    );
    _sessions[id] = session;
    await session.waitForOutput(Duration(milliseconds: yieldTimeMs));
    return session.snapshot(maxOutputTokens: maxOutputTokens);
  }

  Future<Map<String, dynamic>> write({
    required int sessionId,
    required String? chars,
    required int yieldTimeMs,
    required int? maxOutputTokens,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) {
      return <String, dynamic>{
        'ok': false,
        'error': 'unknown_pty_session',
        'session_id': sessionId,
        'message': '没有找到这个 Codex 长进程会话。',
      };
    }
    final text = chars ?? '';
    if (text.isNotEmpty) {
      if (!session.isRunning) {
        return <String, dynamic>{
          'ok': false,
          'error': 'pty_session_exited',
          'session_id': sessionId,
          'exit_code': session.exitCode,
          'message': '这个 Codex 长进程会话已经退出。',
        };
      }
      await session.write(text);
    }
    await session.waitForOutput(Duration(milliseconds: yieldTimeMs));
    return <String, dynamic>{
      'ok': true,
      ...session.snapshot(maxOutputTokens: maxOutputTokens),
    };
  }

  Future<void> dispose() async {
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      await session.dispose();
    }
  }
}

class _CodexProcessSession {
  _CodexProcessSession({
    required this.id,
    required this.command,
    required this.workdir,
    required this.process,
  }) {
    process.stdin.encoding = systemEncoding;
    _stdoutSubscription = process.stdout.listen((bytes) {
      _appendStdout(systemEncoding.decode(bytes));
    });
    _stderrSubscription = process.stderr.listen((bytes) {
      _appendStderr(systemEncoding.decode(bytes));
    });
    process.exitCode.then((code) {
      exitCode = code;
      _pulse();
    });
  }

  static const _maxBufferedChars = 256 * 1024;

  final int id;
  final String command;
  final String? workdir;
  final Process process;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;
  final _pulseController = StreamController<void>.broadcast();
  var _stdout = '';
  var _stderr = '';
  int? exitCode;

  bool get isRunning => exitCode == null;

  Future<void> write(String chars) async {
    process.stdin.write(chars);
    await process.stdin.flush();
  }

  Future<void> waitForOutput(Duration duration) async {
    if (duration <= Duration.zero) return;
    await Future<void>.delayed(duration);
  }

  Map<String, dynamic> snapshot({required int? maxOutputTokens}) {
    final maxChars = _maxOutputChars(maxOutputTokens);
    return <String, dynamic>{
      'session_id': id,
      'command': command,
      if (workdir != null) 'workdir': workdir,
      'running': isRunning,
      if (exitCode != null) 'exit_code': exitCode,
      'stdout': _tail(_stdout, maxChars),
      'stderr': _tail(_stderr, maxChars),
      'stdout_truncated': _stdout.length > maxChars,
      'stderr_truncated': _stderr.length > maxChars,
    };
  }

  Future<void> dispose() async {
    if (isRunning) {
      try {
        await process.stdin.close();
      } catch (_) {
        // The process may already have closed stdin.
      }
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      // If the process ignores termination, release Dart-side resources anyway.
    }
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _pulseController.close();
    if (Platform.isWindows) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  void _appendStdout(String value) {
    _stdout = _trimBuffered(_stdout + value);
    _pulse();
  }

  void _appendStderr(String value) {
    _stderr = _trimBuffered(_stderr + value);
    _pulse();
  }

  String _trimBuffered(String value) {
    if (value.length <= _maxBufferedChars) return value;
    return value.substring(value.length - _maxBufferedChars);
  }

  void _pulse() {
    if (!_pulseController.isClosed) {
      _pulseController.add(null);
    }
  }
}

class CodexAgentToolRuntimeFactory {
  const CodexAgentToolRuntimeFactory._();

  static Future<CodexAgentToolRuntime> build({
    required CodexToolContext context,
    required WindowsOpsCapabilities windowsOpsCapabilities,
    CodexProcessSessionStore? processSessions,
  }) async {
    final builder = CodexToolRegistryBuilder();
    final sessions = processSessions ?? CodexProcessSessionStore();
    final localSpecs = LocalToolRegistry.buildTools();
    for (final spec in localSpecs) {
      builder.register(
        _LocalRegistryToolHandler(
          spec: spec,
          context: context,
          supportsParallel: _localToolSupportsParallel(spec.name),
        ),
      );
    }
    builder
      ..register(_ReadFileToolHandler(context))
      ..register(_ListDirToolHandler(context))
      ..register(_SearchTextToolHandler(context))
      ..register(_ExecCommandToolHandler(context, sessions))
      ..register(_WriteStdinToolHandler(sessions))
      ..register(_ApplyPatchToolHandler(context))
      ..register(_RequestUserInputToolHandler(context))
      ..register(_RequestPermissionsToolHandler(context))
      ..register(_ViewImageToolHandler(context))
      ..register(_SpawnAgentToolHandler(context))
      ..register(_SendMessageToolHandler(context))
      ..register(_FollowupTaskToolHandler(context))
      ..register(_WaitAgentToolHandler(context))
      ..register(_CloseAgentToolHandler(context))
      ..register(_ListAgentsToolHandler(context))
      ..register(_GetGoalToolHandler(context))
      ..register(_CreateGoalToolHandler(context))
      ..register(_UpdateGoalStatusToolHandler(context))
      ..register(_ToolSearchHandler(builder))
      ..register(_UpdatePlanToolHandler());

    for (final spec in WindowsOpsToolRegistry.buildTools(
      windowsOpsCapabilities,
    )) {
      builder.register(_WindowsOpsToolHandler(spec: spec, context: context));
    }

    return CodexAgentToolRuntime(router: CodexToolRouter(builder.build()));
  }
}

class _LocalRegistryToolHandler extends CodexToolHandler {
  _LocalRegistryToolHandler({
    required Tool spec,
    required this.context,
    required this.supportsParallel,
  }) : _spec = spec,
       _toolName = spec.name;

  final Tool? _spec;
  final String _toolName;
  final CodexToolContext context;
  final bool supportsParallel;

  @override
  String get toolName => _toolName;

  @override
  Tool? get spec => _spec;

  @override
  bool get supportsParallelToolCalls => supportsParallel;

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final content = await LocalToolRegistry.execute(
      invocation.toolName,
      invocation.arguments,
      cwd: context.cwd,
      agentDir: context.agentDir,
      activeAgentId: context.activeAgentId,
      cronStore: context.cronStore,
      runCronNow: context.runCronNow,
      skillManager: context.skillManager,
      browserManager: context.browserManager,
      sessionPath: context.sessionPath,
    );
    return RuntimeToolExecutionResult(
      content: content,
      isError: _toolOutputIsError(content),
    );
  }
}

class _WindowsOpsToolHandler extends CodexToolHandler {
  _WindowsOpsToolHandler({required this.spec, required this.context});

  @override
  final Tool spec;

  final CodexToolContext context;

  @override
  String get toolName => spec.name;

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    try {
      final result = await WindowsOpsToolExecutor(
        context.windowsOpsClient,
      ).execute(invocation.toolName, invocation.arguments);
      return _jsonResult(<String, dynamic>{
        'ok': true,
        'tool': invocation.toolName,
        'result': result,
      });
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': invocation.toolName,
        'error': 'windows_ops_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _ReadFileToolHandler extends CodexToolHandler {
  _ReadFileToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'read_file';

  @override
  bool get supportsParallelToolCalls => true;

  @override
  Tool get spec => const Tool(
    name: 'read_file',
    description:
        '从本地文件系统读取文本文件，优先于 exec_command(cat/head/tail/type/Get-Content)。'
        '如果用户提供文件路径，先按该路径尝试读取；文件不存在会返回结构化错误。'
        '参数使用 PH01 schema：path 必填；可用 start_line/end_line 控制 1-based 行范围；省略行范围时读取全文。'
        '结果按类似 cat -n 的格式返回 1-based 行号和截断信息。此工具只读取文本文件，不读取目录；目录用 list_dir，图片用 view_image。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
        'start_line': <String, dynamic>{'type': 'integer', 'minimum': 1},
        'end_line': <String, dynamic>{'type': 'integer', 'minimum': 1},
      },
      'required': <String>['path'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final rawPath = _stringArg(invocation.arguments, 'path');
    if (rawPath == null || rawPath.trim().isEmpty) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'missing_path',
        'message': 'read_file 需要 path。',
      }, isError: true);
    }
    try {
      final path = _resolveToolPath(rawPath, context.cwd);
      final file = File(path);
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'file_not_found',
          'path': path,
          'message': '文件不存在：$path',
        }, isError: true);
      }
      if (type != FileSystemEntityType.file) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'not_a_file',
          'path': path,
          'message': 'read_file 只能读取文件；目录请使用 list_dir。',
        }, isError: true);
      }
      final bytes = await file.readAsBytes();
      if (_looksBinary(bytes)) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'binary_file',
          'path': path,
          'size_bytes': bytes.length,
          'message': '目标看起来不是文本文件；图片请使用 view_image。',
        }, isError: true);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      final totalLines = lines.length;
      final startLine = _readStartLine(invocation.arguments);
      final endLine = _readEndLine(
        arguments: invocation.arguments,
        startLine: startLine,
        totalLines: totalLines,
      );
      final selected = <String>[];
      for (var lineNo = startLine; lineNo <= endLine; lineNo++) {
        if (lineNo < 1 || lineNo > totalLines) continue;
        selected.add('${lineNo.toString().padLeft(6)}\t${lines[lineNo - 1]}');
      }
      return _jsonResult(<String, dynamic>{
        'ok': true,
        'tool': toolName,
        'path': path,
        'start_line': startLine,
        'end_line': endLine,
        'total_lines': totalLines,
        'truncated': endLine < totalLines || startLine > 1,
        'content': selected.join('\n'),
      });
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'read_file_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _ListDirToolHandler extends CodexToolHandler {
  _ListDirToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'list_dir';

  @override
  bool get supportsParallelToolCalls => true;

  @override
  Tool get spec => const Tool(
    name: 'list_dir',
    description:
        '列出本地目录树，用于了解工作区结构、定位文件夹或按名称浏览文件，优先于 exec_command(ls/dir/find)。'
        '参数使用 PH01 schema：dir_path 指向目录，默认当前工作目录；depth 控制递归深度，limit 控制最多返回条目数。'
        '需要按内容搜索时使用 search_text；需要读取文件内容时使用 read_file。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'dir_path': <String, dynamic>{'type': 'string'},
        'depth': <String, dynamic>{
          'type': 'integer',
          'minimum': 0,
          'maximum': 10,
        },
        'limit': <String, dynamic>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 2000,
        },
      },
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final rawPath = _stringArg(invocation.arguments, 'dir_path') ?? '.';
    try {
      final rootPath = _resolveToolPath(rawPath, context.cwd);
      final type = await FileSystemEntity.type(rootPath);
      if (type == FileSystemEntityType.notFound) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'directory_not_found',
          'path': rootPath,
          'message': '目录不存在：$rootPath',
        }, isError: true);
      }
      if (type != FileSystemEntityType.directory) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'not_a_directory',
          'path': rootPath,
          'message': 'list_dir 只能读取目录；文件请使用 read_file。',
        }, isError: true);
      }
      final depth = (_intArg(invocation.arguments, 'depth') ?? 1).clamp(0, 10);
      final limit = (_intArg(invocation.arguments, 'limit') ?? 200).clamp(
        1,
        2000,
      );
      final entries = <Map<String, dynamic>>[];
      var truncated = false;
      await _collectDirectoryEntries(
        root: Directory(rootPath),
        current: Directory(rootPath),
        depthRemaining: depth,
        limit: limit,
        entries: entries,
        markTruncated: () => truncated = true,
      );
      return _jsonResult(<String, dynamic>{
        'ok': true,
        'tool': toolName,
        'path': rootPath,
        'depth': depth,
        'limit': limit,
        'truncated': truncated,
        'entries': entries,
      });
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'list_dir_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _SearchTextToolHandler extends CodexToolHandler {
  _SearchTextToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'search_text';

  @override
  bool get supportsParallelToolCalls => true;

  @override
  Tool get spec => const Tool(
    name: 'search_text',
    description:
        '在本地文件树中搜索文本和代码，优先于 exec_command(grep/rg/findstr)。'
        '参数使用 PH01 schema：pattern 必填，path 可指向文件或目录；默认按正则表达式搜索，regex=false 时按普通字符串搜索；glob 可限制文件名。'
        '返回匹配文件、行号和片段；开放式多轮研究可先用此工具缩小范围，再读取命中文件。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'pattern': <String, dynamic>{'type': 'string'},
        'path': <String, dynamic>{'type': 'string'},
        'regex': <String, dynamic>{'type': 'boolean'},
        'case_sensitive': <String, dynamic>{'type': 'boolean'},
        'glob': <String, dynamic>{'type': 'string'},
        'limit': <String, dynamic>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 1000,
        },
      },
      'required': <String>['pattern'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final pattern = _stringArg(invocation.arguments, 'pattern');
    if (pattern == null || pattern.isEmpty) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'missing_pattern',
        'message': 'search_text 需要 pattern。',
      }, isError: true);
    }
    try {
      final rootPath = _resolveToolPath(
        _stringArg(invocation.arguments, 'path') ?? '.',
        context.cwd,
      );
      final regexMode = _optionalBoolArg(invocation.arguments, 'regex');
      final caseSensitive =
          _optionalBoolArg(invocation.arguments, 'case_sensitive') ?? true;
      final limit = (_intArg(invocation.arguments, 'limit') ?? 100).clamp(
        1,
        1000,
      );
      final glob = _stringArg(invocation.arguments, 'glob');
      final matcher = _SearchMatcher(
        pattern: pattern,
        regex: regexMode ?? true,
        caseSensitive: caseSensitive,
      );
      final files = await _searchTargetFiles(rootPath, glob: glob);
      final matches = <Map<String, dynamic>>[];
      var filesScanned = 0;
      var truncated = false;
      for (final file in files) {
        if (matches.length >= limit) {
          truncated = true;
          break;
        }
        filesScanned++;
        final bytes = await file.readAsBytes();
        if (_looksBinary(bytes)) continue;
        if (bytes.length > 2 * 1024 * 1024) continue;
        final text = utf8.decode(bytes, allowMalformed: true);
        final lines = const LineSplitter().convert(text);
        for (var i = 0; i < lines.length; i++) {
          if (!matcher.hasMatch(lines[i])) continue;
          matches.add(<String, dynamic>{
            'path': file.path,
            'line': i + 1,
            'snippet': lines[i],
          });
          if (matches.length >= limit) {
            truncated = true;
            break;
          }
        }
      }
      return _jsonResult(<String, dynamic>{
        'ok': true,
        'tool': toolName,
        'pattern': pattern,
        'path': rootPath,
        'files_scanned': filesScanned,
        'truncated': truncated,
        'matches': matches,
      });
    } on FormatException catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'invalid_regex',
        'message': e.message,
      }, isError: true);
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'search_text_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _ExecCommandToolHandler extends CodexToolHandler {
  _ExecCommandToolHandler(this.context, this.processSessions);

  final CodexToolContext context;
  final CodexProcessSessionStore processSessions;

  @override
  String get toolName => 'exec_command';

  @override
  Tool get spec => const Tool(
    name: 'exec_command',
    description:
        '运行本地终端命令并返回 stdout、stderr、exit_code。用于构建、测试、脚本、进程和专用工具覆盖不到的真实终端操作；'
        '读取文件用 read_file，列目录用 list_dir，搜索文本用 search_text。不要用 cat/type/Get-Content、ls/dir/find、grep/rg 替代这些专用工具，除非专用工具确实不足。'
        '常规文件编辑不要用 shell 重定向、heredoc、echo > file 或 sed -i，改用 apply_patch。'
        '调用时设置合适 workdir，路径含空格要加引号；避免依赖 cd 状态；普通沟通直接输出文本，不要用 echo/printf。'
        '避免 sleep 轮询；长进程或交互进程使用 tty=true 后再配合 write_stdin。不要绕过 git hooks 或运行未授权的破坏性 git 命令。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'cmd': <String, dynamic>{'type': 'string'},
        'workdir': <String, dynamic>{'type': 'string'},
        'timeout_ms': <String, dynamic>{
          'type': 'integer',
          'minimum': 1000,
          'maximum': 120000,
        },
        'tty': <String, dynamic>{'type': 'boolean'},
        'yield_time_ms': <String, dynamic>{'type': 'integer'},
        'max_output_tokens': <String, dynamic>{'type': 'integer'},
        'sandbox_permissions': <String, dynamic>{'type': 'string'},
        'justification': <String, dynamic>{'type': 'string'},
      },
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final cmd = _stringArg(invocation.arguments, 'cmd');
    if (cmd == null || cmd.trim().isEmpty) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'missing_command',
        'message': 'exec_command 需要 cmd。',
      }, isError: true);
    }
    final timeoutSeconds = _timeoutSeconds(invocation.arguments);
    final workdir = _stringArg(invocation.arguments, 'workdir') ?? context.cwd;
    if (_boolArg(invocation.arguments, 'tty')) {
      try {
        final snapshot = await processSessions.start(
          command: cmd,
          workdir: workdir,
          yieldTimeMs: _yieldTimeMs(invocation.arguments),
          maxOutputTokens: _intArg(invocation.arguments, 'max_output_tokens'),
        );
        return _jsonResult(<String, dynamic>{
          'ok': true,
          'tool': toolName,
          ...snapshot,
        });
      } catch (e) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'error': 'pty_session_start_failed',
          'tool': toolName,
          'message': e.toString(),
        }, isError: true);
      }
    }
    final body = await _runShellCommand(
      command: cmd,
      workdir: workdir,
      timeoutSeconds: timeoutSeconds ?? 30,
      maxOutputTokens: _intArg(invocation.arguments, 'max_output_tokens'),
    );
    return _jsonResult(body, isError: body['ok'] == false);
  }
}

class _WriteStdinToolHandler extends CodexToolHandler {
  _WriteStdinToolHandler(this.processSessions);

  final CodexProcessSessionStore processSessions;

  @override
  String get toolName => 'write_stdin';

  @override
  Tool get spec => const Tool(
    name: 'write_stdin',
    description:
        '向 exec_command(tty: true) 创建的长进程会话写入字符，并读取近期 stdout/stderr。'
        '只用于已经启动的交互式或长运行进程；不要用它轮询本可一次性完成的短命令。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'session_id': <String, dynamic>{'type': 'integer'},
        'chars': <String, dynamic>{'type': 'string'},
        'yield_time_ms': <String, dynamic>{'type': 'integer'},
        'max_output_tokens': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['session_id'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final sessionId = _intArg(invocation.arguments, 'session_id');
    if (sessionId == null) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'missing_session_id',
        'tool': toolName,
        'message': 'write_stdin 需要 session_id。',
      }, isError: true);
    }
    try {
      final result = await processSessions.write(
        sessionId: sessionId,
        chars: invocation.arguments['chars']?.toString(),
        yieldTimeMs: _yieldTimeMs(invocation.arguments),
        maxOutputTokens: _intArg(invocation.arguments, 'max_output_tokens'),
      );
      return _jsonResult(<String, dynamic>{
        'tool': toolName,
        ...result,
      }, isError: result['ok'] == false);
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'pty_session_write_failed',
        'tool': toolName,
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _ApplyPatchToolHandler extends CodexToolHandler {
  _ApplyPatchToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'apply_patch';

  @override
  Tool get spec => const Tool(
    name: 'apply_patch',
    description:
        '应用 Codex 风格补丁来创建、删除或简单更新文件。编辑前必须先用 search_text/list_dir/read_file 定位并读取相关内容；'
        '始终优先修改现有文件，只在任务确实需要时创建新文件。不要创建 Markdown/README 文档，除非用户明确要求。'
        '补丁应小而明确，只修改本次任务需要的文件；不要用 shell 写文件来绕过补丁审计。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'patch': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['patch'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final patch = _stringArg(invocation.arguments, 'patch');
    if (patch == null || patch.trim().isEmpty) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'missing_patch',
        'tool': toolName,
        'message': 'apply_patch 需要 patch。',
      }, isError: true);
    }
    final parsed = _CodexPatchParser.tryParse(patch, context.cwd);
    if (parsed == null) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'unsupported_patch',
        'tool': toolName,
        'message':
            '当前客户端只支持 Codex apply_patch 的 Add File / Delete File / 简单 Update File 补丁。',
      }, isError: true);
    }
    try {
      final changes = <String, dynamic>{};
      for (final op in parsed.operations) {
        final changed = await op.apply();
        changes[op.path] = changed;
      }
      return _jsonResult(<String, dynamic>{
        'ok': true,
        'tool': toolName,
        'changes': changes,
      });
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'patch_apply_failed',
        'tool': toolName,
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _RequestUserInputToolHandler extends CodexToolHandler {
  _RequestUserInputToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'request_user_input';

  @override
  Tool get spec => const Tool(
    name: 'request_user_input',
    description:
        '请求用户回答一到三个短问题并等待响应。用于澄清歧义、收集偏好或获取无法从本地上下文推断的关键决策；'
        '不要把它作为遇到摩擦时的第一反应。每个问题提供 2 到 3 个互斥选项，推荐项放第一并在 label 末尾标注“（推荐）”。'
        '当前客户端运行时尚未接入阻塞式模态输入时会返回不可用结果。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'questions': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            'type': 'object',
            'additionalProperties': false,
            'properties': <String, dynamic>{
              'id': <String, dynamic>{'type': 'string'},
              'header': <String, dynamic>{'type': 'string'},
              'question': <String, dynamic>{'type': 'string'},
              'options': <String, dynamic>{
                'type': 'array',
                'items': <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{
                    'label': <String, dynamic>{'type': 'string'},
                    'description': <String, dynamic>{'type': 'string'},
                  },
                },
              },
            },
            'required': <String>['id', 'header', 'question', 'options'],
          },
        },
      },
      'required': <String>['questions'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final questions = _parseUserInputQuestions(invocation.arguments);
    if (questions == null || questions.isEmpty || questions.length > 3) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'invalid_questions',
        'tool': toolName,
        'message': 'request_user_input.questions 必须包含 1 到 3 个有效问题。',
      }, isError: true);
    }
    final prompt = context.userInputPrompt;
    if (prompt == null) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'interactive_input_unavailable',
        'tool': toolName,
        'message': '当前客户端没有可用的用户输入模态框回调。',
      }, isError: true);
    }
    final response = await prompt(
      CodexUserInputRequest(callId: invocation.callId, questions: questions),
    );
    if (response == null || response.cancelled) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'user_cancelled',
        'tool': toolName,
        'message': '用户取消了输入。',
      }, isError: true);
    }
    return _jsonResult(<String, dynamic>{
      'ok': true,
      'tool': toolName,
      'response': response.toJson(),
    });
  }
}

class _RequestPermissionsToolHandler extends CodexToolHandler {
  _RequestPermissionsToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'request_permissions';

  @override
  Tool get spec => const Tool(
    name: 'request_permissions',
    description:
        '请求额外文件系统、网络或高风险操作权限。客户端会按权限模式弹出授权框、自动批准或自动拒绝；'
        '如果被拒绝，不要原样重复同一请求，应调整方案或向用户说明阻塞。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'reason': <String, dynamic>{'type': 'string'},
        'permissions': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['permissions'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final permissions = invocation.arguments['permissions'];
    if (permissions is! Map) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'invalid_permissions',
        'tool': toolName,
        'message': 'request_permissions.permissions 必须是对象。',
      }, isError: true);
    }
    final decision = await context.permissionPolicy.request(
      CodexPermissionRequest(
        callId: invocation.callId,
        reason: _stringArg(invocation.arguments, 'reason'),
        permissions: permissions.cast<String, dynamic>(),
      ),
    );
    return _jsonResult(<String, dynamic>{
      'ok': decision.approved,
      'tool': toolName,
      'decision': decision.toJson(),
    }, isError: !decision.approved);
  }
}

class _ViewImageToolHandler extends CodexToolHandler {
  _ViewImageToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'view_image';

  @override
  Tool get spec => const Tool(
    name: 'view_image',
    description:
        '从本地文件系统读取图片，并把图片作为后续视觉上下文返回给模型。'
        '用户提供截图或图片路径时使用此工具查看；仅支持本地图片文件或工具产出的图片路径，不要把非图片文件当作图片读取。'
        '需要保留原始分辨率或做精确定位时设置 detail=original。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string', 'description': '本地图片文件路径。'},
        'detail': <String, dynamic>{
          'type': 'string',
          'enum': <String>['original'],
          'description': '可选细节提示。使用 original 保留图片原始分辨率。',
        },
      },
      'required': <String>['path'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final rawPath = _stringArg(invocation.arguments, 'path');
    if (rawPath == null) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'missing_path',
        'message': 'view_image 需要 path。',
      }, isError: true);
    }
    final detail = _stringArg(invocation.arguments, 'detail');
    if (detail != null && detail != 'original') {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'invalid_detail',
        'message': 'view_image.detail 只支持 original 或省略。',
      }, isError: true);
    }
    try {
      final path = _resolveToolPath(rawPath, context.cwd);
      final file = File(path);
      if (!file.existsSync()) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'image_not_found',
          'message': '图片文件不存在：$path',
        }, isError: true);
      }
      final bytes = await file.readAsBytes();
      final mimeType = _imageMimeType(path);
      if (mimeType == null) {
        return _jsonResult(<String, dynamic>{
          'ok': false,
          'tool': toolName,
          'error': 'unsupported_image_type',
          'message': '不支持的图片类型：$path',
        }, isError: true);
      }
      final imageUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
      final body = <String, dynamic>{
        'ok': true,
        'tool': toolName,
        'image_url': imageUrl,
        'detail': detail,
        'path': path,
      };
      final content = const JsonEncoder.withIndent('  ').convert(body);
      return RuntimeToolExecutionResult(
        content: content,
        details: <String, dynamic>{
          'image_url': imageUrl,
          'detail': detail,
          'path': path,
        },
        followupMessages: <RuntimeMessage>[
          RuntimeMessage.userBlocks(<RuntimeContentBlock>[
            RuntimeTextBlock('view_image 已载入图片：$path'),
            RuntimeImageBlock(
              dataUrl: imageUrl,
              mimeType: mimeType,
              label: p.basename(path),
              path: path,
            ),
          ]),
        ],
      );
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'view_image_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _SpawnAgentToolHandler extends CodexToolHandler {
  _SpawnAgentToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'spawn_agent';

  @override
  Tool get spec => const Tool(
    name: 'spawn_agent',
    description:
        '创建一个子 Agent 处理边界清楚的任务。仅在任务可并行拆分、用户要求多 Agent，或上下文隔离明显有价值时使用；'
        '不要委托自己尚未理解的问题。读取特定文件、搜索特定类/函数、或检查 2-3 个文件时直接使用 read_file/list_dir/search_text。'
        '分配任务时像给刚加入的同事写简报：说明目标、已知事实、排除项、范围、文件责任和期望输出，避免多个 Agent 编辑同一文件集。'
        '子 Agent 的结果对用户不可见，收到后由当前 Agent 汇总；不要伪造或预测其结果。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'task_name': <String, dynamic>{
          'type': 'string',
          'description': '新 Agent 的任务名。使用小写字母、数字和下划线。',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': '发送给新 Agent 的初始纯文本任务。',
        },
        'agent_type': <String, dynamic>{
          'type': 'string',
          'description': '可选的新 Agent 类型名。',
        },
        'fork_turns': <String, dynamic>{
          'type': 'string',
          'description': '可选的上下文分叉轮数。使用 none、all 或正整数字符串。',
        },
        'model': <String, dynamic>{
          'type': 'string',
          'description': '可选的新 Agent 模型覆盖值。',
        },
        'reasoning_effort': <String, dynamic>{
          'type': 'string',
          'description': '可选的新 Agent 推理强度覆盖值。',
        },
      },
      'required': <String>['task_name', 'message'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final control = context.agentControl;
    if (control == null) return _agentControlMissing(toolName);
    try {
      final body = await control.spawnAgent(
        invocation.arguments,
        sourceAgentId: context.activeAgentId,
        cwd: context.cwd,
      );
      return _jsonResult(body, isError: body['ok'] == false);
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'tool': toolName,
        'error': 'spawn_agent_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _SendMessageToolHandler extends CodexToolHandler {
  _SendMessageToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'send_message';

  @override
  Tool get spec => const Tool(
    name: 'send_message',
    description:
        '向已有 Agent 发送消息。消息只进入队列，不会触发新的执行轮次；需要目标继续工作时使用 followup_task。'
        '你的普通文本输出不会被其他 Agent 读取；需要跨 Agent 沟通必须调用此工具。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'target': <String, dynamic>{
          'type': 'string',
          'description': '要发送消息的相对或规范任务名，来自 spawn_agent。',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': '要加入目标 Agent 队列的消息文本。',
        },
      },
      'required': <String>['target', 'message'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final control = context.agentControl;
    if (control == null) return _agentControlMissing(toolName);
    final body = await control.sendMessage(invocation.arguments);
    return _jsonResult(body, isError: body['ok'] == false);
  }
}

class _FollowupTaskToolHandler extends CodexToolHandler {
  _FollowupTaskToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'followup_task';

  @override
  Tool get spec => const Tool(
    name: 'followup_task',
    description:
        '向已有的非根目标 Agent 发送消息，并触发该目标 Agent 执行一轮。只在需要该 Agent 继续处理其明确责任范围时使用。'
        '每次 followup 都要提供完整、具体的下一步，不要让目标凭空推断当前意图。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'target': <String, dynamic>{
          'type': 'string',
          'description': '要发送消息的 Agent ID 或规范任务名，来自 spawn_agent。',
        },
        'message': <String, dynamic>{
          'type': 'string',
          'description': '要发送给目标 Agent 的消息文本。',
        },
      },
      'required': <String>['target', 'message'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final control = context.agentControl;
    if (control == null) return _agentControlMissing(toolName);
    final body = await control.followupTask(invocation.arguments);
    return _jsonResult(body, isError: body['ok'] == false);
  }
}

class _WaitAgentToolHandler extends CodexToolHandler {
  _WaitAgentToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'wait_agent';

  @override
  Tool get spec => const Tool(
    name: 'wait_agent',
    description:
        '等待一个或多个 Agent 到达当前完成点并返回状态。只在你的下一步确实被其结果阻塞时使用；不要用 sleep 或轮询替代。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'target': <String, dynamic>{
          'type': 'string',
          'description': '来自 spawn_agent 的单个目标任务名。',
        },
        'targets': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': '来自 spawn_agent 的目标任务名列表。',
        },
        'timeout_ms': <String, dynamic>{
          'type': 'integer',
          'minimum': 100,
          'maximum': 3600000,
        },
        'yield_time_ms': <String, dynamic>{'type': 'integer'},
      },
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final control = context.agentControl;
    if (control == null) return _agentControlMissing(toolName);
    final body = await control.waitAgent(invocation.arguments);
    return _jsonResult(body, isError: body['ok'] == false);
  }
}

class _CloseAgentToolHandler extends CodexToolHandler {
  _CloseAgentToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'close_agent';

  @override
  Tool get spec => const Tool(
    name: 'close_agent',
    description: '关闭一个不再需要的 Agent，并返回请求关闭前的状态。不要关闭仍承担当前任务必要工作的 Agent。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'target': <String, dynamic>{
          'type': 'string',
          'description': '来自 spawn_agent 的目标任务名。',
        },
      },
      'required': <String>['target'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final control = context.agentControl;
    if (control == null) return _agentControlMissing(toolName);
    final body = await control.closeAgent(invocation.arguments);
    return _jsonResult(body, isError: body['ok'] == false);
  }
}

class _ListAgentsToolHandler extends CodexToolHandler {
  _ListAgentsToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'list_agents';

  @override
  Tool get spec => const Tool(
    name: 'list_agents',
    description: '列出当前 Codex 多 Agent 树中可见的 Agent，用于确认已有子任务状态和可引用目标名。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'path_prefix': <String, dynamic>{
          'type': 'string',
          'description': '可选的任务名前缀过滤条件。',
        },
      },
    },
  );

  @override
  bool get supportsParallelToolCalls => true;

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final control = context.agentControl;
    if (control == null) return _agentControlMissing(toolName);
    final body = await control.listAgents(invocation.arguments);
    return _jsonResult(body, isError: body['ok'] == false);
  }
}

class _GetGoalToolHandler extends CodexToolHandler {
  _GetGoalToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'get_goal';

  @override
  Tool get spec => const Tool(
    name: 'get_goal',
    description: '获取当前线程目标，包括状态和预算字段。仅用于用户或系统明确使用目标机制的会话。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{},
    },
  );

  @override
  bool get supportsParallelToolCalls => true;

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final goal = context.goalStore?.getGoal(_goalThreadKey(context));
    return _jsonResult(<String, dynamic>{'ok': true, 'goal': goal?.toJson()});
  }
}

class _CreateGoalToolHandler extends CodexToolHandler {
  _CreateGoalToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'create_goal';

  @override
  Tool get spec => const Tool(
    name: 'create_goal',
    description: '仅在用户、系统或开发者指令明确要求线程目标时创建目标；不要为普通任务自动创建。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'objective': <String, dynamic>{
          'type': 'string',
          'description': '必填。准备开始执行的具体目标。',
        },
        'token_budget': <String, dynamic>{
          'type': 'integer',
          'description': '可选。新活动目标的正整数 token 预算。',
        },
      },
      'required': <String>['objective'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final store = context.goalStore;
    if (store == null) return _goalStoreMissing(toolName);
    final objective = _stringArg(invocation.arguments, 'objective');
    if (objective == null) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'missing_objective',
        'message': 'create_goal 需要 objective。',
      }, isError: true);
    }
    try {
      final goal = store.createGoal(
        threadKey: _goalThreadKey(context),
        objective: objective,
        tokenBudget: _positiveIntArg(invocation.arguments, 'token_budget'),
      );
      return _jsonResult(<String, dynamic>{'ok': true, 'goal': goal.toJson()});
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'create_goal_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _UpdateGoalStatusToolHandler extends CodexToolHandler {
  _UpdateGoalStatusToolHandler(this.context);

  final CodexToolContext context;

  @override
  String get toolName => 'update_goal';

  @override
  Tool get spec => const Tool(
    name: 'update_goal',
    description: '更新已有目标。仅在目标真实达成且没有必要工作剩余时，用 status=complete 标记完成。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'status': <String, dynamic>{
          'type': 'string',
          'enum': <String>['complete'],
          'description': '必填。仅在目标达成后设置为 complete。',
        },
      },
      'required': <String>['status'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final store = context.goalStore;
    if (store == null) return _goalStoreMissing(toolName);
    final status = _stringArg(invocation.arguments, 'status');
    if (status != 'complete') {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'invalid_goal_status',
        'message': 'update_goal 只允许 status=complete。',
      }, isError: true);
    }
    try {
      final goal = store.completeGoal(_goalThreadKey(context));
      return _jsonResult(<String, dynamic>{'ok': true, 'goal': goal.toJson()});
    } catch (e) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'update_goal_failed',
        'message': e.toString(),
      }, isError: true);
    }
  }
}

class _ToolSearchHandler extends CodexToolHandler {
  _ToolSearchHandler(CodexToolRegistryBuilder builder) : _builder = builder;

  final CodexToolRegistryBuilder _builder;

  @override
  String get toolName => 'tool_search';

  @override
  Tool get spec => const Tool(
    name: 'tool_search',
    description:
        '搜索当前 Codex 工具注册表中的可用工具，用于发现延迟或不熟悉的工具能力。'
        '不要猜测不存在的工具名或参数；找到工具后按返回的工具语义和 PH01 schema 调用。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'query': <String, dynamic>{'type': 'string'},
        'limit': <String, dynamic>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 50,
        },
      },
    },
  );

  @override
  bool get supportsParallelToolCalls => true;

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final query = (_stringArg(invocation.arguments, 'query') ?? '')
        .toLowerCase();
    final limit = (_intArg(invocation.arguments, 'limit') ?? 12).clamp(1, 50);
    final infos = _builder._handlers.values
        .map((handler) => handler.searchInfo)
        .whereType<CodexToolSearchInfo>()
        .where((info) {
          if (query.trim().isEmpty) return true;
          return info.name.toLowerCase().contains(query) ||
              info.description.toLowerCase().contains(query);
        })
        .take(limit)
        .map(
          (info) => <String, dynamic>{
            'name': info.name,
            'description': info.description,
          },
        )
        .toList(growable: false);
    return _jsonResult(<String, dynamic>{
      'ok': true,
      'query': query,
      'tools': infos,
    });
  }
}

class _UpdatePlanToolHandler extends CodexToolHandler {
  final _items = <Map<String, dynamic>>[];

  @override
  String get toolName => 'update_plan';

  @override
  Tool get spec => const Tool(
    name: 'update_plan',
    description:
        '更新当前任务计划。用于复杂、多步骤或长时间任务中同步步骤与状态；最多保持一个 in_progress，'
        '完成步骤后及时更新，不要最后一次性批量标记完成。',
    parameters: <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'explanation': <String, dynamic>{'type': 'string'},
        'plan': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            'type': 'object',
            'additionalProperties': false,
            'properties': <String, dynamic>{
              'step': <String, dynamic>{'type': 'string'},
              'status': <String, dynamic>{
                'type': 'string',
                'enum': <String>['pending', 'in_progress', 'completed'],
              },
            },
            'required': <String>['step', 'status'],
          },
        },
      },
      'required': <String>['plan'],
    },
  );

  @override
  Future<RuntimeToolExecutionResult> handle(
    CodexToolInvocation invocation,
  ) async {
    final rawPlan = invocation.arguments['plan'];
    if (rawPlan is! List) {
      return _jsonResult(<String, dynamic>{
        'ok': false,
        'error': 'invalid_plan',
        'message': 'update_plan.plan 必须是数组。',
      }, isError: true);
    }
    _items
      ..clear()
      ..addAll(
        rawPlan.whereType<Map>().map(
          (item) => <String, dynamic>{
            'step': item['step']?.toString() ?? '',
            'status': item['status']?.toString() ?? 'pending',
          },
        ),
      );
    return _jsonResult(<String, dynamic>{
      'ok': true,
      if (invocation.arguments['explanation'] != null)
        'explanation': invocation.arguments['explanation'].toString(),
      'plan': _items,
    });
  }
}

class CodexInstructionLoader {
  const CodexInstructionLoader._();

  static Future<String> loadForCwd({
    required String? cwd,
    int maxBytes = 65536,
  }) async {
    final start = _directoryOrNull(cwd);
    if (start == null) return '';
    final paths = <String>[];
    var dir = start;
    while (true) {
      final override = File(p.join(dir.path, 'AGENTS.override.md'));
      final agents = File(p.join(dir.path, 'AGENTS.md'));
      if (override.existsSync()) {
        paths.add(override.path);
      } else if (agents.existsSync()) {
        paths.add(agents.path);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    if (paths.isEmpty) return '';
    final orderedPaths = paths.reversed.toList(growable: false);

    final chunks = <String>[];
    var remaining = maxBytes;
    for (final path in orderedPaths) {
      if (remaining <= 0) break;
      final file = File(path);
      List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        continue;
      }
      if (bytes.length > remaining) {
        bytes = bytes.take(remaining).toList(growable: false);
      }
      remaining -= bytes.length;
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isEmpty) continue;
      chunks.add('# ${p.basename(path)}\n$text');
    }
    return chunks.join('\n\n');
  }

  static Directory? _directoryOrNull(String? cwd) {
    final value = cwd?.trim();
    if (value == null || value.isEmpty) return null;
    final type = FileSystemEntity.typeSync(value);
    if (type == FileSystemEntityType.directory) return Directory(value);
    if (type == FileSystemEntityType.file) return File(value).parent;
    return null;
  }
}

class _CodexPatchParser {
  const _CodexPatchParser._();

  static _CodexPatch? tryParse(String input, String? cwd) {
    final lines = input.replaceAll('\r\n', '\n').split('\n');
    if (lines.isEmpty || lines.first.trim() != '*** Begin Patch') {
      return null;
    }
    final endIndex = lines.lastIndexWhere(
      (line) => line.trim() == '*** End Patch',
    );
    if (endIndex <= 0) return null;

    final operations = <_CodexPatchOperation>[];
    var i = 1;
    while (i < endIndex) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      if (line.startsWith('*** Add File: ')) {
        final path = _resolvePatchPath(line.substring(14), cwd);
        final content = <String>[];
        i++;
        while (i < endIndex && !_isPatchOperationHeader(lines[i])) {
          final value = lines[i];
          if (!value.startsWith('+')) return null;
          content.add(value.substring(1));
          i++;
        }
        operations.add(_AddFilePatchOperation(path, content.join('\n')));
        continue;
      }
      if (line.startsWith('*** Delete File: ')) {
        operations.add(
          _DeleteFilePatchOperation(_resolvePatchPath(line.substring(17), cwd)),
        );
        i++;
        continue;
      }
      if (line.startsWith('*** Update File: ')) {
        final path = _resolvePatchPath(line.substring(17), cwd);
        String? moveTo;
        final hunks = <_PatchHunk>[];
        var oldLines = <String>[];
        var newLines = <String>[];

        void flushHunk() {
          if (oldLines.isEmpty && newLines.isEmpty) return;
          hunks.add(_PatchHunk(oldLines.join('\n'), newLines.join('\n')));
          oldLines = <String>[];
          newLines = <String>[];
        }

        i++;
        if (i < endIndex && lines[i].startsWith('*** Move to: ')) {
          moveTo = _resolvePatchPath(lines[i].substring(13), cwd);
          i++;
        }
        while (i < endIndex && !_isPatchOperationHeader(lines[i])) {
          final value = lines[i];
          if (value.startsWith('@@')) {
            flushHunk();
          } else if (value.startsWith(' ')) {
            oldLines.add(value.substring(1));
            newLines.add(value.substring(1));
          } else if (value.startsWith('-')) {
            oldLines.add(value.substring(1));
          } else if (value.startsWith('+')) {
            newLines.add(value.substring(1));
          } else if (value.trim() == r'\ No newline at end of file' ||
              value.trim() == '*** End of File') {
          } else if (value.trim().isEmpty) {
            oldLines.add('');
            newLines.add('');
          } else {
            return null;
          }
          i++;
        }
        flushHunk();
        operations.add(_UpdateFilePatchOperation(path, moveTo, hunks));
        continue;
      }
      return null;
    }

    if (operations.isEmpty) return null;
    return _CodexPatch(operations);
  }
}

class _CodexPatch {
  const _CodexPatch(this.operations);

  final List<_CodexPatchOperation> operations;
}

abstract class _CodexPatchOperation {
  const _CodexPatchOperation(this.path);

  final String path;

  Future<Map<String, dynamic>> apply();
}

class _AddFilePatchOperation extends _CodexPatchOperation {
  const _AddFilePatchOperation(super.path, this.content);

  final String content;

  @override
  Future<Map<String, dynamic>> apply() async {
    final file = File(path);
    if (await file.exists()) {
      throw StateError('文件已存在，拒绝 Add File 覆盖：$path');
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return <String, dynamic>{'type': 'add'};
  }
}

class _DeleteFilePatchOperation extends _CodexPatchOperation {
  const _DeleteFilePatchOperation(super.path);

  @override
  Future<Map<String, dynamic>> apply() async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('文件不存在，无法 Delete File：$path');
    }
    await file.delete();
    return <String, dynamic>{'type': 'delete'};
  }
}

class _UpdateFilePatchOperation extends _CodexPatchOperation {
  const _UpdateFilePatchOperation(super.path, this.moveTo, this.hunks);

  final String? moveTo;
  final List<_PatchHunk> hunks;

  @override
  Future<Map<String, dynamic>> apply() async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('文件不存在，无法 Update File：$path');
    }
    var content = await file.readAsString();
    for (final hunk in hunks) {
      if (hunk.oldText == hunk.newText) continue;
      final next = content.replaceFirst(hunk.oldText, hunk.newText);
      if (next == content) {
        throw StateError('补丁上下文未匹配：$path');
      }
      content = next;
    }
    final targetPath = moveTo ?? path;
    final targetFile = File(targetPath);
    await targetFile.parent.create(recursive: true);
    await targetFile.writeAsString(content, flush: true);
    if (moveTo != null && moveTo != path) {
      await file.delete();
    }
    return <String, dynamic>{
      'type': moveTo == null ? 'update' : 'move',
      if (moveTo != null) 'move_path': moveTo,
    };
  }
}

class _PatchHunk {
  const _PatchHunk(this.oldText, this.newText);

  final String oldText;
  final String newText;
}

RuntimeToolExecutionResult _jsonResult(
  Map<String, dynamic> body, {
  bool isError = false,
}) {
  final content = const JsonEncoder.withIndent('  ').convert(body);
  return RuntimeToolExecutionResult(
    content: content,
    isError: isError || _toolOutputIsError(content),
  );
}

bool _toolOutputIsError(String content) {
  try {
    final decoded = jsonDecode(content);
    return decoded is Map && decoded['ok'] == false;
  } catch (_) {
    return false;
  }
}

String? _stringArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _intArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

int? _positiveIntArg(Map<String, dynamic> args, String key) {
  final value = _intArg(args, key);
  if (value == null || value <= 0) return null;
  return value;
}

bool _boolArg(Map<String, dynamic> args, String key) {
  return _optionalBoolArg(args, key) ?? false;
}

bool? _optionalBoolArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    return switch (value.trim().toLowerCase()) {
      '1' || 'true' || 'yes' || 'y' => true,
      '0' || 'false' || 'no' || 'n' => false,
      _ => false,
    };
  }
  return null;
}

int? _timeoutSeconds(Map<String, dynamic> args) {
  final timeoutMs = _intArg(args, 'timeout_ms');
  if (timeoutMs != null) {
    return (timeoutMs / 1000).ceil().clamp(1, 120);
  }
  final timeoutSeconds = _intArg(args, 'timeout_seconds');
  if (timeoutSeconds != null) return timeoutSeconds.clamp(1, 120);
  return null;
}

int _yieldTimeMs(Map<String, dynamic> args) {
  return (_intArg(args, 'yield_time_ms') ?? 1000).clamp(0, 30000);
}

RuntimeToolExecutionResult _agentControlMissing(String toolName) {
  return _jsonResult(<String, dynamic>{
    'ok': false,
    'tool': toolName,
    'error': 'agent_control_not_configured',
    'message': 'Codex Agent 控制面尚未初始化。',
  }, isError: true);
}

RuntimeToolExecutionResult _goalStoreMissing(String toolName) {
  return _jsonResult(<String, dynamic>{
    'ok': false,
    'tool': toolName,
    'error': 'goal_store_not_configured',
    'message': 'Codex Goal 状态尚未初始化。',
  }, isError: true);
}

String _goalThreadKey(CodexToolContext context) {
  final sessionPath = context.sessionPath?.trim();
  if (sessionPath != null && sessionPath.isNotEmpty) return sessionPath;
  final activeAgentId = context.activeAgentId?.trim();
  if (activeAgentId != null && activeAgentId.isNotEmpty) return activeAgentId;
  return 'default';
}

int _maxOutputChars(int? maxOutputTokens) {
  final tokens = maxOutputTokens?.clamp(256, 20000) ?? 6000;
  return tokens * 4;
}

String _tail(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  return value.substring(value.length - maxChars);
}

int _readStartLine(Map<String, dynamic> arguments) {
  return _positiveIntArg(arguments, 'start_line') ?? 1;
}

int _readEndLine({
  required Map<String, dynamic> arguments,
  required int startLine,
  required int totalLines,
}) {
  if (totalLines == 0) return 0;
  final explicitEnd = _positiveIntArg(arguments, 'end_line');
  if (explicitEnd != null) return explicitEnd.clamp(startLine, totalLines);
  return (startLine + 1999).clamp(startLine, totalLines);
}

bool _looksBinary(List<int> bytes) {
  final sampleLength = bytes.length < 4096 ? bytes.length : 4096;
  for (var i = 0; i < sampleLength; i++) {
    final byte = bytes[i];
    if (byte == 0) return true;
  }
  return false;
}

Future<void> _collectDirectoryEntries({
  required Directory root,
  required Directory current,
  required int depthRemaining,
  required int limit,
  required List<Map<String, dynamic>> entries,
  required void Function() markTruncated,
}) async {
  final children =
      current
          .listSync(followLinks: false)
          .where((entry) => !p.basename(entry.path).startsWith('.git'))
          .toList(growable: false)
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  for (final entity in children) {
    if (entries.length >= limit) {
      markTruncated();
      return;
    }
    final stat = await entity.stat();
    final isDir = stat.type == FileSystemEntityType.directory;
    entries.add(<String, dynamic>{
      'path': entity.path,
      'relative_path': p.relative(entity.path, from: root.path),
      'type': isDir ? 'directory' : 'file',
      if (!isDir) 'size_bytes': stat.size,
      'modified_at': stat.modified.toUtc().toIso8601String(),
    });
    if (isDir && depthRemaining > 0) {
      await _collectDirectoryEntries(
        root: root,
        current: Directory(entity.path),
        depthRemaining: depthRemaining - 1,
        limit: limit,
        entries: entries,
        markTruncated: markTruncated,
      );
    }
  }
}

Future<List<File>> _searchTargetFiles(String rootPath, {String? glob}) async {
  final type = await FileSystemEntity.type(rootPath);
  if (type == FileSystemEntityType.notFound) {
    throw StateError('搜索路径不存在：$rootPath');
  }
  if (type == FileSystemEntityType.file) return <File>[File(rootPath)];
  if (type != FileSystemEntityType.directory) {
    throw StateError('搜索路径不是文件或目录：$rootPath');
  }
  final root = Directory(rootPath);
  final matcher = glob == null || glob.trim().isEmpty
      ? null
      : _SimpleGlob(glob.trim());
  final files = <File>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: root.path);
    if (_pathContainsIgnoredSegment(relative)) continue;
    if (matcher != null && !matcher.matches(relative)) continue;
    files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

bool _pathContainsIgnoredSegment(String relativePath) {
  final parts = p.split(relativePath);
  return parts.any(
    (part) =>
        part == '.git' ||
        part == 'node_modules' ||
        part == 'build' ||
        part == '.dart_tool',
  );
}

class _SearchMatcher {
  _SearchMatcher({
    required this.pattern,
    required bool regex,
    required this.caseSensitive,
  }) : regex = regex ? RegExp(pattern, caseSensitive: caseSensitive) : null,
       literal = caseSensitive ? pattern : pattern.toLowerCase();

  final String pattern;
  final bool caseSensitive;
  final RegExp? regex;
  final String literal;

  bool hasMatch(String line) {
    final regex = this.regex;
    if (regex != null) return regex.hasMatch(line);
    final haystack = caseSensitive ? line : line.toLowerCase();
    return haystack.contains(literal);
  }
}

class _SimpleGlob {
  _SimpleGlob(String pattern) : _regex = _globToRegExp(pattern);

  final RegExp _regex;

  bool matches(String relativePath) {
    final normalized = relativePath.replaceAll(r'\', '/');
    return _regex.hasMatch(normalized);
  }
}

RegExp _globToRegExp(String pattern) {
  final normalized = pattern.replaceAll(r'\', '/');
  final buffer = StringBuffer('^');
  for (var i = 0; i < normalized.length; i++) {
    final char = normalized[i];
    if (char == '*') {
      final isDouble = i + 1 < normalized.length && normalized[i + 1] == '*';
      if (isDouble) {
        buffer.write('.*');
        i++;
      } else {
        buffer.write('[^/]*');
      }
    } else if (char == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

Future<Map<String, dynamic>> _runShellCommand({
  required String command,
  required String? workdir,
  required int timeoutSeconds,
  required int? maxOutputTokens,
}) async {
  final process = await _startShellProcess(command, workdir);
  await process.stdin.close();
  final stdoutFuture = process.stdout
      .fold<BytesBuilder>(BytesBuilder(copy: false), (all, chunk) {
        all.add(chunk);
        return all;
      })
      .then((bytes) => _decodeProcessOutput(bytes.takeBytes()));
  final stderrFuture = process.stderr
      .fold<BytesBuilder>(BytesBuilder(copy: false), (all, chunk) {
        all.add(chunk);
        return all;
      })
      .then((bytes) => _decodeProcessOutput(bytes.takeBytes()));
  final exitCode = await process.exitCode.timeout(
    Duration(seconds: timeoutSeconds),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  final maxChars = _maxOutputChars(maxOutputTokens);
  final stdout = await stdoutFuture;
  final stderr = await stderrFuture;
  return <String, dynamic>{
    'ok': exitCode == 0,
    'exit_code': exitCode,
    'stdout': _tail(stdout, maxChars),
    'stderr': _tail(stderr, maxChars),
    'stdout_truncated': stdout.length > maxChars,
    'stderr_truncated': stderr.length > maxChars,
    'timed_out': exitCode == -1,
  };
}

String _decodeProcessOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return systemEncoding.decode(bytes);
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

Future<Process> _startShellProcess(String command, String? workdir) {
  final effectiveWorkdir = workdir?.trim().isEmpty == true ? null : workdir;
  if (Platform.isWindows) {
    return Process.start(
      'powershell.exe',
      <String>['-NoProfile', '-Command', command],
      workingDirectory: effectiveWorkdir,
      runInShell: false,
    );
  }
  return Process.start(
    '/bin/sh',
    <String>['-lc', command],
    workingDirectory: effectiveWorkdir,
    runInShell: false,
  );
}

Future<Process> _startInteractiveShellProcess(String command, String? workdir) {
  final effectiveWorkdir = workdir?.trim().isEmpty == true ? null : workdir;
  if (Platform.isWindows) {
    return Process.start(
      command,
      const <String>[],
      workingDirectory: effectiveWorkdir,
      runInShell: true,
    );
  }
  return _startShellProcess(command, workdir);
}

List<CodexUserInputQuestion>? _parseUserInputQuestions(
  Map<String, dynamic> args,
) {
  final rawQuestions = args['questions'];
  if (rawQuestions is! List) return null;
  final questions = <CodexUserInputQuestion>[];
  for (final raw in rawQuestions) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim();
    final header = raw['header']?.toString().trim();
    final question = raw['question']?.toString().trim();
    final rawOptions = raw['options'];
    if (id == null ||
        id.isEmpty ||
        header == null ||
        header.isEmpty ||
        question == null ||
        question.isEmpty ||
        rawOptions is! List ||
        rawOptions.isEmpty) {
      return null;
    }
    final options = <CodexUserInputOption>[];
    for (final rawOption in rawOptions) {
      if (rawOption is! Map) return null;
      final label = rawOption['label']?.toString().trim();
      if (label == null || label.isEmpty) return null;
      final description = rawOption['description']?.toString().trim();
      options.add(
        CodexUserInputOption(
          label: label,
          description: description == null || description.isEmpty
              ? null
              : description,
        ),
      );
    }
    questions.add(
      CodexUserInputQuestion(
        id: id,
        header: header,
        question: question,
        options: options,
      ),
    );
  }
  return questions;
}

bool _localToolSupportsParallel(String name) {
  return const <String>{
    LocalToolNames.webFetch,
    LocalToolNames.searchMemory,
    LocalToolNames.listPinnedMemory,
    LocalToolNames.experienceSearch,
  }.contains(name);
}

String _resolvePatchPath(String rawPath, String? cwd) {
  return _resolveToolPath(rawPath, cwd);
}

String _resolveToolPath(String rawPath, String? cwd) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(rawPath, 'path', '路径不能为空');
  }
  if (p.isAbsolute(trimmed)) return p.normalize(trimmed);
  return p.normalize(
    p.join(
      cwd?.trim().isNotEmpty == true ? cwd! : Directory.current.path,
      trimmed,
    ),
  );
}

String? _imageMimeType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  return null;
}

bool _isPatchOperationHeader(String line) {
  return line.startsWith('*** Add File: ') ||
      line.startsWith('*** Delete File: ') ||
      line.startsWith('*** Update File: ');
}
