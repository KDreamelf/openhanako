import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
        LocalToolNames.recallExperience => await _recallExperience(
          arguments,
          agentDir,
        ),
        LocalToolNames.recordExperience => await _recordExperience(
          arguments,
          agentDir,
        ),
        LocalToolNames.presentFiles => _presentFiles(arguments),
        LocalToolNames.createArtifact => _createArtifact(arguments),
        LocalToolNames.notify => _notify(arguments),
        LocalToolNames.cron ||
        LocalToolNames.channel ||
        LocalToolNames.askAgent ||
        LocalToolNames.dm ||
        LocalToolNames.messageAgent ||
        LocalToolNames.browser ||
        LocalToolNames.installSkill ||
        LocalToolNames.delegate => _notAvailableYet(name),
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
    final shell = Platform.isWindows ? 'cmd.exe' : '/bin/sh';
    final shellArgs = Platform.isWindows
        ? <String>['/c', command]
        : <String>['-lc', command];
    final proc = await Process.start(
      shell,
      shellArgs,
      workingDirectory: _defaultCwd(cwd),
      runInShell: false,
    );
    final stdoutFuture = proc.stdout
        .transform(utf8.decoder)
        .join()
        .then(_truncateOutput);
    final stderrFuture = proc.stderr
        .transform(utf8.decoder)
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
    final content = _requiredString(args, 'content');
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
    final keyword = _requiredString(args, 'keyword');
    final file = File(p.join(dir, 'pinned.md'));
    if (!file.existsSync()) return {'ok': true, 'removed': 0};
    final lines = await file.readAsLines();
    final remaining = <String>[];
    var removed = 0;
    for (final line in lines) {
      if (line.contains(keyword)) {
        removed++;
      } else {
        remaining.add(line);
      }
    }
    await file.writeAsString('${remaining.join('\n')}\n');
    return {'ok': true, 'removed': removed};
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
      'message': '当前 Flutter 客户端尚未接入 artifact 预览面板，已将内容作为工具结果返回。',
    };
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

  static Map<String, dynamic> _notAvailableYet(String name) => {
    'ok': false,
    'tool': name,
    'error': 'not_available_in_flutter_client',
    'message': '该工具已按原项目工具面注册，但 Flutter 子体客户端尚未接入对应执行模块。',
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

  static int _boundedInt(Object? value, int fallback, int min, int max) {
    final raw = value is num ? value.toInt() : fallback;
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
    description: '创建和管理定时任务。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'add', 'remove', 'toggle'],
        },
        'type': {
          'type': 'string',
          'enum': ['at', 'every', 'cron'],
        },
        'schedule': {'type': 'string'},
        'prompt': {'type': 'string'},
        'label': {'type': 'string'},
        'model': {'type': 'string'},
        'id': {'type': 'string'},
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
    description: '管理频道消息。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['read', 'post', 'create', 'list'],
        },
        'channel': {'type': 'string'},
        'content': {'type': 'string'},
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
    description: '向另一个 Agent 发起一次同步任务。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'agent': {'type': 'string'},
        'task': {'type': 'string'},
      },
      'required': ['agent', 'task'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.dm,
    description: '给另一个 Agent 发送私信。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'to': {'type': 'string'},
        'message': {'type': 'string'},
      },
      'required': ['to', 'message'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.messageAgent,
    description: '向另一个 Agent 发送消息并等待回复。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'to': {'type': 'string'},
        'message': {'type': 'string'},
        'max_rounds': {'type': 'integer'},
      },
      'required': ['to', 'message'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.browser,
    description: '控制浏览器进行网页浏览、点击、输入、截图等。Flutter 客户端暂未接入执行模块。',
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
    description: '为当前 Agent 安装技能。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'github_url': {'type': 'string'},
        'skill_content': {'type': 'string'},
        'skill_name': {'type': 'string'},
        'reason': {'type': 'string'},
      },
      'required': ['reason'],
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
    description: '委派独立子任务给后台 Agent。Flutter 客户端暂未接入执行模块。',
    parameters: {
      'type': 'object',
      'properties': {
        'task': {'type': 'string'},
        'model': {'type': 'string'},
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
