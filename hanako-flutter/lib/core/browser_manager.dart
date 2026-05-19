import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'preferences_manager.dart';

class BrowserManager {
  BrowserManager({required this.preferences, this.appDir});

  final PreferencesManager preferences;
  final String? appDir;

  Process? _bridgeProcess;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _running = false;
  bool _realBrowserReady = false;
  bool _staticMode = false;
  String? _url;
  String? _title;
  String? _staticText;
  String? _lastError;
  String _bridgeStderr = '';
  final List<Map<String, dynamic>> _actionLog = <Map<String, dynamic>>[];
  int _cmdId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pendingCommands = {};

  bool get enabled {
    final cfg = preferences.get<Map>('browser');
    return cfg?['enabled'] as bool? ?? true;
  }

  void setEnabled(bool value) {
    final prefs = preferences.getPreferences();
    final raw = prefs['browser'];
    final cfg = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
    cfg['enabled'] = value;
    prefs['browser'] = cfg;
    preferences.savePreferences(prefs);
  }

  bool get isRunning => _running && _realBrowserReady;

  BrowserStatus status() => BrowserStatus(
    enabled: enabled,
    running: _running,
    realBrowser: _realBrowserReady,
    mode: _realBrowserReady
        ? 'camoufox'
        : _staticMode
        ? 'static'
        : 'stopped',
    url: _url,
    title: _title,
    lastError: _lastError,
    actionLog: List<Map<String, dynamic>>.unmodifiable(_actionLog),
    camoufoxAvailable: _configPath != null,
    bridgeStderr: _bridgeStderr.isEmpty ? null : _bridgeStderr,
  );

  Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final action = args['action']?.toString().trim();
    if (action == null || action.isEmpty) {
      return _error('missing_action', 'browser 需要 action 参数');
    }
    if (!enabled && action != 'status') {
      return _error('browser_disabled', '浏览器工具已在设置中关闭。');
    }
    try {
      switch (action) {
        case 'status':
        case 'show':
          return _ok('浏览器状态', extra: status().toJson());
        case 'start':
          await start();
          return _ok(
            _realBrowserReady ? 'Camoufox 浏览器已启动' : '静态浏览模式已启用',
            extra: status().toJson(),
          );
        case 'stop':
          await stop();
          return _ok('浏览器已关闭', extra: status().toJson());
        case 'navigate':
          final url = args['url']?.toString().trim();
          if (url == null || url.isEmpty) {
            return _error('missing_url', 'navigate 需要 url 参数');
          }
          return await _navigate(url, args);
        case 'snapshot':
          return await _snapshot();
        case 'screenshot':
          return await _realAction('screenshot', args, successMessage: '截图完成');
        case 'click':
          return await _realAction(
            'click',
            _withSelector(args),
            successMessage: '点击完成',
          );
        case 'type':
          return await _realAction(
            'type',
            _withSelector(args),
            successMessage: '输入完成',
          );
        case 'select':
          return await _realAction(
            'select',
            _withSelector(args),
            successMessage: '选择完成',
          );
        case 'key':
          return await _realAction('key', args, successMessage: '按键完成');
        case 'scroll':
          return await _realAction('scroll', args, successMessage: '滚动完成');
        case 'evaluate':
          return await _evaluate(args['expression']?.toString());
        case 'wait':
          return await _wait(args);
        default:
          return _error('unknown_action', '未知浏览器操作：$action');
      }
    } catch (e) {
      _lastError = e.toString();
      _log(action, args, null, e.toString());
      return _error('browser_failed', '浏览器操作失败：$e');
    }
  }

  Future<void> start() async {
    if (_realBrowserReady) return;

    final configPath = _configPath;
    if (configPath == null) {
      _staticMode = true;
      _running = true;
      _lastError = null;
      return;
    }
    final config = _loadConfig();
    if (config == null) {
      throw StateError('Camoufox 配置文件无效：$configPath');
    }

    await _startBridge(config);
  }

  Future<void> stop() async {
    _url = null;
    _title = null;
    _staticText = null;
    _staticMode = false;
    _lastError = null;
    _actionLog.clear();
    try {
      if (_realBrowserReady && _bridgeProcess != null) {
        await _sendBridgeCommand(
          'stop',
          const <String, dynamic>{},
        ).timeout(const Duration(seconds: 5));
      }
    } catch (_) {}
    await _killBridge();
    _running = false;
    _realBrowserReady = false;
  }

  Future<void> _startBridge(Map<String, dynamic> config) async {
    final configPath = _configPath;
    if (configPath == null) {
      throw StateError('Camoufox 配置文件不存在');
    }

    final python = (config['venvPython'] as String?)?.trim() ?? '';
    final bridgeScript = _resolveBridgeScript(config);
    if (python.isEmpty ||
        (_looksLikePath(python) && !File(python).existsSync())) {
      throw StateError('Camoufox Python 运行时不存在：$python');
    }
    if (bridgeScript.isEmpty || !File(bridgeScript).existsSync()) {
      throw StateError('Hanako 浏览器桥脚本不存在：$bridgeScript');
    }

    await _killBridge();
    _bridgeStderr = '';
    _bridgeProcess = await Process.start(
      python,
      <String>[bridgeScript, configPath],
      environment: <String, String>{'PYTHONUTF8': '1', 'PYTHONUNBUFFERED': '1'},
    );

    _stdoutSub = _bridgeProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleBridgeLine);
    _stderrSub = _bridgeProcess!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleBridgeStderr);
    unawaited(
      _bridgeProcess!.exitCode.then((code) {
        _realBrowserReady = false;
        _running = false;
        _completePendingWithError('浏览器桥进程已退出，exitCode=$code');
        _bridgeProcess = null;
      }),
    );

    final result = await _sendBridgeCommand('start', const <String, dynamic>{});
    if (result['ok'] != true) {
      await _killBridge();
      throw StateError(result['message']?.toString() ?? 'Camoufox 浏览器启动失败');
    }
    _staticMode = false;
    _realBrowserReady = true;
    _running = true;
    _lastError = null;
    _updatePageState(result);
  }

  Future<void> _killBridge() async {
    _completePendingWithError('浏览器桥进程已关闭');
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    final proc = _bridgeProcess;
    _bridgeProcess = null;
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _navigate(
    String url,
    Map<String, dynamic> args,
  ) async {
    _validateHttpUrl(url);
    if (_configPath != null) {
      await start();
      final result = await _sendBridgeCommand('navigate', {
        ...args,
        'url': url,
      });
      return _bridgeResult('navigate', {'url': url}, result);
    }

    final page = await _fetchPageStatic(url);
    _running = true;
    _staticMode = true;
    _url = page.url;
    _title = page.title;
    _staticText = page.text;
    _log('navigate', {'url': url}, page.title ?? page.url);
    return _ok(
      '已打开页面：${page.title ?? page.url}（静态模式，无 Camoufox）',
      extra: status().toJson(),
    );
  }

  Future<Map<String, dynamic>> _snapshot() async {
    if (_realBrowserReady) {
      final result = await _sendBridgeCommand(
        'snapshot',
        const <String, dynamic>{},
      );
      return _bridgeResult('snapshot', const <String, dynamic>{}, result);
    }
    final text = _staticText;
    if (_staticMode && text != null) {
      return _ok(text.isEmpty ? '页面无可读文本' : text, extra: status().toJson());
    }
    return _error('browser_not_running', '浏览器未打开页面');
  }

  Future<Map<String, dynamic>> _evaluate(String? expression) async {
    final expr = expression?.trim();
    if (expr == null || expr.isEmpty) {
      return _error('missing_expression', 'evaluate 需要 expression 参数');
    }
    if (_realBrowserReady || _configPath != null) {
      await start();
      final result = await _sendBridgeCommand('evaluate', {'expression': expr});
      return _bridgeResult('evaluate', {'expression': expr}, result);
    }

    final value = switch (expr) {
      'document.title' => _title ?? '',
      'location.href' || 'window.location.href' => _url ?? '',
      'document.body.innerText' => _staticText ?? '',
      _ => null,
    };
    if (value == null) {
      return _error('unsupported_expression', '静态模式仅支持标题、URL 和正文读取');
    }
    return _ok(value, extra: status().toJson());
  }

  Future<Map<String, dynamic>> _wait(Map<String, dynamic> args) async {
    if (_realBrowserReady || _configPath != null) {
      await start();
      final result = await _sendBridgeCommand('wait', args);
      return _bridgeResult('wait', args, result);
    }
    final timeoutMs = _boundedInt(args['timeout'], 2000, 100, 30000);
    await Future<void>.delayed(Duration(milliseconds: timeoutMs));
    return _ok('等待完成', extra: status().toJson());
  }

  Future<Map<String, dynamic>> _realAction(
    String action,
    Map<String, dynamic> args, {
    required String successMessage,
  }) async {
    if (_configPath == null && !_realBrowserReady) {
      return _error('camoufox_not_available', '$action 需要 Camoufox 浏览器环境。');
    }
    await start();
    final result = await _sendBridgeCommand(action, args);
    return _bridgeResult(action, args, result, fallbackMessage: successMessage);
  }

  Future<Map<String, dynamic>> _sendBridgeCommand(
    String action,
    Map<String, dynamic> params,
  ) async {
    final proc = _bridgeProcess;
    if (proc == null) {
      throw StateError('浏览器桥进程未启动');
    }
    final id = ++_cmdId;
    final completer = Completer<Map<String, dynamic>>();
    _pendingCommands[id] = completer;
    try {
      proc.stdin.writeln(jsonEncode({'id': id, 'action': action, ...params}));
    } catch (e) {
      _pendingCommands.remove(id);
      throw StateError('浏览器桥命令发送失败：$e');
    }
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _pendingCommands.remove(id);
        throw TimeoutException('浏览器命令超时：$action');
      },
    );
  }

  void _handleBridgeLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      final id = decoded['id'];
      if (id is! num) return;
      final completer = _pendingCommands.remove(id.toInt());
      if (completer != null && !completer.isCompleted) {
        completer.complete(decoded);
      }
    } catch (_) {}
  }

  void _handleBridgeStderr(String line) {
    if (line.trim().isEmpty) return;
    final combined = _bridgeStderr.isEmpty ? line : '$_bridgeStderr\n$line';
    _bridgeStderr = combined.length > 3000
        ? combined.substring(combined.length - 3000)
        : combined;
  }

  void _completePendingWithError(String message) {
    final pending = Map<int, Completer<Map<String, dynamic>>>.from(
      _pendingCommands,
    );
    _pendingCommands.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.complete({
          'ok': false,
          'error': 'bridge_closed',
          'message': message,
        });
      }
    }
  }

  Map<String, dynamic> _bridgeResult(
    String action,
    Map<String, dynamic> params,
    Map<String, dynamic> result, {
    String? fallbackMessage,
  }) {
    if (result['ok'] == true) {
      _updatePageState(result);
      _log(action, params, result['message']?.toString());
      final message = result['message']?.toString() ?? '';
      return {
        ...result,
        if (message.isEmpty) 'message': fallbackMessage ?? '浏览器操作完成',
        'status': status().toJson(),
      };
    }
    final message = result['message']?.toString() ?? '浏览器操作失败';
    _lastError = message;
    _log(action, params, null, message);
    return {
      'ok': false,
      'error': result['error']?.toString() ?? 'browser_failed',
      'message': message,
      'status': status().toJson(),
    };
  }

  void _updatePageState(Map<String, dynamic> result) {
    final url = result['url']?.toString();
    final title = result['title']?.toString();
    if (url != null && url.isNotEmpty) _url = url;
    if (title != null) _title = title.isEmpty ? null : title;
  }

  String? get _configPath {
    final dir = appDir;
    if (dir == null) return null;
    final path =
        '$dir${Platform.pathSeparator}browser${Platform.pathSeparator}config.json';
    return File(path).existsSync() ? path : null;
  }

  Map<String, dynamic>? _loadConfig() {
    final path = _configPath;
    if (path == null) return null;
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      if (json is Map<String, dynamic>) return json;
    } catch (_) {}
    return null;
  }

  String _resolveBridgeScript(Map<String, dynamic> config) {
    final configured = (config['bridgeScript'] as String?)?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    final dir = appDir;
    if (dir == null) return '';
    return '$dir${Platform.pathSeparator}browser${Platform.pathSeparator}hanako_browser_bridge.py';
  }

  Future<_FetchedPage> _fetchPageStatic(String input) async {
    final uri = _validateHttpUrl(input);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.userAgentHeader, 'HanakoFlutter/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = await response
          .fold<List<int>>(<int>[], (prev, chunk) => prev..addAll(chunk))
          .timeout(const Duration(seconds: 20));
      final charset = response.headers.contentType?.charset?.toLowerCase();
      final html = charset == 'latin1'
          ? latin1.decode(bytes, allowInvalid: true)
          : utf8.decode(bytes, allowMalformed: true);
      final finalUrl = response.redirects.isNotEmpty
          ? response.redirects.last.location.toString()
          : uri.toString();
      return _FetchedPage(
        url: finalUrl,
        title: _extractTitle(html),
        text: _htmlToText(html),
      );
    } finally {
      client.close(force: true);
    }
  }

  void _log(
    String action,
    Map<String, dynamic> params,
    String? result, [
    String? error,
  ]) {
    final entry = <String, dynamic>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'action': action,
      'params': params,
    };
    if (result != null) entry['result'] = result;
    if (error != null) entry['error'] = error;
    if (_url != null) entry['url'] = _url;
    _actionLog.add(entry);
    if (_actionLog.length > 30) {
      _actionLog.removeRange(0, _actionLog.length - 30);
    }
  }

  Map<String, dynamic> _ok(String message, {Map<String, dynamic>? extra}) => {
    'ok': true,
    'message': message,
    if (extra != null) ...extra,
  };

  Map<String, dynamic> _error(String code, String message) => {
    'ok': false,
    'error': code,
    'message': message,
    'status': status().toJson(),
  };
}

class BrowserStatus {
  const BrowserStatus({
    required this.enabled,
    required this.running,
    required this.realBrowser,
    required this.mode,
    this.url,
    this.title,
    this.lastError,
    this.actionLog = const [],
    this.camoufoxAvailable = false,
    this.bridgeStderr,
  });

  final bool enabled;
  final bool running;
  final bool realBrowser;
  final String mode;
  final String? url;
  final String? title;
  final String? lastError;
  final List<Map<String, dynamic>> actionLog;
  final bool camoufoxAvailable;
  final String? bridgeStderr;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'running': running,
    'realBrowser': realBrowser,
    'mode': mode,
    'camoufoxAvailable': camoufoxAvailable,
    if (url != null) 'url': url,
    if (title != null) 'title': title,
    if (lastError != null) 'lastError': lastError,
    if (bridgeStderr != null) 'bridgeStderr': bridgeStderr,
    'actions': actionLog,
  };
}

class _FetchedPage {
  const _FetchedPage({required this.url, this.title, required this.text});
  final String url;
  final String? title;
  final String text;
}

Map<String, dynamic> _withSelector(Map<String, dynamic> args) {
  final selector = args['selector'] ?? args['ref'];
  return {...args, if (selector != null) 'selector': selector.toString()};
}

bool _looksLikePath(String value) {
  return value.contains('/') || value.contains(r'\') || value.contains(':');
}

Uri _validateHttpUrl(String input) {
  final uri = Uri.parse(input);
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw StateError('浏览器只允许打开 http/https URL');
  }
  return uri;
}

int _boundedInt(Object? raw, int fallback, int min, int max) {
  final parsed = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}

String? _extractTitle(String html) {
  final match = RegExp(
    r'<title[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  final title = match?.group(1);
  if (title == null) return null;
  final clean = _decodeHtml(title).replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.isEmpty ? null : clean;
}

String _htmlToText(String html) {
  final withoutScripts = html
      .replaceAll(
        RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
        ' ',
      );
  final bodyMatch = RegExp(
    r'<body[^>]*>([\s\S]*?)</body>',
    caseSensitive: false,
  ).firstMatch(withoutScripts);
  final body = bodyMatch?.group(1) ?? withoutScripts;
  return _decodeHtml(
    body.replaceAll(RegExp(r'<[^>]+>'), ' '),
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _decodeHtml(String text) => text
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
