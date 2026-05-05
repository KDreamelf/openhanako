import 'dart:async';
import 'dart:io';

import '../shared/hana_home.dart';
import '../shared/yaml_io.dart';

/// 与 legacy core/config-coordinator.js 对齐。
/// 处理 agent config.yaml 的读写、热更新（FileSystemEvent watch）、
/// 共享模型选择、Plan Mode、Memory enabled 等开关。
class ConfigCoordinator {
  ConfigCoordinator(this._home, this._agentId);

  final HanaHome _home;
  String _agentId;

  StreamSubscription<FileSystemEvent>? _watcher;
  final _changeController = StreamController<Map<String, dynamic>>.broadcast();

  /// 配置变更广播（debounce 200ms 后触发）。
  Stream<Map<String, dynamic>> get onChanged => _changeController.stream;

  String get agentId => _agentId;

  void retarget(String agentId) {
    _agentId = agentId;
    _stopWatch();
    _startWatch();
  }

  Future<void> initialize() async {
    _startWatch();
  }

  Future<void> dispose() async {
    _stopWatch();
    await _changeController.close();
  }

  Map<String, dynamic> read() => YamlIo.readMap(_home.agentConfig(_agentId));

  /// 在指定 path 写入值（保留注释）。
  void writeAt(List<Object> path, Object? value) {
    YamlIo.writeAt(_home.agentConfig(_agentId), path, value);
  }

  void removeAt(List<Object> path) {
    YamlIo.removeAt(_home.agentConfig(_agentId), path);
  }

  /// 全量更新（合并到现有 config）。仅当字段命名简单时建议用。
  void updateConfig(Map<String, dynamic> partial) {
    partial.forEach((k, v) {
      writeAt([k], v);
    });
  }

  bool getMemoryEnabled() {
    final cfg = read();
    final mem = cfg['memory'] as Map?;
    return mem?['enabled'] as bool? ?? true;
  }

  void setMemoryEnabled(bool enabled) {
    writeAt(['memory', 'enabled'], enabled);
  }

  bool getPlanMode() => read()['plan_mode'] as bool? ?? false;
  void setPlanMode(bool enabled) => writeAt(['plan_mode'], enabled);

  /// 共享模型 4 项：utility / utility_large / summarizer / compiler
  Map<String, String?> getSharedModels() {
    final cfg = read();
    final models = (cfg['models'] as Map?) ?? const {};
    return {
      'utility': models['utility'] as String?,
      'utility_large': models['utility_large'] as String?,
      'summarizer': models['summarizer'] as String?,
      'compiler': models['compiler'] as String?,
    };
  }

  void setSharedModels(Map<String, String?> partial) {
    partial.forEach((k, v) {
      if (v == null) {
        removeAt(['models', k]);
      } else {
        writeAt(['models', k], v);
      }
    });
  }

  /// utility API（独立的 utility provider）
  Map<String, String?> getUtilityApi() {
    final cfg = read();
    final api = (cfg['utility_api'] as Map?) ?? const {};
    return {
      'provider': api['provider'] as String?,
      'base_url': api['base_url'] as String?,
      'api_key': api['api_key'] as String?,
    };
  }

  void setUtilityApi(Map<String, String?> partial) {
    partial.forEach((k, v) {
      if (v == null) {
        removeAt(['utility_api', k]);
      } else {
        writeAt(['utility_api', k], v);
      }
    });
  }

  // ---- watch ----
  Timer? _debounce;
  void _startWatch() {
    final f = _home.agentConfig(_agentId);
    if (!f.existsSync()) return;
    try {
      _watcher = f.parent.watch(events: FileSystemEvent.modify).listen((e) {
        if (e.path != f.path) return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 200), () {
          if (!_changeController.isClosed) {
            _changeController.add(read());
          }
        });
      });
    } catch (_) {
      // 某些平台 watch 不可用
    }
  }

  void _stopWatch() {
    _watcher?.cancel();
    _watcher = null;
    _debounce?.cancel();
    _debounce = null;
  }
}
