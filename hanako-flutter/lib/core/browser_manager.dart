import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'preferences_manager.dart';

class BrowserManager {
  BrowserManager({required this.preferences});

  final PreferencesManager preferences;

  bool _running = false;
  String? _url;
  String? _title;
  String? _snapshot;
  String? _lastError;
  final List<Map<String, dynamic>> _actionLog = <Map<String, dynamic>>[];

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

  BrowserStatus status() => BrowserStatus(
    enabled: enabled,
    running: _running,
    url: _url,
    title: _title,
    snapshot: _snapshot,
    lastError: _lastError,
    actionLog: List<Map<String, dynamic>>.unmodifiable(_actionLog),
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
          _running = true;
          _lastError = null;
          _log(action, const {}, 'started');
          return _ok('浏览器已启动', extra: status().toJson());
        case 'stop':
          final log = List<Map<String, dynamic>>.of(_actionLog);
          _running = false;
          _url = null;
          _title = null;
          _snapshot = null;
          _lastError = null;
          _actionLog.clear();
          return _ok(
            '浏览器已关闭',
            extra: {'status': status().toJson(), 'actionLog': log},
          );
        case 'navigate':
          final url = args['url']?.toString().trim();
          if (url == null || url.isEmpty) {
            return _error('missing_url', 'navigate 需要 url 参数');
          }
          final page = await _fetchPage(url);
          _running = true;
          _url = page.url;
          _title = page.title;
          _snapshot = page.snapshot;
          _lastError = null;
          _log(action, {'url': url}, page.title ?? page.url);
          return _ok(
            '已打开页面：${page.title ?? page.url}',
            extra: {
              ...status().toJson(),
              'title': page.title,
              'snapshot': page.snapshot,
            },
          );
        case 'snapshot':
          if (!_running || _url == null) {
            return _error('browser_not_running', '浏览器未打开页面。');
          }
          return _ok(
            _snapshot?.isNotEmpty == true ? _snapshot! : '当前页面没有可读文本。',
            extra: status().toJson(),
          );
        case 'evaluate':
          return _evaluate(args['expression']?.toString());
        case 'wait':
          final timeoutMs = _boundedInt(args['timeout'], 500, 0, 5000);
          await Future<void>.delayed(Duration(milliseconds: timeoutMs));
          return _ok('等待完成', extra: status().toJson());
        case 'show':
          return _ok('浏览器状态已置前显示', extra: status().toJson());
        case 'screenshot':
          return _error(
            'browser_screenshot_unavailable',
            '当前 Flutter Browser 工具尚未接入截图后端；请先使用 snapshot 获取页面标题和文本。',
          );
        case 'click':
        case 'type':
        case 'scroll':
        case 'select':
        case 'key':
          return _error(
            'browser_interaction_unavailable',
            '当前 Flutter Browser 工具暂只支持 start、stop、navigate、snapshot、evaluate、wait 和 show。',
          );
        default:
          return _error('unknown_action', '未知浏览器操作：$action');
      }
    } catch (e) {
      _lastError = e.toString();
      _log(action, args, null, e.toString());
      return _error('browser_failed', '浏览器操作失败：$e');
    }
  }

  Future<_FetchedPage> _fetchPage(String input) async {
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
        snapshot: _htmlToText(html),
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _evaluate(String? expression) {
    final expr = expression?.trim();
    if (expr == null || expr.isEmpty) {
      return _error('missing_expression', 'evaluate 需要 expression 参数');
    }
    final value = switch (expr) {
      'document.title' => _title ?? '',
      'location.href' || 'window.location.href' => _url ?? '',
      'document.body.innerText' => _snapshot ?? '',
      _ => null,
    };
    if (value == null) {
      return _error(
        'unsupported_expression',
        '当前仅支持 document.title、location.href 和 document.body.innerText。',
      );
    }
    return _ok(value, extra: status().toJson());
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
    final url = _url;
    if (url != null) entry['url'] = url;
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
    this.url,
    this.title,
    this.snapshot,
    this.lastError,
    this.actionLog = const [],
  });

  final bool enabled;
  final bool running;
  final String? url;
  final String? title;
  final String? snapshot;
  final String? lastError;
  final List<Map<String, dynamic>> actionLog;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'running': running,
    if (url != null) 'url': url,
    if (title != null) 'title': title,
    if (snapshot != null) 'snapshot': snapshot,
    if (lastError != null) 'lastError': lastError,
    'actions': actionLog,
  };
}

class _FetchedPage {
  const _FetchedPage({required this.url, this.title, required this.snapshot});

  final String url;
  final String? title;
  final String snapshot;
}

int _boundedInt(Object? raw, int fallback, int min, int max) {
  final parsed = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
  if (parsed == null) return fallback;
  if (parsed < min) return min;
  if (parsed > max) return max;
  return parsed;
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
  var text = html.replaceAll(
    RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
    '',
  );
  text = text.replaceAll(
    RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
    '',
  );
  text = text.replaceAll(
    RegExp(
      r'</?(p|div|br|h[1-6]|li|tr|blockquote|section|article|header|footer)[^>]*>',
      caseSensitive: false,
    ),
    '\n',
  );
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = _decodeHtml(text);
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  final lines = text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(120)
      .toList(growable: false);
  return lines.join('\n');
}

String _decodeHtml(String text) => text
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
