import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/browser_manager.dart';
import '../core/cron_store.dart';
import '../core/experience_network_daemon.dart';
import '../core/skill_manager.dart';
import '../experience/experience.dart';
import '../memory/claude_memory.dart';
import '../shared/pii_scrubber.dart';
import '../llm/provider.dart';

class LocalToolRegistry {
  const LocalToolRegistry._();

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
    ExperienceNetworkDaemon? experienceNetworkDaemon,
    String? sessionPath,
  }) async {
    try {
      final result = switch (name) {
        LocalToolNames.webFetch => await _webFetch(arguments),
        LocalToolNames.webSearch => await _webSearch(arguments, browserManager),
        LocalToolNames.searchMemory => await _searchMemory(arguments, agentDir),
        LocalToolNames.pinMemory => await _pinMemory(arguments, agentDir),
        LocalToolNames.unpinMemory => await _unpinMemory(arguments, agentDir),
        LocalToolNames.listPinnedMemory => await _listPinnedMemory(agentDir),
        LocalToolNames.createExperience => await _createExperience(
          arguments,
          agentDir,
          sessionPath,
          cwd,
        ),
        LocalToolNames.experienceSearch => await _experienceSearch(
          arguments,
          agentDir,
        ),
        LocalToolNames.publishDemand => await _publishDemand(
          arguments,
          agentDir,
          experienceNetworkDaemon,
        ),
        LocalToolNames.cron => await _cron(
          arguments,
          cronStore: cronStore,
          activeAgentId: activeAgentId,
          runCronNow: runCronNow,
        ),
        LocalToolNames.createArtifact => _createArtifact(arguments, cwd),
        LocalToolNames.notify => _notify(arguments),
        LocalToolNames.browser => await _browser(arguments, browserManager),
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

  static Future<Map<String, dynamic>> _webFetch(
    Map<String, dynamic> args,
  ) async {
    final rawUrl = _requiredString(args, 'url');
    final maxLength = _boundedInt(args['maxLength'], 12000, 1, 60000);
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

  static Future<Map<String, dynamic>> _webSearch(
    Map<String, dynamic> args,
    BrowserManager? browserManager,
  ) async {
    final query = _requiredString(args, 'query');
    if (browserManager == null) {
      return {
        'ok': false,
        'error': 'browser_unavailable',
        'message': 'Browser 运行时尚未初始化。可以先用 web_fetch 读取已知 URL。',
      };
    }
    await browserManager.start();
    final encodedQuery = Uri.encodeComponent(query);
    final navResult = await browserManager.execute({
      'action': 'navigate',
      'url': 'https://www.bing.com/search?q=$encodedQuery',
    });
    if (navResult['ok'] != true) return navResult;
    await browserManager.execute({'action': 'wait', 'timeout': 2000, 'state': 'networkidle'});
    final evalResult = await browserManager.execute({
      'action': 'evaluate',
      'expression': '''
        JSON.stringify(Array.from(document.querySelectorAll('.b_algo')).slice(0, 10).map(el => ({
          title: (el.querySelector('h2') || {}).textContent || '',
          url: (el.querySelector('a') || {}).href || '',
          snippet: (el.querySelector('.b_caption p, .b_lineclamp2') || {}).textContent || '',
        })))
      ''',
    });
    if (evalResult['ok'] != true) return evalResult;
    final rawJson = evalResult['message']?.toString() ?? '[]';
    try {
      final results = jsonDecode(rawJson);
      return {
        'ok': true,
        'query': query,
        'results': results,
        'source': 'bing',
      };
    } catch (_) {
      return {
        'ok': true,
        'query': query,
        'results': [],
        'raw': rawJson,
        'source': 'bing',
        'message': '搜索结果解析失败，原始文本已返回',
      };
    }
  }

  static Future<Map<String, dynamic>> _searchMemory(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final query = _requiredString(args, 'query');
    final maxResults = _boundedInt(args['max_results'], 20, 1, 200);
    final memoryRoot = getClaudeMemoryRoot(Directory(dir));
    final results = await searchMemoryFiles(
      memoryRoot,
      query,
      maxResults: maxResults,
    );
    return {
      'ok': true,
      'query': query,
      'memory_root': memoryRoot.path,
      'results': results.map((result) => result.toJson()).toList(),
    };
  }

  static Future<Map<String, dynamic>> _pinMemory(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = _requireAgentDir(agentDir);
    final content = scrubPii(_requiredString(args, 'content'));
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

  static Future<Map<String, dynamic>> _experienceSearch(
    Map<String, dynamic> args,
    String? agentDir,
  ) async {
    final dir = Directory(_requireAgentDir(agentDir));
    final query = _requiredString(args, 'query');
    final maxResults = _boundedInt(args['max_results'], 50, 1, 200);
    final scope = _optionalString(args, 'scope');
    final scopes = switch (scope) {
      'private' => {ExperienceScope.private},
      'network' => {ExperienceScope.network},
      _ => {ExperienceScope.private, ExperienceScope.network},
    };
    final store = ExperienceStore(agentDir: dir);
    final results = await store.search(
      query,
      maxResults: maxResults,
      scopes: scopes,
    );
    return {
      'ok': true,
      'query': query,
      'results': results.map((result) => result.toJson()).toList(),
      'message': '仅返回路径、行号和片段；需要全文时请继续用 exec_command 读取对应文件。',
    };
  }

  static Future<Map<String, dynamic>> _publishDemand(
    Map<String, dynamic> args,
    String? agentDir,
    ExperienceNetworkDaemon? daemon,
  ) async {
    if (daemon == null) {
      return {
        'ok': false,
        'error': 'experience_network_unavailable',
        'message': '经验网络守护进程未初始化',
      };
    }
    final query = _requiredString(args, 'query');
    final keywords = _jsonStringList(args['keywords']);
    return daemon.publishDemand(
      query: query,
      keywords: keywords,
      agentDirOverride: agentDir,
    );
  }

  static Future<Map<String, dynamic>> _createExperience(
    Map<String, dynamic> args,
    String? agentDir,
    String? sessionPath,
    String? cwd,
  ) async {
    final dir = Directory(_requireAgentDir(agentDir));
    final title = _requiredString(args, 'title');
    final brief = _optionalString(args, 'brief') ?? '';
    final keywords = _jsonStringList(args['keywords']);
    final source = (_optionalString(args, 'source') ?? 'current_session')
        .trim()
        .toLowerCase();
    final ExperienceSaveResult saved;
    if (source == 'raw_directory') {
      final rawDirectory =
          _optionalString(args, 'raw_directory') ??
          _optionalString(args, 'raw_dir');
      if (rawDirectory == null || rawDirectory.trim().isEmpty) {
        throw StateError('raw_directory 模式需要提供 raw_directory');
      }
      final resolved = _resolvePath(rawDirectory, cwd);
      final rawDir = Directory(resolved);
      if (!rawDir.existsSync()) {
        throw StateError('raw_directory 不存在：$resolved');
      }
      saved = await ExperienceStore(
        agentDir: dir,
      ).importRawDirectoryToPrivate(rawDir: rawDir);
    } else if (source == 'current_session') {
      final path = _optionalString(args, 'session_path') ?? sessionPath;
      if (path == null || path.trim().isEmpty) {
        throw StateError('当前工具缺少 session_path，无法从会话生成经验');
      }
      saved = await ExperienceSessionCapture.saveSessionAsPrivateExperience(
        agentDir: dir,
        sessionPath: path,
        title: title,
        brief: brief,
        keywords: keywords,
        // Model-triggered session capture must be complete; do not let the
        // model choose a partial message window.
        maxMessages: 0,
      );
    } else {
      throw StateError('未知 create_experience source：$source');
    }
    return {
      'ok': true,
      'experience_id': saved.experienceId,
      'scope': saved.scope.wireName,
      'path': saved.path,
      'content_path': saved.contentPath,
      'metadata_path': saved.metadataPath,
      'message': source == 'raw_directory'
          ? '已导入脱敏原始目录为本地私有经验。网络提审需要用户在设置页确认后执行。'
          : '已保存为本地私有经验。网络提审需要用户在设置页确认后执行。',
    };
  }

  static Map<String, dynamic> _createArtifact(
    Map<String, dynamic> args,
    String? cwd,
  ) {
    final type = _requiredString(args, 'type');
    final title = _requiredString(args, 'title');
    final content = _requiredString(args, 'content');
    final id =
        'artifact-${DateTime.now().millisecondsSinceEpoch}-${++_artifactCounter}';
    final language = _optionalString(args, 'language');
    final file = _writeArtifactFile(
      cwd: cwd,
      id: id,
      type: type,
      title: title,
      language: language,
      content: content,
    );
    return {
      'ok': true,
      'artifact': {
        'id': id,
        'type': type,
        'title': title,
        'language': language,
        'file_path': file.path,
        'size_bytes': file.lengthSync(),
      },
      'files': [_fileReference(file, label: title)],
      'message':
          '已创建 Artifact 并写入本地文件。最终回复请用 Markdown 链接引用 file_path，客户端会自动渲染文件卡片。',
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
    final sourcePath = _optionalString(args, 'source_path');
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

  static File _writeArtifactFile({
    required String? cwd,
    required String id,
    required String type,
    required String title,
    required String? language,
    required String content,
  }) {
    final dir = Directory(p.join(_defaultCwd(cwd), 'artifacts'))
      ..createSync(recursive: true);
    final extension = _artifactExtension(type, language);
    final baseName = _safeFileStem(title).isEmpty
        ? id
        : '${_safeFileStem(title)}-$id';
    final file = _uniqueFile(dir, '$baseName.$extension');
    file.writeAsStringSync(content, flush: true);
    return file;
  }

  static File _uniqueFile(Directory dir, String fileName) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
    final ext = dot <= 0 ? '' : fileName.substring(dot);
    var candidate = File(p.join(dir.path, fileName));
    var index = 2;
    while (candidate.existsSync()) {
      candidate = File(p.join(dir.path, '$stem-$index$ext'));
      index++;
    }
    return candidate;
  }

  static String _safeFileStem(String title) {
    final sanitized = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    if (sanitized.length <= 80) return sanitized;
    return sanitized.substring(0, 80);
  }

  static String _artifactExtension(String type, String? language) {
    final normalizedType = type.trim().toLowerCase();
    if (normalizedType == 'markdown') return 'md';
    if (normalizedType == 'html') return 'html';
    if (normalizedType != 'code') return 'txt';
    return switch (language?.trim().toLowerCase()) {
      'dart' => 'dart',
      'javascript' || 'js' => 'js',
      'typescript' || 'ts' => 'ts',
      'tsx' => 'tsx',
      'jsx' => 'jsx',
      'python' || 'py' => 'py',
      'go' || 'golang' => 'go',
      'rust' || 'rs' => 'rs',
      'json' => 'json',
      'yaml' || 'yml' => 'yaml',
      'shell' || 'bash' || 'sh' => 'sh',
      'powershell' || 'ps1' => 'ps1',
      'bat' || 'cmd' => 'bat',
      'css' => 'css',
      'scss' => 'scss',
      'sql' => 'sql',
      'markdown' || 'md' => 'md',
      _ => 'txt',
    };
  }

  static Map<String, dynamic> _fileReference(File file, {String? label}) {
    final stat = file.statSync();
    return {
      'path': file.path,
      'label': label?.trim().isNotEmpty == true
          ? label!.trim()
          : p.basename(file.path),
      'size_bytes': stat.size,
      'modified_at': stat.modified.toUtc().toIso8601String(),
      'mime_type': _mimeTypeForPath(file.path),
    };
  }

  static String _mimeTypeForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.html' || '.htm' => 'text/html',
      '.md' || '.markdown' => 'text/markdown',
      '.txt' || '.log' => 'text/plain',
      '.json' => 'application/json',
      '.yaml' || '.yml' => 'application/x-yaml',
      '.csv' => 'text/csv',
      '.pdf' => 'application/pdf',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.svg' => 'image/svg+xml',
      '.zip' => 'application/zip',
      '.7z' => 'application/x-7z-compressed',
      '.rar' => 'application/vnd.rar',
      '.mp3' => 'audio/mpeg',
      '.wav' => 'audio/wav',
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      _ => 'application/octet-stream',
    };
  }

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
    final raw = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? fallback;
    if (raw < min) return min;
    if (raw > max) return max;
    return raw;
  }

  static List<String> _jsonStringList(Object? value) {
    if (value is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final item in value) {
      final text = item.toString().trim();
      if (text.isEmpty || !seen.add(text)) continue;
      out.add(text);
    }
    return out;
  }

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

  static const searchMemory = 'search_memory';
  static const webSearch = 'web_search';
  static const webFetch = 'web_fetch';
  static const pinMemory = 'pin_memory';
  static const unpinMemory = 'unpin_memory';
  static const listPinnedMemory = 'list_pinned_memory';
  static const createExperience = 'create_experience';
  static const experienceSearch = 'experience_search';
  static const publishDemand = 'publish_demand';
  static const cron = 'cron';
  static const createArtifact = 'create_artifact';
  static const browser = 'browser';
  static const installSkill = 'install_skill';
  static const notify = 'notify';
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

final _knownToolNames = <String>{for (final spec in _toolSpecs) spec.name};

const _toolSpecs = <_ToolSpec>[
  _ToolSpec(
    name: LocalToolNames.searchMemory,
    description:
        '搜索当前 Agent 的本地记忆文件树（含 MEMORY.md 索引、topic 文件与 team 子目录），只返回路径、行号和片段。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'query': {'type': 'string'},
        'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 200},
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
    description:
        '搜索互联网获取实时信息。仅在需要当前事件、最新数据或外部信息时使用；回答时应附上来源链接。当前 Flutter 客户端需要配置搜索 provider 后才能执行。',
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
    description:
        '抓取指定 http/https URL 并提取可读文本。URL 必须完整有效；此工具只读，不修改文件；会阻止内网地址访问，结果过大时按 maxLength 截断。',
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
    name: LocalToolNames.createExperience,
    description:
        '把当前会话或 Agent 已通过文件编辑生成的原始目录保存为 PH01 本地私有经验，不会提交网络审核。经验本体必须来自会话截取或 raw_directory 文件树；AI 不得把完整经验正文作为工具参数传入。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'source': {
          'type': 'string',
          'enum': ['current_session', 'raw_directory'],
          'description':
              '默认 current_session；脱敏导入只能使用 raw_directory，且目录必须由 Agent 通过持续文件读写生成。',
        },
        'title': {'type': 'string'},
        'brief': {'type': 'string'},
        'keywords': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'raw_directory': {
          'type': 'string',
          'description':
              'raw_directory 模式必填。指向 Agent 在独立会话里写好的暂存目录，目录根部应包含 metadata.json、raw/conversation.md、raw/events.md、tool-calls/、attachments/。',
        },
        'session_path': {'type': 'string', 'description': '可选；默认使用当前会话路径。'},
      },
      'required': ['title'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.experienceSearch,
    description:
        '检索 PH01 经验包文件树，只返回经验 ID、文件路径、行号和短片段。读取全文或继续定位请使用 read_file/list_dir/search_text。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'query': {'type': 'string'},
        'scope': {
          'type': 'string',
          'enum': ['private', 'network', 'all'],
        },
        'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 200},
      },
      'required': ['query'],
    },
  ),
  _ToolSpec(
    name: LocalToolNames.publishDemand,
    description:
        '向经验网络发布需求。描述你需要什么类型的经验，网络中持有匹配经验的节点会自动响应并传输经验包。',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'query': {
          'type': 'string',
          'description': '自然语言需求描述，例如"如何用 Flutter 实现自定义 Paint"',
        },
        'keywords': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '可选的结构化关键词',
        },
      },
      'required': ['query'],
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
    name: LocalToolNames.createArtifact,
    description:
        '创建 HTML、代码或 Markdown 产物，并写入当前 Agent 工作目录下的 artifacts 文件夹；完成后返回本地文件路径，最终回复需用 Markdown 链接引用该路径。',
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
    name: LocalToolNames.browser,
    description:
        '控制浏览器打开网页、读取页面标题/文本和查看状态。用于需要真实页面状态、动态内容或轻量自动化的场景；已知 URL 的静态内容优先用 web_fetch。'
        '浏览器操作应聚焦具体任务；连续失败、页面无响应、加载超时或自动化变复杂时停止并向用户说明尝试过程。避免触发 alert/confirm/prompt 等会阻塞自动化的浏览器模态对话框。'
        '复杂交互会返回中文限制说明。',
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
];
