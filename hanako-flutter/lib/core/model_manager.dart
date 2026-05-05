import 'dart:async';
import 'dart:convert';

import '../shared/hana_home.dart';

/// AI 网关授权模型目录。
///
/// 子体不再维护供应商、API Key、OAuth 或 Codex 登录配置。
/// 可选模型完全来自 AI 网关在密钥协商后返回的授权模型列表。
class ModelManager {
  ModelManager(this._home);

  final HanaHome _home;

  ModelInfo? _currentModel;
  List<ModelInfo> _availableModels = const [];

  ModelInfo? get currentModel => _currentModel;
  String? get currentModelId => _currentModel?.id;
  List<ModelInfo> get availableModels => List.unmodifiable(_availableModels);

  Future<void> initialize() async {
    await _loadCache();
  }

  Future<void> replaceAvailableModels(
    Iterable<String> ids, {
    String? preferredModelId,
  }) async {
    final unique = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      unique.add(id);
    }

    _availableModels = [for (final id in unique) ModelInfo(id: id, name: id)];

    final preferred = preferredModelId?.trim();
    final current = _currentModel?.id;
    final nextId = _containsId(preferred)
        ? preferred
        : _containsId(current)
        ? current
        : unique.isNotEmpty
        ? unique.first
        : null;
    _currentModel = nextId == null ? null : ModelInfo(id: nextId, name: nextId);
    await _saveCache();
  }

  Future<void> selectModel(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return;
    if (!_containsId(id)) {
      throw ArgumentError.value(modelId, 'modelId', '模型不在网关授权列表中');
    }
    _currentModel = ModelInfo(id: id, name: id);
    await _saveCache();
  }

  bool contains(String modelId) => _containsId(modelId.trim());

  void setCurrentModel(ModelInfo model) {
    _currentModel = model;
    unawaited(_saveCache());
  }

  bool _containsId(String? id) {
    if (id == null || id.isEmpty) return false;
    return _availableModels.any((m) => m.id == id);
  }

  Future<void> _loadCache() async {
    final file = _home.modelsJson;
    if (!file.existsSync()) return;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return;
      final models =
          (raw['models'] as List?)
              ?.whereType<String>()
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toList() ??
          const <String>[];
      final current = (raw['current_model'] as String?)?.trim();
      await replaceAvailableModels(models, preferredModelId: current);
    } catch (_) {
      _availableModels = const [];
      _currentModel = null;
    }
  }

  Future<void> _saveCache() async {
    final file = _home.modelsJson;
    file.parent.createSync(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'current_model': _currentModel?.id,
        'models': [for (final model in _availableModels) model.id],
      }),
      flush: true,
    );
  }
}

class ModelInfo {
  const ModelInfo({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}
