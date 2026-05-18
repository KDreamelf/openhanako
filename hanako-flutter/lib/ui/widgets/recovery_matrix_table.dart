import 'package:flutter/material.dart';

import '../../identity/word_dict.dart';
import '../design/design.dart';

/// 记忆恢复矩阵 — Onboarding 与设置页里显示候选词矩阵的表格。
///
/// 把 hammingDistance / activePositions / candidateRanks 等业务输入翻译成
/// 视觉上的"行排序、列排序、选中、活跃"组合：
///   - 选中单元格：边框 + 强填充 + 发光
///   - 活跃单元格：暗化背景填充，提示当前 hamming distance 命中
///   - 表头活跃列：图标颜色提亮
class RecoveryCandidateMatrixTable extends StatelessWidget {
  const RecoveryCandidateMatrixTable({
    super.key,
    required this.matrix,
    required this.anchors,
    required this.candidatesPerColumn,
    required this.usedLlm,
    required this.hammingDistance,
    required this.attempted,
    required this.elapsedMs,
    this.combinationId,
    this.candidateRanks = const [],
    this.wordIds = const [],
    this.activePositions = const [],
  });

  final List<List<int>> matrix;
  final List<String> anchors;
  final int candidatesPerColumn;
  final bool usedLlm;
  final int hammingDistance;
  final int attempted;
  final int elapsedMs;
  final int? combinationId;
  final List<int> candidateRanks;
  final List<int> wordIds;
  final List<int> activePositions;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = usedLlm ? palette.accentLavender : palette.accentEmerald;
    final k = candidatesPerColumn > 0
        ? candidatesPerColumn
        : (matrix.isEmpty ? 0 : matrix.first.length);
    final rows = matrix.length > anchors.length
        ? matrix.length
        : anchors.length;
    final theoretical = _boundedSearchSpace(rows, k, hammingDistance);
    final fullSpace = _boundedSearchSpace(rows, k, rows);
    final rowOrder = _matrixRowOrder(rows, candidateRanks, activePositions);
    final rankOrder = _matrixRankOrder(k, candidateRanks, rowOrder);
    final activeRows = rowOrder
        .where(
          (row) => _isActiveMatrixRow(row, candidateRanks, activePositions),
        )
        .map((row) => row + 1)
        .take(4)
        .join('、');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DS.s14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.bgFloating.withValues(alpha: palette.isDark ? 0.55 : 0.94),
            palette.bgRaised.withValues(alpha: palette.isDark ? 0.45 : 0.86),
          ],
        ),
        borderRadius: BorderRadius.circular(DS.r12),
        border: Border.all(color: palette.divider, width: DS.hairline),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.08),
            blurRadius: 20,
            spreadRadius: -6,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(DS.r6),
                  border: Border.all(color: accent.withValues(alpha: 0.36)),
                ),
                child: Icon(
                  usedLlm
                      ? Icons.psychology_alt_outlined
                      : Icons.dataset_outlined,
                  size: 14,
                  color: accent,
                ),
              ),
              const SizedBox(width: DS.s10),
              Expanded(
                child: Text(
                  usedLlm ? 'LLM 语义候选矩阵' : '确定性候选矩阵',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: DS.t14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              HanaPill(
                label: '$rows × $k',
                color: accent,
                dense: true,
                outlined: false,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: DS.s6,
            runSpacing: 4,
            children: [
              if (hammingDistance > 0)
                _MatrixStat(
                  label: 'D ≤ $hammingDistance',
                  value: '理论 $theoretical',
                  color: palette.accentCyan,
                ),
              _MatrixStat(
                label: '全矩阵',
                value: '$fullSpace',
                color: palette.textTertiary,
              ),
              _MatrixStat(
                label: '实际',
                value: '$attempted',
                color: palette.accentEmerald,
              ),
              if (combinationId != null)
                _MatrixStat(
                  label: '组合',
                  value: '#$combinationId',
                  color: palette.accentLavender,
                ),
              if (elapsedMs > 0)
                _MatrixStat(
                  label: '吞吐',
                  value: formatRecoveryAttemptRate(attempted, elapsedMs),
                  color: palette.accentAmber,
                ),
              if (activeRows.isNotEmpty)
                _MatrixStat(
                  label: '活跃',
                  value: activeRows,
                  color: accent,
                ),
            ],
          ),
          const SizedBox(height: DS.s12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.5 : 0.40),
                borderRadius: BorderRadius.circular(DS.r8),
                border: Border.all(color: palette.divider),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DS.r8),
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder.symmetric(
                    inside: BorderSide(
                      color: palette.divider.withValues(alpha: 0.6),
                      width: DS.hairline,
                    ),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: palette.bgRaised
                            .withValues(alpha: palette.isDark ? 0.6 : 0.80),
                      ),
                      children: [
                        _RecoveryMatrixCell(
                          text: '#',
                          isHeader: true,
                          palette: palette,
                        ),
                        if (anchors.isNotEmpty)
                          _RecoveryMatrixCell(
                            text: '锚点',
                            isHeader: true,
                            palette: palette,
                          ),
                        for (final rank in rankOrder)
                          _RecoveryMatrixCell(
                            text: '候选 ${rank + 1}',
                            isHeader: true,
                            isActive: _rankIsActive(rank, candidateRanks),
                            palette: palette,
                            accent: accent,
                          ),
                      ],
                    ),
                    for (final row in rowOrder)
                      TableRow(
                        children: [
                          _RecoveryMatrixCell(
                            text: '${row + 1}',
                            palette: palette,
                            isActive: _isActiveMatrixRow(
                              row,
                              candidateRanks,
                              activePositions,
                            ),
                            accent: accent,
                          ),
                          if (anchors.isNotEmpty)
                            _RecoveryMatrixCell(
                              text: row < anchors.length ? anchors[row] : '-',
                              palette: palette,
                              isActive: _isActiveMatrixRow(
                                row,
                                candidateRanks,
                                activePositions,
                              ),
                              accent: accent,
                            ),
                          for (final rank in rankOrder)
                            _RecoveryMatrixCell(
                              text: row < matrix.length
                                  ? _candidateLabel(matrix[row], rank)
                                  : '-',
                              palette: palette,
                              isSelected: _isSelectedCandidate(
                                row: row,
                                rank: rank,
                                matrix: matrix,
                                candidateRanks: candidateRanks,
                                wordIds: wordIds,
                              ),
                              isActive: _isActiveMatrixRow(
                                row,
                                candidateRanks,
                                activePositions,
                              ),
                              accent: accent,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MatrixStat extends StatelessWidget {
  const _MatrixStat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.s8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.isDark ? 0.08 : 0.06),
        borderRadius: BorderRadius.circular(DS.r6),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: DS.t10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: DS.t11,
              fontWeight: FontWeight.w600,
              fontFamilyFallback: DS.monoFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecoveryMatrixCell extends StatelessWidget {
  const _RecoveryMatrixCell({
    required this.text,
    required this.palette,
    this.isHeader = false,
    this.isSelected = false,
    this.isActive = false,
    this.accent,
  });

  final String text;
  final HanaPalette palette;
  final bool isHeader;
  final bool isSelected;
  final bool isActive;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final base = accent ?? palette.accentEmerald;
    final bgColor = isSelected
        ? base.withValues(alpha: palette.isDark ? 0.22 : 0.20)
        : (isActive
            ? base.withValues(alpha: palette.isDark ? 0.10 : 0.08)
            : null);
    final foreground = isSelected
        ? Color.lerp(palette.textPrimary, base, 0.42)
        : isActive
            ? Color.lerp(palette.textSecondary, base, 0.36)
            : (isHeader ? palette.textSecondary : palette.textPrimary);
    return AnimatedContainer(
      duration: DS.dQuick,
      curve: DS.cStandard,
      padding: const EdgeInsets.symmetric(
        horizontal: DS.s10,
        vertical: DS.s8,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        border: isSelected
            ? Border.all(color: base.withValues(alpha: 0.55), width: 1.2)
            : null,
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: base.withValues(alpha: 0.36),
                  blurRadius: 6,
                ),
              ]
            : null,
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: isHeader ? DS.t11 : DS.t12,
          fontWeight: isHeader || isSelected
              ? FontWeight.w700
              : FontWeight.w500,
          fontFamily: isHeader ? null : 'monospace',
          letterSpacing: isHeader ? 0.4 : 0,
        ),
      ),
    );
  }
}

String formatRecoveryAttemptRate(int attempted, int elapsedMs) {
  if (attempted <= 0 || elapsedMs <= 0) return '0 次/秒';
  final rate = attempted * 1000 / elapsedMs;
  if (rate >= 100000000) {
    return '${(rate / 100000000).toStringAsFixed(2)} 亿次/秒';
  }
  if (rate >= 10000) {
    return '${(rate / 10000).toStringAsFixed(1)} 万次/秒';
  }
  if (rate >= 1000) {
    return '${rate.toStringAsFixed(0)} 次/秒';
  }
  return '${rate.toStringAsFixed(1)} 次/秒';
}

String _candidateLabel(List<int> row, int rank) {
  if (rank >= row.length) return '-';
  final id = row[rank];
  final word = wordById(id) ?? '?';
  return '$id $word';
}

List<int> _matrixRowOrder(
  int rows,
  List<int> candidateRanks,
  List<int> activePositions,
) {
  final seen = <int>{};
  final ordered = <int>[];

  void add(int row) {
    if (row < 0 || row >= rows || !seen.add(row)) return;
    ordered.add(row);
  }

  for (final row in activePositions) {
    add(row);
  }
  if (ordered.isEmpty) {
    for (var row = 0; row < candidateRanks.length && row < rows; row++) {
      if (candidateRanks[row] > 0) add(row);
    }
  }
  for (var row = 0; row < rows; row++) {
    add(row);
  }
  return ordered;
}

List<int> _matrixRankOrder(
  int k,
  List<int> candidateRanks,
  List<int> rowOrder,
) {
  final seen = <int>{};
  final ordered = <int>[];

  void add(int rank) {
    if (rank < 0 || rank >= k || !seen.add(rank)) return;
    ordered.add(rank);
  }

  for (final row in rowOrder) {
    if (row >= 0 && row < candidateRanks.length && candidateRanks[row] > 0) {
      add(candidateRanks[row]);
    }
  }
  for (var rank = 0; rank < k; rank++) {
    add(rank);
  }
  return ordered;
}

bool _isActiveMatrixRow(
  int row,
  List<int> candidateRanks,
  List<int> activePositions,
) {
  if (activePositions.contains(row)) return true;
  return row >= 0 && row < candidateRanks.length && candidateRanks[row] > 0;
}

bool _rankIsActive(int rank, List<int> candidateRanks) {
  return rank > 0 && candidateRanks.contains(rank);
}

bool _isSelectedCandidate({
  required int row,
  required int rank,
  required List<List<int>> matrix,
  required List<int> candidateRanks,
  required List<int> wordIds,
}) {
  if (row < 0 ||
      row >= matrix.length ||
      rank < 0 ||
      rank >= matrix[row].length) {
    return false;
  }
  if (row < candidateRanks.length) {
    return candidateRanks[row] == rank;
  }
  if (row < wordIds.length) {
    return matrix[row][rank] == wordIds[row];
  }
  return false;
}

int _boundedSearchSpace(int rows, int k, int maxDistance) {
  if (rows <= 0 || k <= 0) return 0;
  final limit = maxDistance.clamp(0, rows).toInt();
  var total = 0;
  for (var d = 0; d <= limit; d++) {
    total += _binom(rows, d) * _pow(k - 1, d);
  }
  return total;
}

int _binom(int n, int k) {
  if (k < 0 || k > n) return 0;
  if (k == 0 || k == n) return 1;
  var result = 1;
  final kk = k > n - k ? n - k : k;
  for (var i = 0; i < kk; i++) {
    result = result * (n - i) ~/ (i + 1);
  }
  return result;
}

int _pow(int base, int exp) {
  var result = 1;
  for (var i = 0; i < exp; i++) {
    result *= base;
  }
  return result;
}
