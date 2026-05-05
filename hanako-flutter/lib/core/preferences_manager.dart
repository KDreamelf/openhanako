import 'dart:convert';
import 'dart:io';

import '../shared/hana_home.dart';

/// PreferencesManager 与 legacy core/preferences-manager.js 对齐：
/// 全局 preferences.json 读写。
class PreferencesManager {
  PreferencesManager(this._home);
  final HanaHome _home;

  Map<String, dynamic>? _cache;

  Map<String, dynamic> _read() {
    if (_cache != null) return _cache!;
    final f = _home.preferencesFile;
    if (!f.existsSync()) {
      _cache = <String, dynamic>{};
      return _cache!;
    }
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map<String, dynamic>) {
        _cache = j;
      } else {
        _cache = <String, dynamic>{};
      }
    } catch (_) {
      _cache = <String, dynamic>{};
    }
    return _cache!;
  }

  void _write(Map<String, dynamic> data) {
    _cache = data;
    final f = _home.preferencesFile;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  Map<String, dynamic> getPreferences() => Map<String, dynamic>.of(_read());

  void savePreferences(Map<String, dynamic> prefs) => _write(prefs);

  String? getPrimaryAgent() => _read()['primaryAgent'] as String?;
  void savePrimaryAgent(String? agentId) {
    final p = Map<String, dynamic>.of(_read());
    if (agentId == null) {
      p.remove('primaryAgent');
    } else {
      p['primaryAgent'] = agentId;
    }
    _write(p);
  }

  bool getSandbox() => _read()['sandbox'] as bool? ?? false;
  void setSandbox(bool v) {
    final p = Map<String, dynamic>.of(_read());
    p['sandbox'] = v;
    _write(p);
  }

  String getThinkingLevel() =>
      _read()['thinking_level'] as String? ?? 'auto';
  void setThinkingLevel(String level) {
    final p = Map<String, dynamic>.of(_read());
    p['thinking_level'] = level;
    _write(p);
  }

  String getLocale() => _read()['locale'] as String? ?? Platform.localeName;
  void setLocale(String locale) {
    final p = Map<String, dynamic>.of(_read());
    p['locale'] = locale;
    _write(p);
  }

  String getTimezone() => _read()['timezone'] as String? ?? 'Asia/Shanghai';
  void setTimezone(String tz) {
    final p = Map<String, dynamic>.of(_read());
    p['timezone'] = tz;
    _write(p);
  }

  /// 任意 key 读写（UI 直接用）
  T? get<T>(String key) => _read()[key] as T?;
  void set(String key, dynamic value) {
    final p = Map<String, dynamic>.of(_read());
    if (value == null) {
      p.remove(key);
    } else {
      p[key] = value;
    }
    _write(p);
  }
}
