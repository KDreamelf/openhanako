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

    _availableModels = [
      for (final id in unique)
        ModelInfo(
          id: id,
          name: id,
          contextWindow: _knownContextWindow(id),
          maxOutputTokens: _knownMaxOutputTokens(id),
        ),
    ];

    final preferred = preferredModelId?.trim();
    final current = _currentModel?.id;
    final nextId = _containsId(preferred)
        ? preferred
        : _containsId(current)
        ? current
        : unique.isNotEmpty
        ? unique.first
        : null;
    _currentModel = nextId == null
        ? null
        : ModelInfo(
            id: nextId,
            name: nextId,
            contextWindow: _knownContextWindow(nextId),
            maxOutputTokens: _knownMaxOutputTokens(nextId),
          );
    await _saveCache();
  }

  Future<void> selectModel(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return;
    if (!_containsId(id)) {
      throw ArgumentError.value(modelId, 'modelId', '模型不在网关授权列表中');
    }
    _currentModel = ModelInfo(
      id: id,
      name: id,
      contextWindow: _knownContextWindow(id),
      maxOutputTokens: _knownMaxOutputTokens(id),
    );
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
  const ModelInfo({
    required this.id,
    required this.name,
    this.contextWindow = defaultContextWindow,
    this.maxOutputTokens = defaultMaxOutputTokens,
  });

  final String id;
  final String name;
  final int contextWindow;
  final int maxOutputTokens;

  static const int defaultContextWindow = 128000;
  static const int defaultMaxOutputTokens = 8000;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contextWindow': contextWindow,
    'maxOutputTokens': maxOutputTokens,
  };
}

/// 已知模型的上下文窗口大小。新增模型在此 map 里添加即可；不在列表
/// 内的走默认值（128K / 8K）。
///
/// 数据来源：各供应商公开文档。如果 AI 网关以后下发 model metadata，
/// 这个 map 可以被动态数据覆盖。
const _knownModels = <String, ({int contextWindow, int maxOutputTokens})>{
  'gpt-5.5': (contextWindow: 200000, maxOutputTokens: 32000),
  'gpt-5.4': (contextWindow: 128000, maxOutputTokens: 16000),
  'LongCat-Flash-Chat': (contextWindow: 64000, maxOutputTokens: 8000),
  'LongCat-Flash-Lite': (contextWindow: 64000, maxOutputTokens: 8000),
};

int _knownContextWindow(String modelId) =>
    _knownModels[modelId]?.contextWindow ?? ModelInfo.defaultContextWindow;

int _knownMaxOutputTokens(String modelId) =>
    _knownModels[modelId]?.maxOutputTokens ?? ModelInfo.defaultMaxOutputTokens;
