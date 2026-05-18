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

  // ===== exec_command 默认超时 =====
  //
  // 模型在调 exec_command 时可以显式传 timeout_ms 覆盖。如果模型没传，
  // 后端用本设置作为兜底，避免命令无限挂死。
  static const int defaultExecCommandTimeoutSeconds = 300;
  static const int execCommandTimeoutMinSeconds = 5;
  static const int execCommandTimeoutMaxSeconds = 600;

  int getExecCommandDefaultTimeoutSeconds() {
    final codex = _read()['codex'];
    if (codex is Map) {
      final raw = codex['exec_command_default_timeout_seconds'];
      if (raw is num) {
        return raw.toInt().clamp(
          execCommandTimeoutMinSeconds,
          execCommandTimeoutMaxSeconds,
        );
      }
    }
    return defaultExecCommandTimeoutSeconds;
  }

  void setExecCommandDefaultTimeoutSeconds(int seconds) {
    final clamped = seconds.clamp(
      execCommandTimeoutMinSeconds,
      execCommandTimeoutMaxSeconds,
    );
    final p = Map<String, dynamic>.of(_read());
    final codex = p['codex'] is Map
        ? Map<String, dynamic>.of((p['codex'] as Map).cast<String, dynamic>())
        : <String, dynamic>{};
    codex['exec_command_default_timeout_seconds'] = clamped;
    p['codex'] = codex;
    _write(p);
  }

  // ===== 记忆系统配置 =====
  //
  // 记忆系统走 Claude Code 风格（离散 .md + MEMORY.md 索引）。模型在主对话
  // 中保存 / 读取记忆是核心路径；下面这些设置控制**辅助**链路：
  //   - findRelevantMemories（每轮 recall 时按 description 语义筛选 ≤N 条）
  //   - extractMemories（turn 结束时背景抽取候选记忆）
  // 这两条都需要额外 LLM 调用，因此允许独立配置使用的模型。

  /// 用于 findRelevantMemories / extractMemories 等辅助 LLM 调用的模型 ID。
  /// 未设置时返回 null，调用方应 fallback 到主对话模型。
  String? getMemoryAuxModel() {
    final memory = _read()['memory'];
    if (memory is Map) {
      final raw = memory['aux_model'];
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    }
    return null;
  }

  void setMemoryAuxModel(String? model) {
    final p = Map<String, dynamic>.of(_read());
    final memory = p['memory'] is Map
        ? Map<String, dynamic>.of(
            (p['memory'] as Map).cast<String, dynamic>(),
          )
        : <String, dynamic>{};
    final clean = model?.trim();
    if (clean == null || clean.isEmpty) {
      memory.remove('aux_model');
    } else {
      memory['aux_model'] = clean;
    }
    if (memory.isEmpty) {
      p.remove('memory');
    } else {
      p['memory'] = memory;
    }
    _write(p);
  }
}
