import 'package:flutter/material.dart';

import '../../identity/word_dict.dart';

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
    final theme = Theme.of(context);
    final c = theme.colorScheme;
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: c.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            usedLlm ? 'LLM 语义候选矩阵' : '确定性候选矩阵',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              '$rows × $k',
              'D≤$hammingDistance 理论 $theoretical',
              '全矩阵 $fullSpace',
              '实际 $attempted',
              if (combinationId != null) '组合 #$combinationId',
              if (elapsedMs > 0)
                '吞吐 ${formatRecoveryAttemptRate(attempted, elapsedMs)}',
              if (activeRows.isNotEmpty) '活跃 $activeRows',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: c.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: c.outlineVariant),
              children: [
                TableRow(
                  decoration: BoxDecoration(color: c.surfaceContainerHighest),
                  children: [
                    _RecoveryMatrixCell(
                      text: '#',
                      style: theme.textTheme.labelSmall,
                      isHeader: true,
                    ),
                    if (anchors.isNotEmpty)
                      _RecoveryMatrixCell(
                        text: '锚点',
                        style: theme.textTheme.labelSmall,
                        isHeader: true,
                      ),
                    for (final rank in rankOrder)
                      _RecoveryMatrixCell(
                        text: '候选 ${rank + 1}',
                        style: theme.textTheme.labelSmall,
                        isHeader: true,
                        isActive: _rankIsActive(rank, candidateRanks),
                      ),
                  ],
                ),
                for (final row in rowOrder)
                  TableRow(
                    children: [
                      _RecoveryMatrixCell(
                        text: '${row + 1}',
                        style: theme.textTheme.bodySmall,
                        isActive: _isActiveMatrixRow(
                          row,
                          candidateRanks,
                          activePositions,
                        ),
                      ),
                      if (anchors.isNotEmpty)
                        _RecoveryMatrixCell(
                          text: row < anchors.length ? anchors[row] : '-',
                          style: theme.textTheme.bodySmall,
                          isActive: _isActiveMatrixRow(
                            row,
                            candidateRanks,
                            activePositions,
                          ),
                        ),
                      for (final rank in rankOrder)
                        _RecoveryMatrixCell(
                          text: row < matrix.length
                              ? _candidateLabel(matrix[row], rank)
                              : '-',
                          style: theme.textTheme.bodySmall,
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
                        ),
                    ],
                  ),
              ],
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
    this.style,
    this.isHeader = false,
    this.isSelected = false,
    this.isActive = false,
  });

  final String text;
  final TextStyle? style;
  final bool isHeader;
  final bool isSelected;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final color = isSelected
        ? (isActive ? c.primaryContainer : c.secondaryContainer)
        : (isActive ? c.surfaceContainerHighest : null);
    final foreground = isSelected
        ? (isActive ? c.onPrimaryContainer : c.onSecondaryContainer)
        : null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        border: isSelected ? Border.all(color: c.primary, width: 1.2) : null,
      ),
      child: SelectableText(
        text,
        style: style?.copyWith(
          fontWeight: isHeader ? FontWeight.w700 : style?.fontWeight,
          fontFamily: isHeader ? null : 'monospace',
          color: foreground,
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
