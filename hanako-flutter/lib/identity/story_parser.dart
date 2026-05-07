// lib/identity/story_parser.dart
//
// 故事解析器：恢复期把用户的模糊故事 / 词组列表交给 LLM，让它在字典中找
// 到对应词的"候选矩阵"——12 列（按故事意象顺序）× K 行（每列 top-K
// 候选，按语义相似度从高到低）。
//
// 与 MVP §10.5 对齐 + v2 改造（按用户 2026-04-27 设计）：
//   - 旧版本输出扁平 ID 列表，客户端做全排列穷举，最坏 12! 次。
//   - 新版本输出 12×K 矩阵，客户端按汉明距离递增枚举，最坏 K^12 次。
//     第一阶段默认 K=5，依赖恢复器按汉明距离限制搜索深度。
//     通过 RFA 后可显式提高 K 或搜索深度做深度恢复。
//
// 矩阵协议：
//   {
//     "columns": [
//       [12, 73, ...],     // 第 1 个意象：top-K ID（rank-0 最像）
//       [451, 980, ...],   // 第 2 个意象：top-K ID
//       ...
//       [...]              // 共 12 列
//     ]
//   }

import 'dart:convert';

import 'word_dict.dart';
import 'story_composer.dart' show StoryLlmCaller;

/// 第一阶段每列候选数（与 recovery.dart 中的 K 对齐）。
///
/// K=5 用来容纳人脑复述时常见的近义词、错记词和同类实体替换；
/// 恢复器会把硬搜索深度限制在 10 分钟 UX 预算内。
const int kStoryParserCandidatesPerColumn = 5;

/// 期望的列数（即助记词长度，固定 12）。
const int kStoryParserColumns = 12;
const int _candidateDeadLetterMaxRounds = 100;
const Duration _candidateDeadLetterInitialBackoff = Duration(milliseconds: 800);
const Duration _candidateDeadLetterMaxBackoff = Duration(seconds: 30);

class StoryParseResult {
  StoryParseResult({
    required this.columns,
    required this.rawResponse,
    required this.candidatesPerColumn,
    required this.usedLlm,
    this.anchors = const [],
  });

  /// 12 × K 矩阵。每行（外层）是按用户故事顺序的一个意象，每列内是该意象
  /// 的 top-K 候选 ID（rank-0 最像，rank-K-1 最不像）。
  final List<List<int>> columns;

  /// LLM 的原始返回，用于 debug。
  final String rawResponse;

  /// 本次矩阵每列候选数。
  final int candidatesPerColumn;

  /// 本次结果是否来自 LLM 语义匹配。
  final bool usedLlm;

  /// LLM 第一阶段抽取出的 12 个故事锚点。确定性路径可为空或为精确词。
  final List<String> anchors;

  /// 是否符合协议（12 列 × K 候选 + 全部 ID 在字典范围内）。
  bool get isWellFormed {
    if (columns.length != kStoryParserColumns) return false;
    for (final col in columns) {
      if (col.length != candidatesPerColumn) return false;
      for (final id in col) {
        if (id < 0 || id >= hanakoWordlistSize) return false;
      }
    }
    return true;
  }
}

class StoryParser {
  StoryParser({
    required this.caller,
    this.candidatesPerColumn = kStoryParserCandidatesPerColumn,
  }) {
    if (candidatesPerColumn < 1) {
      throw ArgumentError('candidatesPerColumn 必须大于 0');
    }
  }

  final StoryLlmCaller caller;
  final int candidatesPerColumn;

  String get systemPromptForTesting =>
      '${_buildAnchorPrompt()}\n${_buildCandidateSystemPrompt('凳子')}';

  /// 恢复期入口：用户输入 → 12×K 矩阵。
  ///
  /// [storyOrWords] 可以是模糊故事，也可以是用空格 / 逗号分隔的词组。
  Future<StoryParseResult> parse(
    String storyOrWords, {
    bool forceLlm = false,
    void Function()? onLlm,
    void Function(List<String> anchors)? onAnchorsReady,
    void Function(List<List<int>> columns)? onCandidateMatrixProgress,
  }) async {
    if (!forceLlm) {
      final exactWords =
          _tryParseExactWords(storyOrWords) ??
          _tryParseEmbeddedExactWords(storyOrWords);
      if (exactWords != null) {
        return _exactResult(exactWords);
      }
    }

    onLlm?.call();
    var anchorsRaw = await caller(
      systemPrompt: _buildAnchorPrompt(),
      userPrompt: storyOrWords,
      maxTokens: 800,
    );
    var anchors = _extractAnchors(anchorsRaw);
    if (anchors.isNotEmpty && anchors.length != kStoryParserColumns) {
      final retryRaw = await caller(
        systemPrompt: _buildAnchorPrompt(),
        userPrompt: _buildAnchorRetryUserPrompt(
          storyOrWords: storyOrWords,
          anchors: anchors,
          rawResponse: anchorsRaw,
        ),
        maxTokens: 800,
      );
      final retryAnchors = _extractAnchors(retryRaw);
      if (retryAnchors.length == kStoryParserColumns) {
        anchorsRaw = retryRaw;
        anchors = retryAnchors;
      }
    }
    if (anchors.length != kStoryParserColumns) {
      return StoryParseResult(
        columns: const [],
        rawResponse: _debugRawResponse(
          anchorsRaw: anchorsRaw,
          anchors: anchors,
        ),
        candidatesPerColumn: candidatesPerColumn,
        usedLlm: true,
        anchors: anchors,
      );
    }
    onAnchorsReady?.call(List<String>.unmodifiable(anchors));

    final partial = List<List<int>>.generate(
      anchors.length,
      (_) => const <int>[],
    );
    final candidateRows = await _generateCandidateRowsWithDeadLetters(
      storyOrWords: storyOrWords,
      anchors: anchors,
      partial: partial,
      onCandidateMatrixProgress: onCandidateMatrixProgress,
    );
    final cols = [
      for (var index = 0; index < anchors.length; index++)
        candidateRows[index]?.row ?? const <int>[],
    ];
    return StoryParseResult(
      columns: cols,
      rawResponse: _debugRawResponse(
        anchorsRaw: anchorsRaw,
        anchors: anchors,
        candidateRows: [for (final row in candidateRows) ?row],
      ),
      candidatesPerColumn: candidatesPerColumn,
      usedLlm: true,
      anchors: anchors,
    );
  }

  Future<List<_CandidateRowResult?>> _generateCandidateRowsWithDeadLetters({
    required String storyOrWords,
    required List<String> anchors,
    required List<List<int>> partial,
    void Function(List<List<int>> columns)? onCandidateMatrixProgress,
  }) async {
    final rows = List<_CandidateRowResult?>.filled(anchors.length, null);
    final deadLetters = <_CandidateDeadLetter>[];

    await Future.wait([
      for (var index = 0; index < anchors.length; index++)
        _generateCandidateRow(
              storyOrWords: storyOrWords,
              anchors: anchors,
              index: index,
            )
            .then((row) {
              rows[index] = row;
              partial[index] = List<int>.unmodifiable(row.row);
              onCandidateMatrixProgress?.call(_copyMatrix(partial));
            })
            .catchError((Object error, StackTrace stackTrace) {
              deadLetters.add(
                _CandidateDeadLetter(
                  index: index,
                  error: error,
                  stackTrace: stackTrace,
                ),
              );
            }),
    ]);

    for (
      var round = 1;
      deadLetters.isNotEmpty && round <= _candidateDeadLetterMaxRounds;
      round++
    ) {
      final failed = List<_CandidateDeadLetter>.of(deadLetters);
      deadLetters.clear();
      for (final letter in failed) {
        try {
          final row = await _generateCandidateRow(
            storyOrWords: storyOrWords,
            anchors: anchors,
            index: letter.index,
          );
          rows[letter.index] = row;
          partial[letter.index] = List<int>.unmodifiable(row.row);
          onCandidateMatrixProgress?.call(_copyMatrix(partial));
        } catch (error, stackTrace) {
          deadLetters.add(
            _CandidateDeadLetter(
              index: letter.index,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        }
      }
      if (deadLetters.isNotEmpty) {
        await Future<void>.delayed(_candidateDeadLetterBackoff(round));
      }
    }

    if (deadLetters.isNotEmpty) {
      Error.throwWithStackTrace(
        deadLetters.first.error,
        deadLetters.first.stackTrace,
      );
    }
    return rows;
  }

  Future<_CandidateRowResult> _generateCandidateRow({
    required String storyOrWords,
    required List<String> anchors,
    required int index,
  }) async {
    final raw = await caller(
      systemPrompt: _buildCandidateSystemPrompt(anchors[index]),
      userPrompt: _buildCandidateUserPrompt(
        storyOrWords: storyOrWords,
        anchors: anchors,
        index: index,
      ),
      maxTokens: 500,
    );
    final row = _extractCandidateRow(raw);
    if (row.length == candidatesPerColumn) {
      return _CandidateRowResult(index: index, rawResponse: raw, row: row);
    }

    final retryRaw = await caller(
      systemPrompt: _buildCandidateSystemPrompt(anchors[index]),
      userPrompt: _buildCandidateRetryUserPrompt(
        storyOrWords: storyOrWords,
        anchors: anchors,
        index: index,
        row: row,
        rawResponse: raw,
      ),
      maxTokens: 500,
    );
    final retryRow = _extractCandidateRow(retryRaw);
    return _CandidateRowResult(
      index: index,
      rawResponse: retryRaw,
      row: retryRow,
    );
  }

  StoryParseResult _exactResult(List<List<int>> exactWords) {
    return StoryParseResult(
      columns: exactWords,
      rawResponse: jsonEncode({'columns': exactWords}),
      candidatesPerColumn: 1,
      usedLlm: false,
      anchors: [
        for (final row in exactWords)
          if (row.isNotEmpty) wordById(row.first) ?? '',
      ],
    );
  }

  String _buildAnchorPrompt() {
    return '''
你是一个记忆故事锚点提取器，只负责从用户复述中提取有序锚点，不生成候选词，不输出字典 ID。

任务规则：
1. 用户给你的是一段记忆故事或一组关键词，里面隐含 $kStoryParserColumns 个核心记忆锚点。
2. **严格按故事中锚点出现的顺序**输出，不要按你的理解重新排序。
3. 输出的是用户复述里的短词或短语；可以是"凳子"、"石台"、"冷风"这类近义/错记词，不要提前改成字典词。
4. 如果同一句里有两个可作为记忆锚点的名词，必须拆成相邻两项；例如"立夏的凉粉摊"应输出"立夏"和"凉粉"两个锚点。
5. 如果故事里出现超过 $kStoryParserColumns 个名词，优先保留具体物体、地点、食物、节令、角色和明显被动作串联的实体；把"涟漪/阳光/人群"这类结果、背景、氛围词降级，除非它们明显就是唯一锚点。
6. 如果不足 $kStoryParserColumns 个锚点，按故事语义补出最可能被省略的短语，但不要编造无关实体。
7. 只输出严格 JSON：{"anchors":["词1","词2",...]}，anchors 恰好 $kStoryParserColumns 个字符串。
8. 不要输出任何解释、Markdown、前缀、注释。
''';
  }

  /// 系统提示词。字典本体随提示词一并发给 LLM。
  String _buildCandidateSystemPrompt(String anchor) {
    final rowShape = List.filled(candidatesPerColumn, 'id').join(',');
    final exampleValues = <int>[];
    for (var col = 0; col < candidatesPerColumn; col++) {
      exampleValues.add((137 + col * 29 + 12) % hanakoWordlistSize);
    }
    final dictJson = StringBuffer('{');
    for (var i = 0; i < hanakoWordlistSize; i++) {
      if (i > 0) dictJson.write(',');
      dictJson.write('"$i":"${hanakoWordlist[i]}"');
    }
    dictJson.write('}');

    return '''
你是一个语义候选生成器，负责把单个故事锚点映射到中文名词字典中的 ID。

任务规则：
1. 当前只处理一个锚点，不要处理故事里的其他锚点。
2. 把该锚点转成字典中最接近的 $candidatesPerColumn 个候选 ID（按相似度从高到低）。
3. 同义词必须映射（如"西红柿"→"番茄"，"太空"→"宇宙"，"风琴"→"钢琴"）。
4. 如果用户写的是近义词或错记词，要把"用户写出的词"和"最可能的原始记忆词"都放进候选。例如"凳子"应同时考虑"凳子/板凳/长凳/椅子"，"石台"应优先考虑"石坛/石碑/石桥"，"冷风"应考虑"寒风/凉风/冬风"。
5. 候选词的语义要尽量贴近，避免硬塞无关词。
6. 如果你确实只能想到不足 $candidatesPerColumn 个候选，用最相似的那个重复填满。
7. 只输出严格的 JSON：{"candidates":[$rowShape]}，candidates 恰好 $candidatesPerColumn 个整数。
8. 不要输出任何解释、Markdown、前缀、注释。

当前锚点：$anchor

输出格式示例：
{"candidates":[${exampleValues.join(',')}]}

字典：$dictJson
''';
  }

  String _buildAnchorRetryUserPrompt({
    required String storyOrWords,
    required List<String> anchors,
    required String rawResponse,
  }) {
    return '''
你上一次输出的锚点列表不符合协议，本次不能继续恢复。

错误信息：
- anchors 必须恰好 $kStoryParserColumns 个字符串，但你输出了 ${anchors.length} 个。

原始故事：
$storyOrWords

上一次原始响应：
$rawResponse

上一次解析出的锚点：
${[for (var i = 0; i < anchors.length; i++) '${i + 1}. ${anchors[i]}'].join('\n')}

请基于原始故事和上一次错误输出，重新判断 12 个记忆锚点。
只输出严格 JSON：{"anchors":["词1","词2",...]}，anchors 恰好 $kStoryParserColumns 个字符串。
''';
  }

  String _buildCandidateUserPrompt({
    required String storyOrWords,
    required List<String> anchors,
    required int index,
  }) {
    return '''
原始故事：
$storyOrWords

已抽取锚点：
${[for (var i = 0; i < anchors.length; i++) '${i + 1}. ${anchors[i]}'].join('\n')}

当前只处理第 ${index + 1} 个锚点：${anchors[index]}
请只为这个锚点生成候选 ID，不要处理其他锚点。
''';
  }

  String _buildCandidateRetryUserPrompt({
    required String storyOrWords,
    required List<String> anchors,
    required int index,
    required List<int> row,
    required String rawResponse,
  }) {
    final entries = row.map((id) => '$id:${wordById(id) ?? '?'}').join(', ');
    return '''
你上一次输出的候选列表不符合协议，本次不能继续恢复。

错误信息：
- 当前锚点必须输出恰好 $candidatesPerColumn 个整数 ID，但你输出了 ${row.length} 个有效 ID。

原始故事：
$storyOrWords

已抽取锚点：
${[for (var i = 0; i < anchors.length; i++) '${i + 1}. ${anchors[i]}'].join('\n')}

上一次原始响应：
$rawResponse

当前锚点：
${index + 1}. ${anchors[index]}

上一次解析出的候选（ID:词）：
[$entries]

请只为当前锚点重新生成候选 ID。
只输出严格 JSON：{"candidates":[id,id,...]}，candidates 恰好 $candidatesPerColumn 个整数。
''';
  }

  String _debugRawResponse({
    required String anchorsRaw,
    required List<String> anchors,
    List<_CandidateRowResult>? candidateRows,
  }) {
    return jsonEncode({
      'anchors': anchors,
      'anchors_raw': anchorsRaw,
      if (candidateRows != null)
        'candidate_rows': [
          for (final row in candidateRows)
            {
              'index': row.index,
              'anchor': anchors[row.index],
              'row': row.row,
              'raw': row.rawResponse,
            },
        ],
    });
  }

  List<String> _extractAnchors(String raw) {
    final braceStart = raw.indexOf('{');
    final braceEnd = raw.lastIndexOf('}');
    if (braceStart < 0 || braceEnd <= braceStart) {
      return const [];
    }
    final jsonStr = raw.substring(braceStart, braceEnd + 1);
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return const [];
    }
    final rawAnchors = obj['anchors'] ?? obj['items'];
    if (rawAnchors is! List) return const [];

    final anchors = <String>[];
    for (final item in rawAnchors) {
      String? text;
      if (item is String) {
        text = item;
      } else if (item is Map) {
        final value = item['anchor'] ?? item['text'] ?? item['word'];
        if (value != null) text = value.toString();
      }
      final normalized = text?.trim();
      if (normalized != null && normalized.isNotEmpty) {
        anchors.add(normalized);
      }
    }
    return anchors;
  }

  /// 从 LLM 文本里抽出单个候选行。容忍包裹的 ```json 代码块、前后空白等噪声。
  List<int> _extractCandidateRow(String raw) {
    final braceStart = raw.indexOf('{');
    final braceEnd = raw.lastIndexOf('}');
    if (braceStart < 0 || braceEnd <= braceStart) {
      return const [];
    }
    final jsonStr = raw.substring(braceStart, braceEnd + 1);
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return const [];
    }
    var values = obj['candidates'] ?? obj['ids'];
    if (values == null) {
      final columns = obj['columns'];
      if (columns is List && columns.isNotEmpty) {
        values = columns.first;
      }
    }
    if (values is! List) return const [];

    final row = <int>[];
    for (final v in values) {
      int? id;
      if (v is int) {
        id = v;
      } else if (v is num) {
        id = v.toInt();
      }
      if (id != null && id >= 0 && id < hanakoWordlistSize) {
        row.add(id);
      }
    }
    return row;
  }

  /// 用户直接输入 12 个准确助记词时不依赖 LLM，保证未部署 AI 网关时仍可恢复登录。
  List<List<int>>? _tryParseExactWords(String input) {
    final words = input
        .split(RegExp(r'[\s,，、;；|/]+'))
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.length != kStoryParserColumns) return null;

    final ids = <int>[];
    for (final word in words) {
      final id = idByWord(word);
      if (id == null) return null;
      ids.add(id);
    }
    return _matrixFromIds(ids);
  }

  /// 直接粘贴由 StoryComposer 生成的故事时，故事正文中会按顺序出现 12 个
  /// 精确字典词。这里先做确定性扫描，避免 LLM 在语义匹配阶段改顺序或选近义词。
  List<List<int>>? _tryParseEmbeddedExactWords(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;

    final ids = <int>[];
    var offset = 0;
    while (offset < text.length) {
      _WordEntry? match;
      for (final entry in _wordEntriesByLength) {
        if (text.startsWith(entry.word, offset)) {
          match = entry;
          break;
        }
      }
      if (match == null) {
        offset++;
        continue;
      }
      ids.add(match.id);
      offset += match.word.length;
      if (ids.length > kStoryParserColumns) return null;
    }

    if (ids.length != kStoryParserColumns) return null;
    return _matrixFromIds(ids);
  }

  List<List<int>> _matrixFromIds(List<int> ids) {
    return [
      for (final id in ids) [id],
    ];
  }
}

class _CandidateDeadLetter {
  const _CandidateDeadLetter({
    required this.index,
    required this.error,
    required this.stackTrace,
  });

  final int index;
  final Object error;
  final StackTrace stackTrace;
}

class _WordEntry {
  const _WordEntry(this.word, this.id);

  final String word;
  final int id;
}

class _CandidateRowResult {
  const _CandidateRowResult({
    required this.index,
    required this.rawResponse,
    required this.row,
  });

  final int index;
  final String rawResponse;
  final List<int> row;
}

List<List<int>> _copyMatrix(List<List<int>> matrix) {
  return List<List<int>>.unmodifiable([
    for (final row in matrix) List<int>.unmodifiable(row),
  ]);
}

Duration _candidateDeadLetterBackoff(int round) {
  final exponent = (round - 1).clamp(0, 12).toInt();
  final multiplier = 1 << exponent;
  final exponentialMs =
      _candidateDeadLetterInitialBackoff.inMilliseconds * multiplier;
  final cappedMs = exponentialMs.clamp(
    _candidateDeadLetterInitialBackoff.inMilliseconds,
    _candidateDeadLetterMaxBackoff.inMilliseconds,
  );
  return Duration(milliseconds: cappedMs);
}

final List<_WordEntry> _wordEntriesByLength = List.unmodifiable(
  [
    for (var i = 0; i < hanakoWordlistSize; i++)
      _WordEntry(hanakoWordlist[i], i),
  ]..sort((a, b) {
    final lengthOrder = b.word.length.compareTo(a.word.length);
    if (lengthOrder != 0) return lengthOrder;
    return a.id.compareTo(b.id);
  }),
);
