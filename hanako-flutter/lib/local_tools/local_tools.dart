import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/browser_manager.dart';
import '../core/channel_manager.dart';
import '../core/collaboration_manager.dart';
import '../core/cron_store.dart';
import '../core/skill_manager.dart';
import '../llm/provider.dart';

class LocalToolRegistry {
  const LocalToolRegistry._();

  static final List<_TodoItem> _todos = <_TodoItem>[];
  static int _nextTodoId = 1;
  static int _artifactCounter = 0;

  static List<Tool> buildTools() => _toolSpecs
      .map(
        (tool) => Tool(
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        ),
      )
      .toList(growable: false);

  static bool canExecute(String name) => _knownToolNames.contains(name);

  static Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    String? cwd,
    String? agentDir,
    String? activeAgentId,
    CronStore? cronStore,
    Future<CronRunRecord> Function(String jobId)? runCronNow,
    SkillManager? skillManager,
    BrowserManager? browserManager,
    ChannelManager? channelManager,
    CollaborationManager? collaborationManager,
  }) async {
    try {
      final result = switch (name) {
        LocalToolNames.environment => _environment(cwd, agentDir),
        LocalToolNames.ls ||
        LocalToolNames.listDirectory => _listDirectory(arguments, cwd),
        LocalToolNames.read ||
        LocalToolNames.readTextFile => await _readTextFile(arguments, cwd),
        LocalToolNames.grep ||
        LocalToolNames.searchText => await _grep(arguments, cwd),
        LocalToolNames.find => await _findFiles(arguments, cwd),
        LocalToolNames.write => await _writeFile(arguments, cwd),
        LocalToolNames.edit => await _editFile(arguments, cwd),
        LocalToolNames.bash => await _runCommand(arguments, cwd),
        LocalToolNames.webFetch => await _webFetch(arguments),
        LocalToolNames.webSearch => _notConfigured(
          name,
          '客户端尚未配置搜索 provider。可以先用 web_fetch 读取已知 URL。',
        ),
        LocalToolNames.todo => _todo(arguments),
        LocalToolNames.searchMemory => await _searchMemory(arguments, agentDir),
        LocalToolNames.pinMemory => await _pinMemory(arguments, agentDir),
        LocalToolNames.unpinMemory => await _unpinMemory(arguments, agentDir),
        LocalToolNames.listPinnedMemory => await _listPinnedMemory(agentDir),
        LocalToolNames.recallExperience => await _recallExperience(
          arguments,
          agentDir,
        ),
        LocalToolNames.recordExperience => await _recordExperience(
          arguments,
          agentDir,
        ),
        LocalToolNames.cron => await _cron(
          arguments,
          cronStore: cronStore,
          activeAgentId: activeAgentId,
          runCronNow: runCronNow,
        ),
        LocalToolNames.presentFiles => _presentFiles(arguments),
        LocalToolNames.createArtifact => _createArtifact(arguments),
        LocalToolNames.notify => _notify(arguments),
        LocalToolNames.browser => await _browser(arguments, browserManager),
        LocalToolNames.channel => await _channel(
          arguments,
          channelManager,
          collaborationManager,
          activeAgentId,
        ),
        LocalToolNames.askAgent => await _askAgent(
          arguments,
          collaborationManager,
          activeAgentId,
        ),
        LocalToolNames.dm || LocalToolNames.messageAgent => await _dm(
          arguments,
          collaborationManager,
          activeAgentId,
        ),
        LocalToolNames.delegate => await _delegate(
          arguments,
          collaborationManager,
          activeAgentId,
        ),
        LocalToolNames.installSkill => await _installSkill(
          arguments,
          activeAgentId: activeAgentId,
          skillManager: skillManager,
        ),
        _ => <String, dynamic>{
          'ok': false,
          'error': 'unknown_tool',
          'message': '未知本地工具: $name',
        },
      };
      return const JsonEncoder.withIndent('  ').convert(result);
    } catch (e, st) {
      return const JsonEncoder.withIndent('  ').convert({
        'ok': false,
        'error': 'tool_failed',
        'message': e.toString(),
        'stack': st.toString().split('\n').take(12).join('\n'),
      });
    }
  }

  static Map<String, dynamic> _environment(String? cwd, String? agentDir) => {
    'ok': true,
    'cwd': _defaultCwd(cwd),
    'agent_dir': agentDir,
    'process_cwd': Directory.current.path,
    'operating_system': Platform.operatingSystem,
    'path_separator': p.separator,
  };

  static Map<String, dynamic> _listDirectory(
    Map<String, dynamic> args,
    String? cwd,
  ) {
    final dir = Directory(_resolvePath(args['path'] as String?, cwd));
    final maxEntries = _boundedInt(args['max_entries'], 80, 1, 300);
    if (!dir.existsSync()) {
      return {'ok': false, 'error': 'directory_not_found', 'path': dir.path};
    }

    final entries = <Map<String, dynamic>>[];
    var scanned = 0;
    for (final entity in dir.listSync(followLinks: false)) {
      scanned++;
      if (entries.length >= maxEntries) continue;
      final stat = entity.statSync();
      entries.add({
        'name': p.basename(entity.path),
        'path': entity.path,
        'type': _entityType(stat.type),
        if (stat.type == FileSystemEntityType.file) 'size': stat.size,
        'modified': stat.modified.toIso8601String(),
      });
    }
    entries.sort(
      (a, b) => a['name'].toString().compareTo(b['name'].toString()),
    );
    return {
      'ok': true,
      'path': dir.path,
      'entries': entries,
      'truncated': scanned > entries.length,
      'total_seen': scanned,
    };
  }

  static Future<Map<String, dynamic>> _readTextFile(
    Map<String, dynamic> args,
    String? cwd,
  ) async {
    final path = _resolvePath(_requiredString(args, 'path'), cwd);
    final maxChars = _boundedInt(args['max_chars'], 20000, 1, 60000);
    final file = File(path);
    if (!file.existsSync()) {
      return {'ok': false, 'error': 'file_not_found', 'path': path};
    }
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) {
      return {'ok': false, 'error': 'not_a_file', 'path': path};
    }
    final readLimit = stat.size > 2 * 1024 * 1024 ? 2 * 1024 * 1024 : null;
    final bytes = await file
        .openRead(0, readLimit)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final text = utf8.decode(bytes, allowMalformed: true);
    return {
      'ok': true,
      'path': path,
      'size': stat.size,
      'content': text.length > maxChars ? text.substring(0, maxChars) : text,
      'truncated': text.length > maxChars || stat.size > bytes.length,
    };
  }

  static Future<Map<String, dynamic>> _grep(
    Map<String, dynamic> args,
    String? cwd,
  ) async {
    final root = Directory(
      _resolvePath(
        (args['root'] ?? args['path']) is String
            ? (args['root'] ?? args['path']) as String
            : null,
        cwd,
      ),
    );
    final query =
        _optionalString(args, 'query') ??
        _optionalString(args, 'pattern') ??
        _requiredString(args, 'query');
    final maxResults = _boundedInt(args['max_results'], 60, 1, 200);
    if (!root.existsSync()) {
      return {'ok': false, 'error': 'directory_not_found', 'root': root.path};
    }

    final results = <Map<String, dynamic>>[];
    var filesScanned = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (results.length >= maxResults) break;
      if (_hasSkippedSegment(entity.path)) continue;
      if (entity is! File) continue;
      if (_shouldSkipFile(entity.path)) continue;
      final stat = await entity.stat();
      if (stat.size > 1024 * 1024) continue;
      filesScanned++;
      final lines = await entity
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList()
          .catchError((_) => <String>[]);
      for (var i = 0; i < lines.length && results.length < maxResults; i++) {
        final line = lines[i];
        if (line.contains(query)) {
          results.add({
            'path': entity.path,
            'line': i + 1,
            'text': line.length > 500 ? line.substring(0, 500) : line,
          });
        }
      }
    }
    return {
      'ok': true,
      'root': root.path,
      'query': query,
      'results': results,
      'files_scanned': filesScanned,
      'truncated': results.length >= maxResults,
    };
  }

  static Future<Map<String, dynamic>> _findFiles(
    Map<String, dynamic> args,
    String? cwd,
  ) async {
    final root = Directory(
      _resolvePath(
        (args['root'] ?? args['path']) is String
            ? (args['root'] ?? args['path']) as String
            : null,
        cwd,
      ),
    );
    final pattern =
        _optionalString(args, 'pattern') ??
        _optionalString(args, 'name') ??
        _requiredString(args, 'pattern');
    final maxResults = _boundedInt(args['max_results'], 80, 1, 300);
    if (!root.existsSync()) {
      return {'ok': false, 'error': 'directory_not_found', 'root': root.path};
    }
    final matcher = _globMatcher(pattern);
    final results = <Map<String, dynamic>>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (results.length >= maxResults) break;
      if (_hasSkippedSegment(entity.path)) continue;
      final name = p.basename(entity.path);
      if (!matcher(name) && !entity.path.contains(pattern)) continue;
      final stat = await entity.stat();
      results.add({
        'name': name,
        'path': entity.path,
        'type': _entityType(stat.type),
        if (stat.type == FileSystemEntityType.file) 'size': stat.size,
      });
    }
    return {
      'ok': true,
      'root': root.path,
      'pattern': pattern,
      'results': results,
      'truncated': results.length >= maxResults,
    };
  }

  static Future<Map<String, dynamic>> _writeFile(
    Map<String, dynamic> args,
    String? cwd,
  ) async {
    final path = _resolvePath(_requiredString(args, 'path'), cwd);
    final content = _requiredString(args, 'content');
    final overwrite = args['overwrite'] == true;
    final file = File(path);
    if (file.existsSync() && !overwrite) {
      return {
        'ok': false,
        'error': 'file_exists',
        'path': path,
        'message': '文件已存在；如确需覆盖，传 overwrite=true',
      };
    }
    file.parent.createSync(recursive: true);
    await file.writeAsString(content, flush: true);
    return {'ok': true, 'path': path, 'bytes': await file.length()};
  }

  static Future<Map<String, dynamic>> _editFile(
    Map<String, dynamic> args,
    String? cwd,
  ) async {
    final path = _resolvePath(_requiredString(args, 'path'), cwd);
    final oldText = _requiredString(args, 'old_text');
    final newText = args['new_text']?.toString() ?? '';
    final replaceAll = args['replace_all'] == true;
    final file = File(path);
    if (!file.existsSync()) {
      return {'ok': false, 'error': 'file_not_found', 'path': path};
    }
    final original = await file.readAsString();
    if (!original.contains(oldText)) {
      return {'ok': false, 'error': 'old_text_not_found', 'path': path};
    }
    final updated = replaceAll
        ? original.replaceAll(oldText, newText)
        : original.replaceFirst(oldText, newText);
    await file.writeAsString(updated, flush: true);
    return {
      'ok': true,
      'path': path,
      'replacements': replaceAll ? original.split(oldText).length - 1 : 1,
    };
  }

  static Future<Map<String, dynamic>> _runCommand(
    Map<String, dynamic> args,
    String? cwd,
  ) async {
    final command = _requiredString(args, 'command');
    final timeoutSeconds = _boundedInt(args['timeout_seconds'], 30, 1, 120);
    final invocation = _resolveShellInvocation(command);
    final proc = await Process.start(
      invocation.executable,
      invocation.args,
      workingDirectory: _defaultCwd(cwd),
      runInShell: false,
    );
    const outputDecoder = Utf8Decoder(allowMalformed: true);
    final stdoutFuture = proc.stdout
        .transform(outputDecoder)
        .join()
        .then(_truncateOutput);
    final stderrFuture = proc.stderr
        .transform(outputDecoder)
        .join()
        .then(_truncateOutput);
    final exitCode = await proc.exitCode.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    return {
      'ok': exitCode == 0,
      'exit_code': exitCode,
      'stdout': await stdoutFuture,
      'stderr': await stderrFuture,
      'timed_out': exitCode == -1,
    };
  }

  static _ShellInvocation _resolveShellInvocation(String command) {
    if (!Platform.isWindows) {
      return _ShellInvocation('/bin/sh', <String>['-lc', command]);
    }

    return _tryPowerShellInvocation(command) ??
        _ShellInvocation('cmd.exe', <String>['/c', command]);
  }

  static _ShellInvocation? _tryPowerShellInvocation(String command) {
    final executable = _readWindowsCommandToken(command, 0);
    if (executable == null || !_isPowerShellExecutable(executable.value)) {
      return null;
    }

    final prefixArgs = <String>[];
    var offset = executable.end;
    while (true) {
      final token = _readWindowsCommandToken(command, offset);
      if (token == null) return null;

      final value = token.value.toLowerCase();
      if (value == '-command' ||
          value == '-c' ||
          value == '/command' ||
          value == '/c') {
        final rawScript = command.substring(token.end).trim();
        if (rawScript.isEmpty) return null;
        return _ShellInvocation(executable.value, <String>[
          ...prefixArgs,
          '-Command',
          _wrapPowerShellScript(_stripCommandOuterQuotes(rawScript)),
        ]);
      }

      if (value == '-encodedcommand' ||
          value == '-enc' ||
          value == '/encodedcommand' ||
          value == '/enc' ||
          value == '-file' ||
          value == '-f' ||
          value == '/file' ||
          value == '/f') {
        return null;
      }

      prefixArgs.add(token.value);
      offset = token.end;
    }
  }

  static _CommandToken? _readWindowsCommandToken(String input, int offset) {
    var i = offset;
    while (i < input.length && input.codeUnitAt(i) <= 0x20) {
      i++;
    }
    if (i >= input.length) return null;

    final token = StringBuffer();
    var inQuotes = false;
    final start = i;
    while (i < input.length) {
      final char = input[i];
      if (char == r'\') {
        final next = i + 1 < input.length ? input[i + 1] : '';
        if (next == '"') {
          token.write('"');
          i += 2;
          continue;
        }
      }
      if (char == '"') {
        inQuotes = !inQuotes;
        i++;
        continue;
      }
      if (!inQuotes && char.codeUnitAt(0) <= 0x20) break;
      token.write(char);
      i++;
    }
    return _CommandToken(token.toString(), start, i);
  }

  static bool _isPowerShellExecutable(String executable) {
    final baseName = executable.split(RegExp(r'[\\/]')).last.toLowerCase();
    return baseName == 'powershell' ||
        baseName == 'powershell.exe' ||
        baseName == 'pwsh' ||
        baseName == 'pwsh.exe';
  }

  static String _stripCommandOuterQuotes(String value) {
    var text = value.trim();
    if (text.length >= 4 && text.startsWith(r'\"') && text.endsWith(r'\"')) {
      text = text.substring(2, text.length - 2);
    }
    if (text.length >= 2) {
      final first = text[0];
      final last = text[text.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return text.substring(1, text.length - 1);
      }
    }
    return text;
  }

  static String _wrapPowerShellScript(String script) {
    final escaped = script.replaceAll("'", "''");
    return <String>[
      r"$ErrorActionPreference = 'Stop'",
      'try {',
      "  Invoke-Expression '$escaped'",
      r'  if ($global:LASTEXITCODE -is [int] -and $global:LASTEXITCODE -ne 0) { exit $global:LASTEXITCODE }',
      '  exit 0',
      '} catch {',
      r'  [Console]::Error.WriteLine(($_ | Out-String))',
      '  exit 1',
      '}',
    ].join('; ');
  }

  static Future<Map<String, dynamic>> _webFetch(
    Map<String, dynamic> args,
  ) async {
    final rawUrl = _requiredString(args, 'url');
    final maxLength = _boundedInt(
      args['maxLength'] ?? args['max_length'],
      12000,
      1,
      60000,
    );
    Uri uri;
    try {
      uri = Uri.parse(rawUrl);
    } catch (_) {
      return {'ok': false, 'error': 'invalid_url', 'url': rawUrl};
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return {
        'ok': false,
        'error': 'unsupported_scheme',
        'message': '只支持 http/https URL',
      };
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'HanakoBot/1.0';
    try {
      for (var hop = 0; hop <= 5; hop++) {
        if (await _isPrivateHost(uri.host)) {
          return {
            'ok': false,
            'error': 'private_host_blocked',
            'host': uri.host,
          };
        }
        final req = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        req.followRedirects = false;
        req.headers.set(
          HttpHeaders.acceptHeader,
          'text/html,application/json,text/plain,*/*',
        );
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (_isRedirect(resp.statusCode)) {
          final location = resp.headers.value(HttpHeaders.locationHeader);
          await resp.drain<void>();
          if (location == null || location.trim().isEmpty) break;
          uri = uri.resolve(location);
          continue;
        }
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          return {
            'ok': false,
            'error': 'http_error',
            'status': resp.statusCode,
            'body': _truncate(body, 2000),
          };
        }
        final contentType =
            resp.headers.value(HttpHeaders.contentTypeHeader) ?? '';
        final format = contentType.contains('text/html')
            ? 'html'
            : contentType.contains('application/json')
            ? 'json'
            : 'text';
        final text = format == 'html' ? _htmlToText(body) : body;
        return {
          'ok': true,
          'url': uri.toString(),
          'format': format,
          'content': _truncate(text, maxLength),
          'truncated': text.length > maxLength,
        };
      }
      return {'ok': false, 'error': 'too_many_redirects'};
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, dynamic> _todo(Map<String, dynamic> args) {
    final action = _requiredString(args, 'action');
    switch (action) {
      case 'list':
        return {
          'ok': true,
          'todos': _todos.map((todo) => todo.toJson()).toList(growable: false),
        };
      case 'add':
        final text = _requiredString(args, 'text');
        final todo = _TodoItem(id: _nextTodoId++, text: text);
        _todos.add(todo);
        return {'ok': true, 'todo': todo.toJson()};
      case 'toggle':
        final id = _boundedInt(args['id'], -1, -1, 1 << 31);
        final match = _todos.where((todo) => todo.id == id).firstOrNull;
        if (match == null) {
          return {'ok': false, 'error': 'todo_not_found', 'id': id};
        }
        match.done = !match.done;
        return {'ok': true, 'todo': match.toJson()};
      case 'clear':
        final count = _todos.length;
        _todos.clear();
        _nextTodoId = 1;
        return {'ok': true, 'cleared': count};
      default:
        return {'ok': false, 'error': 'unknown_action', 'action': action};
    }
  }

  static Future<Map<String, dynamic>> _searchMemory(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final query = _requiredString(args, 'query');
    final files = [
      File(p.join(dir, 'memory', 'memory.md')),
      File(p.join(dir, 'memory', 'facts.md')),
      File(p.join(dir, 'pinned.md')),
    ];
    final results = <Map<String, dynamic>>[];
    for (final file in files) {
      if (!file.existsSync()) continue;
      final lines = await file.readAsLines();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(query)) {
          results.add({'path': file.path, 'line': i + 1, 'text': lines[i]});
        }
      }
    }
    return {'ok': true, 'query': query, 'results': results};
  }

  static Future<Map<String, dynamic>> _pinMemory(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final content = _scrubPii(_requiredString(args, 'content'));
    final file = File(p.join(dir, 'pinned.md'));
    file.parent.createSync(recursive: true);
    final existing = file.existsSync() ? await file.readAsString() : '';
    if (existing.contains(content)) {
      return {'ok': true, 'status': 'already_exists'};
    }
    await file.writeAsString(
      '${existing.trimRight()}\n- $content\n'.trimLeft(),
    );
    return {'ok': true, 'path': file.path};
  }

  static Future<Map<String, dynamic>> _unpinMemory(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final keyword = _requiredString(args, 'keyword').toLowerCase();
    final file = File(p.join(dir, 'pinned.md'));
    if (!file.existsSync()) return {'ok': true, 'removed': 0};
    final lines = await file.readAsLines();
    final remaining = <String>[];
    var removed = 0;
    for (final line in lines) {
      if (line.toLowerCase().contains(keyword)) {
        removed++;
      } else {
        remaining.add(line);
      }
    }
    await file.writeAsString('${remaining.join('\n')}\n');
    return {'ok': true, 'removed': removed};
  }

  static Future<Map<String, dynamic>> _listPinnedMemory(
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final file = File(p.join(dir, 'pinned.md'));
    if (!file.existsSync()) {
      return {'ok': true, 'path': file.path, 'items': const <String>[]};
    }
    final lines = await file.readAsLines();
    final items = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line.replaceFirst(RegExp(r'^-\s*'), '').trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return {'ok': true, 'path': file.path, 'items': items};
  }

  static Future<Map<String, dynamic>> _recallExperience(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final category = _optionalString(args, 'category');
    final file = category == null || category.isEmpty
        ? File(p.join(dir, 'experience.md'))
        : File(p.join(dir, 'experience', '$category.md'));
    if (!file.existsSync()) {
      return {'ok': true, 'content': '', 'message': '经验库为空或分类不存在'};
    }
    return {
      'ok': true,
      'path': file.path,
      'content': await file.readAsString(),
    };
  }

  static Future<Map<String, dynamic>> _recordExperience(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final category = _requiredString(
      args,
      'category',
    ).replaceAll('#', '').trim();
    final content = _requiredString(args, 'content');
    final experienceDir = Directory(p.join(dir, 'experience'));
    experienceDir.createSync(recursive: true);
    final file = File(p.join(experienceDir.path, '$category.md'));
    final existing = file.existsSync() ? await file.readAsString() : '';
    if (existing.contains(content)) {
      return {'ok': true, 'status': 'already_exists', 'path': file.path};
    }
    final count = RegExp(
      r'^\d+\.\s',
      multiLine: true,
    ).allMatches(existing).length;
    await file.writeAsString(
      '${existing.trimRight()}\n${count + 1}. $content\n'.trimLeft(),
    );
    return {'ok': true, 'path': file.path};
  }

  static Map<String, dynamic> _presentFiles(Map<String, dynamic> args) {
    final rawPaths = <String>[
      if (args['filepaths'] is List)
        ...(args['filepaths'] as List).map((item) => item.toString()),
      if (args['filePath'] is String) args['filePath'] as String,
    ];
    if (rawPaths.isEmpty) {
      return {'ok': false, 'error': 'missing_filepaths'};
    }
    final files = <Map<String, dynamic>>[];
    final errors = <String>[];
    for (final raw in rawPaths) {
      final path = raw.trim();
      if (!p.isAbsolute(path)) {
        errors.add('路径必须是绝对路径: $path');
        continue;
      }
      final file = File(path);
      if (!file.existsSync()) {
        errors.add('文件不存在: $path');
        continue;
      }
      files.add({'path': file.path, 'label': p.basename(file.path)});
    }
    return {'ok': files.isNotEmpty, 'files': files, 'errors': errors};
  }

  static Map<String, dynamic> _createArtifact(Map<String, dynamic> args) {
    final type = _requiredString(args, 'type');
    final title = _requiredString(args, 'title');
    final content = _requiredString(args, 'content');
    return {
      'ok': true,
      'artifact': {
        'id':
            'artifact-${DateTime.now().millisecondsSinceEpoch}-${++_artifactCounter}',
        'type': type,
        'title': title,
        'content': content,
        'language': args['language'],
      },
      'message': '已创建 Artifact，客户端会在会话中显示预览入口。',
    };
  }

  static Future<Map<String, dynamic>> _installSkill(
    Map<String, dynamic> args, {
    required String? activeAgentId,
    required SkillManager? skillManager,
  }) async {
    final manager = skillManager;
    final agentId = activeAgentId?.trim();
    if (manager == null || agentId == null || agentId.isEmpty) {
      return {
        'ok': false,
        'error': 'not_configured',
        'message': 'Skill 管理器或当前 Agent 尚未初始化。',
      };
    }
    final enable = args['enabled'] is bool ? args['enabled'] as bool : true;
    final content = _optionalString(args, 'skill_content');
    final sourcePath =
        _optionalString(args, 'source_path') ?? _optionalString(args, 'path');
    final githubUrl = _optionalString(args, 'github_url');
    try {
      final skill = content != null
          ? await manager.installFromContent(
              agentId,
              skillContent: content,
              skillName: _optionalString(args, 'skill_name'),
              enable: enable,
            )
          : sourcePath != null
          ? await manager.installFromPath(agentId, sourcePath, enable: enable)
          : throw ArgumentError(
              githubUrl == null
                  ? '需要 skill_content 或 source_path 参数'
                  : '当前 Flutter 客户端暂未接入 GitHub 拉取，请改用 source_path 或 skill_content',
            );
      return {
        'ok': true,
        'skill': skill.toJson(),
        'enabled': manager.enabledSkillNames(agentId),
        'message': '已安装 Skill：${skill.name}${enable ? "（已启用）" : ""}',
      };
    } catch (e) {
      return {'ok': false, 'error': 'invalid_skill', 'message': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> _cron(
    Map<String, dynamic> args, {
    required CronStore? cronStore,
    required String? activeAgentId,
    required Future<CronRunRecord> Function(String jobId)? runCronNow,
  }) async {
    final store = cronStore;
    if (store == null) {
      return {
        'ok': false,
        'tool': LocalToolNames.cron,
        'error': 'not_configured',
        'message': 'Cron 运行时尚未初始化。',
      };
    }
    final action = _requiredString(args, 'action').replaceAll('_', '-');
    switch (action) {
      case 'list':
        final jobs = store.listJobs();
        return {
          'ok': true,
          'jobs': jobs.map(_cronJobJsonWithHistory).toList(growable: false),
          'message': jobs.isEmpty
              ? '没有定时任务'
              : jobs
                    .map((job) {
                      final status = job.enabled ? '✓' : '✗';
                      final next =
                          job.nextRunAt?.toLocal().toIso8601String() ?? '无';
                      return '[$status] ${job.id}: ${job.label} (${job.type}, 下次: $next)';
                    })
                    .join('\n'),
        };
      case 'add':
        final type = _requiredString(args, 'type');
        final schedule = args['schedule'];
        final prompt = _requiredString(args, 'prompt');
        if (schedule == null || schedule.toString().trim().isEmpty) {
          return {
            'ok': false,
            'error': 'missing_schedule',
            'message': 'add 需要 schedule 参数。',
          };
        }
        final agentId =
            _optionalString(args, 'agent') ??
            _optionalString(args, 'agentId') ??
            activeAgentId;
        if (agentId == null || agentId.trim().isEmpty) {
          return {
            'ok': false,
            'error': 'missing_agent',
            'message': 'add 需要当前 Agent 或显式 agent 参数。',
          };
        }
        final everyMs = type == 'every'
            ? int.tryParse(schedule.toString().trim())
            : null;
        if (type == 'every' && (everyMs == null || everyMs <= 0)) {
          return {
            'ok': false,
            'error': 'invalid_schedule',
            'message': 'every 类型的 schedule 必须是正整数毫秒。',
          };
        }
        final job = store.addJob(
          agentId: agentId,
          type: type,
          schedule: type == 'every' ? everyMs! : schedule.toString(),
          prompt: prompt,
          label: _optionalString(args, 'label') ?? '',
          model: _optionalString(args, 'model') ?? '',
        );
        return {
          'ok': true,
          'action': 'added',
          'job': job.toJson(),
          'jobs': store.listJobs().map((job) => job.toJson()).toList(),
          'message': '已创建定时任务：${job.label} (${job.id})',
        };
      case 'remove':
        final id = _requiredString(args, 'id');
        final removed = store.removeJob(id);
        return {
          'ok': removed,
          'action': 'remove',
          'id': id,
          'jobs': store.listJobs().map((job) => job.toJson()).toList(),
          'message': removed ? '已删除任务 $id' : '任务 $id 不存在',
          if (!removed) 'error': 'not_found',
        };
      case 'toggle':
        final id = _requiredString(args, 'id');
        final enabled = args['enabled'] is bool
            ? args['enabled'] as bool
            : null;
        final job = store.toggleJob(id, enabled: enabled);
        if (job == null) {
          return {
            'ok': false,
            'action': 'toggle',
            'id': id,
            'error': 'not_found',
            'message': '任务 $id 不存在',
          };
        }
        return {
          'ok': true,
          'action': 'toggle',
          'job': job.toJson(),
          'jobs': store.listJobs().map((job) => job.toJson()).toList(),
          'message': '任务 ${job.id} ${job.enabled ? "已启用" : "已禁用"}',
        };
      case 'run-now':
        final run = runCronNow;
        if (run == null) {
          return {
            'ok': false,
            'error': 'not_configured',
            'message': 'Cron 调度器尚未接入 run-now。',
          };
        }
        final id = _requiredString(args, 'id');
        final record = await run(id);
        return {
          'ok': record.status == 'success',
          'action': 'run-now',
          'run': record.toJson(),
          'message': record.status == 'success'
              ? '任务 $id 已立即执行'
              : '任务 $id 执行结果：${record.status}',
        };
      case 'history':
        final id = _requiredString(args, 'id');
        final limit = _boundedInt(args['limit'], 20, 1, 100);
        return {
          'ok': true,
          'action': 'history',
          'id': id,
          'runs': store
              .getRunHistory(id, limit: limit)
              .map((run) => run.toJson())
              .toList(growable: false),
        };
      default:
        return {
          'ok': false,
          'error': 'unknown_action',
          'message': '未知 cron 操作：$action',
        };
    }
  }

  static Map<String, dynamic> _cronJobJsonWithHistory(CronJob job) => {
    ...job.toJson(),
  };

  static Future<Map<String, dynamic>> _browser(
    Map<String, dynamic> args,
    BrowserManager? browserManager,
  ) async {
    final manager = browserManager;
    if (manager == null) {
      return _notConfigured(LocalToolNames.browser, 'Browser 运行时尚未初始化。');
    }
    return manager.execute(args);
  }

  static Future<Map<String, dynamic>> _channel(
    Map<String, dynamic> args,
    ChannelManager? channelManager,
    CollaborationManager? collaborationManager,
    String? activeAgentId,
  ) async {
    final manager = collaborationManager;
    if (manager != null) {
      return manager.channel(args, sourceAgentId: activeAgentId);
    }
    final channels = channelManager;
    if (channels == null) {
      return _notConfigured(LocalToolNames.channel, 'Channel 运行时尚未初始化。');
    }
    final action = _requiredString(args, 'action');
    switch (action) {
      case 'list':
        final list = await channels.listChannels();
        return {
          'ok': true,
          'channels': list.map((channel) => channel.toJson()).toList(),
        };
      case 'create':
        final channel = await channels.createChannel(
          id: _optionalString(args, 'channel'),
          name: _optionalString(args, 'name'),
          description: _optionalString(args, 'description'),
          members: _stringList(args['members']),
          intro: _optionalString(args, 'intro'),
        );
        return {'ok': true, 'channel': channel.toJson()};
      case 'read':
        final messages = await channels.readRecent(
          _requiredString(args, 'channel'),
          limit: _boundedInt(args['count'], 50, 1, 200),
        );
        return {
          'ok': true,
          'messages': messages.map((message) => message.toJson()).toList(),
        };
      case 'post':
        await channels.appendMessage(
          _requiredString(args, 'channel'),
          'agent:${activeAgentId ?? "unknown"}',
          _requiredString(args, 'content'),
        );
        return {'ok': true, 'message': '已写入频道消息'};
      default:
        return {
          'ok': false,
          'error': 'unknown_action',
          'message': '未知 channel 操作：$action',
        };
    }
  }

  static Future<Map<String, dynamic>> _askAgent(
    Map<String, dynamic> args,
    CollaborationManager? collaborationManager,
    String? activeAgentId,
  ) async {
    final manager = collaborationManager;
    if (manager == null) {
      return _notConfigured(LocalToolNames.askAgent, '多 Agent 协作运行时尚未初始化。');
    }
    return manager.delegate(
      args,
      sourceAgentId: activeAgentId,
      toolName: LocalToolNames.askAgent,
    );
  }

  static Future<Map<String, dynamic>> _dm(
    Map<String, dynamic> args,
    CollaborationManager? collaborationManager,
    String? activeAgentId,
  ) async {
    final manager = collaborationManager;
    if (manager == null) {
      return _notConfigured(LocalToolNames.dm, 'DM 协作运行时尚未初始化。');
    }
    return manager.dm(args, sourceAgentId: activeAgentId);
  }

  static Future<Map<String, dynamic>> _delegate(
    Map<String, dynamic> args,
    CollaborationManager? collaborationManager,
    String? activeAgentId,
  ) async {
    final manager = collaborationManager;
    if (manager == null) {
      return _notConfigured(LocalToolNames.delegate, 'Delegate 协作运行时尚未初始化。');
    }
    return manager.delegate(args, sourceAgentId: activeAgentId);
  }

  static Map<String, dynamic> _notify(Map<String, dynamic> args) => {
    'ok': true,
    'title': _requiredString(args, 'title'),
    'body': _requiredString(args, 'body'),
    'delivered': false,
    'message': '当前客户端暂未接入系统通知发送器。',
  };

  static Map<String, dynamic> _notConfigured(String name, String message) => {
    'ok': false,
    'tool': name,
    'error': 'not_configured',
    'message': message,
  };

  static String _resolvePath(String? raw, String? cwd) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return _defaultCwd(cwd);
    if (p.isAbsolute(value)) return p.normalize(value);
    return p.normalize(p.join(_defaultCwd(cwd), value));
  }

  static String _defaultCwd(String? cwd) {
    final value = cwd?.trim();
    if (value != null && value.isNotEmpty) return p.normalize(value);
    return Directory.current.path;
  }

  static String _requireAgentDir(String? agentDir) {
    final value = agentDir?.trim();
    if (value == null || value.isEmpty) {
      throw StateError('agentDir is required for this tool');
    }
    return value;
  }

  static String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    throw ArgumentError('参数 $key 必须是非空字符串');
  }

  static String? _optionalString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static List<String> _stringList(Object? raw) {
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

  static int _boundedInt(Object? value, int fallback, int min, int max) {
    final raw = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? fallback;
    if (raw < min) return min;
    if (raw > max) return max;
    return raw;
  }

  static String _entityType(FileSystemEntityType type) {
    if (type == FileSystemEntityType.directory) return 'directory';
    if (type == FileSystemEntityType.file) return 'file';
    if (type == FileSystemEntityType.link) return 'link';
    return 'other';
  }

  static bool _shouldSkipDir(String path) {
    return const {
      '.git',
      '.dart_tool',
      '.gradle',
      '.idea',
      '.vscode',
      'node_modules',
      'build',
      'dist',
      'target',
      '.next',
    }.contains(p.basename(path).toLowerCase());
  }

  static bool _hasSkippedSegment(String path) {
    final segments = p.split(path).map((segment) => segment.toLowerCase());
    for (final segment in segments) {
      if (_shouldSkipDir(segment)) return true;
    }
    return false;
  }

  static bool _shouldSkipFile(String path) {
    final name = p.basename(path).toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.ico') ||
        name.endsWith('.exe') ||
        name.endsWith('.dll') ||
        name.endsWith('.onnx') ||
        name.endsWith('.rten') ||
        name.endsWith('.zip') ||
        name.endsWith('.7z');
  }

  static bool Function(String name) _globMatcher(String pattern) {
    final escaped = RegExp.escape(
      pattern,
    ).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    final regex = RegExp('^$escaped\$', caseSensitive: false);
    return (name) => regex.hasMatch(name);
  }

  static String _truncateOutput(String text) => _truncate(text, 40000);

  static String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}\n\n[... 内容已截断，共 ${text.length} 字符]';
  }

  static String _scrubPii(String text) {
    var out = text;
    out = out.replaceAll(
      RegExp(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'),
      '[REDACTED:CARD]',
    );
    out = out.replaceAll(RegExp(r'\b\d{17}[\dXx]\b'), '[REDACTED:ID]');
    out = out.replaceAll(RegExp(r'\b1[3-9]\d{9}\b'), '[REDACTED:PHONE]');
    out = out.replaceAll(
      RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b'),
      '[REDACTED:EMAIL]',
    );
    return out;
  }

  static bool _isRedirect(int code) =>
      code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  static Future<bool> _isPrivateHost(String host) async {
    try {
      final addresses = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 5));
      if (addresses.isEmpty) return true;
      return addresses.any(_isPrivateAddress);
    } catch (_) {
      return true;
    }
  }

  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final raw = address.address.toLowerCase();
    if (raw == '0.0.0.0' || raw == '::1') return true;
    final parts = raw.split('.');
    if (parts.length == 4) {
      final nums = parts.map(int.tryParse).toList();
      if (nums.any((n) => n == null)) return true;
      final a = nums[0]!;
      final b = nums[1]!;
      return a == 10 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254);
    }
    return raw.startsWith('fc') ||
        raw.startsWith('fd') ||
        raw.startsWith('fe80');
  }

  static String _htmlToText(String html) {
    var text = html
        .replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<head[\s\S]*?</head>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<nav[\s\S]*?</nav>', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'<footer[\s\S]*?</footer>', caseSensitive: false),
          '',
        );
    text = text.replaceAll(
      RegExp(
        r'</?(p|div|br|h[1-6]|li|tr|blockquote|section|article|header)[^>]*>',
        caseSensitive: false,
      ),
      '\n',
    );
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }
}

class LocalToolNames {
  const LocalToolNames._();

  static const environment = 'local_environment';
  static const listDirectory = 'local_list_directory';
  static const readTextFile = 'local_read_text_file';
  static const searchText = 'local_search_text';

  static const read = 'read';
  static const write = 'write';
  static const edit = 'edit';
  static const bash = 'bash';
  static const grep = 'grep';
  static const find = 'find';
  static const ls = 'ls';

  static const searchMemory = 'search_memory';
  static const webSearch = 'web_search';
  static const webFetch = 'web_fetch';
  static const todo = 'todo';
  static const pinMemory = 'pin_memory';
  static const unpinMemory = 'unpin_memory';
  static const listPinnedMemory = 'list_pinned_memory';
  static const recallExperience = 'recall_experience';
  static const recordExperience = 'record_experience';
  static const cron = 'cron';
  static const presentFiles = 'present_files';
  static const createArtifact = 'create_artifact';
  static const channel = 'channel';
  static const askAgent = 'ask_agent';
  static const dm = 'dm';
  static const messageAgent = 'message_agent';
  static const browser = 'browser';
  static const installSkill = 'install_skill';
  static const notify = 'notify';
  static const delegate = 'delegate';
}

class _TodoItem {
  _TodoItem({required this.id, required this.text});

  final int id;
  final String text;
  bool done = false;

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'done': done};
}

class _ToolSpec {
  const _ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

class _ShellInvocation {
  const _ShellInvocation(this.executable, this.args);

  final String executable;
  final List<String> args;
}

class _CommandToken {
  const _CommandToken(this.value, this.start, this.end);

  final String value;
  final int start;
  final int end;
}

final _knownToolNames = <String>{
  for (final spec in _toolSpecs) spec.name,
  LocalToolNames.environment,
  LocalToolNames.listDirectory,
  LocalToolNames.readTextFile,
  LocalToolNames.searchText,
};

const _toolSpecs = <_ToolSpec>[
  _ToolSpec(
    name: LocalToolNames.read,
    description: '读取本地文本文件内容。用于查看代码、配置、日志和普通文本；过长内容会截断。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'path': {'type': 'string', 'description': '文件路径'},
        'max_chars': {'type': 'integer', 'minimum': 1, 'maximum': 60000},
      },
      'required': ['path'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.write,
    description: '写入本地文本文件。默认不覆盖已存在文件；确需覆盖时传 overwrite=true。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
        'overwrite': {'type': 'boolean'},
      },
      'required': ['path', 'content'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.edit,
    description: '在本地文本文件中替换指定文本。适合小范围精确编辑。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'path': {'type': 'string'},
        'old_text': {'type': 'string'},
        'new_text': {'type': 'string'},
        'replace_all': {'type': 'boolean'},
      },
      'required': ['path', 'old_text', 'new_text'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.bash,
    description: '在当前工作目录执行一条 shell 命令，并返回 stdout/stderr/exit_code。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'command': {'type': 'string'},
        'timeout_seconds': {'type': 'integer', 'minimum': 1, 'maximum': 120},
      },
      'required': ['command'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.grep,
    description: '在目录下搜索文本。适合定位代码符号、配置项和错误信息。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'root': {'type': 'string'},
        'path': {'type': 'string'},
        'query': {'type': 'string'},
        'pattern': {'type': 'string'},
        'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 200},
      },
    },
  ),
  _ToolSpec(
    name: LocalToolNames.find,
    description: '按文件名或路径片段查找文件。支持 * 和 ? 通配符。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'root': {'type': 'string'},
        'path': {'type': 'string'},
        'pattern': {'type': 'string'},
        'name': {'type': 'string'},
        'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 300},
      },
    },
  ),
  _ToolSpec(
    name: LocalToolNames.ls,
    description: '列出本地目录内容。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'path': {'type': 'string'},
        'max_entries': {'type': 'integer', 'minimum': 1, 'maximum': 300},
      },
    },
  ),
  _ToolSpec(
    name: LocalToolNames.searchMemory,
    description: '搜索当前 Agent 的本地记忆文本。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'query': {'type': 'string'},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'date_from': {'type': 'string'},
        'date_to': {'type': 'string'},
      },
      'required': ['query'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.webSearch,
    description: '搜索互联网获取实时信息。当前 Flutter 客户端需要配置搜索 provider 后才能执行。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'query': {'type': 'string'},
        'maxResults': {'type': 'integer', 'minimum': 1, 'maximum': 20},
      },
      'required': ['query'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.webFetch,
    description: '抓取指定 http/https URL 并提取文本。会阻止内网地址访问。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'url': {'type': 'string'},
        'maxLength': {'type': 'integer', 'minimum': 1, 'maximum': 60000},
      },
      'required': ['url'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.todo,
    description: '管理当前客户端会话内的待办清单。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'add', 'toggle', 'clear'],
        },
        'text': {'type': 'string'},
        'id': {'type': 'integer'},
      },
      'required': ['action'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.pinMemory,
    description: '将内容写入当前 Agent 的置顶记忆。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'content': {'type': 'string'},
      },
      'required': ['content'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.unpinMemory,
    description: '按关键词从当前 Agent 的置顶记忆中移除内容。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'keyword': {'type': 'string'},
      },
      'required': ['keyword'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.listPinnedMemory,
    description: '列出当前 Agent 的置顶记忆。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, Object>{},
    },
  ),
  _ToolSpec(
    name: LocalToolNames.recallExperience,
    description: '查看当前 Agent 的经验库索引或指定分类。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'category': {'type': 'string'},
      },
    },
  ),
  _ToolSpec(
    name: LocalToolNames.recordExperience,
    description: '把一条经验记录到当前 Agent 的经验库。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'category': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['category', 'content'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.cron,
    description: '创建和管理定时任务。到期后会在后台打开独立 session 执行指定 prompt。',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'add', 'remove', 'toggle', 'run-now', 'history'],
        },
        'type': {
          'type': 'string',
          'enum': ['at', 'every', 'cron'],
        },
        'schedule': {'type': 'string'},
        'prompt': {'type': 'string'},
        'label': {'type': 'string'},
        'model': {'type': 'string'},
        'agent': {'type': 'string'},
        'agentId': {'type': 'string'},
        'id': {'type': 'string'},
        'enabled': {'type': 'boolean'},
        'limit': {'type': 'integer'},
      },
      'required': ['action'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.presentFiles,
    description: '将已生成的本地文件呈现给用户。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'filepaths': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'filePath': {'type': 'string'},
        'label': {'type': 'string'},
      },
    },
  ),
  _ToolSpec(
    name: LocalToolNames.createArtifact,
    description: '创建 HTML、代码或 Markdown 预览内容。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'type': {
          'type': 'string',
          'enum': ['html', 'code', 'markdown'],
        },
        'title': {'type': 'string'},
        'content': {'type': 'string'},
        'language': {'type': 'string'},
      },
      'required': ['type', 'title', 'content'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.channel,
    description: '管理频道消息，并可触发多 Agent channel triage。',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'read',
            'post',
            'create',
            'list',
            'triage',
            'status',
            'configure',
          ],
        },
        'channel': {'type': 'string'},
        'content': {'type': 'string'},
        'description': {'type': 'string'},
        'sender': {'type': 'string'},
        'agent': {'type': 'string'},
        'targetAgentId': {'type': 'string'},
        'auto_triage': {'type': 'boolean'},
        'enabled': {'type': 'boolean'},
        'triage': {'type': 'boolean'},
        'name': {'type': 'string'},
        'members': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'intro': {'type': 'string'},
        'count': {'type': 'integer'},
      },
      'required': ['action'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.askAgent,
    description: '向另一个 Agent 发起一次同步任务，并返回结果 session 路径与摘要。',
    parameters: {
      'type': 'object',
      'properties': {
        'agent': {'type': 'string'},
        'targetAgentId': {'type': 'string'},
        'task': {'type': 'string'},
        'model': {'type': 'string'},
        'depth': {'type': 'integer'},
      },
      'required': ['task'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.dm,
    description: '给另一个 Agent 发送私信，或配置 DM 自动回复开关。',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['send', 'status', 'configure'],
        },
        'to': {'type': 'string'},
        'agent': {'type': 'string'},
        'message': {'type': 'string'},
        'auto_reply': {'type': 'boolean'},
        'enabled': {'type': 'boolean'},
        'depth': {'type': 'integer'},
      },
      'required': [],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.messageAgent,
    description: '向另一个 Agent 发送消息并等待回复。',
    parameters: {
      'type': 'object',
      'properties': {
        'to': {'type': 'string'},
        'agent': {'type': 'string'},
        'message': {'type': 'string'},
        'max_rounds': {'type': 'integer'},
        'depth': {'type': 'integer'},
      },
      'required': ['to', 'message'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.browser,
    description: '控制浏览器打开网页、读取页面标题/文本和查看状态；复杂交互会返回中文限制说明。',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'start',
            'stop',
            'navigate',
            'snapshot',
            'screenshot',
            'click',
            'type',
            'scroll',
            'select',
            'key',
            'wait',
            'evaluate',
            'show',
            'status',
          ],
        },
        'url': {'type': 'string'},
        'ref': {'type': 'integer'},
        'text': {'type': 'string'},
        'direction': {
          'type': 'string',
          'enum': ['up', 'down'],
        },
        'amount': {'type': 'integer'},
        'value': {'type': 'string'},
        'key': {'type': 'string'},
        'expression': {'type': 'string'},
        'timeout': {'type': 'integer'},
        'state': {'type': 'string'},
        'pressEnter': {'type': 'boolean'},
      },
      'required': ['action'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.installSkill,
    description: '为当前 Agent 安装 Anthropic Agent Skill，并可立即启用。',
    parameters: {
      'type': 'object',
      'properties': {
        'github_url': {'type': 'string'},
        'source_path': {'type': 'string'},
        'path': {'type': 'string'},
        'skill_content': {'type': 'string'},
        'skill_name': {'type': 'string'},
        'reason': {'type': 'string'},
        'enabled': {'type': 'boolean'},
      },
    },
  ),
  _ToolSpec(
    name: LocalToolNames.notify,
    description: '向用户发送系统通知。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'title': {'type': 'string'},
        'body': {'type': 'string'},
      },
      'required': ['title', 'body'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.delegate,
    description: '委派独立子任务给后台 Agent，结果会写入目标 Agent session 和活动记录。',
    parameters: {
      'type': 'object',
      'properties': {
        'agent': {'type': 'string'},
        'targetAgentId': {'type': 'string'},
        'task': {'type': 'string'},
        'model': {'type': 'string'},
        'depth': {'type': 'integer'},
      },
      'required': ['task'],
    },
  ),
];

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
