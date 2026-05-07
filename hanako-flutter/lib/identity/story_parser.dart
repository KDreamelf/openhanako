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

class StoryParseResult {
  StoryParseResult({
    required this.columns,
    required this.rawResponse,
    required this.candidatesPerColumn,
    required this.usedLlm,
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

  String get systemPromptForTesting => _buildSystemPrompt();

  /// 恢复期入口：用户输入 → 12×K 矩阵。
  ///
  /// [storyOrWords] 可以是模糊故事，也可以是用空格 / 逗号分隔的词组。
  Future<StoryParseResult> parse(
    String storyOrWords, {
    bool forceLlm = false,
  }) async {
    if (!forceLlm) {
      final exactWords =
          _tryParseExactWords(storyOrWords) ??
          _tryParseEmbeddedExactWords(storyOrWords);
      if (exactWords != null) {
        return _exactResult(exactWords);
      }
    }

    final raw = await caller(
      systemPrompt: _buildSystemPrompt(),
      userPrompt: storyOrWords,
      maxTokens: 1500,
    );
    final cols = _extractMatrix(raw);
    if (cols.isNotEmpty && cols.length != kStoryParserColumns) {
      final retryRaw = await caller(
        systemPrompt: _buildSystemPrompt(),
        userPrompt: _buildRetryUserPrompt(
          storyOrWords: storyOrWords,
          columns: cols,
          rawResponse: raw,
        ),
        maxTokens: 1500,
      );
      final retryCols = _extractMatrix(retryRaw);
      if (retryCols.length == kStoryParserColumns) {
        return StoryParseResult(
          columns: retryCols,
          rawResponse: retryRaw,
          candidatesPerColumn: candidatesPerColumn,
          usedLlm: true,
        );
      }
    }
    return StoryParseResult(
      columns: cols,
      rawResponse: raw,
      candidatesPerColumn: candidatesPerColumn,
      usedLlm: true,
    );
  }

  StoryParseResult _exactResult(List<List<int>> exactWords) {
    return StoryParseResult(
      columns: exactWords,
      rawResponse: jsonEncode({'columns': exactWords}),
      candidatesPerColumn: 1,
      usedLlm: false,
    );
  }

  /// 系统提示词。字典本体随提示词一并发给 LLM。
  String _buildSystemPrompt() {
    final rowShape = List.filled(candidatesPerColumn, 'id').join(',');
    final exampleRows = <String>[];
    for (var row = 0; row < kStoryParserColumns; row++) {
      final values = <int>[];
      for (var col = 0; col < candidatesPerColumn; col++) {
        values.add((row * 137 + col * 29 + 12) % hanakoWordlistSize);
      }
      exampleRows.add('[${values.join(',')}]');
    }
    final dictJson = StringBuffer('{');
    for (var i = 0; i < hanakoWordlistSize; i++) {
      if (i > 0) dictJson.write(',');
      dictJson.write('"$i":"${hanakoWordlist[i]}"');
    }
    dictJson.write('}');

    return '''
你是一个语义匹配器，负责把用户描述的"故事"或"词组"映射到中文名词字典中的 ID。

任务规则：
1. 用户给你的内容是一段故事或一组关键词；故事里隐含 $kStoryParserColumns 个核心意象。
2. **按故事中意象出现的顺序**，把每个意象转成字典中最接近的 $candidatesPerColumn 个候选 ID（按相似度从高到低）。
3. 同义词必须映射（如"西红柿"→"番茄"，"太空"→"宇宙"，"风琴"→"钢琴"）。
4. 如果用户写的是近义词或错记词，要把"用户写出的词"和"最可能的原始记忆词"都放进候选。例如"凳子"应同时考虑"凳子/板凳/长凳/椅子"，"石台"应优先考虑"石坛/石碑/石桥"，"冷风"应考虑"寒风/凉风/冬风"。
5. 如果同一句里有两个可作为记忆锚点的名词，必须拆成相邻两列；例如"立夏的凉粉摊"应输出"立夏"和"凉粉"两个位置，不能合并成一列。
6. 如果故事里出现超过 $kStoryParserColumns 个名词，优先保留具体物体、地点、食物、节令和角色锚点；把"涟漪/阳光/人群"这类结果、背景、氛围词降级，除非它们明显就是唯一锚点。
7. 候选词的语义要尽量贴近，避免硬塞无关词。
8. 如果你确实只能想到不足 $candidatesPerColumn 个候选，用最相似的那个重复填满。
9. 只输出严格的 JSON：{"columns":[[$rowShape],[$rowShape],...]}，恰好 $kStoryParserColumns 个数组，每个数组恰好 $candidatesPerColumn 个整数。
10. 不要输出任何解释、Markdown、前缀、注释。

输出格式示例：
{"columns":[${exampleRows.join(',')}]}

字典：$dictJson
''';
  }

  String _buildRetryUserPrompt({
    required String storyOrWords,
    required List<List<int>> columns,
    required String rawResponse,
  }) {
    final matrixLines = <String>[];
    for (var row = 0; row < columns.length; row++) {
      final entries = columns[row]
          .map((id) => '$id:${wordById(id) ?? '?'}')
          .join(', ');
      matrixLines.add('${row + 1}. [$entries]');
    }
    return '''
你上一次输出的候选矩阵不符合协议，本次不能继续恢复。

错误信息：
- columns 必须恰好 $kStoryParserColumns 行，但你输出了 ${columns.length} 行。
- 每行必须恰好 $candidatesPerColumn 个整数 ID。

原始故事：
$storyOrWords

上一次原始响应：
$rawResponse

上一次解析出的矩阵（ID:词）：
${matrixLines.join('\n')}

请基于原始故事和上一次错误输出，重新完成同一个语义匹配任务。
注意：这不是让程序替你裁剪矩阵，而是要求你自己重新判断 12 个记忆锚点。
只输出恰好 $kStoryParserColumns × $candidatesPerColumn 的严格 JSON。
''';
  }

  /// 从 LLM 文本里抽出矩阵。容忍包裹的 ```json 代码块、前后空白等噪声。
  List<List<int>> _extractMatrix(String raw) {
    // 找 JSON 主体
    final braceStart = raw.indexOf('{');
    final braceEnd = raw.lastIndexOf('}');
    if (braceStart < 0 || braceEnd <= braceStart) {
      return _emptyMatrix();
    }
    final jsonStr = raw.substring(braceStart, braceEnd + 1);
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return _emptyMatrix();
    }
    final cols = obj['columns'];
    if (cols is! List) return _emptyMatrix();

    final out = <List<int>>[];
    for (final c in cols) {
      if (c is! List) continue;
      final row = <int>[];
      for (final v in c) {
        if (v is int) {
          row.add(v);
        } else if (v is num) {
          row.add(v.toInt());
        }
      }
      // 不足 K 个时，用 rank-0 重复补足；超过 K 个时截断。
      if (row.isEmpty) continue;
      while (row.length < candidatesPerColumn) {
        row.add(row.first);
      }
      if (row.length > candidatesPerColumn) {
        row.removeRange(candidatesPerColumn, row.length);
      }
      out.add(row);
    }
    return out;
  }

  List<List<int>> _emptyMatrix() => const [];

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

class _WordEntry {
  const _WordEntry(this.word, this.id);

  final String word;
  final int id;
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
