import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'preferences_manager.dart';

class BrowserManager {
  BrowserManager({required this.preferences, this.appDir});

  final PreferencesManager preferences;
  final String? appDir;

  Process? _connectorProcess;
  WebSocket? _ws;
  int _wsPort = 0;
  bool _running = false;
  String? _url;
  String? _title;
  String? _lastError;
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

  bool get isRunning => _running && _ws != null;

  BrowserStatus status() => BrowserStatus(
    enabled: enabled,
    running: _running,
    url: _url,
    title: _title,
    lastError: _lastError,
    actionLog: List<Map<String, dynamic>>.unmodifiable(_actionLog),
    camoufoxAvailable: _configPath != null,
    wsPort: _wsPort,
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
          return _ok('浏览器状态', extra: status().toJson());
        case 'start':
          await start();
          return _ok('浏览器已启动', extra: status().toJson());
        case 'stop':
          await stop();
          return _ok('浏览器已关闭', extra: status().toJson());
        case 'navigate':
          final url = args['url']?.toString().trim();
          if (url == null || url.isEmpty) {
            return _error('missing_url', 'navigate 需要 url 参数');
          }
          return _navigate(url);
        case 'snapshot':
          return _snapshot();
        case 'screenshot':
          return _screenshot();
        case 'click':
          return _click(args['ref']?.toString() ?? args['selector']?.toString() ?? '');
        case 'type':
          return _type(
            args['ref']?.toString() ?? args['selector']?.toString() ?? '',
            args['text']?.toString() ?? '',
          );
        case 'evaluate':
          return _evaluate(args['expression']?.toString());
        case 'wait':
          final timeoutMs = _boundedInt(args['timeout'], 2000, 100, 30000);
          final state = args['state']?.toString();
          if (state == 'networkidle' || state == 'load') {
            await _sendCommand('waitForLoadState', {'state': state, 'timeout': timeoutMs});
          } else {
            await Future<void>.delayed(Duration(milliseconds: timeoutMs));
          }
          return _ok('等待完成', extra: status().toJson());
        case 'show':
          return _ok('浏览器状态', extra: status().toJson());
        default:
          return _error('unknown_action', '未知浏览器操作：$action');
      }
    } catch (e) {
      _lastError = e.toString();
      _log(action, args, null, e.toString());
      return _error('browser_failed', '浏览器操作失败：$e');
    }
  }

  // ---- Camoufox connector 进程管理 ----

  Future<void> start() async {
    if (_running && _ws != null) return;

    final config = _loadConfig();
    if (config == null) {
      // Camoufox 未安装，fallback 到静态 HTTP 模式
      _running = true;
      _lastError = null;
      return;
    }

    final python = config['venvPython'] as String? ?? '';
    final module = config['connectorModule'] as String? ?? 'camoufox_connector';
    final dataDir = config['browserDataDir'] as String? ?? '';
    final headless = config['headless'] as String? ?? 'virtual';
    _wsPort = await _findAvailablePort();

    final env = <String, String>{
      if (dataDir.isNotEmpty) 'CAMOUFOX_DATA_DIR': dataDir,
    };

    _connectorProcess = await Process.start(
      python,
      ['-m', module, '--port', '$_wsPort', '--headless', headless],
      environment: env,
      mode: ProcessStartMode.detachedWithStdio,
    );

    _connectorProcess!.exitCode.then((_) {
      _running = false;
      _ws = null;
      _connectorProcess = null;
    });

    // 等待 WS 就绪
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      try {
        _ws = await WebSocket.connect('ws://localhost:$_wsPort')
            .timeout(const Duration(seconds: 2));
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    if (_ws == null) {
      await _killConnector();
      throw StateError('Camoufox connector 启动超时（30s）');
    }

    _ws!.listen(
      (data) {
        if (data is String) _handleWsMessage(data);
      },
      onDone: () {
        _ws = null;
        _running = false;
      },
    );

    _running = true;
    _lastError = null;
  }

  Future<void> stop() async {
    _url = null;
    _title = null;
    _lastError = null;
    _pendingCommands.clear();
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
    await _killConnector();
    _running = false;
    _actionLog.clear();
  }

  Future<void> _killConnector() async {
    final proc = _connectorProcess;
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
    _connectorProcess = null;
  }

  // ---- WebSocket 命令 ----

  Future<Map<String, dynamic>> _sendCommand(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_ws == null) {
      throw StateError('浏览器未连接');
    }
    final id = ++_cmdId;
    final completer = Completer<Map<String, dynamic>>();
    _pendingCommands[id] = completer;
    _ws!.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingCommands.remove(id);
        throw TimeoutException('浏览器命令超时：$method');
      },
    );
  }

  void _handleWsMessage(String data) {
    try {
      final json = jsonDecode(data);
      if (json is Map<String, dynamic>) {
        final id = json['id'];
        if (id is int) {
          final completer = _pendingCommands.remove(id);
          completer?.complete(json);
        }
      }
    } catch (_) {}
  }

  // ---- 具体操作 ----

  Future<Map<String, dynamic>> _navigate(String url) async {
    if (_ws != null) {
      await _sendCommand('goto', {'url': url});
      final titleResult = await _sendCommand('evaluate', {'expression': 'document.title'});
      _url = url;
      _title = titleResult['result']?.toString();
      _log('navigate', {'url': url}, _title);
      return _ok('已打开页面：${_title ?? url}', extra: status().toJson());
    }
    // Fallback: 静态 HTTP
    final page = await _fetchPageStatic(url);
    _running = true;
    _url = page.url;
    _title = page.title;
    _log('navigate', {'url': url}, page.title ?? page.url);
    return _ok(
      '已打开页面：${page.title ?? page.url}（静态模式，无 Camoufox）',
      extra: status().toJson(),
    );
  }

  Future<Map<String, dynamic>> _snapshot() async {
    if (_ws != null) {
      final result = await _sendCommand('evaluate', {
        'expression': 'document.body.innerText',
      });
      final text = result['result']?.toString() ?? '';
      return _ok(text.isEmpty ? '页面无可读文本' : text, extra: status().toJson());
    }
    return _error('browser_not_running', '浏览器未打开页面');
  }

  Future<Map<String, dynamic>> _screenshot() async {
    if (_ws != null) {
      final result = await _sendCommand('screenshot', {});
      final base64 = result['result']?.toString();
      if (base64 != null && base64.isNotEmpty) {
        return _ok('截图完成', extra: {'screenshot': base64, ...status().toJson()});
      }
    }
    return _error('screenshot_failed', '截图失败');
  }

  Future<Map<String, dynamic>> _click(String selector) async {
    if (_ws == null) return _error('browser_not_running', '浏览器未连接');
    await _sendCommand('click', {'selector': selector});
    _log('click', {'selector': selector}, 'done');
    return _ok('点击完成', extra: status().toJson());
  }

  Future<Map<String, dynamic>> _type(String selector, String text) async {
    if (_ws == null) return _error('browser_not_running', '浏览器未连接');
    await _sendCommand('fill', {'selector': selector, 'value': text});
    _log('type', {'selector': selector, 'text': text}, 'done');
    return _ok('输入完成', extra: status().toJson());
  }

  Future<Map<String, dynamic>> _evaluate(String? expression) async {
    final expr = expression?.trim();
    if (expr == null || expr.isEmpty) {
      return _error('missing_expression', 'evaluate 需要 expression 参数');
    }
    if (_ws != null) {
      final result = await _sendCommand('evaluate', {'expression': expr});
      return _ok(result['result']?.toString() ?? '', extra: status().toJson());
    }
    // Fallback 静态模式
    final value = switch (expr) {
      'document.title' => _title ?? '',
      'location.href' || 'window.location.href' => _url ?? '',
      _ => null,
    };
    if (value == null) {
      return _error('unsupported_expression', '静态模式仅支持 document.title 和 location.href');
    }
    return _ok(value, extra: status().toJson());
  }

  // ---- config ----

  String? get _configPath {
    final dir = appDir;
    if (dir == null) return null;
    final path = '$dir${Platform.pathSeparator}browser${Platform.pathSeparator}config.json';
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

  Future<int> _findAvailablePort() async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    } catch (_) {
      return 9222 + DateTime.now().millisecond % 1000;
    }
  }

  // ---- 静态 HTTP fallback ----

  Future<_FetchedPage> _fetchPageStatic(String input) async {
    final uri = Uri.parse(input);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw StateError('浏览器只允许打开 http/https URL');
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.userAgentHeader, 'HanakoFlutter/1.0');
      final response = await request.close().timeout(const Duration(seconds: 20));
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
      );
    } finally {
      client.close(force: true);
    }
  }

  // ---- logging / helpers ----

  void _log(String action, Map<String, dynamic> params, String? result, [String? error]) {
    final entry = <String, dynamic>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'action': action,
      'params': params,
    };
    if (result != null) entry['result'] = result;
    if (error != null) entry['error'] = error;
    if (_url != null) entry['url'] = _url;
    _actionLog.add(entry);
    if (_actionLog.length > 30) _actionLog.removeRange(0, _actionLog.length - 30);
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
    this.url,
    this.title,
    this.lastError,
    this.actionLog = const [],
    this.camoufoxAvailable = false,
    this.wsPort = 0,
  });

  final bool enabled;
  final bool running;
  final String? url;
  final String? title;
  final String? lastError;
  final List<Map<String, dynamic>> actionLog;
  final bool camoufoxAvailable;
  final int wsPort;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'running': running,
    'camoufoxAvailable': camoufoxAvailable,
    if (url != null) 'url': url,
    if (title != null) 'title': title,
    if (lastError != null) 'lastError': lastError,
    if (wsPort > 0) 'wsPort': wsPort,
    'actions': actionLog,
  };
}

class _FetchedPage {
  const _FetchedPage({required this.url, this.title});
  final String url;
  final String? title;
}

int _boundedInt(Object? raw, int fallback, int min, int max) {
  final parsed = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}

String? _extractTitle(String html) {
  final match = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html);
  final title = match?.group(1);
  if (title == null) return null;
  final clean = _decodeHtml(title).replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.isEmpty ? null : clean;
}

String _decodeHtml(String text) => text
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
