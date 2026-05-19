import 'model_manager.dart';

class CompactThresholds {
  const CompactThresholds({
    required this.contextWindow,
    required this.maxOutputTokens,
    required this.effectiveWindow,
    required this.autoCompactThreshold,
    required this.warningThreshold,
  });

  final int contextWindow;
  final int maxOutputTokens;
  final int effectiveWindow;
  final int autoCompactThreshold;
  final int warningThreshold;

  double usagePercent(int currentTokens) {
    if (effectiveWindow <= 0) return 0;
    return (currentTokens / effectiveWindow).clamp(0.0, 1.0);
  }

  CompactLevel level(int currentTokens) {
    if (currentTokens >= autoCompactThreshold) return CompactLevel.critical;
    if (currentTokens >= warningThreshold) return CompactLevel.warning;
    return CompactLevel.normal;
  }

  int remainingTokens(int currentTokens) =>
      (effectiveWindow - currentTokens).clamp(0, effectiveWindow);
}

enum CompactLevel { normal, warning, critical }

const int _autoCompactBufferTokens = 13000;
const int _warningBufferTokens = 20000;
const int _reservedForSummaryMax = 20000;

CompactThresholds computeThresholds(ModelInfo model) {
  final reservedForSummary = model.maxOutputTokens < _reservedForSummaryMax
      ? model.maxOutputTokens
      : _reservedForSummaryMax;
  final effectiveWindow = model.contextWindow - reservedForSummary;
  final autoCompact = effectiveWindow - _autoCompactBufferTokens;
  final warning = autoCompact - _warningBufferTokens;

  return CompactThresholds(
    contextWindow: model.contextWindow,
    maxOutputTokens: model.maxOutputTokens,
    effectiveWindow: effectiveWindow,
    autoCompactThreshold: autoCompact,
    warningThreshold: warning,
  );
}
